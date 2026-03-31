# frozen_string_literal: true

module Async
  module Background
    # Shared clock helpers used across Runner, Queue::Store, and Queue::Client.
    #
    # monotonic_now — CLOCK_MONOTONIC, for in-process intervals and durations
    #                 (immune to NTP drift / wall-clock jumps)
    #
    # realtime_now  — CLOCK_REALTIME, for persisted timestamps (SQLite run_at,
    #                 created_at, locked_at) and human-readable metrics
    #
    module Clock
      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def realtime_now
        Process.clock_gettime(Process::CLOCK_REALTIME)
      end
    end
  end
end
