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
            id         INTEGER PRIMARY KEY,
            class_name TEXT    NOT NULL,
            args       TEXT    NOT NULL DEFAULT '[]',
            status     TEXT    NOT NULL DEFAULT 'pending',
            created_at REAL    NOT NULL,
            run_at     REAL    NOT NULL,
            locked_by  INTEGER,
            locked_at  REAL
          );
          CREATE INDEX IF NOT EXISTS idx_jobs_status_run_at_id ON jobs(status, run_at, id);
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

        attr_reader :path

        def initialize(path: self.class.default_path, mmap: true)
          @path = path
          @mmap = mmap
          @db   = nil
          @schema_checked = false
          @last_cleanup_at = nil
        end

        def ensure_database!
          require_sqlite3
          db = SQLite3::Database.new(@path)
          db.execute('PRAGMA busy_timeout = 5000')
          db.execute_batch(PRAGMAS.call(@mmap ? MMAP_SIZE : 0))
          db.execute_batch(SCHEMA)
          db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
          db.close
          @schema_checked = true
        end

        def enqueue(class_name, args = [], run_at = nil)
          ensure_connection
          run_at ||= realtime_now
          @enqueue_stmt.execute(class_name, JSON.generate(args), realtime_now, run_at)
          @db.last_insert_row_id
        end

        def fetch(worker_id)
          ensure_connection
          now = realtime_now
          @db.execute("BEGIN IMMEDIATE")
          results = @fetch_stmt.execute(worker_id, now, now)
          row = results.first
          @fetch_stmt.reset!
          @db.execute("COMMIT")
          return unless row

          maybe_cleanup
          { id: row[0], class_name: row[1], args: JSON.parse(row[2]) }
        rescue
          @db.execute("ROLLBACK") rescue nil
          raise
        end
        def complete(job_id)
          ensure_connection
          @complete_stmt.execute(job_id)
        end

        def fail(job_id)
          ensure_connection
          @fail_stmt.execute(job_id)
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
          @db.execute('PRAGMA busy_timeout = 5000')
          @db.execute_batch(PRAGMAS.call(@mmap ? MMAP_SIZE : 0))

          unless @schema_checked
            @db.execute_batch(SCHEMA)
            @schema_checked = true
          end

          prepare_statements
          @last_cleanup_at = monotonic_now
        end

        def prepare_statements
          @enqueue_stmt = @db.prepare(
            "INSERT INTO jobs (class_name, args, created_at, run_at) VALUES (?, ?, ?, ?)"
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
            RETURNING id, class_name, args
          SQL

          @complete_stmt = @db.prepare("UPDATE jobs SET status = 'done' WHERE id = ?")
          @fail_stmt     = @db.prepare("UPDATE jobs SET status = 'failed' WHERE id = ?")

          @requeue_stmt = @db.prepare(
            "UPDATE jobs SET status = 'pending', locked_by = NULL, locked_at = NULL " \
            "WHERE status = 'running' AND locked_by = ?"
          )

          @cleanup_stmt = @db.prepare("DELETE FROM jobs WHERE status = 'done' AND created_at < ?")
        end

        def finalize_statements
          %i[enqueue_stmt fetch_stmt complete_stmt fail_stmt requeue_stmt cleanup_stmt].each do |name|
            stmt = instance_variable_get(:"@#{name}")
            stmt&.close rescue nil
            instance_variable_set(:"@#{name}", nil)
          end
        end

        def maybe_cleanup
          now = monotonic_now
          return if (now - @last_cleanup_at) < CLEANUP_INTERVAL

          @last_cleanup_at = now
          @cleanup_stmt.execute(realtime_now - CLEANUP_AGE)

          if @db.changes > 100
            @db.execute("PRAGMA incremental_vacuum")
          end
        end

      end
    end
  end
end
