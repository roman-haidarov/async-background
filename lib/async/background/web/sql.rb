# frozen_string_literal: true

module Async
  module Background
    module Web
      module SQL
        BEGIN_READ_TRANSACTION = 'BEGIN'.freeze
        COMMIT = 'COMMIT'.freeze
        ROLLBACK = 'ROLLBACK'.freeze
        QUERY_ONLY = 'PRAGMA query_only = ON'.freeze
        BUSY_TIMEOUT = 'PRAGMA busy_timeout = 2000'.freeze

        OVERVIEW_EXECUTING = "SELECT COUNT(*) FROM jobs WHERE status = 'running' AND started_at IS NOT NULL".freeze
        OVERVIEW_CLAIMED   = "SELECT COUNT(*) FROM jobs WHERE status = 'running' AND started_at IS NULL".freeze
        OVERVIEW_PENDING   = "SELECT COUNT(*) FROM jobs WHERE status = 'pending'".freeze
        OVERVIEW_DONE      = "SELECT COUNT(*) FROM jobs WHERE status = 'done'".freeze
        OVERVIEW_FAILED    = "SELECT COUNT(*) FROM jobs WHERE status = 'failed'".freeze
        OVERVIEW_NEXT_PENDING = "SELECT MIN(run_at) FROM jobs WHERE status = 'pending'".freeze

        EXECUTING = <<~SQL.freeze
          SELECT id, class_name, args, options, started_at, locked_by, locked_at
          FROM jobs
          WHERE status = 'running' AND started_at IS NOT NULL
          ORDER BY started_at, id
          LIMIT ?
        SQL

        CLAIMED = <<~SQL.freeze
          SELECT id, class_name, args, options, locked_at, locked_by
          FROM jobs
          WHERE status = 'running' AND started_at IS NULL
          ORDER BY locked_at, id
          LIMIT ?
        SQL

        DONE = <<~SQL.freeze
          SELECT id, class_name, args, options, finished_at, duration_ms
          FROM jobs
          WHERE status = 'done'
          ORDER BY finished_at DESC, id DESC
          LIMIT ?
        SQL

        DONE_AFTER = <<~SQL.freeze
          SELECT id, class_name, args, options, finished_at, duration_ms
          FROM jobs
          WHERE status = 'done' AND (finished_at, id) < (?, ?)
          ORDER BY finished_at DESC, id DESC
          LIMIT ?
        SQL

        FAILED = <<~SQL.freeze
          SELECT id, class_name, args, options, finished_at, duration_ms,
                 last_error_class, last_error_message
          FROM jobs
          WHERE status = 'failed'
          ORDER BY finished_at DESC, id DESC
          LIMIT ?
        SQL

        FAILED_AFTER = <<~SQL.freeze
          SELECT id, class_name, args, options, finished_at, duration_ms,
                 last_error_class, last_error_message
          FROM jobs
          WHERE status = 'failed' AND (finished_at, id) < (?, ?)
          ORDER BY finished_at DESC, id DESC
          LIMIT ?
        SQL

        PENDING = <<~SQL.freeze
          SELECT id, class_name, args, options, created_at, run_at
          FROM jobs
          WHERE status = 'pending'
          ORDER BY run_at, id
          LIMIT ?
        SQL

        PENDING_AFTER = <<~SQL.freeze
          SELECT id, class_name, args, options, created_at, run_at
          FROM jobs
          WHERE status = 'pending' AND (run_at, id) > (?, ?)
          ORDER BY run_at, id
          LIMIT ?
        SQL
      end
    end
  end
end
