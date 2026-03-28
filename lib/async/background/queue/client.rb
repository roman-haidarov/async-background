# frozen_string_literal: true

module Async
  module Background
    module Queue
      # Usage:
      #   Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")
      #
      class Client
        def initialize(store:, notifier:)
          @store    = store
          @notifier = notifier
        end

        def push(class_name, args = [])
          id = @store.enqueue(class_name, args)
          @notifier.notify
          id
        end
      end

      class << self
        attr_accessor :default_client

        def enqueue(job_class, *args)
          raise "Async::Background::Queue not configured" unless default_client

          if job_class.is_a?(String)
            class_name = job_class
          else
            raise ArgumentError, "#{job_class} must implement .perform_now" unless job_class.respond_to?(:perform_now)
            class_name = job_class.name
          end

          default_client.push(class_name, args)
        end
      end
    end
  end
end
