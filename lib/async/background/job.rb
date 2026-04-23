# frozen_string_literal: true

module Async
  module Background
    module Job
      DEFAULT_TIMEOUT = 120
      VALID_BACKOFFS = %i[fixed linear exponential].freeze

      Options = Data.define(:timeout, :retry, :retry_delay, :backoff, :attempt) do
        def initialize(**kwargs)
          values = normalize_values(kwargs)
          validate_values!(values)
          super(**values)
        end

        def retry?
          retry_limit.positive?
        end

        def retry_limit
          public_send(:retry)
        end

        def attempt_count
          public_send(:attempt) || 0
        end

        def next_attempt
          attempt_count + 1
        end

        def next_retry_delay(attempt = next_attempt)
          attempt = Integer(attempt)
          raise ArgumentError, "attempt must be > 0" unless attempt.positive?
          delay = public_send(:retry_delay)
          raise ArgumentError, "retry_delay must be configured when retry is enabled" unless delay

          case backoff_strategy
          when :fixed
            delay
          when :linear
            delay * attempt
          when :exponential
            delay * (2**(attempt - 1))
          end
        end

        def with_attempt(attempt)
          self.class.new(**to_h.merge(attempt: Integer(attempt)))
        end

        private

        def normalize_values(values)
          {
            timeout: coerce_timeout(values.fetch(:timeout, DEFAULT_TIMEOUT)),
            retry: coerce_retry_limit(values.fetch(:retry, 0)),
            retry_delay: coerce_optional_float(values, :retry_delay),
            backoff: coerce_backoff(values[:backoff]),
            attempt: coerce_optional_integer(values, :attempt)
          }
        end

        def validate_values!(values)
          validate_timeout!(values[:timeout])
          validate_retry_limit!(values[:retry])
          validate_retry_delay!(values[:retry], values[:retry_delay])
          validate_backoff!(values[:backoff])
          validate_attempt!(values[:attempt])
        end

        def coerce_timeout(value)
          Integer(value)
        end

        def coerce_retry_limit(value)
          Integer(value || 0)
        end

        def coerce_optional_float(values, key)
          return nil unless values.key?(key)
          value = values[key]
          value.nil? ? nil : Float(value)
        end

        def coerce_optional_integer(values, key)
          return nil unless values.key?(key)
          value = values[key]
          value.nil? ? nil : Integer(value)
        end

        def coerce_backoff(value)
          value&.to_sym
        end

        def validate_timeout!(value)
          raise ArgumentError, "timeout must be > 0" unless value.positive?
        end

        def validate_retry_limit!(value)
          raise ArgumentError, "retry must be >= 0" if value.negative?
        end

        def validate_retry_delay!(retry_limit, retry_delay)
          return unless retry_limit.positive?

          raise ArgumentError, "retry_delay is required when retry is enabled" if retry_delay.nil?
          raise ArgumentError, "retry_delay must be > 0" unless retry_delay.positive?
        end

        def validate_backoff!(value)
          return if value.nil? || VALID_BACKOFFS.include?(value)

          raise ArgumentError, "backoff must be one of: #{VALID_BACKOFFS.join(', ')}"
        end

        def validate_attempt!(value)
          return if value.nil?

          raise ArgumentError, "attempt must be >= 0" if value.negative?
        end

        def backoff_strategy
          public_send(:backoff) || :fixed
        end

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
          @options = normalize_options(values)
        end

        def resolve_options = @options || {}

        private

        def normalize_options(values)
          Options.new(**values).to_h.compact
        end
      end

      def perform(*args)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
