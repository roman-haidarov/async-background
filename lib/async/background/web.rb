# frozen_string_literal: true

begin
  require 'rack'
rescue LoadError
  raise LoadError,
        "Async::Background::Web requires 'rack'. " \
        "Add `gem 'rack', '~> 3.0'` to your Gemfile."
end

require_relative 'web/errors'
require_relative 'web/configuration'
require_relative 'web/sql'
require_relative 'web/cursor'
require_relative 'web/request'
require_relative 'web/response'
require_relative 'web/snapshot'
require_relative 'web/metrics_reader'
require_relative 'web/serializer'
require_relative 'web/auth'
require_relative 'web/router'
require_relative 'web/event_hub'
require_relative 'web/stream'
require_relative 'web/assets'
require_relative 'web/app'

module Async
  module Background
    module Web
      module_function

      def configure
        @configuration ||= Configuration.new
        yield @configuration if block_given?
        @configuration
      end

      def configuration
        @configuration or raise NotConfiguredError,
                               'Async::Background::Web is not configured. Call Async::Background::Web.configure.'
      end

      def reset!
        @configuration = nil
      end

      def app
        App.new(configuration)
      end
    end
  end
end
