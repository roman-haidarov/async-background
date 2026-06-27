# frozen_string_literal: true

require_relative '../clock'
require_relative 'store'

module Async
  module Background
    module Queue
      class Client
        include Clock

        def initialize(store:, notifier: nil)
          @store    = store
          @notifier = notifier
        end

        def push(class_name, args = EMPTY_ARGS, run_at = nil, options: EMPTY_OPTIONS)
          id = @store.enqueue(class_name, args, run_at, options: options)
          @notifier&.notify_all
          id
        end

        def push_in(delay, class_name, args = EMPTY_ARGS, options: EMPTY_OPTIONS)
          push(class_name, args, realtime_now + delay.to_f, options: options)
        end

        def push_at(time, class_name, args = EMPTY_ARGS, options: EMPTY_OPTIONS)
          run_at = time.respond_to?(:to_f) ? time.to_f : time
          push(class_name, args, run_at, options: options)
        end
      end

      class << self
        attr_accessor :default_client

        def migrate!(path: Store.default_path, options: {})
          Store.migrate!(path: path, options: options)
        end

        def prepare_dashboard!(path: Store.default_path, options: {})
          Store.prepare_dashboard!(path: path, options: options)
        end

        def enqueue(job_class, *args, options: EMPTY_OPTIONS)
          ensure_configured!
          default_client.push(resolve_class_name(job_class), normalized_args(args), nil, options: build_options(job_class, options))
        end

        def enqueue_in(delay, job_class, *args, options: EMPTY_OPTIONS)
          ensure_configured!
          default_client.push_in(delay, resolve_class_name(job_class), normalized_args(args), options: build_options(job_class, options))
        end

        def enqueue_at(time, job_class, *args, options: EMPTY_OPTIONS)
          ensure_configured!
          default_client.push_at(time, resolve_class_name(job_class), normalized_args(args), options: build_options(job_class, options))
        end

        private

        RETRY_KEYS = %i[retry retry_delay backoff jitter].freeze
        private_constant :RETRY_KEYS

        def build_options(job_class, call_site)
          call_site ||= EMPTY_OPTIONS
          class_options = resolve_options(job_class)
          return EMPTY_OPTIONS if class_options.empty? && call_site.empty?

          merged = class_options.merge(call_site.compact)
          apply_retry_overrides!(merged, call_site)

          merged.empty? ? EMPTY_OPTIONS : Job::Options.new(**merged).to_h.compact
        end

        def apply_retry_overrides!(merged, call_site)
          return unless RETRY_KEYS.any? { |k| call_site.key?(k) && !call_site[k].nil? }

          RETRY_KEYS.each { |k| merged[k] = call_site[k] if call_site.key?(k) }
        end

        def ensure_configured!
          raise "Async::Background::Queue not configured" unless default_client
        end

        def normalized_args(args) = args.empty? ? EMPTY_ARGS : args

        def resolve_class_name(job_class)
          return job_class if job_class.is_a?(String)
          return job_class.name if job_class.respond_to?(:perform_now)

          raise ArgumentError, "#{job_class} must include Async::Background::Job"
        end

        def resolve_options(job_class)
          return EMPTY_OPTIONS unless job_class.respond_to?(:resolve_options)

          options = if job_class.respond_to?(:queue_options)
            job_class.queue_options
          else
            job_class.resolve_options
          end

          options.empty? ? EMPTY_OPTIONS : options
        end
      end
    end
  end
end
