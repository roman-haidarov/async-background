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
        logger.info { "Async::Background: stopping gracefully" }
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

        # Lazy require — only loaded when queue is actually used
        require_relative 'queue/store'
        require_relative 'queue/socket_waker'
        require_relative 'queue/client'

        isolated = ENV.fetch("ISOLATION_FORKS", "").split(",").map(&:to_i)
        return if isolated.include?(worker_index)

        @listen_queue = true
        @queue_store  = Queue::Store.new(
          path: queue_db_path || Queue::Store.default_path,
          mmap: queue_mmap
        )

        socket_path = File.join(queue_socket_dir, "async_bg_worker_#{worker_index}.sock")
        @queue_waker = Queue::SocketWaker.new(socket_path)
        @queue_waker.open!

        recovered = @queue_store.recover(worker_index)
        logger.info { "Async::Background queue: recovered #{recovered} stale jobs" } if recovered > 0
      end

      def start_queue_listener(task)
        @queue_waker.start_accept_loop(task)

        task.async do
          logger.info { "Async::Background queue: listening on worker #{worker_index}" }

          while running?
            @queue_waker.wait(timeout: QUEUE_POLL_INTERVAL)

            while running?
              job = @queue_store.fetch(worker_index)
              break unless job

              semaphore.async { |job_task| run_queue_job(job_task, job) }
              sleep(0)
            end
          end
        end
      end

      def run_queue_job(job_task, job)
        class_name = job[:class_name]
        args       = job[:args]
        klass      = resolve_job_class(class_name)

        metrics.job_started(nil)
        t = monotonic_now

        job_task.with_timeout(DEFAULT_TIMEOUT) { klass.perform_now(*args) }

        duration = monotonic_now - t
        metrics.job_finished(nil, duration)
        @queue_store.complete(job[:id])

        logger.info('Async::Background') {
          "queue(#{class_name}): completed in #{duration.round(2)}s"
        }
      rescue ::Async::TimeoutError
        metrics.job_timed_out(nil)
        @queue_store.fail(job[:id])
        logger.error('Async::Background') { "queue(#{class_name}): timed out" }
      rescue => e
        metrics.job_failed(nil, e)
        @queue_store.fail(job[:id])
        logger.error('Async::Background') {
          "queue(#{class_name}): #{e.class} #{e.message}\n#{e.backtrace.join("\n")}"
        }
      end

      def resolve_job_class(class_name)
        raise ConfigError, "empty class name in queue job" if class_name.nil? || class_name.strip.empty?

        names = class_name.split("::")
        klass = names.reduce(Object) do |mod, name|
          raise ConfigError, "unknown class: #{class_name}" unless mod.const_defined?(name, false)
          mod.const_get(name, false)
        end

        raise ConfigError, "#{class_name} must include Async::Background::Job" unless klass.respond_to?(:perform_now)

        klass
      end

      def scheduler_loop(task)
        loop do
          entry = heap.peek
          break unless entry

          now = monotonic_now
          wait = [entry.next_run_at - now, MIN_SLEEP_TIME].max
          wait_with_shutdown(task, wait)
          break unless running?

          now = monotonic_now
          while (entry = heap.peek) && entry.next_run_at <= now
            break unless running?

            if entry.running
              logger.warn('Async::Background') { "#{entry.name}: skipped, previous run still active" }
              metrics.job_skipped(entry)
              entry.reschedule(monotonic_now)
              heap.replace_top(entry)
              next
            end

            entry.running = true
            semaphore.async do |job_task|
              run_job(job_task, entry)
            ensure
              entry.running = false
            end

            entry.reschedule(monotonic_now)
            heap.replace_top(entry)
          end
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

        raw = YAML.safe_load_file(config_path)
        raise ConfigError, "Empty schedule: #{config_path}" unless raw&.any?

        heap = MinHeap.new
        now  = monotonic_now

        raw.each do |name, config|
          assigned = config['worker']&.to_i || ((Zlib.crc32(name) % total_workers) + 1)
          next unless assigned == worker_index

          task_config = build_task_config(name, config)
          jitter = rand * [task_config[:interval] || MAX_JITTER, MAX_JITTER].min

          next_run_at = if task_config[:interval]
            now + jitter + task_config[:interval]
          else
            now_wall = Time.now
            wall_wait = task_config[:cron].next_time(now_wall).to_f - now_wall.to_f
            now + jitter + [wall_wait, MIN_SLEEP_TIME].max
          end

          heap.push(Entry.new(
            name:        name,
            job_class:   task_config[:job_class],
            interval:    task_config[:interval],
            cron:        task_config[:cron],
            timeout:     task_config[:timeout],
            next_run_at: next_run_at
          ))
        end

        heap
      end

      def build_task_config(name, config)
        class_name = config&.dig('class').to_s.strip
        raise ConfigError, "[#{name}] missing class" if class_name.empty?

        begin
          job_class = Object.const_get(class_name)
        rescue NameError
          raise ConfigError, "[#{name}] unknown class: #{class_name}"
        end

        raise ConfigError, "[#{name}] #{class_name} must include Async::Background::Job" unless job_class.respond_to?(:perform_now)

        interval = config['every']&.then { |v|
          int = v.to_i
          raise ConfigError, "[#{name}] 'every' must be > 0" unless int.positive?
          int
        }

        cron = config['cron']&.then { |c|
          Fugit::Cron.new(c) || raise(ConfigError, "[#{name}] invalid cron: #{c}")
        }

        raise ConfigError, "[#{name}] specify 'every' or 'cron'" unless interval || cron

        {
          job_class: job_class,
          interval: interval,
          cron: cron,
          timeout: config.fetch('timeout', DEFAULT_TIMEOUT).to_i
        }
      end

      def run_job(job_task, entry)
        metrics.job_started(entry)
        t = monotonic_now
        job_task.with_timeout(entry.timeout) { entry.job_class.perform_now }

        duration = monotonic_now - t
        metrics.job_finished(entry, duration)
        logger.info('Async::Background') {
          "#{entry.name}: completed in #{duration.round(2)}s"
        }
      rescue ::Async::TimeoutError
        metrics.job_timed_out(entry)
        logger.error('Async::Background') { "#{entry.name}: timed out after #{entry.timeout}s" }
      rescue => e
        metrics.job_failed(entry, e)
        logger.error('Async::Background') {
          "#{entry.name}: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}"
        }
      end
    end
  end
end
