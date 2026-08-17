# frozen_string_literal: true

require 'base64'

module Async
  module Background
    module Web
      module Cursor
        module_function

        def encode(timestamp, id)
          return if timestamp.nil? || id.nil?

          Base64.urlsafe_encode64("#{Float(timestamp)}:#{Integer(id)}", padding: false)
        end

        def encode_finished(finished_at, id) = encode(finished_at, id)
        def encode_pending(run_at, id) = encode(run_at, id)
        def decode_finished(value) = decode_as(:finished_at, value)
        def decode_pending(value) = decode_as(:run_at, value)

        def decode_as(key, value)
          timestamp, id = decode(value)
          return unless timestamp

          {key => timestamp, :id => id}
        end

        def decode(value)
          return if value.nil? || value.to_s.empty?

          timestamp_raw, id_raw, extra = Base64.urlsafe_decode64(value.to_s).split(':', 3)
          raise RequestError, 'invalid cursor' if timestamp_raw.nil? || id_raw.nil? || extra

          timestamp = Float(timestamp_raw)
          id = Integer(id_raw)
          raise RequestError, 'invalid cursor' unless timestamp.finite? && id.positive?

          [timestamp, id]
        rescue ArgumentError, TypeError
          raise RequestError, 'invalid cursor'
        end
        private_class_method :decode, :decode_as
      end
    end
  end
end
