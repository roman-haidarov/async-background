# frozen_string_literal: true

module Async
  module Background
    module Web
      class Router
        GET_ROUTES = {
          '/' => :index,
          '/assets/app.js' => :javascript,
          '/assets/app.css' => :stylesheet,
          '/api/overview' => :overview,
          '/api/executing' => :executing,
          '/api/claimed' => :claimed,
          '/api/done' => :done,
          '/api/failed' => :failed,
          '/api/pending' => :pending,
          '/api/metrics' => :metrics,
          '/api/config' => :config,
          '/api/stream' => :stream
        }.freeze

        def match(env)
          return unless env['REQUEST_METHOD'] == 'GET'

          GET_ROUTES[env['PATH_INFO'] || '/']
        end
      end
    end
  end
end
