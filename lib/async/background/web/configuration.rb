# frozen_string_literal: true

require_relative '../queue/store'

module Async
  module Background
    module Web
      class Configuration
        DEFAULT_LIST_LIMIT = 50
        MAX_LIST_LIMIT = 200
        DEFAULT_COUNTS_TTL = 3.0
        DEFAULT_POLL_INTERVAL_MS = 2000
        DEFAULT_STREAM_POLL_SECONDS = 0.5
        DEFAULT_STREAM_HEARTBEAT_SECONDS = 25.0
        DEFAULT_STREAM_RETRY_MS = 5000
        TRANSPORTS = %i[polling sse].freeze
        DEFAULT_TRANSPORT = :sse
        DEFAULT_REDACT = ->(args) { args.is_a?(Array) ? args.map { '***' } : args }

        attr_accessor :queue_path,
                      :auth,
                      :expose_args,
                      :redact_args,
                      :metrics_path,
                      :total_workers,
                      :counts_cache_ttl,
                      :list_limit,
                      :poll_interval_ms,
                      :transport,
                      :stream_poll_seconds,
                      :stream_heartbeat_seconds,
                      :stream_retry_ms,
                      :title,
                      :mount_path,
                      :logger

        def initialize
          @queue_path = Queue::Store.default_path
          @auth = nil
          @expose_args = false
          @redact_args = DEFAULT_REDACT
          @metrics_path = nil
          @total_workers = nil
          @counts_cache_ttl = DEFAULT_COUNTS_TTL
          @list_limit = DEFAULT_LIST_LIMIT
          @poll_interval_ms = DEFAULT_POLL_INTERVAL_MS
          @transport = DEFAULT_TRANSPORT
          @stream_poll_seconds = DEFAULT_STREAM_POLL_SECONDS
          @stream_heartbeat_seconds = DEFAULT_STREAM_HEARTBEAT_SECONDS
          @stream_retry_ms = DEFAULT_STREAM_RETRY_MS
          @title = 'Async::Background'
          @mount_path = ''
          @logger = nil
        end

        RULES = [
          [:queue_path, ->(value, _) { !value.nil? && !value.to_s.empty? }, 'queue_path must be set'],
          [:auth, ->(value, _) { !value.nil? }, 'auth must be configured (gem ships no permissive default)'],
          [:auth, ->(value, _) { value.respond_to?(:call) },
            'auth must respond to #call(env) and return truthy on success'],
          [:list_limit, ->(value, _) { value.is_a?(Integer) && value.between?(1, MAX_LIST_LIMIT) },
            "list_limit must be an Integer between 1 and #{MAX_LIST_LIMIT}"],
          [:counts_cache_ttl, ->(value, _) { value.is_a?(Numeric) && value >= 0 },
            'counts_cache_ttl must be a non-negative Numeric'],
          [:poll_interval_ms, ->(value, _) { value.is_a?(Integer) && value >= 200 },
            'poll_interval_ms must be an Integer >= 200'],
          [:transport, ->(value, _) { TRANSPORTS.include?(value) },
            "transport must be one of #{TRANSPORTS.inspect}"],
          [:stream_poll_seconds, ->(value, _) { value.is_a?(Numeric) && value >= 0.1 },
            'stream_poll_seconds must be a Numeric >= 0.1'],
          [:stream_heartbeat_seconds, ->(value, _) { value.is_a?(Numeric) && value >= 5 },
            'stream_heartbeat_seconds must be a Numeric >= 5'],
          [:stream_retry_ms, ->(value, _) { value.is_a?(Integer) && value >= 500 },
            'stream_retry_ms must be an Integer >= 500'],
          [:redact_args, ->(value, config) { !config.expose_args || value.nil? || value.respond_to?(:call) },
            'redact_args must respond to #call(args)'],
          [:total_workers, ->(value, config) {
            !config.metrics_enabled? || (value.is_a?(Integer) && value.positive?)
          }, 'metrics_path requires total_workers to be a positive Integer'],
          [:mount_path, ->(value, _) { value.is_a?(String) }, 'mount_path must be a String'],
          [:mount_path, ->(value, _) { value.empty? || value.start_with?('/') },
            'mount_path must start with "/" or be empty'],
          [:mount_path, ->(value, _) { value.empty? || !value.end_with?('/') },
            'mount_path must not end with "/"'],
          [:mount_path, ->(value, _) { value.empty? || !value.match?(/[[:cntrl:]]/) },
            'mount_path must not contain control characters'],
          [:mount_path, ->(value, _) { value.empty? || !value.match?(/\s/) },
            'mount_path must not contain whitespace'],
          [:logger, ->(value, _) { value.nil? || (value.respond_to?(:warn) && value.respond_to?(:error)) },
            'logger must respond to #warn and #error']
        ].freeze

        def validate!
          RULES.each do |attribute, valid, message|
            raise ConfigurationError, message unless valid.call(public_send(attribute), self)
          end
          self
        end

        # Strict request-path parsing. Silently changing a malformed requested
        # page size to the default makes API clients repeat or skip work.
        def limit_for(requested)
          return list_limit if requested.nil? || requested.empty?

          value = Integer(requested, 10)
          raise RequestError, 'limit must be a positive integer' unless value.positive?

          [value, MAX_LIST_LIMIT].min
        rescue ArgumentError, TypeError
          raise RequestError, 'limit must be a positive integer'
        end

        def metrics_enabled?
          !metrics_path.nil?
        end
      end
    end
  end
end
