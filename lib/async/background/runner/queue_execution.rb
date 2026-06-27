# frozen_string_literal: true

module Async
  module Background
    class Runner
      # Queue-only lifecycle. Keeping it separate from recurring scheduling makes
      # the different delivery guarantees visible without adding runtime objects.
      module QueueExecution
        private

        def setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
          @listen_queue = !!queue_socket_dir && !isolated_worker?
          return unless @listen_queue

          require_relative '../queue/client'
          require_relative '../queue/socket_waker'
          require_relative '../queue/store'

          @queue_store = Queue::Store.new(
            path: queue_db_path || Queue::Store.default_path,
            options: {mmap: queue_mmap}
          )

          @queue_waker = Queue::SocketWaker.new(queue_socket_path(queue_socket_dir))
          @queue_waker.open!
          recover_queue_jobs
        end

        def start_queue_listener(task)
          @queue_waker.start_accept_loop(task)

          task.async do
            logger.info { "Async::Background queue: listening on worker #{worker_index}" }

            while running?
              @queue_waker.wait(timeout: next_wait_timeout)
              dispatch_available_queue_jobs
            end
          end
        end

        def next_wait_timeout
          next_due = @queue_store.next_pending_run_at
          return QUEUE_POLL_INTERVAL unless next_due

          remaining = next_due - realtime_now
          return MIN_QUEUE_WAIT if remaining <= 0

          [remaining, QUEUE_POLL_INTERVAL].min
        end

        def run_queue_job(job_task, job)
          class_name = job[:class_name]
          claim_token = job[:claim_token]
          options = nil
          started_at = nil
          metrics_started = false

          klass = resolve_job_class(class_name)
          options = parse_job_options(job[:options])
          return unless start_queue_job!(job, class_name, claim_token)

          metrics.job_started(nil)
          metrics_started = true
          started_at = monotonic_now
          job_task.with_timeout(options.timeout) { klass.perform_now(*job[:args]) }

          complete_queue_job!(job, class_name, claim_token, started_at)
        rescue ConfigError => error
          record_invalid_queue_job!(job, class_name, claim_token, error)
        rescue ::Async::TimeoutError => error
          handle_queue_failure(
            job,
            options,
            "timed out after #{options&.timeout}s",
            error: error,
            duration: started_at && (monotonic_now - started_at),
            timeout: true,
            backtrace: nil
          )
        rescue StandardError => error
          handle_queue_failure(
            job,
            options,
            "#{error.class} #{error.message}",
            error: error,
            duration: started_at && (monotonic_now - started_at),
            timeout: false,
            backtrace: error.backtrace
          )
        ensure
          metrics.job_stopped(nil) if metrics_started
        end

        def handle_queue_failure(job, options, message, error:, duration:, timeout:, backtrace:)
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
          result == :retried ? log_queue_retry(job, class_name, message, options) :
            log_queue_failure(class_name, message, backtrace)
        end

        def parse_job_options(raw)
          Job::Options.new(**(raw || {}))
        rescue ArgumentError, TypeError => error
          raise ConfigError, "invalid queue options: #{error.message}"
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
          while running?
            job = @queue_store.fetch(worker_index)
            break unless job

            semaphore.async { |job_task| run_queue_job(job_task, job) }
          end
        end

        def start_queue_job!(job, class_name, claim_token)
          return true if @queue_store.mark_started!(job[:id], claim_token: claim_token)

          logger.warn('Async::Background') {
            "queue(#{class_name}): lost lease before start for job #{job[:id]}, ignored"
          }
          false
        end

        def complete_queue_job!(job, class_name, claim_token, started_at)
          duration = monotonic_now - started_at
          if @queue_store.complete(job[:id], claim_token: claim_token, duration_ms: duration_ms(duration))
            metrics.job_succeeded(nil, duration)
            logger.info('Async::Background') { "queue(#{class_name}): completed in #{duration.round(2)}s" }
          else
            logger.warn('Async::Background') {
              "queue(#{class_name}): complete: stale lease for job #{job[:id]}, ignored"
            }
          end
        end

        def record_invalid_queue_job!(job, class_name, claim_token, error)
          recorded = @queue_store.fail(
            job[:id],
            claim_token: claim_token,
            error_class: error.class,
            error_message: error.message
          )
          metrics.job_failed(nil, error) if recorded
          logger.error('Async::Background') { "queue(#{class_name}): #{error.class} #{error.message}" }
        end

        def log_stale_queue_failure(job, class_name, timeout)
          logger.warn('Async::Background') do
            kind = timeout ? 'timeout' : 'failure'
            "queue(#{class_name}): #{kind} on stale lease for job #{job[:id]}, ignored"
          end
        end

        def log_queue_retry(job, class_name, message, options)
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
