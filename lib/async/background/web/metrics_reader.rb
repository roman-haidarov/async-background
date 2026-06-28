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
        EMPTY_TOTALS = {
          total_runs: 0,
          total_successes: 0,
          total_failures: 0,
          total_timeouts: 0,
          total_skips: 0,
          active_jobs: 0,
          last_run_at: 0,
          last_duration_ms: nil
        }.freeze

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

        def unavailable
          {available: false, workers: EMPTY_WORKERS, totals: EMPTY_TOTALS}
        end

        def aggregate(workers)
          totals = {
            total_runs: 0,
            total_successes: 0,
            total_failures: 0,
            total_timeouts: 0,
            total_skips: 0,
            active_jobs: 0,
            last_run_at: 0,
            last_duration_ms: nil
          }

          workers.each do |worker|
            totals[:total_runs] += worker[:total_runs].to_i
            totals[:total_successes] += worker[:total_successes].to_i
            totals[:total_failures] += worker[:total_failures].to_i
            totals[:total_timeouts] += worker[:total_timeouts].to_i
            totals[:total_skips] += worker[:total_skips].to_i
            totals[:active_jobs] += worker[:active_jobs].to_i

            last_run_at = worker[:last_run_at].to_i
            next unless last_run_at > totals[:last_run_at]

            totals[:last_run_at] = last_run_at
            totals[:last_duration_ms] = worker[:last_duration_ms]
          end

          totals.freeze
        end
      end
    end
  end
end
