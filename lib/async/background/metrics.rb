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

        @registry = nil
        @enabled  = false
        @registry = ::Async::Utilization::Registry.new
        @enabled  = true

        ensure_shm!(total_workers, shm_path)
        attach_observer!(worker_index, total_workers, shm_path)
      rescue LoadError
      end

      def enabled?
        @enabled
      end

      def job_started(entry)
        return unless @enabled

        @registry.increment(:total_runs)
        @registry.increment(:active_jobs)
        @registry.set(:last_run_at, Process.clock_gettime(Process::CLOCK_REALTIME).to_i)
      end

      def job_finished(entry, duration)
        return unless @enabled

        @registry.decrement(:active_jobs)
        @registry.increment(:total_successes)
        @registry.set(:last_duration_ms, (duration * 1000).to_i)
      end

      def job_failed(entry, error)
        return unless @enabled

        @registry.decrement(:active_jobs)
        @registry.increment(:total_failures)
      end

      def job_timed_out(entry)
        return unless @enabled

        @registry.decrement(:active_jobs)
        @registry.increment(:total_timeouts)
      end

      def job_skipped(entry)
        return unless @enabled

        @registry.increment(:total_skips)
      end

      def values
        return {} unless @enabled

        @registry.values
      end

      def self.schema
        require 'async/utilization'
        ::Async::Utilization::Schema.build(SCHEMA_FIELDS)
      end

      # Read metrics for all workers from the shm file.
      # No server needed — just reads the mmap'd file.
      #
      #   Async::Background::Metrics.read_all(total_workers: 2)
      #   # => [
      #   #   { worker: 1, total_runs: 142, active_jobs: 1, ... },
      #   #   { worker: 2, total_runs: 98,  active_jobs: 0, ... }
      #   # ]
      #
      def self.read_all(total_workers:, path: default_shm_path)
        require 'async/utilization'

        s = schema
        segment = segment_size
        file_size = segment * total_workers

        buffer = File.open(path, "rb") do |f|
          IO::Buffer.map(f, file_size, 0)
        end

        (1..total_workers).map do |i|
          base = (i - 1) * segment
          row = { worker: i }
          s.fields.each do |field|
            row[field.name] = buffer.get_value(field.type, base + field.offset)
          end
          row
        end
      end

      def self.default_shm_path
        File.join(Dir.tmpdir, "async-background.shm")
      end

      def self.segment_size
        SCHEMA_FIELDS.sum { |_, type| IO::Buffer.size_of(type) }
      end

      private

      def ensure_shm!(total_workers, path)
        required = self.class.segment_size * total_workers

        File.open(path, File::CREAT | File::RDWR, 0644) do |f|
          f.flock(File::LOCK_EX)
          f.truncate(required) if f.size < required
          f.flock(File::LOCK_UN)
        end
      end

      def attach_observer!(worker_index, total_workers, path)
        segment = self.class.segment_size
        offset  = (worker_index - 1) * segment
        observer = ::Async::Utilization::Observer.open(
          self.class.schema, path, segment, offset
        )
        @registry.observer = observer
      end
    end
  end
end
