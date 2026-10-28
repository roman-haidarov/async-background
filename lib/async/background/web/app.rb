# frozen_string_literal: true

module Async
  module Background
    module Web
      class App
        def initialize(config)
          @config = config.validate!
          @logger = @config.logger
          @auth = Auth.new(@config.auth, logger: @logger)
          @snapshot = Snapshot.new(path: @config.queue_path, counts_cache_ttl: @config.counts_cache_ttl).open!
          @metrics_reader = build_metrics_reader
          @serializer = Serializer.new(@config)
          @event_hub = build_event_hub
          @router = Router.new
        end

        def call(env)
          head = env['REQUEST_METHOD'] == 'HEAD'
          response = handle(env, head: head)
          return response unless head

          status, headers, _body = response
          [status, headers, []]
        end

        def close
          @event_hub&.close
          @snapshot.close
          self
        end

        private

        LIST_ROUTES = {
          executing: [:executing, :executing, nil].freeze,
          claimed: [:claimed, :claimed, nil].freeze,
          done: %i[recent_done done finished_cursor].freeze,
          failed: %i[recent_failed failed finished_cursor].freeze,
          pending: %i[pending pending pending_cursor].freeze
        }.freeze
        STATIC_ROUTES = {
          index: :index_response,
          javascript: :javascript_response,
          stylesheet: :stylesheet_response,
          overview: :overview_response,
          metrics: :metrics_response,
          config: :config_response,
          stream: :stream_response
        }.freeze

        def handle(env, head:)
          return Response.unauthorized unless @auth.authorized?(env)

          route = @router.match(env)
          return Response.not_found unless route

          if head && route == :stream
            return @config.transport == :sse ? [200, Response.sse_headers, []] : Response.not_found
          end

          dispatch(route, env)
        rescue RequestError => e
          Response.bad_request(e.message)
        rescue UnavailableError, ClosedError
          Response.unavailable
        rescue StandardError => e
          # Do not turn internal class names, paths or database errors into an
          # unauthenticated information disclosure channel — but do surface
          # them to the operator via the configured logger.
          log_internal_error(env, e)
          Response.internal_error
        end

        def build_metrics_reader
          return unless @config.metrics_enabled?

          MetricsReader.new(path: @config.metrics_path, total_workers: @config.total_workers)
        end

        def build_event_hub
          return unless @config.transport == :sse

          EventHub.new(@snapshot, @serializer, metrics_reader: @metrics_reader)
        end

        def dispatch(route, env)
          return list_response(route, env) if LIST_ROUTES.key?(route)

          handler = STATIC_ROUTES[route]
          handler ? send(handler) : Response.not_found
        end

        def index_response = Response.html(Assets.render_index(@config))

        def javascript_response = Response.javascript(Assets::JS)

        def stylesheet_response = Response.stylesheet(Assets::CSS)

        def list_response(route, env)
          reader, shape, cursor_kind = LIST_ROUTES.fetch(route)
          request = Request.new(env, @config)

          unless cursor_kind
            rows = @snapshot.public_send(reader, limit: request.limit)
            return Response.json({ items: @serializer.public_send(shape, rows) })
          end

          rows = @snapshot.public_send(reader, limit: request.limit, cursor: request.public_send(cursor_kind))
          Response.json(@serializer.public_send(shape, rows))
        end

        def overview_response
          Response.json(@serializer.overview(@snapshot.overview, metrics_payload))
        end

        def metrics_response
          Response.json(metrics_payload || MetricsReader::UNAVAILABLE)
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
              retry_ms: @config.stream_retry_ms,
              poll_seconds: @config.stream_poll_seconds,
              logger: @logger
            )
          )
        end

        def log_internal_error(env, error)
          @logger&.error(
            '[async-background-web] internal error on ' \
            "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}: " \
            "#{error.class}: #{error.message}"
          )
        end
      end
    end
  end
end
