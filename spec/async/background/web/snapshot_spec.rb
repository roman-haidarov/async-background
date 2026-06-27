# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Snapshot do
  let(:db_path) { temp_db_path }
  let(:store) { Async::Background::Queue::Store.new(path: db_path) }
  let(:snapshot) { described_class.new(path: db_path, counts_cache_ttl: 0).open! }

  before do
    Async::Background::Queue::Store.prepare_dashboard!(path: db_path)
  end

  after do
    snapshot.close
    store.close
  end

  def seed_done(n, base_time: 1_700_000_000.0)
    n.times do |i|
      id = store.enqueue('DoneJob', [i], base_time - 100)
      job = store.fetch(1)
      store.complete(job[:id], claim_token: job[:claim_token], finished_at: base_time - (n - i), duration_ms: 10 + i)
      id
    end
  end

  def seed_failed(n, base_time: 1_700_000_000.0)
    n.times do |i|
      store.enqueue('FailJob', [i], base_time - 100)
      job = store.fetch(1)
      store.fail(
        job[:id],
        claim_token: job[:claim_token],
        error_class: StandardError,
        error_message: "boom #{i}",
        finished_at: base_time - (n - i),
        duration_ms: 5
      )
    end
  end

  def seed_pending(n, base_time: 1_700_000_000.0)
    n.times { |i| store.enqueue('PendingJob', [i], base_time + i) }
  end

  def seed_executing(n, base_time: 1_700_000_000.0)
    n.times do |i|
      store.enqueue("ExecJob#{i}", [i], base_time - 100)
      job = store.fetch(1)
      store.mark_started!(job[:id], claim_token: job[:claim_token], started_at: base_time + i)
    end
  end

  def seed_claimed(n, base_time: 1_700_000_000.0)
    n.times do |i|
      store.enqueue("ClaimedJob#{i}", [i], base_time - 100)
      store.fetch(1)
    end
  end

  describe 'mode=ro enforcement' do
    it 'cannot write through the snapshot connection' do
      db = snapshot.instance_variable_get(:@db)
      expect {
        db.execute("INSERT INTO jobs (class_name, args, status, created_at, run_at) VALUES ('X', '[]', 'pending', 1, 1)")
      }.to raise_error(SQLite3::Exception)
    end
  end

  describe '#overview' do
    it 'returns counts and data_version' do
      seed_pending(2)
      seed_done(3)
      seed_failed(1)
      result = snapshot.overview
      expect(result[:counts]).to include(pending: 2, done: 3, failed: 1)
      expect(result[:data_version]).to be_a(Integer)
      expect(result[:generated_at]).to be_a(Numeric)
    end

    it 'reports executing vs claimed separately' do
      seed_executing(2)
      seed_claimed(3)
      result = snapshot.overview
      expect(result[:counts][:executing]).to eq(2)
      expect(result[:counts][:claimed]).to eq(3)
    end

    it 'returns next_pending_run_at' do
      seed_pending(2, base_time: 1_700_000_000.0)
      expect(snapshot.overview[:next_pending_run_at]).to eq(1_700_000_000.0)
    end
  end

  describe 'counts cache' do
    let(:snapshot) { described_class.new(path: db_path, counts_cache_ttl: 60).open! }

    it 'reuses cached counts within ttl' do
      seed_done(2)
      first = snapshot.overview
      seed_done(3)
      second = snapshot.overview
      expect(second).to eq(first)
    end

    it 'can bypass the cache for a committed-event refresh' do
      seed_done(2)
      snapshot.overview
      seed_done(3)

      expect(snapshot.overview(force: true)[:counts][:done]).to eq(5)
    end
  end

  describe '#recent_done' do
    it 'returns jobs in finished_at DESC order' do
      seed_done(5)
      rows = snapshot.recent_done(limit: 3)
      finished = rows.map { |r| r[:finished_at] }
      expect(finished).to eq(finished.sort.reverse)
      expect(rows.length).to eq(3)
    end

    it 'cursor pagination yields each row exactly once with no duplicates or gaps' do
      seed_done(10, base_time: 1_700_000_000.0)
      all_ids = []
      cursor = nil
      4.times do
        page = snapshot.recent_done(limit: 3, cursor: cursor)
        ids = page.map { |r| r[:id] }
        all_ids.concat(ids)
        break if page.empty?

        last = page.last
        cursor = { finished_at: last[:finished_at], id: last[:id] }
      end
      expect(all_ids.uniq.length).to eq(all_ids.length)
      expect(all_ids.length).to eq(10)
    end

    it 'cursor pagination is stable when many rows share the same finished_at' do
      same_time = 1_700_000_000.0
      6.times { |i| store.enqueue("Same#{i}", [i], same_time - 100) }
      6.times do
        job = store.fetch(1)
        store.complete(job[:id], claim_token: job[:claim_token], finished_at: same_time, duration_ms: 1)
      end
      all_ids = []
      cursor = nil
      3.times do
        page = snapshot.recent_done(limit: 2, cursor: cursor)
        break if page.empty?

        all_ids.concat(page.map { |r| r[:id] })
        last = page.last
        cursor = { finished_at: last[:finished_at], id: last[:id] }
      end
      expect(all_ids.uniq.length).to eq(all_ids.length)
      expect(all_ids.length).to eq(6)
    end
  end

  describe '#recent_failed' do
    it 'carries last_error_class and last_error_message' do
      seed_failed(1)
      rows = snapshot.recent_failed(limit: 1)
      expect(rows.first[:last_error_class]).to eq('StandardError')
      expect(rows.first[:last_error_message]).to include('boom 0')
    end
  end

  describe '#executing' do
    it 'returns only running rows with started_at set' do
      seed_executing(2)
      seed_claimed(3)
      rows = snapshot.executing(limit: 10)
      expect(rows.length).to eq(2)
      expect(rows).to all(satisfy { |r| !r[:started_at].nil? })
    end
  end

  describe '#claimed' do
    it 'returns only running rows with started_at NULL' do
      seed_executing(2)
      seed_claimed(3)
      rows = snapshot.claimed(limit: 10)
      expect(rows.length).to eq(3)
    end
  end

  describe '#pending' do
    it 'returns pending rows ordered by run_at asc' do
      seed_pending(5, base_time: 1_700_000_000.0)
      rows = snapshot.pending(limit: 10)
      run_ats = rows.map { |r| r[:run_at] }
      expect(run_ats).to eq(run_ats.sort)
    end
  end

  describe '#data_version' do
    it 'returns an integer' do
      expect(snapshot.data_version).to be_a(Integer)
    end
  end

  describe 'read errors' do
    it 'raises a typed error after close' do
      snapshot.close
      expect { snapshot.overview }.to raise_error(Async::Background::Web::ClosedError, /closed/)
    end
  end

  describe '#close' do
    it 'is idempotent' do
      snapshot.close
      expect { snapshot.close }.not_to raise_error
    end
  end
end
