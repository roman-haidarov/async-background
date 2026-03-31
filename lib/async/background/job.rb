# frozen_string_literal: true

module Async
  module Background
    module Job
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def perform_now(*args)
          new.perform(*args)
        end

        def perform_async(*args)
          Async::Background::Queue.enqueue(self, *args)
        end

        def perform_in(delay, *args)
          Async::Background::Queue.enqueue_in(delay, self, *args)
        end

        def perform_at(time, *args)
          Async::Background::Queue.enqueue_at(time, self, *args)
        end
      end

      def perform(*args)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
