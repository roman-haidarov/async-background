# frozen_string_literal: true

require_relative '../clock'
require_relative '../metrics'

module Async
  module Background
    module Web
      class MetricsReader
        include Clock

        DEFAULT_TTL = 1.0
        EMPTY_WORKERS = [].freeze
        SUMMED_FIELDS = %i[
          total_runs
          total_successes
          total_failures
          total_timeouts
          total_skips
          active_jobs
        ].freeze

        LATEST_FIELD = :last_run_at
        LATEST_COMPANION = :last_duration_ms

        EMPTY_TOTALS = (
          SUMMED_FIELDS.to_h { |field| [field, 0] }
            .merge(LATEST_FIELD => 0, LATEST_COMPANION => nil)
        ).freeze

        UNAVAILABLE = {available: false, workers: EMPTY_WORKERS, totals: EMPTY_TOTALS}.freeze

        def initialize(path:, total_workers:, ttl: DEFAULT_TTL)
          @path = path
          @total_workers = total_workers
          @ttl = ttl
          @mutex = Mutex.new
          @cache = nil
          @cached_at = nil
        end

        def aggregated
          @mutex.synchronize do
            now = monotonic_now
            return @cache if cache_current?(now)

            @cache = read_metrics.freeze
            @cached_at = now
            @cache
          end
        end

        private

        def cache_current?(now)
          @cache && @cached_at && (now - @cached_at) < @ttl
        end

        def read_metrics
          return unavailable unless Metrics.available? && File.file?(@path)

          workers = Metrics.read_all(total_workers: @total_workers, path: @path)
          {available: true, workers: workers, totals: aggregate(workers)}
        rescue StandardError
          unavailable
        end

        def unavailable = UNAVAILABLE

        def aggregate(workers)
          totals = EMPTY_TOTALS.dup
          most_recent = nil

          workers.each do |worker|
            SUMMED_FIELDS.each { |field| totals[field] += worker[field].to_i }

            last_run_at = worker[LATEST_FIELD].to_i
            next unless last_run_at > totals[LATEST_FIELD]

            totals[LATEST_FIELD] = last_run_at
            most_recent = worker
          end

          totals[LATEST_COMPANION] = most_recent[LATEST_COMPANION] if most_recent
          totals.freeze
        end
      end
    end
  end
end
