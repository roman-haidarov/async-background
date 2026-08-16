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
        EVENT_STREAM_TYPE = 'text/event-stream; charset=utf-8'

        NO_STORE = 'no-store'
        ASSET_CACHE = 'public, max-age=31536000, immutable'
        SSE_CACHE = 'no-cache, no-transform'

        BASE_SECURITY_HEADERS = {
          'x-content-type-options' => 'nosniff',
          'referrer-policy' => 'no-referrer',
          'cross-origin-resource-policy' => 'same-origin'
        }.freeze

        HTML_SECURITY_HEADERS = BASE_SECURITY_HEADERS.merge(
          'x-frame-options' => 'DENY',
          'content-security-policy' =>
            "default-src 'none'; " \
            "script-src 'self'; " \
            "style-src 'self'; " \
            "img-src 'self' data:; " \
            "connect-src 'self'; " \
            "frame-ancestors 'none'; " \
            "base-uri 'none'; " \
            "form-action 'none'"
        ).freeze

        ERRORS = {
          unauthorized: [401, 'unauthorized'],
          not_found: [404, 'not_found'],
          bad_request: [400, 'invalid_request'],
          unavailable: [503, 'service_unavailable'],
          internal_error: [500, 'internal_error']
        }.freeze

        ERROR_BODY = ERRORS.to_h { |name, (_, code)| [name, JSON.generate(error: code).freeze] }.freeze

        def headers(content_type, cache_control, security = BASE_SECURITY_HEADERS)
          {'content-type' => content_type, 'cache-control' => cache_control}.merge(security)
        end

        def no_store_headers(content_type) = headers(content_type, NO_STORE)
        def html_headers = headers(HTML_TYPE, NO_STORE, HTML_SECURITY_HEADERS)
        def asset_headers(content_type) = headers(content_type, ASSET_CACHE)

        def sse_headers
          {
            'content-type' => EVENT_STREAM_TYPE,
            'cache-control' => SSE_CACHE,
            'x-accel-buffering' => 'no'
          }.merge(BASE_SECURITY_HEADERS)
        end

        def sse(body) = [200, sse_headers, body]
        def html(body) = [200, html_headers, [body]]
        def javascript(body) = [200, asset_headers(JAVASCRIPT_TYPE), [body]]
        def stylesheet(body) = [200, asset_headers(CSS_TYPE), [body]]

        def json(payload, status: 200)
          [status, no_store_headers(JSON_TYPE), [JSON.generate(payload)]]
        end

        def unauthorized = error_response(:unauthorized)
        def not_found = error_response(:not_found)
        def unavailable = error_response(:unavailable)
        def internal_error = error_response(:internal_error)

        def bad_request(message = nil)
          return error_response(:bad_request) if message.nil?

          error_response(:bad_request, JSON.generate(error: 'invalid_request', message: message))
        end

        def error_response(name, body = ERROR_BODY.fetch(name))
          status = ERRORS.fetch(name).first
          [status, no_store_headers(JSON_TYPE), [body]]
        end
        private_class_method :error_response
      end
    end
  end
end
