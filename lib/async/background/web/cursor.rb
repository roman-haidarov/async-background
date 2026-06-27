# frozen_string_literal: true

require 'base64'

module Async
  module Background
    module Web
      module Cursor
        module_function

        def encode_finished(finished_at, id)
          encode(finished_at, id)
        end

        def encode_pending(run_at, id)
          encode(run_at, id)
        end

        def decode_finished(value)
          timestamp, id = decode(value)
          return unless timestamp

          {finished_at: timestamp, id: id}
        end

        def decode_pending(value)
          timestamp, id = decode(value)
          return unless timestamp

          {run_at: timestamp, id: id}
        end

        def encode(timestamp, id)
          return if timestamp.nil? || id.nil?

          Base64.urlsafe_encode64("#{Float(timestamp)}:#{Integer(id)}", padding: false)
        end
        private_class_method :encode

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
        private_class_method :decode
      end
    end
  end
end
