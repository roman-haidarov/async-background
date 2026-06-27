# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative '../clock'
require_relative 'options'
require_relative 'schema'
require_relative 'sql'

module Async
  module Background
    module Queue
      class Store
        include Clock

        SCHEMA_VERSION = Schema::VERSION
        MIGRATION_BUSY_TIMEOUT_MS = Schema::MIGRATION_BUSY_TIMEOUT_MS
        REQUIRED_INDEXES = Schema::REQUIRED_INDEXES
        SCHEMA = SQL::CREATE_SCHEMA

        CLEANUP_INTERVAL = 300
        CLEANUP_AGE = 3600
        FAILED_RETENTION_AGE = 7 * 24 * 3600
        ERROR_MESSAGE_MAX_LEN = 2_000
        EMPTY_ARGS_JSON = '[]'.freeze

        attr_reader :path, :options

        def self.migrate!(path: default_path, options: {})
          store = new(path: path, options: options)
          store.migrate!
          SCHEMA_VERSION
        ensure
          store&.close
        end

        def self.prepare_dashboard!(path: default_path, options: {})
          store = new(path: path, options: options)
          store.prepare_dashboard!
          SCHEMA_VERSION
        ensure
          store&.close
        end

        def self.default_path = 'async_background_queue.db'

        def initialize(path: self.class.default_path, options: {})
          @path = path
          @options = StoreOptions.build(options)
          @pragma_sql = @options.pragma_sql.freeze
          @db = nil
          @schema_checked = false
          @last_cleanup_at = nil
        end

        def migrate!
          raise SchemaError, 'close the Store before calling migrate!' if connected?

          with_database { |db| migrate_database!(db) }
          @schema_checked = true
          self
        end

        alias ensure_database! migrate!

        def prepare_dashboard!
          raise SchemaError, 'close the Store before calling prepare_dashboard!' if connected?

          with_database { |db| Schema.prepare_dashboard!(db) }
          @schema_checked = true
          self
        end

        def schema_version
          ensure_connection
          @db.get_first_value(SQL::USER_VERSION).to_i
        end

        def enqueue(class_name, args = EMPTY_ARGS, run_at = nil, options: EMPTY_OPTIONS)
          ensure_connection
          now = realtime_now
          @enqueue_stmt.execute(class_name, dump_args(args), dump_options(options), now, run_at || now)
          @db.last_insert_row_id
        end

        def fetch(worker_id)
          ensure_connection
          token = generate_claim_token
          now = realtime_now

          row = transaction do
            with_statement(@fetch_stmt) { |statement| statement.execute(worker_id, now, token, now).first }
          end
          return unless row

          maybe_cleanup
          job_from_row(row, token)
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

        def retry_or_fail(
          job_id,
          claim_token:,
          error_class: nil,
          error_message: nil,
          fallback_options: nil,
          finished_at: realtime_now,
          duration_ms: nil
        )
          ensure_connection

          transaction do
            stored_options = stored_options_for(job_id, claim_token)
            next unless lease_alive?(job_id, claim_token)

            policy = retry_policy(stored_options, fallback_options)
            policy_retries?(policy) ? retry_job!(job_id, claim_token, policy, error_class, error_message) :
              fail_job!(job_id, claim_token, error_class, error_message, finished_at, duration_ms)
          end
        end

        def recover(worker_id)
          ensure_connection
          @requeue_stmt.execute(worker_id)
          @db.changes
        end

        def next_pending_run_at
          ensure_connection
          with_statement(@next_pending_stmt) { |statement| statement.execute.first&.first }
        end

        def data_version
          ensure_connection
          @db.get_first_value(SQL::DATA_VERSION).to_i
        end

        def close
          return unless connected?

          finalize_statements
          @db.execute(SQL::OPTIMIZE) rescue nil
          @db.close
          @db = nil
          @schema_checked = false
        end

        private

        def connected?
          @db && !@db.closed?
        end

        def open_database
          require_sqlite3
          db = SQLite3::Database.new(@path)
          configure_database(db)
          db
        rescue StandardError
          db&.close unless db&.closed?
          raise
        end

        def with_database
          db = open_database
          yield db
        ensure
          db&.close unless db&.closed?
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

          finalize_statements
          db = open_database
          migrate_database!(db) unless @schema_checked
          @schema_checked = true
          @db = db
          prepare_statements
          @last_cleanup_at = monotonic_now
        rescue StandardError
          db&.close unless db&.equal?(@db) || db&.closed?
          reset_connection!
          raise
        end

        def reset_connection!
          @schema_checked = false
          @db&.close unless @db&.closed?
          @db = nil
        end

        def configure_database(db)
          db.execute(SQL.busy_timeout(5000))
          db.execute_batch(@pragma_sql)
        end

        def migrate_database!(db)
          Schema.migrate!(db)
        end

        def job_from_row(row, claim_token)
          {
            id: row[0],
            class_name: row[1],
            args: JSON.parse(row[2]),
            options: load_options(row[3]),
            claim_token: claim_token
          }
        end

        def stored_options_for(job_id, claim_token)
          with_statement(@retry_state_stmt) do |statement|
            load_options(statement.execute(job_id, claim_token).first&.first)
          end
        end

        def retry_policy(stored_options, fallback_options)
          return Job::Options.new(**stored_options) unless stored_options.empty?

          normalize_options(fallback_options)
        end

        def policy_retries?(policy)
          policy&.retry? && policy.next_attempt <= policy.retry
        end

        def retry_job!(job_id, claim_token, policy, error_class, error_message)
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
        end

        def fail_job!(job_id, claim_token, error_class, error_message, finished_at, duration_ms)
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

        def generate_claim_token = SecureRandom.hex(16)

        def truncate_message(message)
          return if message.nil?

          string = message.to_s
          string.length > ERROR_MESSAGE_MAX_LEN ? string.byteslice(0, ERROR_MESSAGE_MAX_LEN) : string
        end

        def lease_alive?(job_id, claim_token)
          with_statement(@lease_check_stmt) do |statement|
            !statement.execute(job_id, claim_token).first.nil?
          end
        end

        def transaction
          @db.execute(SQL::BEGIN_IMMEDIATE)
          result = yield
          @db.execute(SQL::COMMIT)
          result
        rescue StandardError
          @db.execute(SQL::ROLLBACK) rescue nil
          raise
        end

        def with_statement(statement)
          yield statement
        ensure
          statement.reset! rescue nil
        end

        def dump_args(args)
          args.equal?(EMPTY_ARGS) ? EMPTY_ARGS_JSON : JSON.generate(args)
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
          @enqueue_stmt = @db.prepare(SQL::INSERT_JOB)
          @fetch_stmt = @db.prepare(SQL::FETCH_NEXT_JOB)
          @mark_started_stmt = @db.prepare(SQL::MARK_STARTED)
          @complete_stmt = @db.prepare(SQL::COMPLETE_JOB)
          @fail_stmt = @db.prepare(SQL::FAIL_JOB)
          @retry_state_stmt = @db.prepare(SQL::RETRY_STATE)
          @lease_check_stmt = @db.prepare(SQL::LEASE_ALIVE)
          @retry_stmt = @db.prepare(SQL::RETRY_JOB)
          @requeue_stmt = @db.prepare(SQL::RECOVER_WORKER)
          @cleanup_done_stmt = @db.prepare(SQL::CLEANUP_DONE)
          @cleanup_failed_stmt = @db.prepare(SQL::CLEANUP_FAILED)
          @next_pending_stmt = @db.prepare(SQL::NEXT_PENDING_RUN_AT)
        end

        def finalize_statements
          statements.each { |statement| statement&.close rescue nil }
          clear_statements
        end

        def statements
          [
            @enqueue_stmt,
            @fetch_stmt,
            @mark_started_stmt,
            @complete_stmt,
            @fail_stmt,
            @retry_state_stmt,
            @lease_check_stmt,
            @retry_stmt,
            @requeue_stmt,
            @cleanup_done_stmt,
            @cleanup_failed_stmt,
            @next_pending_stmt
          ]
        end

        def clear_statements
          @enqueue_stmt = @fetch_stmt = @mark_started_stmt = nil
          @complete_stmt = @fail_stmt = @retry_state_stmt = @lease_check_stmt = nil
          @retry_stmt = @requeue_stmt = nil
          @cleanup_done_stmt = @cleanup_failed_stmt = nil
          @next_pending_stmt = nil
        end

        def maybe_cleanup
          now = monotonic_now
          return if (now - @last_cleanup_at) < CLEANUP_INTERVAL

          @last_cleanup_at = now
          cleanup_finished_jobs(realtime_now)
        end

        def cleanup_finished_jobs(now)
          @cleanup_done_stmt.execute(now - CLEANUP_AGE)
          @cleanup_failed_stmt.execute(now - FAILED_RETENTION_AGE)
          @db.execute(SQL::INCREMENTAL_VACUUM) if @db.changes > 100
        end
      end
    end
  end
end
