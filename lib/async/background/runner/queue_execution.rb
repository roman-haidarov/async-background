# frozen_string_literal: true

module Async
  module Background
    class Runner
      # Queue-only lifecycle. Keeping it separate from recurring scheduling makes
      # the different delivery guarantees visible without adding runtime objects.
      module QueueExecution
        QueueRun = Data.define(:job, :class_name, :claim_token, :options, :started_at, :job_class)
        QueueFailure = Data.define(:job, :options, :message, :error, :duration, :timeout, :backtrace)
        private_constant :QueueRun, :QueueFailure

        private

        def setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
          @queue_saturated = false
          @listen_queue = !queue_socket_dir.nil? && !isolated_worker?
          return unless @listen_queue

          require_relative '../queue/client'
          require_relative '../queue/socket_waker'
          require_relative '../queue/store'

          @queue_store = Queue::Store.new(
            path: queue_db_path || Queue::Store.default_path,
            options: { mmap: queue_mmap }
          )

          @queue_waker = Queue::SocketWaker.new(queue_socket_path(queue_socket_dir))
          @queue_waker.open!
          recover_queue_jobs
        end

        def start_queue_listener
          @queue_waker.start_accept_loop

          @services.spawn(name: 'queue-listener') do
            logger.info { "Async::Background queue: listening on worker #{worker_index}" }

            failures = 0

            while running?
              begin
                @queue_waker.wait(timeout: next_wait_timeout)
                break unless running?

                dispatch_available_queue_jobs
                failures = 0
              rescue StandardError => e
                failures += 1
                backoff = [QUEUE_ERROR_BACKOFF * failures, QUEUE_POLL_INTERVAL].min
                logger.error('Async::Background') do
                  "queue listener: #{e.class} #{e.message}; retrying in #{backoff}s"
                end
                shutdown.wait(backoff)
              end
            end
          end
        end

        def next_wait_timeout
          return QUEUE_POLL_INTERVAL if @queue_saturated

          next_due = @queue_store.next_pending_run_at
          return QUEUE_POLL_INTERVAL unless next_due

          remaining = next_due - realtime_now
          return MIN_QUEUE_WAIT if remaining <= 0

          [remaining, QUEUE_POLL_INTERVAL].min
        end

        def run_queue_job(job_task, job)
          context = QueueRun.new(job, job[:class_name], job[:claim_token], nil, nil, nil)
          context = resolve_queue_run(context)
          metrics_started = false
          metrics_started = start_queue_metrics(context)
          return unless metrics_started

          context = context.with(started_at: monotonic_now)
          perform_queue_run(job_task, context)
          complete_queue_job!(context)
        rescue ConfigError => e
          record_invalid_queue_job!(context, e)
        rescue Runtime::TimeoutError => e
          handle_queue_failure(queue_failure(context, e, timeout: true))
        rescue StandardError => e
          handle_queue_failure(queue_failure(context, e, timeout: false))
        ensure
          metrics.job_stopped(nil) if metrics_started
        end

        def resolve_queue_run(context)
          job, class_name, = context.deconstruct
          job_class = resolve_job_class(class_name)
          options = parse_job_options(job[:options])
          context.with(options: options, job_class: job_class)
        end

        def start_queue_metrics(context)
          job, class_name, claim_token, = context.deconstruct
          return false unless start_queue_job!(job, class_name, claim_token)

          metrics.job_started(nil)
          true
        end

        def perform_queue_run(job_task, context)
          job, _class_name, _claim_token, options, _started_at, job_class = context.deconstruct
          job_task.with_timeout(options.timeout) do
            job_class.perform_now(*job[:args])
          end
        end

        def queue_failure(context, error, timeout:)
          job, _class_name, _claim_token, options, started_at = context.deconstruct
          message = timeout ? "timed out after #{options&.timeout}s" : "#{error.class} #{error.message}"
          duration = started_at && (monotonic_now - started_at)
          QueueFailure.new(job, options, message, error, duration, timeout, timeout ? nil : error.backtrace)
        end

        def handle_queue_failure(failure)
          job, options, message, error, duration, timeout, backtrace = failure.deconstruct
          class_name = job[:class_name]
          result = @queue_store.retry_or_fail(
            job[:id],
            claim_token: job[:claim_token],
            error_class: error.class,
            error_message: timeout ? message : error.message,
            fallback_options: options,
            duration_ms: duration_ms(duration)
          )
          return log_stale_queue_failure(job, class_name, timeout) unless result

          timeout ? metrics.job_timed_out(nil) : metrics.job_failed(nil, error)
          if result == :retried
            log_queue_retry(job, class_name, message, options)
          else
            log_queue_failure(class_name, message, backtrace)
          end
        end

        def parse_job_options(raw)
          Job::Options.new(**(raw || {}))
        rescue ArgumentError, TypeError => e
          raise ConfigError, "invalid queue options: #{e.message}"
        end

        def isolated_worker?
          ENV.fetch('ISOLATION_FORKS', '').split(',').map(&:to_i).include?(worker_index)
        end

        def queue_socket_path(directory)
          File.join(directory, "async_bg_worker_#{worker_index}.sock")
        end

        def recover_queue_jobs
          recovered = @queue_store.recover(worker_index)
          logger.info { "Async::Background queue: recovered #{recovered} stale jobs" } if recovered.positive?
        end

        def dispatch_available_queue_jobs
          @queue_saturated = false

          while running?
            if @jobs.size >= @semaphore.limit
              @queue_saturated = true
              return
            end

            job = @queue_store.fetch(worker_index)
            return if job.nil?

            spawn_job { |job_task| run_queue_job(job_task, job) }
          end
        end

        def start_queue_job!(job, class_name, claim_token)
          return true if @queue_store.mark_started!(job[:id], claim_token: claim_token)

          logger.warn('Async::Background') do
            "queue(#{class_name}): lost lease before start for job #{job[:id]}, ignored"
          end
          false
        end

        def complete_queue_job!(context)
          job, class_name, claim_token, _options, started_at = context.deconstruct
          duration = monotonic_now - started_at
          if @queue_store.complete(job[:id], claim_token: claim_token, duration_ms: duration_ms(duration))
            metrics.job_succeeded(nil, duration)
            logger.info('Async::Background') do
              "queue(#{class_name}): completed in #{duration.round(2)}s"
            end
          else
            logger.warn('Async::Background') do
              "queue(#{class_name}): complete: stale lease for job #{job[:id]}, ignored"
            end
          end
        end

        def record_invalid_queue_job!(context, error)
          job, class_name, claim_token, = context.deconstruct
          recorded = @queue_store.fail(
            job[:id],
            claim_token: claim_token,
            error_class: error.class,
            error_message: error.message
          )
          metrics.job_failed(nil, error) if recorded
          logger.error('Async::Background') do
            "queue(#{class_name}): #{error.class} #{error.message}"
          end
        end

        def log_stale_queue_failure(job, class_name, timeout)
          logger.warn('Async::Background') do
            kind = timeout ? 'timeout' : 'failure'
            "queue(#{class_name}): #{kind} on stale lease for job #{job[:id]}, ignored"
          end
        end

        def log_queue_retry(_job, class_name, message, options)
          @queue_waker&.signal
          logger.warn('Async::Background') do
            "queue(#{class_name}): #{message}; retry #{options&.next_attempt}/#{options&.retry}"
          end
        end

        def log_queue_failure(class_name, message, backtrace)
          tail = backtrace ? "\n#{backtrace.join("\n")}" : ''
          logger.error('Async::Background') { "queue(#{class_name}): #{message}#{tail}" }
        end

        def duration_ms(duration)
          return if duration.nil? || duration.negative?

          (duration * 1000).to_i
        end
      end
    end
  end
end
