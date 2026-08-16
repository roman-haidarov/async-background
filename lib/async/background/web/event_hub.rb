# frozen_string_literal: true

require 'json'

module Async
  module Background
    module Web
      class EventHub
        HEARTBEAT_FRAME = ":keepalive\n\n"
        UNAVAILABLE_FRAME = "event: unavailable\ndata: #{JSON.generate(error: 'unavailable')}\n\n".freeze

        def initialize(snapshot, serializer, metrics_reader: nil)
          @snapshot = snapshot
          @serializer = serializer
          @metrics_reader = metrics_reader
          @mutex = Mutex.new
          @cached_version = nil
          @cached_frame = nil
          @closed = false
        end

        def current_version
          with_open {}
          @snapshot.data_version
        end

        def frame_for(version)
          with_open do
            next @cached_frame if @cached_version == version && @cached_frame

            refresh_frame_locked!
            @cached_frame
          end
        end

        def initial_frame
          with_open do
            refresh_frame_locked!
            [@cached_version, @cached_frame]
          end
        end

        def close
          @mutex.synchronize do
            @closed = true
            @cached_frame = nil
            @cached_version = nil
          end
          self
        end

        def closed?
          @mutex.synchronize { @closed }
        end

        private

        def with_open
          @mutex.synchronize do
            raise ClosedError, 'event hub is closed' if @closed

            yield
          end
        end

        def refresh_frame_locked!
          overview = @snapshot.overview(force: true)
          metrics = @metrics_reader&.aggregated
          payload = @serializer.overview(overview, metrics)
          @cached_version = payload.fetch(:data_version)
          @cached_frame = "event: overview\ndata: #{JSON.generate(payload)}\n\n"
        end
      end
    end
  end
end
