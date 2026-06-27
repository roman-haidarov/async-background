# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe 'dashboard SQL query plans', type: :unit do
  let(:db_path) { temp_db_path }
  let(:db) do
    Async::Background::Queue::Store.prepare_dashboard!(path: db_path)
    require 'sqlite3'
    SQLite3::Database.new(db_path)
  end

  after do
    db&.close unless db&.closed?
  end

  def plan_for(sql, binds = [])
    db.execute("EXPLAIN QUERY PLAN #{sql}", binds).map { |row| row.last.to_s }.join("\n")
  end

  shared_examples 'uses index without temp sort' do |sql_const, binds, expected_index|
    it "uses #{expected_index} and avoids temp B-tree" do
      sql = Async::Background::Web::SQL.const_get(sql_const)
      plan = plan_for(sql, binds)
      expect(plan).to include(expected_index),
        "plan was:\n#{plan}\nexpected index: #{expected_index}"
      expect(plan).not_to include('USE TEMP B-TREE'),
        "plan should not require a temp B-tree sort:\n#{plan}"
    end
  end

  describe 'list queries' do
    include_examples 'uses index without temp sort', :DONE,          [50],                       'idx_jobs_done_finished_at'
    include_examples 'uses index without temp sort', :DONE_AFTER,    [1_700_000_000.0, 999, 50], 'idx_jobs_done_finished_at'
    include_examples 'uses index without temp sort', :FAILED,        [50],                       'idx_jobs_failed_finished_at'
    include_examples 'uses index without temp sort', :FAILED_AFTER,  [1_700_000_000.0, 999, 50], 'idx_jobs_failed_finished_at'
    include_examples 'uses index without temp sort', :PENDING,       [50],                       'idx_jobs_pending'
    include_examples 'uses index without temp sort', :PENDING_AFTER, [1_700_000_000.0, 0, 50],   'idx_jobs_pending'
  end

  describe 'overview scalar queries' do
    it 'pending count uses idx_jobs_pending' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_PENDING)
      expect(plan).to include('idx_jobs_pending')
    end

    it 'done count uses the per-status covering index' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_DONE)
      expect(plan).to include('idx_jobs_done_finished_at')
    end

    it 'failed count uses the per-status covering index' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_FAILED)
      expect(plan).to include('idx_jobs_failed_finished_at')
    end

    it 'next_pending uses idx_jobs_pending' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_NEXT_PENDING)
      expect(plan).to include('idx_jobs_pending')
    end

    it 'executing count uses the executing partial index' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_EXECUTING)
      expect(plan).to include('idx_jobs_executing_started_at')
    end

    it 'claimed count uses the claimed partial index' do
      plan = plan_for(Async::Background::Web::SQL::OVERVIEW_CLAIMED)
      expect(plan).to include('idx_jobs_claimed_locked_at')
    end
  end

  describe 'no overview query does a full table scan' do
    %i[OVERVIEW_PENDING OVERVIEW_DONE OVERVIEW_FAILED OVERVIEW_NEXT_PENDING].each do |const|
      it "#{const} avoids SCAN jobs without an index" do
        plan = plan_for(Async::Background::Web::SQL.const_get(const))
        expect(plan).not_to match(/SCAN jobs(?! USING)/),
          "plan does a full scan:\n#{plan}"
      end
    end
  end
end
