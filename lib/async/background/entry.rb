# frozen_string_literal: true

module Async
  module Background
    class Entry
      attr_reader :name, :job_class, :interval, :cron, :timeout
      attr_accessor :next_run_at, :running

      def initialize(name:, job_class:, interval:, cron:, timeout:, next_run_at:)
        @name        = name
        @job_class   = job_class
        @interval    = interval
        @cron        = cron
        @timeout     = timeout
        @next_run_at = next_run_at
        @running     = false
      end

      def reschedule(monotonic_now)
        if interval
          @next_run_at += interval
          @next_run_at = monotonic_now + interval if @next_run_at <= monotonic_now
        else
          now_wall = Time.now
          wait = cron.next_time(now_wall).to_f - now_wall.to_f
          @next_run_at = monotonic_now + [wait, Async::Background::MIN_SLEEP_TIME].max
        end
      end
    end
  end
end
