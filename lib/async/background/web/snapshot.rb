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
          read_rows(SQL::EXECUTING, [limit]).map { |row| executing_row(row) }
        end

        def claimed(limit:)
          read_rows(SQL::CLAIMED, [limit]).map { |row| claimed_row(row) }
        end

        def recent_done(limit:, cursor: nil)
          sql, binds = terminal_query(SQL::DONE, SQL::DONE_AFTER, limit, cursor)
          read_rows(sql, binds).map { |row| done_row(row) }
        end

        def recent_failed(limit:, cursor: nil)
          sql, binds = terminal_query(SQL::FAILED, SQL::FAILED_AFTER, limit, cursor)
          read_rows(sql, binds).map { |row| failed_row(row) }
        end

        def pending(limit:, cursor: nil)
          sql, binds = pending_query(limit, cursor)
          read_rows(sql, binds).map { |row| pending_row(row) }
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
          path = URI::DEFAULT_PARSER.escape(File.expand_path(@path)).gsub('?', '%3F')
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
              claimed:   db.get_first_value(SQL::OVERVIEW_CLAIMED).to_i,
              pending:   db.get_first_value(SQL::OVERVIEW_PENDING).to_i,
              done:      db.get_first_value(SQL::OVERVIEW_DONE).to_i,
              failed:    db.get_first_value(SQL::OVERVIEW_FAILED).to_i
            }.freeze,
            next_pending_run_at: db.get_first_value(SQL::OVERVIEW_NEXT_PENDING),
            data_version: db.get_first_value(Queue::SQL::DATA_VERSION).to_i,
            generated_at: realtime_now
          }
        end

        def terminal_query(first_page_sql, next_page_sql, limit, cursor)
          return [first_page_sql, [limit]] unless cursor

          [next_page_sql, [cursor.fetch(:finished_at), cursor.fetch(:id), limit]]
        end

        def pending_query(limit, cursor)
          return [SQL::PENDING, [limit]] unless cursor

          [SQL::PENDING_AFTER, [cursor.fetch(:run_at), cursor.fetch(:id), limit]]
        end

        def executing_row(row)
          {
            id: row[0],
            class_name: row[1],
            args_raw: row[2],
            options_raw: row[3],
            started_at: row[4],
            locked_by: row[5],
            locked_at: row[6]
          }
        end

        def claimed_row(row)
          {
            id: row[0],
            class_name: row[1],
            args_raw: row[2],
            options_raw: row[3],
            locked_at: row[4],
            locked_by: row[5]
          }
        end

        def done_row(row)
          {
            id: row[0],
            class_name: row[1],
            args_raw: row[2],
            options_raw: row[3],
            finished_at: row[4],
            duration_ms: row[5]
          }
        end

        def failed_row(row)
          {
            id: row[0],
            class_name: row[1],
            args_raw: row[2],
            options_raw: row[3],
            finished_at: row[4],
            duration_ms: row[5],
            last_error_class: row[6],
            last_error_message: row[7]
          }
        end

        def pending_row(row)
          {
            id: row[0],
            class_name: row[1],
            args_raw: row[2],
            options_raw: row[3],
            created_at: row[4],
            run_at: row[5]
          }
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
