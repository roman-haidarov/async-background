# frozen_string_literal: true

require 'tmpdir'

module Async
  module Background
    class Metrics
      SCHEMA_FIELDS = {
        total_runs:       :u64,
        total_successes:  :u64,
        total_failures:   :u64,
        total_timeouts:   :u64,
        total_skips:      :u64,
        active_jobs:      :u32,
        last_run_at:      :u64,
        last_duration_ms: :u32
      }.freeze

      attr_reader :registry, :shm_path, :unavailable_reason

      def initialize(worker_index:, total_workers:, shm_path: self.class.default_shm_path)
        @enabled = false
        @registry = nil
        @metric_handles = {}
        @shm_path = shm_path
        @unavailable_reason = nil

        validate_worker!(worker_index, total_workers)
        self.class.load_utilization!

        ensure_shm!(total_workers, shm_path)

        @registry = ::Async::Utilization::Registry.new
        unless @registry.respond_to?(:metric)
          raise LoadError, 'async-utilization >= 0.3 is required for metrics'
        end

        attach_observer!(worker_index, total_workers, shm_path)
        @metric_handles = SCHEMA_FIELDS.keys.to_h { |name| [name, @registry.metric(name)] }.freeze
        @enabled = true
      rescue LoadError => error
        @registry = nil
        @metric_handles = {}.freeze
        @unavailable_reason = error.message
      end

      def enabled?
        @enabled
      end

      def job_started(_entry)
        return unless enabled?

        metric(:total_runs).increment
        metric(:active_jobs).increment
        metric(:last_run_at).set(Process.clock_gettime(Process::CLOCK_REALTIME).to_i)
      end

      def job_finished(_entry, duration)
        return unless enabled?

        metric(:active_jobs).decrement
        metric(:total_successes).increment
        metric(:last_duration_ms).set((duration * 1000).to_i)
      end

      def job_failed(_entry, _error)
        return unless enabled?

        metric(:active_jobs).decrement
        metric(:total_failures).increment
      end

      def job_timed_out(_entry)
        return unless enabled?

        metric(:active_jobs).decrement
        metric(:total_timeouts).increment
      end

      def job_skipped(_entry)
        return unless enabled?

        metric(:total_skips).increment
      end

      def values
        return {} unless enabled?

        registry.values
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

        # Read one best-effort snapshot for every worker from the shared-memory file.
        # The values are independently updated counters, not a globally atomic snapshot.
        # Returns an empty array when metrics are unavailable or workers have not created
        # the shared-memory file yet, which keeps dashboard callers dependency-free.
        def read_all(total_workers:, path: default_shm_path)
          validate_total_workers!(total_workers)
          return [] unless available?
          return [] unless File.file?(path)

          layout = schema
          segment = segment_size
          file_size = segment * total_workers

          File.open(path, 'rb') do |file|
            file.flock(File::LOCK_SH)
            return [] if file.size < file_size

            buffer = IO::Buffer.map(file, file_size, 0, IO::Buffer::READONLY)
            decode_all(buffer, layout, segment, total_workers)
          ensure
            file.flock(File::LOCK_UN) rescue nil
          end
        rescue Errno::ENOENT
          []
        end

        def default_shm_path
          ENV.fetch('ASYNC_BACKGROUND_METRICS_PATH') do
            File.join(Dir.tmpdir, 'async-background.shm')
          end
        end

        def segment_size
          SCHEMA_FIELDS.sum { |_, type| IO::Buffer.size_of(type) }
        end

        private

        def validate_total_workers!(total_workers)
          return if total_workers.is_a?(Integer) && total_workers.positive?

          raise ArgumentError, 'total_workers must be a positive Integer'
        end

        def decode_all(buffer, schema, segment, total_workers)
          (1..total_workers).map do |worker|
            base = (worker - 1) * segment
            values = schema.fields.each_with_object(worker: worker) do |field, row|
              row[field.name] = buffer.get_value(field.type, base + field.offset)
            end
            values.freeze
          end.freeze
        end
      end

      private

      def metric(name)
        @metric_handles.fetch(name)
      end

      def validate_worker!(worker_index, total_workers)
        self.class.send(:validate_total_workers!, total_workers)
        return if worker_index.is_a?(Integer) && worker_index.between?(1, total_workers)

        raise ArgumentError, 'worker_index must be an Integer between 1 and total_workers'
      end

      def ensure_shm!(total_workers, path)
        required = self.class.segment_size * total_workers

        File.open(path, File::CREAT | File::RDWR, 0o644) do |file|
          file.flock(File::LOCK_EX)
          file.truncate(required) if file.size < required
        ensure
          file.flock(File::LOCK_UN) rescue nil
        end
      end

      def attach_observer!(worker_index, total_workers, path)
        segment = self.class.segment_size
        offset = (worker_index - 1) * segment
        observer = ::Async::Utilization::Observer.open(
          self.class.schema,
          path,
          segment,
          offset
        )
        registry.observer = observer
      end
    end
  end
end
