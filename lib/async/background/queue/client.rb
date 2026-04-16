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

        def push(class_name, args = [], run_at = nil, options: nil)
          id = @store.enqueue(class_name, args, run_at, options: options)
          @notifier&.notify_all
          id
        end

        def push_in(delay, class_name, args = [], options: nil)
          run_at = realtime_now + delay.to_f
          push(class_name, args, run_at, options: options)
        end

        def push_at(time, class_name, args = [], options: nil)
          run_at = time.respond_to?(:to_f) ? time.to_f : time
          push(class_name, args, run_at, options: options)
        end
      end

      class << self
        attr_accessor :default_client

        def enqueue(job_class, *args, options: {})
          ensure_configured!
          merged = build_options(job_class, options)
          default_client.push(resolve_class_name(job_class), args, nil, options: merged)
        end

        def enqueue_in(delay, job_class, *args, options: {})
          ensure_configured!
          merged = build_options(job_class, options)
          default_client.push_in(delay, resolve_class_name(job_class), args, options: merged)
        end

        def enqueue_at(time, job_class, *args, options: {})
          ensure_configured!
          merged = build_options(job_class, options)
          default_client.push_at(time, resolve_class_name(job_class), args, options: merged)
        end

        private

        def build_options(job_class, call_site_options)
          merged = resolve_options(job_class).merge!(call_site_options.compact)
          return nil if merged.empty?

          Job::Options.new(**merged).to_h
        end

        def ensure_configured!
          raise "Async::Background::Queue not configured" unless default_client
        end

        def resolve_class_name(job_class)
          return job_class if job_class.is_a?(String)
          return job_class.name if job_class.respond_to?(:perform_now)

          raise ArgumentError, "#{job_class} must include Async::Background::Job"
        end

        def resolve_options(job_class)
          return {} unless job_class.respond_to?(:resolve_options)

          job_class.resolve_options.dup
        end
      end
    end
  end
end
