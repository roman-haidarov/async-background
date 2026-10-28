# frozen_string_literal: true

module Async
  module Background
    module Job
      DEFAULT_TIMEOUT = 120
      EMPTY_OPTIONS   = {}.freeze
      BACKOFFS        = %i[fixed linear exponential].freeze
      DEFAULT_JITTER_FOR = { fixed: 0.0, linear: 0.0, exponential: 0.5 }.freeze

      NormalizedOptions = Data.define(:timeout, :retries, :retry_delay, :backoff, :attempt, :jitter)
      private_constant :NormalizedOptions

      Options = Data.define(:timeout, :retry, :retry_delay, :backoff, :attempt, :jitter) do
        def initialize(timeout: DEFAULT_TIMEOUT, retry: 0, retry_delay: nil, backoff: :fixed, attempt: nil, jitter: nil)
          retries = Integer(binding.local_variable_get(:retry) || 0)
          settings = NormalizedOptions.new(
            Integer(timeout), retries, retry_delay.nil? ? nil : Float(retry_delay), backoff.to_sym,
            attempt.nil? ? nil : Integer(attempt), jitter.nil? ? nil : Float(jitter)
          )
          validate_options!(settings)
          super(timeout: settings.timeout, retry: settings.retries, retry_delay: settings.retry_delay,
                backoff: settings.backoff, attempt: settings.attempt, jitter: settings.jitter)
        end

        def retry?          = self.retry.positive?
        def attempts_made   = attempt || 0
        def next_attempt    = attempts_made + 1
        def with_attempt(n) = with(attempt: Integer(n))

        def next_retry_delay(for_attempt = next_attempt, rng: Random)
          raise ArgumentError, 'attempt must be > 0' unless for_attempt.positive?
          raise ArgumentError, 'retry_delay must be configured' if retry_delay.nil?

          apply_jitter(base_retry_delay(for_attempt), rng)
        end

        private

        def validate_options!(settings)
          validate_timeout!(settings.timeout)
          validate_retry_count!(settings.retries)
          validate_attempt!(settings.attempt)
          validate_backoff!(settings.backoff)
          validate_retry_delay!(settings)
          validate_jitter!(settings.jitter)
        end

        def validate_timeout!(timeout)
          raise ArgumentError, 'timeout must be > 0' unless timeout.positive?
        end

        def validate_retry_count!(retries)
          raise ArgumentError, 'retry must be >= 0' if retries.negative?
        end

        def validate_attempt!(attempt)
          raise ArgumentError, 'attempt must be >= 0' if attempt&.negative?
        end

        def validate_backoff!(backoff)
          raise ArgumentError, "backoff must be one of #{BACKOFFS.inspect}" unless BACKOFFS.include?(backoff)
        end

        def validate_retry_delay!(settings)
          return unless settings.retries.positive?

          raise ArgumentError, 'retry_delay is required when retry > 0' if settings.retry_delay.nil?
          raise ArgumentError, 'retry_delay must be > 0' unless settings.retry_delay.positive?
        end

        def validate_jitter!(jitter)
          raise ArgumentError, 'jitter must be in [0, 1]' if jitter && !(0.0..1.0).cover?(jitter)
        end

        def base_retry_delay(for_attempt)
          multiplier = case backoff
                       when :fixed then 1
                       when :linear then for_attempt
                       when :exponential then 2**(for_attempt - 1)
                       end
          retry_delay * multiplier
        end

        def apply_jitter(base, rng)
          factor = jitter || DEFAULT_JITTER_FOR[backoff]
          factor.zero? ? base : base * (1 + rng.rand * factor)
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def perform_now(*args) = new.perform(*args)

        def perform_async(*args, options: EMPTY_OPTIONS)
          Async::Background::Queue.enqueue(self, *args, options: options)
        end

        def perform_in(delay, *args, options: EMPTY_OPTIONS)
          Async::Background::Queue.enqueue_in(delay, self, *args, options: options)
        end

        def perform_at(time, *args, options: EMPTY_OPTIONS)
          Async::Background::Queue.enqueue_at(time, self, *args, options: options)
        end

        def options(**values)
          @options = Options.new(**values).to_h.compact
        end

        def resolve_options = @options || {}
        def queue_options = @options || EMPTY_OPTIONS
      end

      def perform(*)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
