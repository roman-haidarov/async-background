# frozen_string_literal: true

require_relative '../clock'

module Async
  module Background
    module Queue
      EMPTY_OPTIONS = {}.freeze

      class Client
        include Clock

        def initialize(store:, notifier: nil)
          @store    = store
          @notifier = notifier
        end

        def push(class_name, args = [], run_at = nil, options: {}, idempotency_key: nil)
          id = @store.enqueue(class_name, args, run_at,
                              options: options,
                              idempotency_key: idempotency_key)
          @notifier&.notify_all
          id
        end

        def push_in(delay, class_name, args = [], options: {}, idempotency_key: nil)
          push(class_name, args, realtime_now + delay.to_f,
               options: options, idempotency_key: idempotency_key)
        end

        def push_at(time, class_name, args = [], options: {}, idempotency_key: nil)
          run_at = time.respond_to?(:to_f) ? time.to_f : time
          push(class_name, args, run_at,
               options: options, idempotency_key: idempotency_key)
        end

        def push_many(jobs)
          results = @store.enqueue_many(jobs)
          @notifier&.notify_all if results.any? { |r| r[:inserted] }
          results
        end
      end

      class << self
        attr_accessor :default_client

        def enqueue(job_class, *args, options: {}, idempotency_key: nil)
          ensure_configured!
          default_client.push(
            resolve_class_name(job_class), args, nil,
            options: build_options(job_class, options),
            idempotency_key: idempotency_key
          )
        end

        def enqueue_in(delay, job_class, *args, options: {}, idempotency_key: nil)
          ensure_configured!
          default_client.push_in(
            delay, resolve_class_name(job_class), args,
            options: build_options(job_class, options),
            idempotency_key: idempotency_key
          )
        end

        def enqueue_at(time, job_class, *args, options: {}, idempotency_key: nil)
          ensure_configured!
          default_client.push_at(
            time, resolve_class_name(job_class), args,
            options: build_options(job_class, options),
            idempotency_key: idempotency_key
          )
        end

        def enqueue_many(entries)
          ensure_configured!
          payload = entries.map do |entry|
            {
              class_name:      resolve_class_name(entry.fetch(:job_class)),
              args:            entry[:args] || [],
              options:         build_options(entry[:job_class], entry[:options] || {}),
              run_at:          coerce_run_at(entry[:run_at]),
              idempotency_key: entry[:idempotency_key]
            }
          end
          default_client.push_many(payload)
        end

        private

        RETRY_KEYS = %i[retry retry_delay backoff jitter].freeze
        private_constant :RETRY_KEYS

        def build_options(job_class, call_site)
          call_site ||= {}
          merged = resolve_options(job_class).merge(call_site.compact)
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

        def resolve_class_name(job_class)
          return job_class if job_class.is_a?(String)
          return job_class.name if job_class.respond_to?(:perform_now)

          raise ArgumentError, "#{job_class} must include Async::Background::Job"
        end

        def resolve_options(job_class)
          return {} unless job_class.respond_to?(:resolve_options)

          job_class.resolve_options.dup
        end

        def coerce_run_at(value)
          return nil if value.nil?
          value.respond_to?(:to_f) ? value.to_f : value
        end
      end
    end
  end
end
