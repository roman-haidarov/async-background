# frozen_string_literal: true

module Async
  module Background
    module Queue
      module SQL
        USER_VERSION = 'PRAGMA user_version'.freeze
        DATA_VERSION = 'PRAGMA data_version'.freeze
        BUSY_TIMEOUT = 'PRAGMA busy_timeout'.freeze
        TABLE_INFO = 'PRAGMA table_info(jobs)'.freeze
        OPTIMIZE = 'PRAGMA optimize'.freeze
        INCREMENTAL_VACUUM = 'PRAGMA incremental_vacuum'.freeze
        AUTO_VACUUM_INCREMENTAL = 'PRAGMA auto_vacuum = INCREMENTAL'.freeze
        BEGIN_IMMEDIATE = 'BEGIN IMMEDIATE'.freeze
        COMMIT = 'COMMIT'.freeze
        ROLLBACK = 'ROLLBACK'.freeze

        def self.busy_timeout(milliseconds)
          "PRAGMA busy_timeout = #{Integer(milliseconds)}"
        end

        def self.user_version(version)
          "PRAGMA user_version = #{Integer(version)}"
        end

        def self.add_column(name, sql_type)
          "ALTER TABLE jobs ADD COLUMN #{name} #{sql_type}"
        end

        CREATE_SCHEMA = <<~SQL.freeze
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
            ON jobs(run_at) WHERE status = 'pending';
        SQL

        INSERT_JOB = <<~SQL.freeze
          INSERT INTO jobs (class_name, args, options, created_at, run_at)
          VALUES (?, ?, ?, ?, ?)
        SQL

        FETCH_NEXT_JOB = <<~SQL.freeze
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

        MARK_STARTED = <<~SQL.freeze
          UPDATE jobs
          SET    started_at = ?
          WHERE  id = ? AND claim_token = ? AND status = 'running' AND started_at IS NULL
        SQL

        COMPLETE_JOB = <<~SQL.freeze
          UPDATE jobs
          SET    status      = 'done',
                 locked_by   = NULL,
                 locked_at   = NULL,
                 finished_at = ?,
                 duration_ms = ?
          WHERE  id = ? AND claim_token = ? AND status = 'running'
        SQL

        FAIL_JOB = <<~SQL.freeze
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

        RETRY_STATE = <<~SQL.freeze
          SELECT options
          FROM jobs
          WHERE id = ? AND claim_token = ? AND status = 'running'
        SQL

        LEASE_ALIVE = <<~SQL.freeze
          SELECT 1
          FROM jobs
          WHERE id = ? AND claim_token = ? AND status = 'running'
        SQL

        RETRY_JOB = <<~SQL.freeze
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

        RECOVER_WORKER = <<~SQL.freeze
          UPDATE jobs
          SET    status      = 'pending',
                 locked_by   = NULL,
                 locked_at   = NULL,
                 claim_token = NULL,
                 started_at  = NULL
          WHERE  status = 'running' AND locked_by = ?
        SQL

        BACKFILL_FINISHED_AT = <<~SQL.freeze
          UPDATE jobs
          SET finished_at = created_at
          WHERE finished_at IS NULL AND status IN ('done', 'failed')
        SQL

        CLEANUP_DONE = <<~SQL.freeze
          DELETE FROM jobs
          WHERE status = 'done' AND finished_at IS NOT NULL AND finished_at < ?
        SQL

        CLEANUP_FAILED = <<~SQL.freeze
          DELETE FROM jobs
          WHERE status = 'failed' AND finished_at IS NOT NULL AND finished_at < ?
        SQL

        NEXT_PENDING_RUN_AT = <<~SQL.freeze
          SELECT MIN(run_at)
          FROM jobs
          WHERE status = 'pending'
        SQL

        JOBS_TABLE_EXISTS = <<~SQL.freeze
          SELECT 1
          FROM sqlite_master
          WHERE type = 'table' AND name = 'jobs'
          LIMIT 1
        SQL

        JOB_INDEX_NAMES = <<~SQL.freeze
          SELECT name
          FROM sqlite_master
          WHERE type = 'index' AND tbl_name = 'jobs'
        SQL

        DROP_LEGACY_PENDING_INDEX = 'DROP INDEX IF EXISTS idx_jobs_status_run_at_id'.freeze

        CREATE_PENDING_INDEX = <<~SQL.freeze
          CREATE INDEX IF NOT EXISTS idx_jobs_pending
          ON jobs(run_at) WHERE status = 'pending'
        SQL

        CREATE_DONE_INDEX = <<~SQL.freeze
          CREATE INDEX IF NOT EXISTS idx_jobs_done_finished_at
          ON jobs(finished_at DESC, id DESC)
          WHERE status = 'done'
        SQL

        CREATE_FAILED_INDEX = <<~SQL.freeze
          CREATE INDEX IF NOT EXISTS idx_jobs_failed_finished_at
          ON jobs(finished_at DESC, id DESC)
          WHERE status = 'failed'
        SQL

        CREATE_EXECUTING_INDEX = <<~SQL.freeze
          CREATE INDEX IF NOT EXISTS idx_jobs_executing_started_at
          ON jobs(started_at)
          WHERE status = 'running' AND started_at IS NOT NULL
        SQL

        CREATE_CLAIMED_INDEX = <<~SQL.freeze
          CREATE INDEX IF NOT EXISTS idx_jobs_claimed_locked_at
          ON jobs(locked_at)
          WHERE status = 'running' AND started_at IS NULL
        SQL

        CREATE_DASHBOARD_INDEXES = [
          CREATE_DONE_INDEX,
          CREATE_FAILED_INDEX,
          CREATE_EXECUTING_INDEX,
          CREATE_CLAIMED_INDEX
        ].freeze
      end
    end
  end
end
