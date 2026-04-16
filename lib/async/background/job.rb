# frozen_string_literal: true

module Async
  module Background
    module Job
      DEFAULT_TIMEOUT = 120
      VALID_BACKOFFS = %i[fixed linear exponential].freeze

      Options = Data.define(:timeout, :retry, :retry_delay, :backoff, :attempt) do
        def initialize(**kwargs)
          timeout_value = Integer(kwargs.fetch(:timeout, DEFAULT_TIMEOUT))
          retry_value = Integer(kwargs.fetch(:retry, 0) || 0)
          retry_delay_raw = kwargs.key?(:retry_delay) ? kwargs[:retry_delay] : nil
          retry_delay_value = retry_delay_raw.nil? ? nil : Float(retry_delay_raw)
          backoff_value = normalize_backoff(kwargs[:backoff])
          attempt_raw = kwargs.key?(:attempt) ? kwargs[:attempt] : nil
          attempt_value = attempt_raw.nil? ? nil : Integer(attempt_raw)

          validate_timeout!(timeout_value)
          validate_retry!(retry_value)
          validate_retry_delay!(retry_value, retry_delay_value)
          validate_backoff!(backoff_value)
          validate_attempt!(attempt_value)

          super(
            timeout: timeout_value,
            retry: retry_value,
            retry_delay: retry_delay_value,
            backoff: backoff_value,
            attempt: attempt_value
          )
        end

        def retry?
          __send__(:retry).positive?
        end

        def attempt_count
          Integer(__send__(:attempt) || 0)
        end

        def next_attempt
          attempt_count + 1
        end

        def next_retry_delay(attempt = next_attempt)
          attempt = Integer(attempt)
          raise ArgumentError, "attempt must be > 0" unless attempt.positive?

          delay = __send__(:retry_delay)
          strategy = __send__(:backoff) || :fixed

          raise ArgumentError, "retry_delay must be configured when retry is enabled" unless delay

          case strategy
          when :fixed
            delay
          when :linear
            delay * attempt
          when :exponential
            delay * (2**(attempt - 1))
          else
            raise ArgumentError, "Unsupported backoff: #{strategy.inspect}"
          end
        end

        def with_attempt(attempt)
          self.class.new(**to_h.merge(attempt: Integer(attempt)))
        end

        private

        def normalize_backoff(value)
          return nil if value.nil?

          value.to_sym
        end

        def validate_timeout!(value)
          raise ArgumentError, "timeout must be > 0" unless value.positive?
        end

        def validate_retry!(value)
          raise ArgumentError, "retry must be >= 0" if value.negative?
        end

        def validate_retry_delay!(retry_value, delay_value)
          return if retry_value.zero? && delay_value.nil?
          return if retry_value.zero? && !delay_value.nil?

          raise ArgumentError, "retry_delay is required when retry is enabled" if delay_value.nil?
          raise ArgumentError, "retry_delay must be >= 0" if delay_value.negative?
        end

        def validate_backoff!(value)
          return if value.nil? || VALID_BACKOFFS.include?(value)

          raise ArgumentError, "backoff must be one of: #{VALID_BACKOFFS.join(', ')}"
        end

        def validate_attempt!(value)
          return if value.nil?

          raise ArgumentError, "attempt must be >= 0" if value.negative?
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
          @options = Options.new(**values).to_h.compact
        end

        def resolve_options = @options || {}
      end

      def perform(*args)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
