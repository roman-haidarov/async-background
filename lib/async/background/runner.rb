# frozen_string_literal: true

require_relative 'runtime'
require_relative 'runner/lifecycle'
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
      include Lifecycle
      include QueueExecution
      include Schedule

      Settings = Data.define(
        :config_path, :job_count, :queue_socket_dir, :queue_db_path, :queue_mmap,
        :drain_timeout, :metrics_shm_path
      )
      private_constant :Settings

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

      def initialize(worker_index:, total_workers:, **options)
        settings = Settings.new(**default_settings.merge(options))
        initialize_worker(worker_index, total_workers, settings)
      end

      def default_settings
        {
          config_path: nil,
          job_count: 2,
          queue_socket_dir: nil,
          queue_db_path: nil,
          queue_mmap: true,
          drain_timeout: DRAIN_GRACE,
          metrics_shm_path: Metrics.default_shm_path
        }
      end

      def initialize_worker(worker_index, total_workers, settings)
        config_path = settings.config_path
        job_count = settings.job_count
        @logger = Console.logger
        @worker_index = worker_index
        @total_workers = total_workers
        @running = true
        @drain_timeout = settings.drain_timeout
        @shutdown = Runtime::Notification.new
        @metrics = Metrics.new(worker_index: worker_index, total_workers: total_workers, shm_path: settings.metrics_shm_path)
        logger.info { "Async::Background worker_index=#{worker_index}/#{total_workers}, job_count=#{job_count}" }

        @jobs = Runtime::TaskGroup.new(on_error: error_handler, on_release: method(:job_released))
        @services = Runtime::TaskGroup.new(on_error: error_handler)
        @semaphore = Runtime::Semaphore.new(job_count)
        @heap = config_path.nil? ? MinHeap.new : build_heap(config_path)
        setup_queue(settings.queue_socket_dir, settings.queue_db_path, settings.queue_mmap)
        validate_work_source!(config_path)
      end
      private :default_settings, :initialize_worker

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

      def spawn_job
        @jobs.spawn(name: 'job') { |task| semaphore.acquire { yield(task) } }
      end

      def job_released(_task)
        return unless @queue_saturated

        @queue_waker&.signal
      end

      def run_job(job_task, entry)
        metrics_started = false
        metrics_started = start_job_metrics(entry)
        execute_entry_job(job_task, entry)
      rescue Runtime::TimeoutError
        record_job_timeout(entry)
      rescue StandardError => e
        record_job_failure(entry, e)
      ensure
        metrics.job_stopped(entry) if metrics_started
      end

      def start_job_metrics(entry)
        metrics.job_started(entry)
        true
      end

      def execute_entry_job(job_task, entry)
        started_at = monotonic_now
        job_task.with_timeout(entry.timeout) { entry.job_class.perform_now }
        record_job_success(entry, monotonic_now - started_at)
      end

      def record_job_success(entry, duration)
        metrics.job_succeeded(entry, duration)
        logger.info('Async::Background') { "#{entry.name}: completed in #{duration.round(2)}s" }
      end

      def record_job_timeout(entry)
        metrics.job_timed_out(entry)
        logger.error('Async::Background') { "#{entry.name}: timed out after #{entry.timeout}s" }
      end

      def record_job_failure(entry, error)
        metrics.job_failed(entry, error)
        logger.error('Async::Background') do
          "#{entry.name}: #{error.class} #{error.message}\n#{error.backtrace.join("\n")}"
        end
      end

      def wait_with_shutdown(duration)
        shutdown.wait(duration)
      end
    end
  end
end
