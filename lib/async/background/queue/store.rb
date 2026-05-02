# frozen_string_literal: true

require 'json'
require_relative '../clock'

module Async
  module Background
    module Queue
      SYNCHRONOUS_LEVELS = { normal: 'NORMAL', full: 'FULL', extra: 'EXTRA' }.freeze
      WAL_AUTOCHECKPOINT_RANGE = 100..10_000
      DEFAULTS = { mmap: true, synchronous: :normal, wal_autocheckpoint: 1_000 }.freeze
      MMAP_SIZE = 268_435_456

      StoreOptions = Data.define(:mmap, :synchronous, :wal_autocheckpoint) do
        def self.build(value = {}) = value.is_a?(self) ? value : new(**DEFAULTS, **value)

        def initialize(mmap:, synchronous:, wal_autocheckpoint:)
          unless mmap == true || mmap == false
            raise ArgumentError, "mmap must be true or false, got #{mmap.inspect}"
          end

          unless SYNCHRONOUS_LEVELS.key?(synchronous)
            raise ArgumentError,
              "synchronous must be one of #{SYNCHRONOUS_LEVELS.keys.inspect}, got #{synchronous.inspect}"
          end

          unless wal_autocheckpoint.is_a?(Integer) && WAL_AUTOCHECKPOINT_RANGE.cover?(wal_autocheckpoint)
            raise ArgumentError,
              "wal_autocheckpoint must be an Integer in #{WAL_AUTOCHECKPOINT_RANGE}, " \
              "got #{wal_autocheckpoint.inspect}"
          end

          super
        end

        def synchronous_pragma = SYNCHRONOUS_LEVELS.fetch(synchronous)
        def mmap_size = mmap ? MMAP_SIZE : 0

        def pragma_sql
          <<~SQL
            PRAGMA journal_mode       = WAL;
            PRAGMA synchronous        = #{synchronous_pragma};
            PRAGMA mmap_size          = #{mmap_size};
            PRAGMA cache_size         = -16000;
            PRAGMA temp_store         = MEMORY;
            PRAGMA journal_size_limit = 67108864;
            PRAGMA wal_autocheckpoint = #{wal_autocheckpoint};
          SQL
        end
      end

      class Store
        include Clock

        SCHEMA = <<~SQL
          PRAGMA auto_vacuum = INCREMENTAL;
          CREATE TABLE IF NOT EXISTS jobs (
            id         INTEGER PRIMARY KEY,
            class_name TEXT    NOT NULL,
            args       TEXT    NOT NULL DEFAULT '[]',
            options    TEXT,
            status     TEXT    NOT NULL DEFAULT 'pending',
            created_at REAL    NOT NULL,
            run_at     REAL    NOT NULL,
            locked_by  INTEGER,
            locked_at  REAL
          );
          CREATE INDEX IF NOT EXISTS idx_jobs_pending ON jobs(run_at, id) WHERE status = 'pending';
        SQL

        CLEANUP_INTERVAL = 300
        CLEANUP_AGE      = 3600

        attr_reader :path, :options

        def initialize(path: self.class.default_path, options: {})
          @path           = path
          @options        = StoreOptions.build(options)
          @pragma_sql     = @options.pragma_sql.freeze
          @db             = nil
          @schema_checked = false
          @last_cleanup_at = nil
        end

        def ensure_database!
          require_sqlite3
          db = SQLite3::Database.new(@path)
          configure_database(db)
          db.execute_batch(SCHEMA)
          db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
          db.close
          @schema_checked = true
        end

        def enqueue(class_name, args = [], run_at = nil, options: {})
          ensure_connection
          now = realtime_now
          @enqueue_stmt.execute(class_name, JSON.generate(args), dump_options(options), now, run_at || now)
          @db.last_insert_row_id
        end

        def fetch(worker_id)
          ensure_connection
          now = realtime_now

          row = transaction { with_stmt(@fetch_stmt) { |s| s.execute(worker_id, now, now).first } }
          return unless row

          maybe_cleanup
          { id: row[0], class_name: row[1], args: JSON.parse(row[2]), options: load_options(row[3]) }
        end

        def complete(job_id)
          ensure_connection
          @complete_stmt.execute(job_id)
        end

        def fail(job_id)
          ensure_connection
          @fail_stmt.execute(job_id)
        end

        def retry_or_fail(job_id, fallback_options: nil)
          ensure_connection

          transaction do
            stored = with_stmt(@retry_state_stmt) { |s| load_options(s.execute(job_id).first&.first) }
            policy = stored.empty? ? normalize_options(fallback_options) : Job::Options.new(**stored)

            if policy&.retry? && policy.next_attempt <= policy.retry
              advanced = policy.with_attempt(policy.next_attempt)
              @retry_stmt.execute(realtime_now + advanced.next_retry_delay(advanced.attempt), dump_options(advanced.to_h.compact), job_id)
              :retried
            else
              @fail_stmt.execute(job_id)
              :failed
            end
          end
        end

        def recover(worker_id)
          ensure_connection
          @requeue_stmt.execute(worker_id)
          @db.changes
        end

        def close
          return unless @db && !@db.closed?

          finalize_statements
          @db.execute("PRAGMA optimize") rescue nil
          @db.close
          @db = nil
        end

        def self.default_path
          "async_background_queue.db"
        end

        private

        def require_sqlite3
          require 'sqlite3'
        rescue LoadError
          raise LoadError,
            "sqlite3 gem is required for Async::Background::Queue. " \
            "Add `gem 'sqlite3', '~> 2.0'` to your Gemfile."
        end

        def ensure_connection
          return if @db && !@db.closed?

          require_sqlite3
          finalize_statements
          @db = SQLite3::Database.new(@path)
          configure_database(@db)

          unless @schema_checked
            @db.execute_batch(SCHEMA)
            @db.execute("ALTER TABLE jobs ADD COLUMN options TEXT") rescue nil
            @schema_checked = true
          end

          prepare_statements
          @last_cleanup_at = monotonic_now
        end

        def configure_database(db)
          db.execute("PRAGMA busy_timeout = 5000")
          db.execute_batch(@pragma_sql)
        end

        def transaction
          @db.execute("BEGIN IMMEDIATE")
          result = yield
          @db.execute("COMMIT")
          result
        rescue
          @db.execute("ROLLBACK") rescue nil
          raise
        end

        def with_stmt(stmt)
          yield stmt
        ensure
          stmt.reset! rescue nil
        end

        def dump_options(options)
          options.empty? ? nil : JSON.generate(options)
        end

        def load_options(json)
          json ? JSON.parse(json, symbolize_names: true) : {}
        end

        def normalize_options(options)
          return if options.nil?
          return options if options.is_a?(Job::Options)

          Job::Options.new(**options)
        end

        def prepare_statements
          @enqueue_stmt = @db.prepare(
            "INSERT INTO jobs (class_name, args, options, created_at, run_at) VALUES (?, ?, ?, ?, ?)"
          )

          @fetch_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    status = 'running', locked_by = ?, locked_at = ?
            WHERE  id = (
              SELECT id FROM jobs
              WHERE  status = 'pending' AND run_at <= ?
              ORDER BY run_at, id
              LIMIT 1
            )
            RETURNING id, class_name, args, options
          SQL

          @complete_stmt    = @db.prepare("UPDATE jobs SET status = 'done',   locked_by = NULL, locked_at = NULL WHERE id = ?")
          @fail_stmt        = @db.prepare("UPDATE jobs SET status = 'failed', locked_by = NULL, locked_at = NULL WHERE id = ?")
          @retry_state_stmt = @db.prepare("SELECT options FROM jobs WHERE id = ?")
          @retry_stmt       = @db.prepare(
            "UPDATE jobs SET status = 'pending', locked_by = NULL, locked_at = NULL, run_at = ?, options = ? WHERE id = ?"
          )
          @requeue_stmt = @db.prepare(
            "UPDATE jobs SET status = 'pending', locked_by = NULL, locked_at = NULL " \
            "WHERE status = 'running' AND locked_by = ?"
          )
          @cleanup_stmt = @db.prepare("DELETE FROM jobs WHERE status = 'done' AND created_at < ?")
        end

        def finalize_statements
          [@enqueue_stmt, @fetch_stmt, @complete_stmt, @fail_stmt,
           @retry_state_stmt, @retry_stmt, @requeue_stmt, @cleanup_stmt].each do |stmt|
            stmt&.close rescue next
          end

          @enqueue_stmt = @fetch_stmt = @complete_stmt = @fail_stmt = nil
          @retry_state_stmt = @retry_stmt = @requeue_stmt = @cleanup_stmt = nil
        end

        def maybe_cleanup
          now = monotonic_now
          return if (now - @last_cleanup_at) < CLEANUP_INTERVAL

          @last_cleanup_at = now
          @cleanup_stmt.execute(realtime_now - CLEANUP_AGE)
          @db.execute("PRAGMA incremental_vacuum") if @db.changes > 100
        end
      end
    end
  end
end
