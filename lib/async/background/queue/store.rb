# frozen_string_literal: true

require 'json'
require 'securerandom'
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
            id                 INTEGER PRIMARY KEY,
            class_name         TEXT    NOT NULL,
            args               TEXT    NOT NULL DEFAULT '[]',
            options            TEXT,
            status             TEXT    NOT NULL DEFAULT 'pending',
            created_at         REAL    NOT NULL,
            run_at             REAL    NOT NULL,
            locked_by          INTEGER,
            locked_at          REAL,
            claim_token        TEXT,
            started_at         REAL,
            finished_at        REAL,
            duration_ms        INTEGER,
            last_error_class   TEXT,
            last_error_message TEXT
          );
          CREATE INDEX IF NOT EXISTS idx_jobs_pending
            ON jobs(run_at, id) WHERE status = 'pending';
          CREATE INDEX IF NOT EXISTS idx_jobs_status_finished_at
            ON jobs(status, finished_at);
        SQL

        MIGRATIONS = [
          "ALTER TABLE jobs ADD COLUMN options TEXT",
          "ALTER TABLE jobs ADD COLUMN claim_token TEXT",
          "ALTER TABLE jobs ADD COLUMN started_at REAL",
          "ALTER TABLE jobs ADD COLUMN finished_at REAL",
          "ALTER TABLE jobs ADD COLUMN duration_ms INTEGER",
          "ALTER TABLE jobs ADD COLUMN last_error_class TEXT",
          "ALTER TABLE jobs ADD COLUMN last_error_message TEXT",
          "UPDATE jobs SET finished_at = created_at " \
            "WHERE finished_at IS NULL AND status IN ('done', 'failed')",
          "CREATE INDEX IF NOT EXISTS idx_jobs_status_finished_at " \
            "ON jobs(status, finished_at)"
        ].freeze

        CLEANUP_INTERVAL       = 300
        CLEANUP_AGE            = 3600
        FAILED_RETENTION_AGE   = 7 * 24 * 3600
        ERROR_MESSAGE_MAX_LEN  = 2_000

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
          MIGRATIONS.each { |sql| db.execute(sql) rescue nil }
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
          now    = realtime_now
          token  = generate_claim_token

          row = transaction { with_stmt(@fetch_stmt) { |s| s.execute(worker_id, now, token, now).first } }
          return unless row

          maybe_cleanup
          {
            id:          row[0],
            class_name:  row[1],
            args:        JSON.parse(row[2]),
            options:     load_options(row[3]),
            claim_token: token
          }
        end

        def mark_started!(job_id, claim_token:, started_at: realtime_now)
          ensure_connection
          @mark_started_stmt.execute(started_at, job_id, claim_token)
          @db.changes.positive?
        end

        def complete(job_id, claim_token:, finished_at: realtime_now, duration_ms: nil)
          ensure_connection
          @complete_stmt.execute(finished_at, duration_ms, job_id, claim_token)
          @db.changes.positive?
        end

        def fail(job_id, claim_token:, error_class: nil, error_message: nil, finished_at: realtime_now, duration_ms: nil)
          ensure_connection
          @fail_stmt.execute(
            finished_at,
            duration_ms,
            error_class&.to_s,
            truncate_message(error_message),
            job_id,
            claim_token
          )
          @db.changes.positive?
        end

        def retry_or_fail(job_id, claim_token:, error_class: nil, error_message: nil, fallback_options: nil, finished_at: realtime_now, duration_ms: nil)
          ensure_connection

          transaction do
            stored = with_stmt(@retry_state_stmt) { |s| load_options(s.execute(job_id, claim_token).first&.first) }

            unless lease_alive?(job_id, claim_token)
              next nil
            end

            policy = stored.empty? ? normalize_options(fallback_options) : Job::Options.new(**stored)

            if policy&.retry? && policy.next_attempt <= policy.retry
              advanced = policy.with_attempt(policy.next_attempt)
              @retry_stmt.execute(
                realtime_now + advanced.next_retry_delay(advanced.attempt),
                dump_options(advanced.to_h.compact),
                error_class&.to_s,
                truncate_message(error_message),
                job_id,
                claim_token
              )
              @db.changes.positive? ? :retried : nil
            else
              @fail_stmt.execute(
                finished_at,
                duration_ms,
                error_class&.to_s,
                truncate_message(error_message),
                job_id,
                claim_token
              )
              @db.changes.positive? ? :failed : nil
            end
          end
        end

        def recover(worker_id)
          ensure_connection
          @requeue_stmt.execute(worker_id)
          @db.changes
        end

        def next_pending_run_at
          ensure_connection
          row = with_stmt(@next_pending_stmt) { |s| s.execute.first }
          row && row[0]
        end

        def data_version
          ensure_connection
          @db.execute("PRAGMA data_version").first[0]
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

        def generate_claim_token
          SecureRandom.hex(16)
        end

        def truncate_message(msg)
          return nil if msg.nil?
          s = msg.to_s
          s.length > ERROR_MESSAGE_MAX_LEN ? s.byteslice(0, ERROR_MESSAGE_MAX_LEN) : s
        end

        def lease_alive?(job_id, claim_token)
          with_stmt(@lease_check_stmt) do |s|
            row = s.execute(job_id, claim_token).first
            !row.nil?
          end
        end

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
            MIGRATIONS.each { |sql| @db.execute(sql) rescue nil }
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
            SET    status      = 'running',
                   locked_by   = ?,
                   locked_at   = ?,
                   claim_token = ?,
                   started_at  = NULL,
                   finished_at = NULL,
                   duration_ms = NULL
            WHERE  id = (
              SELECT id FROM jobs
              WHERE  status = 'pending' AND run_at <= ?
              ORDER BY run_at, id
              LIMIT 1
            )
            RETURNING id, class_name, args, options
          SQL

          @mark_started_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    started_at = ?
            WHERE  id = ? AND claim_token = ? AND status = 'running' AND started_at IS NULL
          SQL

          @complete_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    status      = 'done',
                   locked_by   = NULL,
                   locked_at   = NULL,
                   finished_at = ?,
                   duration_ms = ?
            WHERE  id = ? AND claim_token = ? AND status = 'running'
          SQL

          @fail_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    status             = 'failed',
                   locked_by          = NULL,
                   locked_at          = NULL,
                   finished_at        = ?,
                   duration_ms        = ?,
                   last_error_class   = ?,
                   last_error_message = ?
            WHERE  id = ? AND claim_token = ? AND status = 'running'
          SQL

          @retry_state_stmt = @db.prepare(
            "SELECT options FROM jobs WHERE id = ? AND claim_token = ? AND status = 'running'"
          )
          @lease_check_stmt = @db.prepare(
            "SELECT 1 FROM jobs WHERE id = ? AND claim_token = ? AND status = 'running'"
          )

          @retry_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    status             = 'pending',
                   locked_by          = NULL,
                   locked_at          = NULL,
                   claim_token        = NULL,
                   started_at         = NULL,
                   finished_at        = NULL,
                   duration_ms        = NULL,
                   run_at             = ?,
                   options            = ?,
                   last_error_class   = ?,
                   last_error_message = ?
            WHERE  id = ? AND claim_token = ? AND status = 'running'
          SQL

          @requeue_stmt = @db.prepare(<<~SQL)
            UPDATE jobs
            SET    status      = 'pending',
                   locked_by   = NULL,
                   locked_at   = NULL,
                   claim_token = NULL,
                   started_at  = NULL
            WHERE  status = 'running' AND locked_by = ?
          SQL

          @cleanup_done_stmt = @db.prepare(
            "DELETE FROM jobs WHERE status = 'done' AND finished_at IS NOT NULL AND finished_at < ?"
          )
          @cleanup_failed_stmt = @db.prepare(
            "DELETE FROM jobs WHERE status = 'failed' AND finished_at IS NOT NULL AND finished_at < ?"
          )

          @next_pending_stmt = @db.prepare(
            "SELECT MIN(run_at) FROM jobs WHERE status = 'pending'"
          )
        end

        def finalize_statements
          [
            @enqueue_stmt, @fetch_stmt, @mark_started_stmt,
            @complete_stmt, @fail_stmt, @retry_state_stmt, @lease_check_stmt,
            @retry_stmt, @requeue_stmt,
            @cleanup_done_stmt, @cleanup_failed_stmt,
            @next_pending_stmt
          ].each { |stmt| stmt&.close rescue next }

          @enqueue_stmt = @fetch_stmt = @mark_started_stmt = nil
          @complete_stmt = @fail_stmt = @retry_state_stmt = @lease_check_stmt = nil
          @retry_stmt = @requeue_stmt = nil
          @cleanup_done_stmt = @cleanup_failed_stmt = nil
          @next_pending_stmt = nil
        end

        def maybe_cleanup
          now_mono = monotonic_now
          return if (now_mono - @last_cleanup_at) < CLEANUP_INTERVAL

          @last_cleanup_at = now_mono
          now_real = realtime_now
          @cleanup_done_stmt.execute(now_real - CLEANUP_AGE)
          @cleanup_failed_stmt.execute(now_real - FAILED_RETENTION_AGE)
          @db.execute("PRAGMA incremental_vacuum") if @db.changes > 100
        end
      end
    end
  end
end
