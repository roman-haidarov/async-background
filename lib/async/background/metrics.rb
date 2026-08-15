# frozen_string_literal: true

require 'tmpdir'

module Async
  module Background
    class Metrics
      SCHEMA_FIELDS = {
        total_runs: :u64,
        total_successes: :u64,
        total_failures: :u64,
        total_timeouts: :u64,
        total_skips: :u64,
        active_jobs: :u32,
        last_run_at: :u64,
        last_duration_ms: :u32
      }.freeze

      EMPTY_HANDLES = {}.freeze

      attr_reader :registry, :shm_path, :unavailable_reason

      def initialize(worker_index:, total_workers:, shm_path: self.class.default_shm_path)
        @enabled = false
        @registry = nil
        @metric_handles = EMPTY_HANDLES
        @shm_path = shm_path
        @unavailable_reason = nil

        validate_worker!(worker_index, total_workers)
        initialize_registry!(worker_index, total_workers, shm_path)
      rescue LoadError => error
        mark_unavailable!(error)
      end

      def enabled? = @enabled

      def job_started(_entry)
        return unless enabled?

        increment(:total_runs)
        increment(:active_jobs)
        set(:last_run_at, Process.clock_gettime(Process::CLOCK_REALTIME).to_i)
      end

      def job_succeeded(_entry, duration)
        return unless enabled?

        increment(:total_successes)
        set(:last_duration_ms, duration_to_milliseconds(duration))
      end

      def job_finished(entry, duration)
        job_succeeded(entry, duration)
        job_stopped(entry)
      end

      def job_failed(_entry, _error)
        increment(:total_failures) if enabled?
      end

      def job_timed_out(_entry)
        increment(:total_timeouts) if enabled?
      end

      def job_stopped(_entry)
        decrement(:active_jobs) if enabled?
      end

      def job_skipped(_entry)
        increment(:total_skips) if enabled?
      end

      def values
        enabled? ? registry.values : {}
      end

      class << self
        def available?
          load_utilization!
          true
        rescue LoadError
          false
        end

        def load_utilization!
          require 'async/utilization'
        end

        def schema
          load_utilization!
          ::Async::Utilization::Schema.build(SCHEMA_FIELDS)
        end

        def read_all(total_workers:, path: default_shm_path)
          validate_total_workers!(total_workers)
          return [] unless available? && File.file?(path)

          layout = schema
          segment = segment_size
          required_size = segment * total_workers

          File.open(path, 'rb') do |file|
            return [] if file.size < required_size

            buffer = IO::Buffer.map(file, required_size, 0, IO::Buffer::READONLY)
            decode_workers(buffer, layout, segment, total_workers)
          end
        rescue Errno::ENOENT
          []
        end

        def default_shm_path
          ENV.fetch('ASYNC_BACKGROUND_METRICS_PATH') { File.join(Dir.tmpdir, 'async-background.shm') }
        end

        def segment_size
          SCHEMA_FIELDS.sum { |_, type| IO::Buffer.size_of(type) }
        end

        private

        def validate_total_workers!(total_workers)
          return if total_workers.is_a?(Integer) && total_workers.positive?

          raise ArgumentError, 'total_workers must be a positive Integer'
        end

        def decode_workers(buffer, schema, segment, total_workers)
          (1..total_workers).map { |worker| decode_worker(buffer, schema, segment, worker) }.freeze
        end

        def decode_worker(buffer, schema, segment, worker)
          offset = (worker - 1) * segment
          schema.fields.each_with_object(worker: worker) do |field, values|
            values[field.name] = buffer.get_value(field.type, offset + field.offset)
          end.freeze
        end
      end

      private

      def initialize_registry!(worker_index, total_workers, path)
        self.class.load_utilization!
        ensure_shm!(total_workers, path)

        @registry = ::Async::Utilization::Registry.new
        unless @registry.respond_to?(:metric)
          raise LoadError, 'async-utilization >= 0.3 is required for metrics'
        end

        attach_observer!(worker_index, path)
        @metric_handles = SCHEMA_FIELDS.keys.to_h { |name| [name, @registry.metric(name)] }.freeze
        @enabled = true
      end

      def mark_unavailable!(error)
        @registry = nil
        @metric_handles = EMPTY_HANDLES
        @unavailable_reason = error.message
      end

      def increment(name)
        metric(name).increment
      end

      def decrement(name)
        metric(name).decrement
      end

      def set(name, value)
        metric(name).set(value)
      end

      def metric(name)
        @metric_handles.fetch(name)
      end

      def duration_to_milliseconds(duration)
        (duration * 1000).to_i
      end

      def validate_worker!(worker_index, total_workers)
        self.class.send(:validate_total_workers!, total_workers)
        return if worker_index.is_a?(Integer) && worker_index.between?(1, total_workers)

        raise ArgumentError, 'worker_index must be an Integer between 1 and total_workers'
      end

      def ensure_shm!(total_workers, path)
        required_size = self.class.segment_size * total_workers
        page_size = IO::Buffer::PAGE_SIZE
        mapped_size = ((required_size + page_size - 1) / page_size) * page_size

        File.open(path, File::CREAT | File::RDWR, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.truncate(mapped_size) if file.size < mapped_size
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      end

      def attach_observer!(worker_index, path)
        segment = self.class.segment_size
        observer = ::Async::Utilization::Observer.open(
          self.class.schema,
          path,
          segment,
          (worker_index - 1) * segment
        )
        registry.observer = observer
      end
    end
  end
end
