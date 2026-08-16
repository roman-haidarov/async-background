# frozen_string_literal: true

require 'uri'

require_relative '../clock'
require_relative '../queue/sql'
require_relative 'sql'

module Async
  module Background
    module Web
      class Snapshot
        include Clock

        CacheEntry = Data.define(:value, :created_at)
        RAW_COLUMNS = {'args' => :args_raw, 'options' => :options_raw}.freeze

        ROW_KEYS = SQL::EXTRA_COLUMNS.to_h do |status, extra|
          columns = SQL::BASE_COLUMNS + extra
          [status, columns.map { |column| RAW_COLUMNS.fetch(column, column.to_sym) }.freeze]
        end.freeze

        PAGING = {
          executing: [SQL::EXECUTING, nil, nil].freeze,
          claimed: [SQL::CLAIMED, nil, nil].freeze,
          done: [SQL::DONE, SQL::DONE_AFTER, %i[finished_at id].freeze].freeze,
          failed: [SQL::FAILED, SQL::FAILED_AFTER, %i[finished_at id].freeze].freeze,
          pending: [SQL::PENDING, SQL::PENDING_AFTER, %i[run_at id].freeze].freeze
        }.freeze

        def initialize(path:, counts_cache_ttl:)
          @path = path
          @overview_cache_ttl = counts_cache_ttl
          @mutex = Mutex.new
          @db = nil
          @overview_cache = nil
        end

        def open!
          @mutex.synchronize do
            return self if connected?

            db = open_database
            configure_database(db)
            @db = db
          rescue StandardError
            db&.close unless db&.closed?
            raise
          end
          self
        end

        def close
          @mutex.synchronize do
            @db&.close unless @db&.closed?
            @db = nil
            @overview_cache = nil
          end
          self
        end

        def closed?
          @mutex.synchronize { !connected? }
        end

        def data_version
          with_database { |db| db.get_first_value(Queue::SQL::DATA_VERSION).to_i }
        end

        def overview(force: false)
          with_database do |db|
            now = monotonic_now
            return @overview_cache.value if !force && overview_cache_current?(now)

            value = read_transaction(db) { overview_from(db) }.freeze
            @overview_cache = CacheEntry.new(value, now)
            value
          end
        end

        def executing(limit:)
          list(:executing, limit: limit)
        end

        def claimed(limit:)
          list(:claimed, limit: limit)
        end

        def recent_done(limit:, cursor: nil)
          list(:done, limit: limit, cursor: cursor)
        end

        def recent_failed(limit:, cursor: nil)
          list(:failed, limit: limit, cursor: cursor)
        end

        def pending(limit:, cursor: nil)
          list(:pending, limit: limit, cursor: cursor)
        end

        private

        def connected?
          @db && !@db.closed?
        end

        def open_database
          require_sqlite3
          SQLite3::Database.new(database_uri, uri: true)
        rescue LoadError
          raise
        rescue StandardError => error
          raise UnavailableError, "cannot open queue database: #{error.message}"
        end

        def database_uri
          path = URI::RFC2396_PARSER.escape(File.expand_path(@path)).gsub('?', '%3F')
          "file:#{path}?mode=ro"
        end

        def configure_database(db)
          db.execute(SQL::BUSY_TIMEOUT)
          db.execute(SQL::QUERY_ONLY)
        end

        def with_database
          @mutex.synchronize do
            raise ClosedError, 'snapshot is closed' unless connected?

            yield @db
          end
        rescue ClosedError, UnavailableError
          raise
        rescue StandardError
          raise UnavailableError, 'queue database is unavailable'
        end

        def read_rows(sql, binds)
          with_database { |db| read_transaction(db) { db.execute(sql, binds) } }
        end

        def read_transaction(db)
          db.execute(SQL::BEGIN_READ_TRANSACTION)
          result = yield
          db.execute(SQL::COMMIT)
          result
        rescue StandardError
          rollback(db)
          raise
        end

        def rollback(db)
          db.execute(SQL::ROLLBACK)
        rescue StandardError
          nil
        end

        def overview_cache_current?(now)
          cache = @overview_cache
          cache && (now - cache.created_at) < @overview_cache_ttl
        end

        def overview_from(db)
          {
            counts: {
              executing: db.get_first_value(SQL::OVERVIEW_EXECUTING).to_i,
              claimed: db.get_first_value(SQL::OVERVIEW_CLAIMED).to_i,
              pending: db.get_first_value(SQL::OVERVIEW_PENDING).to_i,
              done: db.get_first_value(SQL::OVERVIEW_DONE).to_i,
              failed: db.get_first_value(SQL::OVERVIEW_FAILED).to_i
            }.freeze,
            next_pending_run_at: db.get_first_value(SQL::OVERVIEW_NEXT_PENDING),
            data_version: db.get_first_value(Queue::SQL::DATA_VERSION).to_i,
            generated_at: realtime_now
          }
        end

        def list(status, limit:, cursor: nil)
          sql, binds = page_query(status, limit, cursor)
          keys = ROW_KEYS.fetch(status)
          read_rows(sql, binds).map { |row| keys.zip(row).to_h }
        end

        def page_query(status, limit, cursor)
          first_sql, seek_sql, cursor_keys = PAGING.fetch(status)
          return [first_sql, [limit]] unless cursor

          [seek_sql, cursor_keys.map { |key| cursor.fetch(key) } << limit]
        end

        def require_sqlite3
          require 'sqlite3'
        rescue LoadError
          raise LoadError,
                "sqlite3 gem is required for Async::Background::Web. " \
                "Add `gem 'sqlite3', '~> 2.0'` to your Gemfile."
        end
      end
    end
  end
end
