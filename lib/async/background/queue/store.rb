# frozen_string_literal: true

require 'json'
require_relative '../clock'

module Async
  module Background
    module Queue
      class Store
        include Clock

        SCHEMA = <<~SQL
          PRAGMA auto_vacuum = INCREMENTAL;
          CREATE TABLE IF NOT EXISTS jobs (
            id              INTEGER PRIMARY KEY,
            class_name      TEXT    NOT NULL,
            args            TEXT    NOT NULL DEFAULT '[]',
            options         TEXT,
            status          TEXT    NOT NULL DEFAULT 'pending',
            created_at      REAL    NOT NULL,
            run_at          REAL    NOT NULL,
            locked_by       INTEGER,
            locked_at       REAL,
            idempotency_key TEXT
          );
          CREATE INDEX IF NOT EXISTS idx_jobs_pending
            ON jobs(run_at, id) WHERE status = 'pending';
          CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_idempotency
            ON jobs(idempotency_key) WHERE idempotency_key IS NOT NULL;
        SQL

        MMAP_SIZE = 268_435_456
        PRAGMAS = ->(mmap_size) {
          <<~SQL
            PRAGMA journal_mode       = WAL;
            PRAGMA synchronous        = NORMAL;
            PRAGMA mmap_size          = #{mmap_size};
            PRAGMA cache_size         = -16000;
            PRAGMA temp_store         = MEMORY;
            PRAGMA busy_timeout       = 5000;
            PRAGMA journal_size_limit = 67108864;
          SQL
        }.freeze

        CLEANUP_INTERVAL = 300
        CLEANUP_AGE      = 3600

        MAX_BATCH_SIZE = 100

        attr_reader :path

        def initialize(path: self.class.default_path, mmap: true)
          @path            = path
          @pragma_sql      = PRAGMAS.call(mmap ? MMAP_SIZE : 0).freeze
          @db              = nil
          @schema_checked  = false
          @last_cleanup_at = nil
        end

        def ensure_database!
          require_sqlite3
          db = SQLite3::Database.new(@path)
          configure_database(db)
          db.execute_batch(SCHEMA)
          ensure_idempotency_column(db)
          db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
          db.close
          @schema_checked = true
        end

        def enqueue(class_name, args = [], run_at = nil, options: {}, idempotency_key: nil)
          ensure_connection
          now    = realtime_now
          run_at ||= now

          if idempotency_key.nil?
            @enqueue_stmt.execute(class_name, JSON.generate(args), dump_options(options), now, run_at, nil)
            return @db.last_insert_row_id
          end

          transaction do
            @enqueue_stmt.execute(class_name, JSON.generate(args), dump_options(options), now, run_at, idempotency_key)
            inserted_id = @db.last_insert_row_id

            if @db.changes == 1
              inserted_id
            else
              with_stmt(@select_by_idem_stmt) { |s| s.execute(idempotency_key).first&.first }
            end
          end
        end

        def enqueue_many(jobs)
          ensure_connection
          return [] if jobs.nil? || jobs.empty?

          results = []

          transaction do
            jobs.each_slice(MAX_BATCH_SIZE) do |chunk|
              results.concat(enqueue_chunk(chunk))
            end
          end

          results
        end

        def fetch(worker_id)
          ensure_connection
          now = realtime_now

          row = transaction { with_stmt(@fetch_stmt) { |s| s.execute(worker_id, now, now).first } }
          return unless row

          maybe_cleanup
          { id: row[0], class_name: row[1], args: JSON.parse(row[2]), options: load_options(row[3]) }
        end

        def fetch_batch(worker_id, limit:)
          ensure_connection
          return []                       if limit <= 0
          return [fetch(worker_id)].compact if limit == 1

          limit = [limit, MAX_BATCH_SIZE].min
          now   = realtime_now

          rows = transaction do
            sql = <<~SQL
              UPDATE jobs
              SET    status = 'running', locked_by = ?, locked_at = ?
              WHERE  id IN (
                SELECT id FROM jobs
                WHERE  status = 'pending' AND run_at <= ?
                ORDER BY run_at, id
                LIMIT  ?
              )
              RETURNING id, class_name, args, options
            SQL
            @db.execute(sql, [worker_id, now, now, limit])
          end

          maybe_cleanup
          rows.map do |row|
            { id: row[0], class_name: row[1], args: JSON.parse(row[2]), options: load_options(row[3]) }
          end
        end

        def complete(job_id)
          ensure_connection
          @complete_stmt.execute(job_id)
        end

        def complete_batch(ids, worker_id: nil)
          ensure_connection
          update_batch_status(ids, 'done', worker_id: worker_id)
        end

        def fail(job_id)
          ensure_connection
          @fail_stmt.execute(job_id)
        end

        def fail_batch(ids, worker_id: nil)
          ensure_connection
          update_batch_status(ids, 'failed', worker_id: worker_id)
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

        def retry_or_fail_batch(decisions, worker_id: nil)
          ensure_connection
          return { retried: [], failed: [] } if decisions.nil? || decisions.empty?

          retried_ids = []
          failed_ids  = []

          transaction do
            ids            = decisions.map { |d| d[:id] }
            stored_options = load_options_for_ids(ids)

            decisions.each do |decision|
              id     = decision[:id]
              stored = stored_options[id] || {}
              policy = stored.empty? ? normalize_options(decision[:fallback_options]) : Job::Options.new(**stored)

              if policy&.retry? && policy.next_attempt <= policy.retry
                advanced = policy.with_attempt(policy.next_attempt)
                run_at   = realtime_now + advanced.next_retry_delay(advanced.attempt)
                @retry_stmt.execute(run_at, dump_options(advanced.to_h.compact), id)
                retried_ids << id
              else
                failed_ids << id
              end
            end

            failed_ids.each_slice(MAX_BATCH_SIZE) do |chunk|
              placeholders = (['?'] * chunk.size).join(',')
              if worker_id
                sql = "UPDATE jobs SET status = 'failed', locked_by = NULL, locked_at = NULL WHERE status = 'running' AND locked_by = ? AND id IN (#{placeholders})"
                @db.execute(sql, [worker_id, *chunk])
              else
                sql = "UPDATE jobs SET status = 'failed', locked_by = NULL, locked_at = NULL WHERE id IN (#{placeholders})"
                @db.execute(sql, chunk)
              end
            end
          end

          { retried: retried_ids, failed: failed_ids }
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
            ensure_idempotency_column(@db)
            @schema_checked = true
          end

          prepare_statements
          @last_cleanup_at = monotonic_now
        end

        def ensure_idempotency_column(db)
          db.execute("ALTER TABLE jobs ADD COLUMN idempotency_key TEXT") rescue nil
          db.execute(<<~SQL)
            CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_idempotency
              ON jobs(idempotency_key) WHERE idempotency_key IS NOT NULL
          SQL
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
          return nil if options.nil? || (options.respond_to?(:empty?) && options.empty?)
          JSON.generate(options)
        end

        def load_options(json)
          json ? JSON.parse(json, symbolize_names: true) : {}
        end

        def update_batch_status(ids, status, worker_id: nil)
          return 0 if ids.nil? || ids.empty?

          total = 0
          transaction do
            ids.each_slice(MAX_BATCH_SIZE) do |chunk|
              placeholders = (['?'] * chunk.size).join(',')
              if worker_id
                sql = "UPDATE jobs SET status = ?, locked_by = NULL, locked_at = NULL WHERE status = 'running' AND locked_by = ? AND id IN (#{placeholders})"
                @db.execute(sql, [status, worker_id, *chunk])
              else
                sql = "UPDATE jobs SET status = ?, locked_by = NULL, locked_at = NULL WHERE id IN (#{placeholders})"
                @db.execute(sql, [status, *chunk])
              end
              total += @db.changes
            end
          end
          total
        end

        def load_options_for_ids(ids)
          return {} if ids.empty?

          result = {}
          ids.each_slice(MAX_BATCH_SIZE) do |chunk|
            placeholders = (['?'] * chunk.size).join(',')
            sql = "SELECT id, options FROM jobs WHERE id IN (#{placeholders})"
            @db.execute(sql, chunk).each do |row|
              result[row[0]] = load_options(row[1])
            end
          end
          result
        end

        def normalize_options(options)
          return if options.nil?
          return options if options.is_a?(Job::Options)

          Job::Options.new(**options)
        end

        def enqueue_chunk(chunk)
          now = realtime_now

          rows_sql = []
          params   = []
          chunk.each do |job|
            args_json    = JSON.generate(job[:args] || [])
            options_json = dump_options(job[:options] || {})
            run_at       = job[:run_at] || now
            ikey         = job[:idempotency_key]
            class_name   = job[:class_name]

            rows_sql << "(?, ?, ?, 'pending', ?, ?, ?)"
            params << class_name << args_json << options_json << now << run_at << ikey
          end

          sql = <<~SQL
            INSERT OR IGNORE INTO jobs
              (class_name, args, options, status, created_at, run_at, idempotency_key)
            VALUES #{rows_sql.join(',')}
            RETURNING id, idempotency_key
          SQL

          inserted_rows = @db.execute(sql, params)
          inserted_by_key = {}
          inserted_ids_no_key = []
          inserted_rows.each do |row|
            id, key = row[0], row[1]
            if key.nil?
              inserted_ids_no_key << id
            else
              inserted_by_key[key] = id
            end
          end

          missing_keys = chunk
            .map { |j| j[:idempotency_key] }
            .compact
            .reject { |k| inserted_by_key.key?(k) }
            .uniq

          existing_by_key = {}
          unless missing_keys.empty?
            placeholders = (['?'] * missing_keys.size).join(',')
            sql_lookup = "SELECT idempotency_key, id FROM jobs WHERE idempotency_key IN (#{placeholders})"
            @db.execute(sql_lookup, missing_keys).each do |row|
              existing_by_key[row[0]] = row[1]
            end
          end

          no_key_iter = inserted_ids_no_key.each
          seen_inserted_keys = {}
          chunk.map do |job|
            ikey = job[:idempotency_key]
            if ikey.nil?
              { id: no_key_iter.next, idempotency_key: nil, inserted: true }
            elsif inserted_by_key.key?(ikey) && !seen_inserted_keys[ikey]
              seen_inserted_keys[ikey] = true
              { id: inserted_by_key[ikey], idempotency_key: ikey, inserted: true }
            else
              { id: existing_by_key[ikey] || inserted_by_key[ikey], idempotency_key: ikey, inserted: false }
            end
          end
        end

        def prepare_statements
          @enqueue_stmt = @db.prepare(
            "INSERT OR IGNORE INTO jobs " \
            "(class_name, args, options, created_at, run_at, idempotency_key) " \
            "VALUES (?, ?, ?, ?, ?, ?)"
          )

          @select_by_idem_stmt = @db.prepare(
            "SELECT id FROM jobs WHERE idempotency_key = ?"
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
          [@enqueue_stmt, @select_by_idem_stmt, @fetch_stmt, @complete_stmt, @fail_stmt,
           @retry_state_stmt, @retry_stmt, @requeue_stmt, @cleanup_stmt].each do |stmt|
            stmt&.close rescue next
          end

          @enqueue_stmt = @select_by_idem_stmt = @fetch_stmt = @complete_stmt = @fail_stmt = nil
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
