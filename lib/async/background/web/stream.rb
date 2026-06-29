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
          last_yield = monotonic_now
          unavailable_announced = false

          loop do
            sleep_for_poll

            begin
              new_version = @hub.current_version

              if new_version != version
                version = new_version
                yield @hub.frame_for(version)
                last_yield = monotonic_now
              elsif (monotonic_now - last_yield) >= @heartbeat_seconds
                yield EventHub::HEARTBEAT_FRAME
                last_yield = monotonic_now
              end

              unavailable_announced = false
            rescue ClosedError
              break
            rescue UnavailableError
              unless unavailable_announced
                yield EventHub::UNAVAILABLE_FRAME
                unavailable_announced = true
                last_yield = monotonic_now
              end
            end
          end
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil
        rescue StandardError => error
          @logger&.error(
            "[async-background-web] SSE stream terminated: " \
            "#{error.class}: #{error.message}"
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
      end
    end
  end
end
