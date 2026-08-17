# frozen_string_literal: true

require_relative 'sql'

module Async
  module Background
    module Queue
      class Store
        class SchemaError < StandardError; end
      end

      module Schema
        VERSION = 1
        MIGRATION_BUSY_TIMEOUT_MS = 30_000
        CORE_INDEXES = %w[idx_jobs_pending].freeze
        DASHBOARD_INDEXES = %w[
          idx_jobs_done_finished_at
          idx_jobs_failed_finished_at
          idx_jobs_executing_started_at
          idx_jobs_claimed_locked_at
        ].freeze
        REQUIRED_INDEXES = CORE_INDEXES

        module_function

        def migrate!(db)
          reject_future_version!(db)
          return if current?(db)

          enable_incremental_vacuum!(db) unless jobs_table?(db)

          synchronized_change(db) do
            reject_future_version!(db)
            upgrade!(db) unless current?(db)
          end
        end

        def prepare_dashboard!(db)
          migrate!(db)
          return if dashboard_indexes_current?(db)

          synchronized_change(db) do
            create_dashboard_indexes!(db) unless dashboard_indexes_current?(db)
          end
        end

        def synchronized_change(db, &change)
          with_migration_timeout(db) { immediate_transaction(db, &change) }
        end

        def current?(db)
          jobs_table?(db) && version(db) == VERSION && core_indexes_current?(db)
        end

        def dashboard_indexes_current?(db) = indexes_present?(db, DASHBOARD_INDEXES)

        def version(db)
          db.get_first_value(SQL::USER_VERSION).to_i
        end

        def upgrade!(db)
          jobs_table?(db) ? upgrade_existing_database!(db) : create_current_schema!(db)
        end

        def create_current_schema!(db)
          db.execute_batch(SQL::CREATE_SCHEMA)
          set_version!(db, VERSION)
        end

        def upgrade_existing_database!(db)
          add_column_unless_exists!(db, 'options', 'TEXT')
          add_lifecycle_columns!(db)
          backfill_finished_at!(db)
          ensure_pending_index!(db)
          set_version!(db, VERSION)
        end

        def add_lifecycle_columns!(db)
          {
            'claim_token' => 'TEXT',
            'started_at' => 'REAL',
            'finished_at' => 'REAL',
            'duration_ms' => 'INTEGER',
            'last_error_class' => 'TEXT',
            'last_error_message' => 'TEXT'
          }.each { |name, type| add_column_unless_exists!(db, name, type) }
        end

        def backfill_finished_at!(db)
          db.execute(SQL::BACKFILL_FINISHED_AT)
        end

        def ensure_pending_index!(db)
          db.execute(SQL::DROP_LEGACY_PENDING_INDEX)
          db.execute(SQL::CREATE_PENDING_INDEX)
        end

        def create_dashboard_indexes!(db)
          SQL::CREATE_DASHBOARD_INDEXES.each { |statement| db.execute(statement) }
        end

        def core_indexes_current?(db) = indexes_present?(db, CORE_INDEXES)

        def indexes_present?(db, names)
          (names - index_names(db)).empty?
        end

        def jobs_table?(db)
          !db.get_first_value(SQL::JOBS_TABLE_EXISTS).nil?
        end

        def index_names(db)
          db.execute(SQL::JOB_INDEX_NAMES).map(&:first)
        end

        def add_column_unless_exists!(db, name, sql_type)
          return if table_columns(db).include?(name)

          db.execute(SQL.add_column(name, sql_type))
        end

        def table_columns(db)
          db.execute(SQL::TABLE_INFO).map { |row| row[1] }
        end

        def reject_future_version!(db)
          return unless version(db) > VERSION

          raise Store::SchemaError,
                "queue database schema #{version(db)} is newer than supported schema #{VERSION}"
        end

        def set_version!(db, value)
          db.execute(SQL.user_version(value))
        end

        def enable_incremental_vacuum!(db)
          db.execute(SQL::AUTO_VACUUM_INCREMENTAL)
        end

        def with_migration_timeout(db)
          original_timeout = db.get_first_value(SQL::BUSY_TIMEOUT).to_i
          db.execute(SQL.busy_timeout(MIGRATION_BUSY_TIMEOUT_MS))
          yield
        ensure
          begin
            db.execute(SQL.busy_timeout(original_timeout)) if defined?(original_timeout)
          rescue StandardError
            # Restoring a connection option must not hide the migration exception.
          end
        end

        def immediate_transaction(db)
          db.execute(SQL::BEGIN_IMMEDIATE)
          result = yield
          db.execute(SQL::COMMIT)
          result
        rescue StandardError
          db.execute(SQL::ROLLBACK) rescue nil
          raise
        end
      end
    end
  end
end
