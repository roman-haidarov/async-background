# frozen_string_literal: true

require 'async/barrier'

require_relative 'runner/queue_execution'
require_relative 'runner/schedule'

module Async
  module Background
    class ConfigError < StandardError; end

    DEFAULT_TIMEOUT = 30
    MIN_SLEEP_TIME = 0.1
    MAX_JITTER = 5
    QUEUE_POLL_INTERVAL = 5
    MIN_QUEUE_WAIT = 0.001

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
                  :queue_store

      # `config_path: nil` explicitly disables recurring jobs. This keeps the
      # dynamic SQLite queue usable on its own; a supplied path remains strict
      # so a typo cannot silently disable scheduled work.
      def initialize(
        config_path: nil,
        job_count: 2,
        worker_index:,
        total_workers:,
        queue_socket_dir: nil,
        queue_db_path: nil,
        queue_mmap: true,
        metrics_shm_path: Metrics.default_shm_path
      )
        @logger = Console.logger
        @worker_index = worker_index
        @total_workers = total_workers
        @running = true
        @shutdown = ::Async::Condition.new
        @metrics = Metrics.new(
          worker_index: worker_index,
          total_workers: total_workers,
          shm_path: metrics_shm_path
        )
        logger.info { "Async::Background worker_index=#{worker_index}/#{total_workers}, job_count=#{job_count}" }

        @drain_barrier = ::Async::Barrier.new
        @semaphore = ::Async::Semaphore.new(job_count, parent: @drain_barrier)
        @heap = config_path.nil? ? MinHeap.new : build_heap(config_path)
        setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
        validate_work_source!(config_path)
      end

      def run
        Async do |task|
          setup_signal_handlers
          start_signal_watcher(task)
          start_queue_listener(task) if @listen_queue

          scheduler_loop(task)
          drain_and_close_queue
        end
      end

      def stop
        return unless @running

        @running = false
        logger.info { 'Async::Background: stopping gracefully' }
        shutdown.signal
        @queue_waker&.signal
      end

      def running? = @running

      private

      def scheduler_loop(task)
        # Queue-only workers have no heap entry to sleep on. Keep the runner
        # alive until #stop / SIGTERM wakes this condition; the queue listener
        # continues independently in its own Async task.
        return shutdown.wait if heap.empty? && @listen_queue

        loop do
          entry = heap.peek
          break unless entry

          wait_for_next_entry(task, entry)
          break unless running?

          dispatch_due_entries
        end
      end

      def validate_work_source!(config_path)
        return unless config_path.nil? && !@listen_queue

        raise ConfigError, 'Runner requires config_path or queue_socket_dir'
      end

      def wait_for_next_entry(task, entry)
        wait = [entry.next_run_at - monotonic_now, MIN_SLEEP_TIME].max
        wait_with_shutdown(task, wait)
      end

      def dispatch_due_entries
        now = monotonic_now
        while (entry = heap.peek) && entry.next_run_at <= now
          break unless running?

          dispatch_entry(entry)
        end
      end

      def dispatch_entry(entry)
        if entry.running
          skip_entry(entry)
        else
          execute_entry(entry)
        end

        entry.reschedule(monotonic_now)
        heap.replace_top(entry)
      end

      def skip_entry(entry)
        logger.warn('Async::Background') { "#{entry.name}: skipped, previous run still active" }
        metrics.job_skipped(entry)
      end

      def execute_entry(entry)
        entry.running = true
        semaphore.async do |job_task|
          run_job(job_task, entry)
        ensure
          entry.running = false
        end
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
      rescue ::Async::TimeoutError
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

      def start_signal_watcher(task)
        task.async(transient: true) do
          loop do
            @signal_r.wait_readable
            @signal_r.read_nonblock(256) rescue nil
            shutdown.signal
            @queue_waker&.signal
            break unless running?
          end
        end
      end

      def wait_with_shutdown(task, duration)
        task.with_timeout(duration) { shutdown.wait }
      rescue ::Async::TimeoutError
      end

      def drain_and_close_queue
        @drain_barrier.wait
        @queue_store&.close
        @queue_waker&.close
      end
    end
  end
end
