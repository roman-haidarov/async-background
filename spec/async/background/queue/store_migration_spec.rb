# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Async::Background::Queue schema migrations', type: :unit do
  let(:db_path) { temp_db_path }

  def indexes(db)
    db.execute("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'jobs'").map(&:first)
  end

  def plan_details(db, sql, binds = [])
    db.execute("EXPLAIN QUERY PLAN #{sql}", binds).map(&:last).join("\n")
  end

  after do
    @db&.close unless @db&.closed?
  end

  it 'creates schema version 1 with the one-index queue schema for a fresh database' do
    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    expect(@db.get_first_value('PRAGMA user_version')).to eq(Async::Background::Queue::Store::SCHEMA_VERSION)
    expect(indexes(@db)).to contain_exactly('idx_jobs_pending')
  end

  it 'upgrades an unversioned released database directly to schema version 1' do
    @db = SQLite3::Database.new(db_path)
    @db.execute_batch(<<~SQL)
      CREATE TABLE jobs (
        id         INTEGER PRIMARY KEY,
        class_name TEXT    NOT NULL,
        args       TEXT    NOT NULL DEFAULT '[]',
        status     TEXT    NOT NULL DEFAULT 'pending',
        created_at REAL    NOT NULL,
        run_at     REAL    NOT NULL,
        locked_by  INTEGER,
        locked_at  REAL
      );
      CREATE INDEX idx_jobs_status_run_at_id ON jobs(status, run_at, id);
    SQL
    @db.execute(
      "INSERT INTO jobs (class_name, args, status, created_at, run_at) VALUES (?, ?, 'done', ?, ?)",
      ['LegacyJob', '[]', 100.0, 100.0]
    )
    @db.close
    @db = nil

    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    columns = @db.execute('PRAGMA table_info(jobs)').map { |row| row[1] }
    expect(columns).to include(
      'options', 'claim_token', 'started_at', 'finished_at', 'duration_ms',
      'last_error_class', 'last_error_message'
    )
    expect(@db.get_first_value('SELECT finished_at FROM jobs WHERE id = 1')).to eq(100.0)
    expect(@db.get_first_value('PRAGMA user_version')).to eq(Async::Background::Queue::Store::SCHEMA_VERSION)
    expect(indexes(@db)).to contain_exactly('idx_jobs_pending')
  end

  it 'does not execute DDL again after the core schema reaches the current version' do
    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)
    before = @db.get_first_value('PRAGMA schema_version')
    @db.close
    @db = nil

    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    expect(@db.get_first_value('PRAGMA schema_version')).to eq(before)
  end

  it 'fails rather than silently mutating a database from a newer queue version' do
    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)
    @db.execute("PRAGMA user_version = #{Async::Background::Queue::Store::SCHEMA_VERSION + 1}")
    @db.close
    @db = nil

    expect {
      Async::Background::Queue.migrate!(path: db_path)
    }.to raise_error(Async::Background::Queue::Store::SchemaError, /newer than supported/)
  end

  it 'keeps fetch ordering on the compact pending index' do
    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    plan = plan_details(
      @db,
      "SELECT id FROM jobs WHERE status = 'pending' AND run_at <= ? " \
      'ORDER BY run_at ASC, id ASC LIMIT 1',
      [Time.now.to_f]
    )

    expect(plan).to include('idx_jobs_pending')
    expect(plan).not_to include('USE TEMP B-TREE FOR ORDER BY')
  end

  it 'installs compact dashboard indexes only when explicitly requested' do
    Async::Background::Queue.migrate!(path: db_path)
    Async::Background::Queue.prepare_dashboard!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    expect(indexes(@db)).to contain_exactly(
      'idx_jobs_pending',
      'idx_jobs_done_finished_at',
      'idx_jobs_failed_finished_at',
      'idx_jobs_running'
    )

    schema_version = @db.get_first_value('PRAGMA schema_version')
    @db.close
    @db = nil

    Async::Background::Queue.prepare_dashboard!(path: db_path)
    Async::Background::Queue.migrate!(path: db_path)
    @db = SQLite3::Database.new(db_path)

    expect(@db.get_first_value('PRAGMA schema_version')).to eq(schema_version)
    expect(indexes(@db)).to contain_exactly(
      'idx_jobs_pending',
      'idx_jobs_done_finished_at',
      'idx_jobs_failed_finished_at',
      'idx_jobs_running'
    )
  end

  it 'uses compact dashboard indexes without a temporary ORDER BY b-tree' do
    Async::Background::Queue.migrate!(path: db_path)
    Async::Background::Queue.prepare_dashboard!(path: db_path)
    @db = SQLite3::Database.new(db_path)
    now = Time.now.to_f

    %w[done failed].each do |status|
      3.times do |index|
        @db.execute(
          "INSERT INTO jobs (class_name, args, status, created_at, run_at, finished_at) " \
          "VALUES (?, '[]', ?, ?, ?, ?)",
          ['ReadModelJob', status, now, now, now + index]
        )
      end
    end

    @db.execute(
      "INSERT INTO jobs (class_name, args, status, created_at, run_at, locked_at) " \
      "VALUES ('ReadModelJob', '[]', 'running', ?, ?, ?)",
      [now, now, now]
    )
    @db.execute(
      "INSERT INTO jobs (class_name, args, status, created_at, run_at, locked_at, started_at) " \
      "VALUES ('ReadModelJob', '[]', 'running', ?, ?, ?, ?)",
      [now, now, now, now]
    )

    plans = {
      done: plan_details(
        @db,
        "SELECT id FROM jobs WHERE status = 'done' " \
        'ORDER BY finished_at DESC, id DESC LIMIT 50'
      ),
      failed: plan_details(
        @db,
        "SELECT id FROM jobs WHERE status = 'failed' " \
        'ORDER BY finished_at DESC, id DESC LIMIT 50'
      ),
      in_flight: plan_details(
        @db,
        "SELECT id FROM jobs WHERE status = 'running' ORDER BY locked_at ASC, id ASC LIMIT 50"
      )
    }

    expect(plans.fetch(:done)).to include('idx_jobs_done_finished_at')
    expect(plans.fetch(:failed)).to include('idx_jobs_failed_finished_at')
    expect(plans.fetch(:in_flight)).to include('idx_jobs_running')
    plans.each_value { |plan| expect(plan).not_to include('USE TEMP B-TREE FOR ORDER BY') }
  end

  it 'paginates terminal rows with identical finished_at values without gaps or duplicates' do
    Async::Background::Queue.migrate!(path: db_path)
    Async::Background::Queue.prepare_dashboard!(path: db_path)
    @db = SQLite3::Database.new(db_path)
    finished_at = Time.now.to_f

    50.times do
      @db.execute(
        "INSERT INTO jobs (class_name, args, status, created_at, run_at, finished_at) " \
        "VALUES ('CursorJob', '[]', 'done', ?, ?, ?)",
        [finished_at, finished_at, finished_at]
      )
    end

    cursor = nil
    ids = []

    loop do
      rows = if cursor
        @db.execute(
          "SELECT id, finished_at FROM jobs " \
          "WHERE status = 'done' AND (finished_at, id) < (?, ?) " \
          'ORDER BY finished_at DESC, id DESC LIMIT 7',
          [cursor.fetch(:finished_at), cursor.fetch(:id)]
        )
      else
        @db.execute(
          "SELECT id, finished_at FROM jobs WHERE status = 'done' " \
          'ORDER BY finished_at DESC, id DESC LIMIT 7'
        )
      end

      break if rows.empty?

      ids.concat(rows.map(&:first))
      id, cursor_finished_at = rows.last
      cursor = {id: id, finished_at: cursor_finished_at}
    end

    expect(ids).to eq(ids.sort.reverse)
    expect(ids.size).to eq(50)
    expect(ids.uniq.size).to eq(50)
  end
end
