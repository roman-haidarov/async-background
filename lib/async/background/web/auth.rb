# frozen_string_literal: true

module Async
  module Background
    module Web
      class Auth
        def initialize(callable)
          @callable = callable
        end

        def authorized?(env)
          !!@callable.call(env)
        rescue StandardError
          false
        end
      end
    end
  end
end
