# frozen_string_literal: true

require 'yaml'
require 'zlib'

module Async
  module Background
    class Runner
      # Pure schedule parsing and heap construction. It deliberately returns the
      # existing Hash contract from #build_task_config because specs and callers
      # use that shape while the Runner owns execution state.
      module Schedule
        private

        def build_heap(config_path)
          return MinHeap.new if config_path.nil?

          schedule = load_schedule(config_path)
          build_entries(schedule, monotonic_now)
        end

        def build_task_config(name, config)
          class_name = config&.dig('class').to_s.strip
          raise ConfigError, "[#{name}] missing class" if class_name.empty?

          job_class = resolve_scheduled_job(name, class_name)
          interval = parse_interval(name, config['every'])
          cron = parse_cron(name, config['cron'])
          validate_schedule_frequency!(name, interval, cron)

          {
            job_class: job_class,
            interval: interval,
            cron: cron,
            timeout: parse_timeout(name, config)
          }
        end

        def resolve_job_class(class_name)
          raise ConfigError, 'empty class name in queue job' if class_name.nil? || class_name.to_s.strip.empty?

          klass = class_name.split('::').reduce(Object) do |namespace, name|
            raise ConfigError, "unknown class: #{class_name}" unless namespace.const_defined?(name, false)

            namespace.const_get(name, false)
          end

          return klass if klass.respond_to?(:perform_now)

          raise ConfigError, "#{class_name} must include Async::Background::Job"
        end

        def load_schedule(path)
          raise ConfigError, "Schedule file not found: #{path}" unless File.exist?(path)

          YAML.safe_load_file(path).tap do |schedule|
            raise ConfigError, "Empty schedule: #{path}" unless schedule&.any?
          end
        end

        def build_entries(schedule, now)
          schedule
            .filter_map { |name, config| entry_for(name, config, now) }
            .each_with_object(MinHeap.new) { |entry, heap| heap.push(entry) }
        end

        def entry_for(name, config, now)
          return unless assigned_worker(config, name) == worker_index

          build_entry(name, build_task_config(name, config), now)
        end

        def assigned_worker(config, name)
          config['worker']&.to_i || ((Zlib.crc32(name) % total_workers) + 1)
        end

        def build_entry(name, task, now)
          Entry.new(
            name: name,
            job_class: task[:job_class],
            interval: task[:interval],
            cron: task[:cron],
            timeout: task[:timeout],
            next_run_at: initial_next_run_at(task, now)
          )
        end

        def initial_next_run_at(task, now)
          jitter = rand * [task[:interval] || MAX_JITTER, MAX_JITTER].min
          return now + jitter + task[:interval] if task[:interval]

          wall_now = Time.now
          wait = task[:cron].next_time(wall_now).to_f - wall_now.to_f
          now + jitter + [wait, MIN_SLEEP_TIME].max
        end

        def resolve_scheduled_job(name, class_name)
          resolve_job_class(class_name)
        rescue ConfigError => error
          raise ConfigError, "[#{name}] #{error.message}"
        end

        def parse_interval(name, value)
          return if value.nil?

          interval = value.to_i
          raise ConfigError, "[#{name}] 'every' must be > 0" unless interval.positive?

          interval
        end

        def parse_cron(name, value)
          return if value.nil?

          Fugit::Cron.new(value) || raise(ConfigError, "[#{name}] invalid cron: #{value}")
        end

        def parse_timeout(name, config)
          Job::Options.new(timeout: config.fetch('timeout', DEFAULT_TIMEOUT)).timeout
        rescue ArgumentError, TypeError => error
          raise ConfigError, "[#{name}] #{error.message}"
        end

        def validate_schedule_frequency!(name, interval, cron)
          return if interval || cron

          raise ConfigError, "[#{name}] specify 'every' or 'cron'"
        end
      end
    end
  end
end
