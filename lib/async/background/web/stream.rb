# frozen_string_literal: true

module Async
  module Background
    module Web
      class Stream
        def initialize(hub, heartbeat_seconds:, retry_ms:)
          @hub = hub
          @heartbeat_seconds = heartbeat_seconds
          @retry_ms = retry_ms
        end

        def each
          subscription, initial_frame = @hub.subscribe
          yield "retry: #{@retry_ms}\n\n"
          yield initial_frame

          loop do
            frame = subscription.pop(timeout: @heartbeat_seconds)
            break if frame.nil? && subscription.closed?

            yield(frame || EventHub::HEARTBEAT_FRAME)
          end
        rescue Errno::EPIPE, IOError
          nil
        rescue ClosedError, UnavailableError
          safe_yield(EventHub::UNAVAILABLE_FRAME) { |frame| yield frame }
          nil
        ensure
          @hub.unsubscribe(subscription) if subscription
        end

        private

        def safe_yield(frame)
          yield frame
        rescue Errno::EPIPE, IOError
          nil
        end
      end
    end
  end
end
