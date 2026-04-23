# frozen_string_literal: true

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

      attr_reader :registry

      def initialize(worker_index:, total_workers:, shm_path: self.class.default_shm_path)
        require 'async/utilization'

        @registry = ::Async::Utilization::Registry.new
        ensure_shm!(total_workers, shm_path)
        attach_observer!(worker_index, path: shm_path)
        @enabled = true
      rescue LoadError, ArgumentError
        @registry = nil
        @enabled = false
      end

      def enabled?
        @enabled
      end

      def job_started(_entry)
        with_registry do |registry|
          registry.increment(:total_runs)
          registry.increment(:active_jobs)
          registry.set(:last_run_at, Process.clock_gettime(Process::CLOCK_REALTIME).to_i)
        end
      end

      def job_finished(_entry, duration)
        with_registry do |registry|
          registry.decrement(:active_jobs)
          registry.increment(:total_successes)
          registry.set(:last_duration_ms, (duration * 1000).to_i)
        end
      end

      def job_failed(_entry, _error)
        with_registry do |registry|
          registry.decrement(:active_jobs)
          registry.increment(:total_failures)
        end
      end

      def job_timed_out(_entry)
        with_registry do |registry|
          registry.decrement(:active_jobs)
          registry.increment(:total_timeouts)
        end
      end

      def job_skipped(_entry)
        with_registry do |registry|
          registry.increment(:total_skips)
        end
      end

      def values
        return {} unless enabled?

        registry.values
      end

      def self.schema
        require 'async/utilization'
        ::Async::Utilization::Schema.build(SCHEMA_FIELDS)
      end

      def self.read_all(total_workers:, path: default_shm_path)
        require 'async/utilization'

        schema_definition = schema
        segment = segment_size
        file_size = segment * total_workers

        buffer = File.open(path, 'rb') do |file|
          IO::Buffer.map(file, file_size, 0)
        end

        (1..total_workers).map do |worker_index|
          base_offset = (worker_index - 1) * segment

          { worker: worker_index }.tap do |row|
            schema_definition.fields.each do |field|
              row[field.name] = buffer.get_value(field.type, base_offset + field.offset)
            end
          end
        end
      end

      def self.default_shm_path
        File.join(Dir.tmpdir, 'async-background.shm')
      end

      def self.segment_size
        SCHEMA_FIELDS.sum { |_, type| IO::Buffer.size_of(type) }
      end

      private

      def with_registry
        return unless enabled?

        yield registry
      end

      def ensure_shm!(total_workers, path)
        required_size = self.class.segment_size * total_workers

        File.open(path, File::CREAT | File::RDWR, 0o644) do |f|
          f.flock(File::LOCK_EX)
          f.truncate(required_size) if f.size < required_size
          f.flock(File::LOCK_UN)
        end
      end

      def attach_observer!(worker_index, path:)
        segment = self.class.segment_size
        offset  = (worker_index - 1) * segment
        registry.observer = ::Async::Utilization::Observer.open(
          self.class.schema, path, segment, offset
        )
      end
    end
  end
end
