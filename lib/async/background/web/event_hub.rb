# frozen_string_literal: true

require 'json'

module Async
  module Background
    module Web
      class EventHub
        HEARTBEAT_FRAME = ":keepalive\n\n"
        UNAVAILABLE_FRAME = "event: unavailable\ndata: #{JSON.generate(error: 'unavailable')}\n\n".freeze

        class Subscription
          def initialize(clock: nil)
            @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @mutex = Mutex.new
            @condition = ConditionVariable.new
            @frame = nil
            @closed = false
          end

          def publish(frame)
            @mutex.synchronize do
              return false if @closed

              @frame = frame
              @condition.signal
              true
            end
          end

          def pop(timeout:)
            deadline = @clock.call + timeout

            @mutex.synchronize do
              while @frame.nil? && !@closed
                remaining = deadline - @clock.call
                break if remaining <= 0

                @condition.wait(@mutex, remaining)
              end

              frame = @frame
              @frame = nil
              frame
            end
          end

          def close
            @mutex.synchronize do
              return if @closed

              @closed = true
              @condition.broadcast
            end
          end

          def closed?
            @mutex.synchronize { @closed }
          end
        end

        def initialize(snapshot, serializer, metrics_reader: nil, poll_seconds:, sleeper: nil)
          @snapshot = snapshot
          @serializer = serializer
          @metrics_reader = metrics_reader
          @poll_seconds = poll_seconds
          @sleeper = sleeper || ->(seconds) { sleep(seconds) }
          @mutex = Mutex.new
          @condition = ConditionVariable.new
          @subscribers = {}
          @closed = false
          @monitor = nil
          @last_data_version = nil
          @unavailable = false
        end

        def subscribe
          subscription = Subscription.new
          frame, data_version = current_overview

          @mutex.synchronize do
            raise ClosedError, 'event hub is closed' if @closed

            @subscribers[subscription.object_id] = subscription
            @last_data_version ||= data_version
            start_monitor_unless_running!
            @condition.signal
          end

          [subscription, frame]
        end

        def unsubscribe(subscription)
          @mutex.synchronize do
            @subscribers.delete(subscription.object_id)
          end
          subscription.close
          nil
        end

        def close
          monitor = nil
          subscribers = nil

          @mutex.synchronize do
            return if @closed

            @closed = true
            subscribers = @subscribers.values
            @subscribers.clear
            monitor = @monitor
            @condition.broadcast
          end

          subscribers.each(&:close)
          monitor&.join(1) unless monitor == Thread.current
          nil
        end

        private

        def start_monitor_unless_running!
          return if @monitor&.alive?

          @monitor = Thread.new { monitor_loop }
          @monitor.name = 'async-background-web-events' if @monitor.respond_to?(:name=)
          @monitor.abort_on_exception = false
        end

        def monitor_loop
          loop do
            break unless wait_for_subscribers

            begin
              detect_change
            rescue ClosedError, UnavailableError
              notify_unavailable
            end

            @sleeper.call(@poll_seconds)
          end
        ensure
          @mutex.synchronize { @monitor = nil if @monitor == Thread.current }
        end

        def wait_for_subscribers
          @mutex.synchronize do
            @condition.wait(@mutex) while !@closed && @subscribers.empty?
            !@closed
          end
        end

        def detect_change
          version = @snapshot.data_version
          previous_version = @mutex.synchronize { @last_data_version }
          if version == previous_version
            @mutex.synchronize { @unavailable = false }
            return
          end

          frame, observed_version = current_overview
          @mutex.synchronize do
            @last_data_version = observed_version
            @unavailable = false
          end
          broadcast(frame)
        end

        def current_overview
          overview = @snapshot.overview(force: true)
          metrics = @metrics_reader&.aggregated
          payload = @serializer.overview(overview, metrics)
          ["event: overview\ndata: #{JSON.generate(payload)}\n\n", payload.fetch(:data_version)]
        end

        def notify_unavailable
          should_broadcast = @mutex.synchronize do
            next false if @unavailable

            @unavailable = true
            true
          end
          broadcast(UNAVAILABLE_FRAME) if should_broadcast
        end

        def broadcast(frame)
          subscribers = @mutex.synchronize { @subscribers.values.dup }
          subscribers.each { |subscription| subscription.publish(frame) }
          nil
        end
      end
    end
  end
end
