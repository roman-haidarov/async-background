# frozen_string_literal: true

module Async
  module Background
    module Web
      class Error < StandardError; end
      class ConfigurationError < Error; end
      class NotConfiguredError < Error; end
      class RequestError < Error; end
      class UnavailableError < Error; end
      class ClosedError < Error; end
    end
  end
end
