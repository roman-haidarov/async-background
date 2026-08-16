# frozen_string_literal: true

require_relative 'runtime'
require_relative 'runner/queue_execution'
require_relative 'runner/schedule'

module Async
  module Background
    class ConfigError < Error; end

    DEFAULT_TIMEOUT = 30
    MIN_SLEEP_TIME = 0.1
    MAX_JITTER = 5
    QUEUE_POLL_INTERVAL = 5
    MIN_QUEUE_WAIT = 0.001
    QUEUE_ERROR_BACKOFF = 0.5
    SERVICE_SHUTDOWN_GRACE = 5
    SERVICE_CANCEL_GRACE = 2
    DRAIN_GRACE = 30
    JOB_CANCEL_GRACE = 5

    class Runner
      include Clock
      include QueueExecution
      include Schedule

      attr_reader :logger,
                  :semaphore,
                  :heap,
                  :worker_index,
                  :total_workers,
                  :shutdown,
                  :metrics,
                  :queue_store,
                  :jobs,
                  :services

      def initialize(
        config_path: nil,
        job_count: 2,
        worker_index:,
        total_workers:,
        queue_socket_dir: nil,
        queue_db_path: nil,
        queue_mmap: true,
        drain_timeout: DRAIN_GRACE,
        metrics_shm_path: Metrics.default_shm_path
      )
        @logger = Console.logger
        @worker_index = worker_index
        @total_workers = total_workers
        @running = true
        @drain_timeout = drain_timeout
        @shutdown = Runtime::Notification.new
        @metrics = Metrics.new(worker_index: worker_index, total_workers: total_workers, shm_path: metrics_shm_path)
        logger.info { "Async::Background worker_index=#{worker_index}/#{total_workers}, job_count=#{job_count}" }

        @jobs = Runtime::TaskGroup.new(on_error: error_handler, on_release: method(:job_released))
        @services = Runtime::TaskGroup.new(on_error: error_handler)
        @semaphore = Runtime::Semaphore.new(job_count)
        @heap = config_path.nil? ? MinHeap.new : build_heap(config_path)
        setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
        validate_work_source!(config_path)
      end

      def run
        Runtime.scheduler!
        warn_unsafe_timeouts

        Runtime.with_error_handler(error_handler) do
          setup_signal_handlers
          start_signal_watcher
          start_queue_listener if @listen_queue

          scheduler_loop
          shutdown_gracefully
        end
      end

      def stop
        return unless @running

        @running = false
        wake_signal_watcher
      end

      def running? = @running

      private

      def scheduler_loop
        return shutdown.wait if heap.empty? && @listen_queue

        while running?
          entry = heap.peek
          break unless entry

          wait_for_next_entry(entry)
          break unless running?

          dispatch_due_entries
        end
      end

      def validate_work_source!(config_path)
        return unless config_path.nil? && !@listen_queue

        raise ConfigError, 'Runner requires config_path or queue_socket_dir'
      end

      def wait_for_next_entry(entry)
        wait = [entry.next_run_at - monotonic_now, MIN_SLEEP_TIME].max
        wait_with_shutdown(wait)
      end

      def dispatch_due_entries
        now = monotonic_now
        while (entry = heap.peek) && entry.next_run_at <= now
          break unless running?

          dispatch_entry(entry)
        end
      end

      def dispatch_entry(entry)
        entry.running ? skip_entry(entry) : execute_entry(entry)
        entry.reschedule(monotonic_now)
        heap.replace_top(entry)
      end

      def skip_entry(entry)
        logger.warn('Async::Background') { "#{entry.name}: skipped, previous run still active" }
        metrics.job_skipped(entry)
      end

      def execute_entry(entry)
        entry.running = true
        spawn_job do |job_task|
          run_job(job_task, entry)
        ensure
          entry.running = false
        end
      end

      def spawn_job(&block)
        @jobs.spawn(name: 'job') { |task| semaphore.acquire { block.call(task) } }
      end

      def job_released(_task)
        return unless @queue_saturated

        @queue_waker&.signal
      end

      def run_job(job_task, entry)
        metrics_started = false
        metrics.job_started(entry)
        metrics_started = true
        started_at = monotonic_now
        job_task.with_timeout(entry.timeout) { entry.job_class.perform_now }

        duration = monotonic_now - started_at
        metrics.job_succeeded(entry, duration)
        logger.info('Async::Background') { "#{entry.name}: completed in #{duration.round(2)}s" }
      rescue Runtime::TimeoutError
        metrics.job_timed_out(entry)
        logger.error('Async::Background') { "#{entry.name}: timed out after #{entry.timeout}s" }
      rescue StandardError => error
        metrics.job_failed(entry, error)
        logger.error('Async::Background') {
          "#{entry.name}: #{error.class} #{error.message}\n#{error.backtrace.join("\n")}"
        }
      ensure
        metrics.job_stopped(entry) if metrics_started
      end

      def setup_signal_handlers
        @signal_r, @signal_w = IO.pipe

        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            @running = false
            @signal_w.write_nonblock('.') rescue nil
          end
        end
      end

      def start_signal_watcher
        @services.spawn(name: 'signal-watcher') do
          while running?
            begin
              @signal_r.wait_readable
              @signal_r.read_nonblock(256)
            rescue IO::WaitReadable
              next
            rescue IOError, Errno::EBADF
              break
            end

            logger.info { 'Async::Background: stopping gracefully' } unless running?

            shutdown.signal_all
            @queue_waker&.signal
          end
        end
      end

      def error_handler
        @error_handler ||= begin
          log = logger
          lambda do |task, error|
            log.error('Async::Background') do
              "task #{task&.name || 'unnamed'} died: #{error.class} #{error.message}\n" \
                "#{Array(error.backtrace).join("\n")}"
            end
          end
        end
      end

      def warn_unsafe_timeouts
        return if Runtime.native_timeouts?

        logger.warn('Async::Background') do
          "#{Fiber.scheduler.class} does not implement #timeout_after; job timeouts " \
            'fall back to stdlib Timeout and may interrupt an unrelated fiber'
        end
      end

      def wake_signal_watcher
        @signal_w&.write_nonblock('.')
      rescue StandardError
        nil
      end

      def wait_with_shutdown(duration)
        shutdown.wait(duration)
      end

      def shutdown_gracefully
        wake_services
        drain_jobs
        stop_services
        close_queue
        close_signal_pipe
      end

      def wake_services
        shutdown.signal_all
        wake_signal_watcher
        @queue_waker&.signal
      end

      def drain_jobs
        return if @jobs.empty?

        logger.info { "Async::Background: draining #{@jobs.size} in-flight job(s)" }
        @jobs.wait(@drain_timeout)
      rescue Runtime::TimeoutError
        logger.warn('Async::Background') do
          "#{@jobs.size} job(s) still running after #{@drain_timeout}s, cancelling"
        end
        @jobs.stop_all(JOB_CANCEL_GRACE)
      end

      def stop_services
        return if @services.empty?

        @services.wait(SERVICE_SHUTDOWN_GRACE)
      rescue Runtime::TimeoutError
        logger.warn('Async::Background') { 'service tasks did not exit in time, cancelling' }
        @services.stop_all(SERVICE_CANCEL_GRACE)
      end

      def close_queue
        @queue_waker&.close
        @queue_store&.close
      end

      def close_signal_pipe
        @signal_r&.close
        @signal_w&.close
      rescue IOError
        nil
      end
    end
  end
end
