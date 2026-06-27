# frozen_string_literal: true

module Async
  module Background
    module Web
      class App
        def initialize(config)
          @config = config.validate!
          @auth = Auth.new(@config.auth)
          @snapshot = Snapshot.new(path: @config.queue_path, counts_cache_ttl: @config.counts_cache_ttl).open!
          @metrics_reader = build_metrics_reader
          @serializer = Serializer.new(@config)
          @event_hub = build_event_hub
          @router = Router.new
        end

        def call(env)
          return Response.unauthorized unless @auth.authorized?(env)

          route = @router.match(env)
          return Response.not_found unless route

          dispatch(route, env)
        rescue RequestError => error
          Response.bad_request(error.message)
        rescue UnavailableError, ClosedError
          Response.unavailable
        rescue StandardError
          # Do not turn internal class names, paths or database errors into an
          # unauthenticated information disclosure channel.
          Response.internal_error
        end

        def close
          @event_hub&.close
          @snapshot.close
          self
        end

        private

        def build_metrics_reader
          return unless @config.metrics_enabled?

          MetricsReader.new(path: @config.metrics_path, total_workers: @config.total_workers)
        end

        def build_event_hub
          return unless @config.transport == :sse

          EventHub.new(
            @snapshot,
            @serializer,
            metrics_reader: @metrics_reader,
            poll_seconds: @config.stream_poll_seconds
          )
        end

        def dispatch(route, env)
          case route
          when :index then Response.html(Assets.render_index(@config))
          when :javascript then Response.javascript(Assets::JS)
          when :stylesheet then Response.stylesheet(Assets::CSS)
          when :overview then overview_response
          when :executing then in_flight_response(:executing, env)
          when :claimed then in_flight_response(:claimed, env)
          when :done then terminal_response(:done, env)
          when :failed then terminal_response(:failed, env)
          when :pending then pending_response(env)
          when :metrics then metrics_response
          when :config then config_response
          when :stream then stream_response
          else Response.not_found
          end
        end

        def overview_response
          Response.json(@serializer.overview(@snapshot.overview, metrics_payload))
        end

        def in_flight_response(kind, env)
          request = Request.new(env, @config)
          rows = kind == :executing ? @snapshot.executing(limit: request.limit) : @snapshot.claimed(limit: request.limit)
          payload = kind == :executing ? @serializer.executing(rows) : @serializer.claimed(rows)
          Response.json({items: payload})
        end

        def terminal_response(kind, env)
          request = Request.new(env, @config)
          cursor = request.finished_cursor
          rows = kind == :done ? @snapshot.recent_done(limit: request.limit, cursor: cursor) :
            @snapshot.recent_failed(limit: request.limit, cursor: cursor)
          payload = kind == :done ? @serializer.done(rows) : @serializer.failed(rows)
          Response.json(payload)
        end

        def pending_response(env)
          request = Request.new(env, @config)
          rows = @snapshot.pending(limit: request.limit, cursor: request.pending_cursor)
          Response.json(@serializer.pending(rows))
        end

        def metrics_response
          Response.json(metrics_payload || {available: false, workers: [], totals: MetricsReader::EMPTY_TOTALS})
        end

        def metrics_payload
          @metrics_reader&.aggregated
        end

        def config_response
          Response.json(
            {
              title: @config.title,
              poll_interval_ms: @config.poll_interval_ms,
              transport: @config.transport.to_s,
              expose_args: @config.expose_args,
              list_limit: @config.list_limit,
              mount_path: @config.mount_path
            }
          )
        end

        def stream_response
          return Response.not_found unless @config.transport == :sse

          Response.sse(
            Stream.new(
              @event_hub,
              heartbeat_seconds: @config.stream_heartbeat_seconds,
              retry_ms: @config.stream_retry_ms
            )
          )
        end
      end
    end
  end
end
