# frozen_string_literal: true

module Async
  module Background
    module Job
      DEFAULT_TIMEOUT = 120

      Options = Data.define(:timeout) do
        def initialize(timeout: DEFAULT_TIMEOUT) = super(timeout: Integer(timeout))
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def perform_now(*args)
          new.perform(*args)
        end

        def perform_async(*args, options: {})
          Async::Background::Queue.enqueue(self, *args, options: options)
        end

        def perform_in(delay, *args, options: {})
          Async::Background::Queue.enqueue_in(delay, self, *args, options: options)
        end

        def perform_at(time, *args, options: {})
          Async::Background::Queue.enqueue_at(time, self, *args, options: options)
        end

        def options(**values)
          @options = Options.new(**values).to_h
        end

        def resolve_options = @options || {}
      end

      def perform(*args)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
