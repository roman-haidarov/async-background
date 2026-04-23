# frozen_string_literal: true

require_relative '../clock'

module Async
  module Background
    module Queue
      EMPTY_OPTIONS = {}.freeze
      RETRY_OPTION_KEYS = %i[retry retry_delay backoff].freeze

      class Client
        include Clock

        def initialize(store:, notifier: nil)
          @store = store
          @notifier = notifier
        end

        def push(class_name, args = [], run_at = nil, options: {})
          id = @store.enqueue(class_name, args, run_at, options: options)
          @notifier&.notify_all
          id
        end

        def push_in(delay, class_name, args = [], options: {})
          push(class_name, args, realtime_now + delay.to_f, options: options)
        end

        def push_at(time, class_name, args = [], options: {})
          push(class_name, args, normalize_run_at(time), options: options)
        end

        private

        def normalize_run_at(time)
          time.respond_to?(:to_f) ? time.to_f : time
        end
      end

      class << self
        attr_accessor :default_client

        def enqueue(job_class, *args, options: {})
          push_via_default_client(:push, job_class, args, nil, options)
        end

        def enqueue_in(delay, job_class, *args, options: {})
          push_via_default_client(:push_in, job_class, args, delay, options)
        end

        def enqueue_at(time, job_class, *args, options: {})
          push_via_default_client(:push_at, job_class, args, time, options)
        end

        private

        def push_via_default_client(method_name, job_class, args, schedule_arg, call_site_options)
          ensure_configured!

          merged_options = build_options(job_class, call_site_options)
          class_name = resolve_class_name(job_class)

          case method_name
          when :push
            default_client.public_send(method_name, class_name, args, nil, options: merged_options)
          when :push_in, :push_at
            default_client.public_send(method_name, schedule_arg, class_name, args, options: merged_options)
          else
            raise ArgumentError, "Unsupported enqueue method: #{method_name.inspect}"
          end
        end

        def build_options(job_class, call_site_options)
          merged = resolve_options(job_class)
          explicit = normalize_call_site_options(call_site_options)

          merged.merge!(explicit.compact)
          apply_retry_overrides!(merged, explicit) if active_retry_override?(explicit)

          normalize_options_hash(merged)
        end

        def normalize_call_site_options(options)
          (options || {}).dup
        end

        def active_retry_override?(options)
          RETRY_OPTION_KEYS.any? { |key| options.key?(key) && !options[key].nil? }
        end

        def apply_retry_overrides!(merged, explicit)
          RETRY_OPTION_KEYS.each do |key|
            merged[key] = explicit[key] if explicit.key?(key)
          end
        end

        def normalize_options_hash(options)
          return EMPTY_OPTIONS if options.empty?

          Job::Options.new(**options).to_h.compact
        end

        def ensure_configured!
          raise 'Async::Background::Queue not configured' unless default_client
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
