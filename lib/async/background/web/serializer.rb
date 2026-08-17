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
          rows.map { |row| item(:executing, row) }
        end

        def claimed(rows)
          rows.map { |row| item(:claimed, row) }
        end

        def done(rows)
          page(:done, rows)
        end

        def failed(rows)
          page(:failed, rows)
        end

        def pending(rows)
          page(:pending, rows)
        end

        private

        EXTRA_FIELDS = {
          executing: %i[started_at locked_by locked_at].freeze,
          claimed: %i[locked_at locked_by].freeze,
          done: %i[finished_at duration_ms].freeze,
          failed: %i[finished_at duration_ms last_error_class last_error_message].freeze,
          pending: %i[created_at run_at].freeze
        }.freeze

        CURSOR_KEY = {done: :finished_at, failed: :finished_at, pending: :run_at}.freeze

        def item(kind, row)
          args, args_count = args_for(row[:args_raw])

          fields = {
            id: row[:id],
            class_name: row[:class_name],
            args: args,
            args_count: args_count,
            options: parse_options(row[:options_raw])
          }
          EXTRA_FIELDS.fetch(kind).each { |name| fields[name] = row[name] }
          fields
        end

        def page(kind, rows)
          items = rows.map { |row| item(kind, row) }
          last = items.last
          cursor = last && Cursor.encode(last[CURSOR_KEY.fetch(kind)], last[:id])

          {items: items, next_cursor: cursor}
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
