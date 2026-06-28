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
                      :mount_path

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
        end

        def validate!
          validate_queue_path!
          validate_auth!
          validate_list_limit!
          validate_cache_ttl!
          validate_poll_interval!
          validate_transport!
          validate_stream!
          validate_redactor!
          validate_metrics!
          validate_mount_path!
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

        private

        def validate_queue_path!
          raise ConfigurationError, 'queue_path must be set' if queue_path.nil? || queue_path.to_s.empty?
        end

        def validate_auth!
          raise ConfigurationError, 'auth must be configured (gem ships no permissive default)' if auth.nil?

          return if auth.respond_to?(:call)

          raise ConfigurationError, 'auth must respond to #call(env) and return truthy on success'
        end

        def validate_list_limit!
          return if list_limit.is_a?(Integer) && list_limit.between?(1, MAX_LIST_LIMIT)

          raise ConfigurationError, "list_limit must be an Integer between 1 and #{MAX_LIST_LIMIT}"
        end

        def validate_cache_ttl!
          return if counts_cache_ttl.is_a?(Numeric) && counts_cache_ttl >= 0

          raise ConfigurationError, 'counts_cache_ttl must be a non-negative Numeric'
        end

        def validate_poll_interval!
          return if poll_interval_ms.is_a?(Integer) && poll_interval_ms >= 200

          raise ConfigurationError, 'poll_interval_ms must be an Integer >= 200'
        end

        def validate_transport!
          return if TRANSPORTS.include?(transport)

          raise ConfigurationError, "transport must be one of #{TRANSPORTS.inspect}"
        end

        def validate_stream!
          unless stream_poll_seconds.is_a?(Numeric) && stream_poll_seconds >= 0.1
            raise ConfigurationError, 'stream_poll_seconds must be a Numeric >= 0.1'
          end

          unless stream_heartbeat_seconds.is_a?(Numeric) && stream_heartbeat_seconds >= 5
            raise ConfigurationError, 'stream_heartbeat_seconds must be a Numeric >= 5'
          end

          return if stream_retry_ms.is_a?(Integer) && stream_retry_ms >= 500

          raise ConfigurationError, 'stream_retry_ms must be an Integer >= 500'
        end

        def validate_redactor!
          return unless expose_args && redact_args && !redact_args.respond_to?(:call)

          raise ConfigurationError, 'redact_args must respond to #call(args)'
        end

        def validate_metrics!
          return unless metrics_enabled?
          return if total_workers.is_a?(Integer) && total_workers.positive?

          raise ConfigurationError, 'metrics_path requires total_workers to be a positive Integer'
        end

        def validate_mount_path!
          return if mount_path.is_a?(String)

          raise ConfigurationError, 'mount_path must be a String'
        end
      end
    end
  end
end
