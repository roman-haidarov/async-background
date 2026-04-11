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
          CREATE INDEX IF NOT EXISTS idx_jobs_pending ON jobs(run_at, id) WHERE status = 'pending';
        SQL

        POOL_SIZE = 4
        MMAP_SIZE = 268_435_456
        PRAGMAS = ->(mmap_size) {
          {
            mmap_size:          mmap_size,
            cache_size:         -16_000,
            temp_store:         'MEMORY',
            journal_size_limit: 67_108_864
          }
        }.freeze

        BUSY_TIMEOUT_SECONDS  = 5

        BUSY_FALLBACK_RETRIES = 2
        BUSY_FALLBACK_DELAY   = 0.017

        CLEANUP_INTERVAL = 300
        CLEANUP_AGE      = 3600

        RETRYABLE_ERRCODES = [5, 6, 261, 262, 517].freeze

        FETCH_SQL = <<~SQL
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

        COMPLETE_SQL = "UPDATE jobs SET status = 'done' WHERE id = ?"
        FAIL_SQL     = "UPDATE jobs SET status = 'failed' WHERE id = ?"
        RECOVER_SQL  = "UPDATE jobs SET status = 'pending', locked_by = NULL, locked_at = NULL " \
                       "WHERE status = 'running' AND locked_by = ?"
        ENQUEUE_SQL  = "INSERT INTO jobs (class_name, args, created_at, run_at) VALUES (?, ?, ?, ?) RETURNING id"
        CLEANUP_SQL  = "DELETE FROM jobs WHERE status = 'done' AND created_at < ?"

        attr_reader :path

        def initialize(path: self.class.default_path, mmap: true)
          @path = path
          @mmap = mmap
          @pool = nil
          @last_cleanup_at = nil
        end

        def ensure_database!
          require_extralite
          db = ::Extralite::Database.new(@path, wal: true, pragma: PRAGMAS.call(@mmap ? MMAP_SIZE : 0))
          db.busy_timeout = BUSY_TIMEOUT_SECONDS
          db.execute(SCHEMA)
          db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        ensure
          db&.close
        end

        def enqueue(class_name, args = [], run_at = nil)
          run_at ||= realtime_now
          with_connection do |db|
            with_busy_fallback(db) do
              db.query_single_splat(ENQUEUE_SQL, class_name, JSON.generate(args), realtime_now, run_at)
            end
          end
        end

        def fetch(worker_id)
          now = realtime_now

          row = with_connection do |db|
            with_busy_fallback(db) do
              db.query_single_hash(FETCH_SQL, worker_id, now, now)
            end
          end

          return unless row

          maybe_cleanup
          { id: row[:id], class_name: row[:class_name], args: JSON.parse(row[:args]) }
        end

        def complete(job_id)
          with_connection do |db|
            with_busy_fallback(db) { db.execute(COMPLETE_SQL, job_id) }
          end
        end

        def fail(job_id)
          with_connection do |db|
            with_busy_fallback(db) { db.execute(FAIL_SQL, job_id) }
          end
        end

        def recover(worker_id)
          with_connection do |db|
            with_busy_fallback(db) { db.execute(RECOVER_SQL, worker_id) }
            db.changes
          end
        end

        def close
          return unless @pool

          POOL_SIZE.times do
            db = @pool.pop(non_block: true) rescue nil
            next unless db

            begin
              db.execute("PRAGMA optimize")
            rescue ::Extralite::Error
              # advisory, ignore
            end

            begin
              db.close
            rescue ::Extralite::Error
              # best-effort
            end
          end

          @pool = nil
        end

        def self.default_path
          "async_background_queue.db"
        end

        private

        def require_extralite
          require 'extralite'
        rescue LoadError
          raise LoadError,
            "extralite gem is required for Async::Background::Queue. " \
            "Add `gem 'extralite-bundle', '~> 2.12'` to your Gemfile " \
            "(recommended for fiber-based apps like Falcon)."
        end

        def with_connection
          ensure_pool
          db = @pool.pop
          begin
            yield db
          ensure
            @pool.push(db) if db
          end
        end

        def ensure_pool
          return if @pool

          require_extralite
          pool = SizedQueue.new(POOL_SIZE)

          POOL_SIZE.times do |i|
            mmap = (@mmap && i.zero?) ? MMAP_SIZE : 0
            db = ::Extralite::Database.new(@path, wal: true, pragma: PRAGMAS.call(mmap))
            db.busy_timeout = BUSY_TIMEOUT_SECONDS
            db.on_progress { sleep(0) }

            pool.push(db)
          end

          @pool = pool
          @last_cleanup_at = monotonic_now
        end

        def with_busy_fallback(db)
          attempt = 0
          begin
            yield
          rescue ::Extralite::Error => e
            raise unless retryable_error?(db, e)

            attempt += 1
            raise if attempt > BUSY_FALLBACK_RETRIES

            sleep(BUSY_FALLBACK_DELAY)
            retry
          end
        end

        def retryable_error?(db, error)
          return true if error.is_a?(::Extralite::BusyError)

          RETRYABLE_ERRCODES.include?(db.errcode)
        rescue StandardError
          false
        end

        def maybe_cleanup
          now = monotonic_now
          return if @last_cleanup_at && (now - @last_cleanup_at) < CLEANUP_INTERVAL

          @last_cleanup_at = now
          with_connection do |db|
            db.execute(CLEANUP_SQL, realtime_now - CLEANUP_AGE)
            db.execute("PRAGMA incremental_vacuum") if db.changes > 100
          end
        end
      end
    end
  end
end
