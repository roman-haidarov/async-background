# frozen_string_literal: true

module Async
  module Background
    module Web
      class Auth
        def initialize(callable, logger: nil)
          @callable = callable
          @logger = logger
        end

        def authorized?(env)
          !!@callable.call(env)
        rescue StandardError => error
          @logger&.warn(
            "[async-background-web] auth callable raised: " \
            "#{error.class}: #{error.message}"
          )
          false
        end
      end
    end
  end
end
