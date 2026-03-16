# frozen_string_literal: true

require 'yaml'
require 'zlib'

module Async
  module Background
    class ConfigError < StandardError; end

    DEFAULT_TIMEOUT = 30
    MIN_SLEEP_TIME  = 0.1
    MAX_JITTER      = 5

    class Runner
      attr_reader :logger, :semaphore, :heap, :worker_index, :total_workers

      def initialize(config_path:, job_count: 2, worker_index:, total_workers:)
        @logger        = Console.logger
        @worker_index  = worker_index
        @total_workers = total_workers
        @running       = true

        logger.info { "Async::Background worker_index=#{worker_index}/#{total_workers}, job_count=#{job_count}" }

        @semaphore = ::Async::Semaphore.new(job_count)
        @heap      = build_heap(config_path)
      end

      def run
        Async do |task|
          while true
            entry = heap.peek
            break unless entry

            now = monotonic_now
            wait = [entry.next_run_at - now, MIN_SLEEP_TIME].max
            task.sleep wait
            break unless running?

            now = monotonic_now
            while (top = heap.peek) && top.next_run_at <= now
              break unless running?

              entry = heap.pop

              if entry.running
                logger.warn('Async::Background') { "#{entry.name}: skipped, previous run still active" }
              else
                entry.running = true
                semaphore.async(parent: task) do
                  run_job(task, entry)
                ensure
                  entry.running = false
                end
              end

              entry.reschedule(monotonic_now)
              heap.push(entry)
            end
          end

          semaphore.wait
        end
      end

      def stop
        @running = false
        logger.info { "Async::Background: stopping gracefully" }
      end

      def running?
        @running
      end

      private

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

        raise ConfigError, "[#{name}] #{class_name} must implement .perform_now" unless job_class.respond_to?(:perform_now)

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

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def run_job(task, entry)
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        task.with_timeout(entry.timeout) { entry.job_class.perform_now }
        logger.info('Async::Background') {
          "#{entry.name}: completed in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(2)}s"
        }
      rescue ::Async::TimeoutError
        logger.error('Async::Background') { "#{entry.name}: timed out after #{entry.timeout}s" }
      rescue => e
        logger.error('Async::Background') {
          "#{entry.name}: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}"
        }
      end
    end
  end
end
