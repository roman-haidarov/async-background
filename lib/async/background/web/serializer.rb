# frozen_string_literal: true

require 'json'
require_relative 'cursor'

module Async
  module Background
    module Web
      class Serializer
        EMPTY_OPTIONS = {}.freeze
        EMPTY_ARGS = [].freeze

        def initialize(config)
          @config = config
        end

        def overview(snapshot_data, metrics_data = nil)
          payload = {
            counts: snapshot_data.fetch(:counts),
            next_pending_run_at: snapshot_data[:next_pending_run_at],
            data_version: snapshot_data.fetch(:data_version),
            generated_at: snapshot_data.fetch(:generated_at)
          }
          payload[:metrics] = metrics_data if metrics_data
          payload
        end

        def executing(rows)
          rows.map { |row| executing_item(row) }
        end

        def claimed(rows)
          rows.map { |row| claimed_item(row) }
        end

        def done(rows)
          page(rows.map { |row| done_item(row) }) { |item| Cursor.encode_finished(item[:finished_at], item[:id]) }
        end

        def failed(rows)
          page(rows.map { |row| failed_item(row) }) { |item| Cursor.encode_finished(item[:finished_at], item[:id]) }
        end

        def pending(rows)
          page(rows.map { |row| pending_item(row) }) { |item| Cursor.encode_pending(item[:run_at], item[:id]) }
        end

        private

        def page(items)
          {items: items, next_cursor: items.empty? ? nil : yield(items.last)}
        end

        def executing_item(row)
          args, args_count = args_for(row[:args_raw])
          {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw]),
            started_at: row[:started_at],
            locked_by: row[:locked_by],
            locked_at: row[:locked_at]
          }
        end

        def claimed_item(row)
          args, args_count = args_for(row[:args_raw])
          {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw]),
            locked_at: row[:locked_at],
            locked_by: row[:locked_by]
          }
        end

        def done_item(row)
          args, args_count = args_for(row[:args_raw])
          {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw]),
            finished_at: row[:finished_at],
            duration_ms: row[:duration_ms]
          }
        end

        def failed_item(row)
          args, args_count = args_for(row[:args_raw])
          {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw]),
            finished_at: row[:finished_at],
            duration_ms: row[:duration_ms],
            last_error_class: row[:last_error_class],
            last_error_message: row[:last_error_message]
          }
        end

        def pending_item(row)
          args, args_count = args_for(row[:args_raw])
          {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw]),
            created_at: row[:created_at],
            run_at: row[:run_at]
          }
        end

        def args_for(raw)
          if raw.nil? || raw.empty? || raw == '[]'
            return [@config.expose_args ? redact(EMPTY_ARGS) : nil, 0]
          end

          parsed = parse_json(raw)
          count = parsed.is_a?(Array) ? parsed.length : 0
          return [nil, count] unless @config.expose_args

          [redact(parsed), count]
        end

        def redact(args)
          redactor = @config.redact_args
          redactor ? redactor.call(args) : args
        end

        def parse_options(raw)
          return EMPTY_OPTIONS if raw.nil? || raw.empty? || raw == '{}'

          parsed = parse_json(raw)
          parsed.is_a?(Hash) ? parsed : EMPTY_OPTIONS
        end

        def parse_json(raw)
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
