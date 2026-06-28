# frozen_string_literal: true

require 'json'

module Async
  module Background
    module Web
      module Response
        module_function

        JSON_TYPE = 'application/json; charset=utf-8'
        HTML_TYPE = 'text/html; charset=utf-8'
        TEXT_TYPE = 'text/plain; charset=utf-8'
        JAVASCRIPT_TYPE = 'application/javascript; charset=utf-8'
        CSS_TYPE = 'text/css; charset=utf-8'
        NO_STORE = 'no-store'
        ASSET_CACHE = 'public, max-age=31536000, immutable'

        UNAUTHORIZED_BODY = 'unauthorized'
        NOT_FOUND_BODY = 'not found'
        BAD_REQUEST_BODY = JSON.generate(error: 'invalid_request').freeze
        UNAVAILABLE_BODY = JSON.generate(error: 'service_unavailable').freeze
        INTERNAL_ERROR_BODY = JSON.generate(error: 'internal_error').freeze
        EVENT_STREAM_TYPE = 'text/event-stream; charset=utf-8'

        def sse(body)
          [200, sse_headers, body]
        end

        def json(payload, status: 200)
          [status, no_store_headers(JSON_TYPE), [JSON.generate(payload)]]
        end

        def html(body)
          [200, no_store_headers(HTML_TYPE), [body]]
        end

        def javascript(body)
          [200, asset_headers(JAVASCRIPT_TYPE), [body]]
        end

        def stylesheet(body)
          [200, asset_headers(CSS_TYPE), [body]]
        end

        def unauthorized
          [401, no_store_headers(TEXT_TYPE), [UNAUTHORIZED_BODY]]
        end

        def not_found
          [404, no_store_headers(TEXT_TYPE), [NOT_FOUND_BODY]]
        end

        def bad_request(message = nil)
          body = message.nil? ? BAD_REQUEST_BODY : JSON.generate(error: 'invalid_request', message: message)
          [400, no_store_headers(JSON_TYPE), [body]]
        end

        def unavailable
          [503, no_store_headers(JSON_TYPE), [UNAVAILABLE_BODY]]
        end

        def internal_error
          [500, no_store_headers(JSON_TYPE), [INTERNAL_ERROR_BODY]]
        end

        def no_store_headers(content_type)
          {'content-type' => content_type, 'cache-control' => NO_STORE}
        end

        def asset_headers(content_type)
          {'content-type' => content_type, 'cache-control' => ASSET_CACHE}
        end

        def sse_headers
          {
            'content-type' => EVENT_STREAM_TYPE,
            'cache-control' => 'no-cache, no-transform',
            'x-accel-buffering' => 'no'
          }
        end
      end
    end
  end
end
