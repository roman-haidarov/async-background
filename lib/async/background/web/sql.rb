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
        BASE_COLUMNS = %w[id class_name args options].freeze

        STATUS_PREDICATE = {
          executing: "status = 'running' AND started_at IS NOT NULL",
          claimed: "status = 'running' AND started_at IS NULL",
          pending: "status = 'pending'",
          done: "status = 'done'",
          failed: "status = 'failed'"
        }.freeze

        EXTRA_COLUMNS = {
          executing: %w[started_at locked_by locked_at],
          claimed: %w[locked_at locked_by],
          pending: %w[created_at run_at],
          done: %w[finished_at duration_ms],
          failed: %w[finished_at duration_ms last_error_class last_error_message]
        }.freeze

        KEYSET = {
          executing: ['started_at', :asc],
          claimed: ['locked_at', :asc],
          pending: ['run_at', :asc],
          done: ['finished_at', :desc],
          failed: ['finished_at', :desc]
        }.freeze

        ORDER_SQL = {asc: 'ORDER BY %<column>s, id', desc: 'ORDER BY %<column>s DESC, id DESC'}.freeze
        SEEK_SQL = {asc: '(%<column>s, id) > (?, ?)', desc: '(%<column>s, id) < (?, ?)'}.freeze

        def self.columns_for(status)
          (BASE_COLUMNS + EXTRA_COLUMNS.fetch(status)).join(', ')
        end

        def self.count_query(status)
          "SELECT COUNT(*) FROM jobs WHERE #{STATUS_PREDICATE.fetch(status)}".freeze
        end

        def self.list_query(status, seek: false)
          column, direction = KEYSET.fetch(status)
          predicate = STATUS_PREDICATE.fetch(status)
          predicate += " AND #{format(SEEK_SQL.fetch(direction), column: column)}" if seek

          <<~SQL.freeze
            SELECT #{columns_for(status)}
            FROM jobs
            WHERE #{predicate}
            #{format(ORDER_SQL.fetch(direction), column: column)}
            LIMIT ?
          SQL
        end

        OVERVIEW_EXECUTING = count_query(:executing)
        OVERVIEW_CLAIMED = count_query(:claimed)
        OVERVIEW_PENDING = count_query(:pending)
        OVERVIEW_DONE = count_query(:done)
        OVERVIEW_FAILED = count_query(:failed)
        OVERVIEW_NEXT_PENDING = "SELECT MIN(run_at) FROM jobs WHERE #{STATUS_PREDICATE.fetch(:pending)}".freeze

        EXECUTING = list_query(:executing)
        CLAIMED = list_query(:claimed)
        DONE = list_query(:done)
        FAILED = list_query(:failed)
        PENDING = list_query(:pending)

        DONE_AFTER = list_query(:done, seek: true)
        FAILED_AFTER = list_query(:failed, seek: true)
        PENDING_AFTER = list_query(:pending, seek: true)
      end
    end
  end
end
