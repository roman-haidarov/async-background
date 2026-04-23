# frozen_string_literal: true

module Async
  module Background
    module Job
      DEFAULT_TIMEOUT = 120
      BACKOFFS        = %i[fixed linear exponential].freeze
      DEFAULT_JITTER_FOR = { fixed: 0.0, linear: 0.0, exponential: 0.5 }.freeze

      Options = Data.define(:timeout, :retry, :retry_delay, :backoff, :attempt, :jitter) do
        def initialize(timeout: DEFAULT_TIMEOUT, retry: 0, retry_delay: nil, backoff: :fixed, attempt: nil, jitter: nil)
          timeout     = Integer(timeout)
          retries     = Integer(binding.local_variable_get(:retry) || 0)
          retry_delay = Float(retry_delay) unless retry_delay.nil?
          backoff     = backoff.to_sym
          attempt     = Integer(attempt) unless attempt.nil?
          jitter      = Float(jitter) unless jitter.nil?

          raise ArgumentError, "timeout must be > 0"                        unless timeout.positive?
          raise ArgumentError, "retry must be >= 0"                         if     retries.negative?
          raise ArgumentError, "attempt must be >= 0"                       if     attempt && attempt.negative?
          raise ArgumentError, "backoff must be one of #{BACKOFFS.inspect}" unless BACKOFFS.include?(backoff)
          if retries.positive?
            raise ArgumentError, "retry_delay is required when retry > 0" if retry_delay.nil?
            raise ArgumentError, "retry_delay must be > 0"                unless retry_delay.positive?
          end
          raise ArgumentError, "jitter must be in [0, 1]" if jitter && !(0.0..1.0).cover?(jitter)

          super(timeout:, retry: retries, retry_delay:, backoff:, attempt:, jitter:)
        end

        def retry?          = self.retry.positive?
        def attempts_made   = attempt || 0
        def next_attempt    = attempts_made + 1
        def with_attempt(n) = with(attempt: Integer(n))
        def next_retry_delay(for_attempt = next_attempt, rng: Random)
          raise ArgumentError, "attempt must be > 0" unless for_attempt.positive?
          raise ArgumentError, "retry_delay must be configured" if retry_delay.nil?

          base = case backoff
          when :fixed       then retry_delay
          when :linear      then retry_delay * for_attempt
          when :exponential then retry_delay * (2**(for_attempt - 1))
          end

          factor = jitter || DEFAULT_JITTER_FOR[backoff]
          factor.zero? ? base : base * (1 + rng.rand * factor)
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def perform_now(*args) = new.perform(*args)

        def perform_async(*args, options: {})     = Async::Background::Queue.enqueue(self, *args, options: options)
        def perform_in(delay, *args, options: {}) = Async::Background::Queue.enqueue_in(delay, self, *args, options: options)
        def perform_at(time, *args, options: {})  = Async::Background::Queue.enqueue_at(time, self, *args, options: options)

        def options(**values)
          @options = Options.new(**values).to_h.compact
        end

        def resolve_options = @options || {}
      end

      def perform(*)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end
    end
  end
end
