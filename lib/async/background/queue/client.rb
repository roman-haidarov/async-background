# frozen_string_literal: true

require_relative '../clock'

module Async
  module Background
    module Queue
      class Client
        include Clock

        def initialize(store:, notifier: nil)
          @store    = store
          @notifier = notifier
        end

        def push(class_name, args = [], run_at = nil)
          id = @store.enqueue(class_name, args, run_at)
          @notifier&.notify
          id
        end

        def push_in(delay, class_name, args = [])
          run_at = realtime_now + delay.to_f
          push(class_name, args, run_at)
        end

        def push_at(time, class_name, args = [])
          run_at = time.respond_to?(:to_f) ? time.to_f : time
          push(class_name, args, run_at)
        end
      end

      class << self
        attr_accessor :default_client

        def enqueue(job_class, *args)
          ensure_configured!
          default_client.push(resolve_class_name(job_class), args)
        end

        def enqueue_in(delay, job_class, *args)
          ensure_configured!
          default_client.push_in(delay, resolve_class_name(job_class), args)
        end

        def enqueue_at(time, job_class, *args)
          ensure_configured!
          default_client.push_at(time, resolve_class_name(job_class), args)
        end

        private

        def ensure_configured!
          raise "Async::Background::Queue not configured" unless default_client
        end

        def resolve_class_name(job_class)
          return job_class if job_class.is_a?(String)
          return job_class.name if job_class.respond_to?(:perform_now)

          raise ArgumentError, "#{job_class} must include Async::Background::Job"
        end
      end
    end
  end
end
