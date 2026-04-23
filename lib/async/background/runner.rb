# frozen_string_literal: true

require 'yaml'
require 'zlib'

module Async
  module Background
    class ConfigError < StandardError; end

    DEFAULT_TIMEOUT     = 30
    MIN_SLEEP_TIME      = 0.1
    MAX_JITTER          = 5
    QUEUE_POLL_INTERVAL = 5

    class Runner
      include Clock

      attr_reader :logger, :semaphore, :heap, :worker_index, :total_workers, :shutdown, :metrics, :queue_store

      def initialize(
        config_path:, job_count: 2, worker_index:, total_workers:,
        queue_socket_dir: nil, queue_db_path: nil, queue_mmap: true
      )
        @logger        = Console.logger
        @worker_index  = worker_index
        @total_workers = total_workers
        @running       = true
        @shutdown      = ::Async::Condition.new
        @metrics       = Metrics.new(worker_index: worker_index, total_workers: total_workers)

        logger.info { "Async::Background worker_index=#{worker_index}/#{total_workers}, job_count=#{job_count}" }

        @semaphore = ::Async::Semaphore.new(job_count)
        @heap      = build_heap(config_path)

        setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
      end

      def run
        Async do |task|
          setup_signal_handlers
          start_signal_watcher(task)
          start_queue_listener(task) if @listen_queue
          scheduler_loop(task)

          semaphore.acquire {}
          @queue_store&.close
          @queue_waker&.close
        end
      end

      def stop
        return unless @running

        @running = false
        logger.info { 'Async::Background: stopping gracefully' }
        shutdown.signal
        @queue_waker&.signal
      end

      def running?
        @running
      end

      private

      def setup_queue(queue_socket_dir, queue_db_path, queue_mmap)
        @listen_queue = false
        return unless queue_socket_dir
        return if isolated_worker?(worker_index)

        require_relative 'queue/store'
        require_relative 'queue/socket_waker'
        require_relative 'queue/client'

        @listen_queue = true
        @queue_store = Queue::Store.new(path: queue_db_path || Queue::Store.default_path, mmap: queue_mmap)

        socket_path = File.join(queue_socket_dir, "async_bg_worker_#{worker_index}.sock")
        @queue_waker = Queue::SocketWaker.new(socket_path)
        @queue_waker.open!

        recovered = @queue_store.recover(worker_index)
        logger.info { "Async::Background queue: recovered #{recovered} stale jobs" } if recovered.positive?
      end

      def isolated_worker?(index)
        ENV.fetch('ISOLATION_FORKS', '').split(',').map(&:to_i).include?(index)
      end

      def start_queue_listener(task)
        @queue_waker.start_accept_loop(task)

        task.async do
          logger.info { "Async::Background queue: listening on worker #{worker_index}" }

          while running?
            @queue_waker.wait(timeout: QUEUE_POLL_INTERVAL)
            drain_queue
          end
        end
      end

      def drain_queue
        while (job = @queue_store.fetch(worker_index))
          semaphore.async { |job_task| run_queue_job(job_task, job) }
        end
      end

      def run_queue_job(job_task, job)
        options = queue_job_options(job)
        job_class = resolve_job_class(job[:class_name])

        metrics.job_started(nil)
        duration = timed_run(job_task, options.timeout) { job_class.perform_now(*job[:args]) }
        metrics.job_finished(nil, duration)
        @queue_store.complete(job[:id])

        logger.info('Async::Background') { "queue(#{job[:class_name]}): completed in #{duration.round(2)}s" }
      rescue ::Async::TimeoutError
        metrics.job_timed_out(nil)
        handle_queue_retry(job, options, "timed out after #{options.timeout}s")
      rescue ConfigError => error
        metrics.job_failed(nil, error)
        fail_queue_job(job, format_error_message(error, backtrace: false))
      rescue => error
        metrics.job_failed(nil, error)
        handle_queue_retry(job, options || Job::Options.new, format_error_message(error))
      end

      def queue_job_options(job)
        Job::Options.new(**(job[:options] || {}))
      rescue ArgumentError, TypeError => error
        raise ConfigError, "invalid queue options: #{error.message}"
      end

      def resolve_job_class(class_name)
        class_name = class_name.to_s.strip
        raise ConfigError, 'empty class name in queue job' if class_name.empty?

        klass = class_name.split('::').reduce(Object) do |namespace, name|
          raise ConfigError, "unknown class: #{class_name}" unless namespace.const_defined?(name, false)

          namespace.const_get(name, false)
        end

        raise ConfigError, "#{class_name} must include Async::Background::Job" unless klass.respond_to?(:perform_now)

        klass
      end

      def handle_queue_retry(job, options, message)
        result = @queue_store.retry_or_fail(job[:id], options: options)

        if result == :retried
          attempt = options.next_attempt
          delay = options.next_retry_delay(attempt)
          @queue_waker&.signal
          logger.warn('Async::Background') do
            "queue(#{job[:class_name]}): #{message}; retry #{attempt}/#{options.retry_limit} in #{delay}s"
          end
        else
          logger.error('Async::Background') { "queue(#{job[:class_name]}): #{message}" }
        end
      end

      def fail_queue_job(job, message)
        @queue_store.fail(job[:id])
        logger.error('Async::Background') { "queue(#{job[:class_name]}): #{message}" }
      end

      def scheduler_loop(task)
        loop do
          entry = heap.peek
          break unless entry

          wait_with_shutdown(task, next_wait(entry))
          break unless running?

          run_due_entries
        end
      end

      def next_wait(entry)
        [entry.next_run_at - monotonic_now, MIN_SLEEP_TIME].max
      end

      def run_due_entries
        now = monotonic_now

        while (entry = heap.peek) && entry.next_run_at <= now
          break unless running?

          if entry.running
            logger.warn('Async::Background') { "#{entry.name}: skipped, previous run still active" }
            metrics.job_skipped(entry)
          else
            entry.running = true
            semaphore.async do |job_task|
              run_job(job_task, entry)
            ensure
              entry.running = false
            end
          end

          entry.reschedule(monotonic_now)
          heap.replace_top(entry)
        end
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

      def build_heap(config_path)
        raise ConfigError, "Schedule file not found: #{config_path}" unless File.exist?(config_path)

        schedule = YAML.safe_load_file(config_path)
        raise ConfigError, "Empty schedule: #{config_path}" unless schedule&.any?

        now = monotonic_now
        MinHeap.new.tap do |entries|
          schedule.each do |name, config|
            next unless worker_for(name, config) == worker_index

            task_config = build_task_config(name, config)
            entries.push(Entry.new(**task_config, name: name, next_run_at: initial_next_run_at(task_config, now)))
          end
        end
      end

      def worker_for(name, config)
        config&.[]('worker')&.to_i || ((Zlib.crc32(name) % total_workers) + 1)
      end

      def initial_next_run_at(task_config, monotonic_base)
        monotonic_base + jitter_for(task_config[:interval]) + schedule_delay(task_config)
      end

      def jitter_for(interval)
        rand * [interval || MAX_JITTER, MAX_JITTER].min
      end

      def schedule_delay(task_config)
        return task_config[:interval] if task_config[:interval]

        now_wall = Time.now
        wall_delay = task_config[:cron].next_time(now_wall).to_f - now_wall.to_f
        [wall_delay, MIN_SLEEP_TIME].max
      end

      def build_task_config(name, config)
        class_name = config&.dig('class').to_s.strip
        raise ConfigError, "[#{name}] missing class" if class_name.empty?

        {
          job_class: resolve_scheduled_job_class(name, class_name),
          interval: interval_for(name, config),
          cron: cron_for(name, config),
          timeout: timeout_for(name, config)
        }.tap do |task_config|
          raise ConfigError, "[#{name}] specify 'every' or 'cron'" unless task_config[:interval] || task_config[:cron]
        end
      end

      def resolve_scheduled_job_class(name, class_name)
        resolve_job_class(class_name)
      rescue ConfigError => error
        raise ConfigError, "[#{name}] #{error.message}"
      end

      def interval_for(name, config)
        value = config['every']
        return unless value

        Integer(value).tap do |interval|
          raise ConfigError, "[#{name}] 'every' must be > 0" unless interval.positive?
        end
      rescue ArgumentError, TypeError
        raise ConfigError, "[#{name}] 'every' must be > 0"
      end

      def cron_for(name, config)
        value = config['cron']
        return unless value

        Fugit::Cron.new(value) || raise(ConfigError, "[#{name}] invalid cron: #{value}")
      end

      def timeout_for(name, config)
        Job::Options.new(timeout: config.fetch('timeout', DEFAULT_TIMEOUT)).timeout
      rescue ArgumentError, TypeError => error
        raise ConfigError, "[#{name}] #{error.message}"
      end

      def run_job(job_task, entry)
        metrics.job_started(entry)
        duration = timed_run(job_task, entry.timeout) { entry.job_class.perform_now }
        metrics.job_finished(entry, duration)

        logger.info('Async::Background') { "#{entry.name}: completed in #{duration.round(2)}s" }
      rescue ::Async::TimeoutError
        metrics.job_timed_out(entry)
        logger.error('Async::Background') { "#{entry.name}: timed out after #{entry.timeout}s" }
      rescue => error
        metrics.job_failed(entry, error)
        logger.error('Async::Background') { "#{entry.name}: #{format_error_message(error)}" }
      end

      def timed_run(job_task, timeout)
        started_at = monotonic_now
        job_task.with_timeout(timeout) { yield }
        monotonic_now - started_at
      end

      def format_error_message(error, backtrace: true)
        lines = ["#{error.class} #{error.message}"]
        lines.concat(error.backtrace) if backtrace && error.backtrace
        lines.join("\n")
      end
    end
  end
end
