# frozen_string_literal: true

module Async
  module Background
    module Web
      class Request
        def initialize(env, config)
          @config = config
          @params = parse(env['QUERY_STRING'])
        end

        def limit
          @config.limit_for(@params['limit'])
        end

        def finished_cursor
          Cursor.decode_finished(@params['cursor'])
        end

        def pending_cursor
          Cursor.decode_pending(@params['cursor'])
        end

        private

        def parse(query)
          return {} if query.nil? || query.empty?

          Rack::Utils.parse_query(query)
        rescue StandardError
          raise RequestError, 'invalid query string'
        end
      end
    end
  end
end
