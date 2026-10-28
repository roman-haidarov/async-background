# frozen_string_literal: true

require_relative '../clock'

module Async
  module Background
    module Web
      class Stream
        include Clock

        def initialize(hub, heartbeat_seconds:, retry_ms:, poll_seconds:, logger: nil)
          @hub = hub
          @heartbeat_seconds = heartbeat_seconds
          @retry_ms = retry_ms
          @poll_seconds = poll_seconds
          @logger = logger
        end

        def each
          yield "retry: #{@retry_ms}\n\n"

          version, frame = initial_state
          if version.nil?
            yield EventHub::UNAVAILABLE_FRAME
            return
          end

          yield frame
          stream_updates(version, monotonic_now) { |event| yield event }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil
        rescue StandardError => e
          @logger&.error(
            '[async-background-web] SSE stream terminated: ' \
            "#{e.class}: #{e.message}"
          )
          nil
        end

        private

        def initial_state
          @hub.initial_frame
        rescue ClosedError, UnavailableError
          [nil, nil]
        end

        def sleep_for_poll
          sleep(@poll_seconds)
        end

        def stream_updates(version, last_yield)
          unavailable_announced = false
          loop do
            sleep_for_poll
            state = next_state(version, last_yield, unavailable_announced) { |event| yield event }
            break unless state

            version, last_yield, unavailable_announced = state
          end
        end

        def next_state(version, last_yield, unavailable_announced)
          current_version = @hub.current_version
          return updated_state(current_version) { |event| yield event } if current_version != version
          return heartbeat_state(version) { |event| yield event } if heartbeat_due?(last_yield)

          [version, last_yield, false]
        rescue ClosedError
          nil
        rescue UnavailableError
          announce_unavailable(version, last_yield, unavailable_announced) { |event| yield event }
        end

        def updated_state(version)
          yield @hub.frame_for(version)
          [version, monotonic_now, false]
        end

        def heartbeat_state(version)
          yield EventHub::HEARTBEAT_FRAME
          [version, monotonic_now, false]
        end

        def heartbeat_due?(last_yield)
          (monotonic_now - last_yield) >= @heartbeat_seconds
        end

        def announce_unavailable(version, last_yield, announced)
          return [version, last_yield, true] if announced

          yield_unavailable { |event| yield event }
          [version, monotonic_now, true]
        end

        def yield_unavailable
          yield EventHub::UNAVAILABLE_FRAME
        end
      end
    end
  end
end
