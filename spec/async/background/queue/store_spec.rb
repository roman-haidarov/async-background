# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Queue::Store, type: :unit do
  let(:db_path) { temp_db_path }
  let(:store) { described_class.new(path: db_path) }

  before do
    store.ensure_database!
  end

  after do
    store&.close
  end

  def db
    store.instance_variable_get(:@db)
  end

  describe '#initialize' do
    it 'creates store with database path' do
      expect(store).to be_a(described_class)
      expect(File.exist?(db_path)).to be true
    end

    it 'accepts mmap option' do
      mmap_path = temp_db_path
      store_with_mmap = described_class.new(path: mmap_path, options: { mmap: true })
      store_with_mmap.ensure_database!
      expect(store_with_mmap).to be_a(described_class)
      store_with_mmap.close
    end

    it 'accepts mmap: false' do
      no_mmap_path = temp_db_path
      store_no_mmap = described_class.new(path: no_mmap_path, options: { mmap: false })
      store_no_mmap.ensure_database!
      store_no_mmap.enqueue('NoMmapJob', [])
      store_no_mmap.close
    end

    it 'rejects unknown synchronous level' do
      expect {
        described_class.new(path: temp_db_path, options: { synchronous: :bogus })
      }.to raise_error(ArgumentError, /synchronous must be one of/)
    end

    it 'rejects wal_autocheckpoint outside the allowed range' do
      expect {
        described_class.new(path: temp_db_path, options: { wal_autocheckpoint: 50 })
      }.to raise_error(ArgumentError, /wal_autocheckpoint must be an Integer/)

      expect {
        described_class.new(path: temp_db_path, options: { wal_autocheckpoint: 50_000 })
      }.to raise_error(ArgumentError, /wal_autocheckpoint must be an Integer/)
    end

    it 'rejects non-boolean mmap' do
      expect {
        described_class.new(path: temp_db_path, options: { mmap: 'yes' })
      }.to raise_error(ArgumentError, /mmap must be true or false/)
    end
  end

  describe '#ensure_database!' do
    it 'creates jobs table' do
      store.enqueue('Probe', [])
      result = db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='jobs'"
      )
      expect(result).not_to be_empty
    end

    it 'creates proper table structure including 0.7.2 lifecycle columns' do
      store.enqueue('Probe', [])
      columns = db.execute("PRAGMA table_info(jobs)")
      column_names = columns.map { |col| col[1] }

      required = %w[
        id class_name args options status created_at run_at locked_by locked_at
        claim_token started_at finished_at duration_ms
        last_error_class last_error_message
      ]
      required.each do |col|
        expect(column_names).to include(col)
      end
    end

    it 'creates only the enqueue-critical pending index by default' do
      store.enqueue('Probe', [])
      indexes = db.execute(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='jobs'"
      )

      expect(indexes.map(&:first)).to contain_exactly('idx_jobs_pending')
    end

    it 'keeps dashboard indexes opt-in' do
      store.prepare_dashboard!
      store.enqueue('Probe', [])
      indexes = db.execute(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='jobs'"
      )

      expect(indexes.map(&:first)).to contain_exactly(
        'idx_jobs_pending',
        'idx_jobs_done_finished_at',
        'idx_jobs_failed_finished_at',
        'idx_jobs_executing_started_at',
        'idx_jobs_claimed_locked_at'
      )
    end
  end

  describe '#enqueue' do
    it 'adds job to queue with default run_at (now)' do
      before_time = Time.now.to_f
      job_id = store.enqueue('TestJob', ['arg1', 'arg2'])

      expect(job_id).to be_a(Integer)
      expect(job_id).to be > 0

      run_at = db.execute("SELECT run_at FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(run_at).to be_within(1.0).of(before_time)
    end

    it 'adds job with specified run_at time' do
      future_time = Time.now.to_f + 3600
      job_id = store.enqueue('DelayedJob', ['arg'], future_time)
      row = db.execute("SELECT run_at FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to be_within(0.1).of(future_time)
    end

    it 'stores job arguments as JSON' do
      args = [1, 'string', { 'key' => 'value' }, [1, 2, 3]]
      job_id = store.enqueue('ComplexJob', args)

      jobs = db.execute("SELECT args FROM jobs WHERE id = ?", [job_id])
      stored_args = JSON.parse(jobs.first[0])
      expect(stored_args).to eq(args)
    end

    it 'stores options as JSON when present' do
      job_id = store.enqueue('ConfiguredJob', [], nil, options: { timeout: 30, retry: 2 })

      options_json = db.execute("SELECT options FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(JSON.parse(options_json)).to eq({ 'timeout' => 30, 'retry' => 2 })
    end

    it 'sets initial status as pending' do
      job_id = store.enqueue('TestJob', [])

      jobs = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id])
      expect(jobs.first[0]).to eq('pending')
    end

    it 'returns incremental job IDs' do
      id1 = store.enqueue('Job1', [])
      id2 = store.enqueue('Job2', [])
      id3 = store.enqueue('Job3', [])

      expect(id2).to eq(id1 + 1)
      expect(id3).to eq(id2 + 1)
    end

    it 'persists created_at as a wall-clock timestamp' do
      before_time = Time.now.to_f
      job_id = store.enqueue('TimestampedJob', [])
      after_time = Time.now.to_f

      created_at = db.execute("SELECT created_at FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(created_at).to be >= before_time
      expect(created_at).to be <= after_time
    end

    it 'does not set claim_token / lifecycle fields on a fresh enqueue' do
      job_id = store.enqueue('Fresh', [])
      row = db.execute(
        "SELECT claim_token, started_at, finished_at, duration_ms, last_error_class, last_error_message " \
        "FROM jobs WHERE id = ?", [job_id]
      ).first

      expect(row).to all(be_nil)
    end
  end

  describe '#fetch' do
    let(:worker_id) { 1 }

    context 'with ready jobs' do
      before do
        store.enqueue('ReadyJob', ['arg1'], Time.now.to_f - 1)
        store.enqueue('FutureJob', ['arg2'], Time.now.to_f + 3600)
      end

      it 'returns ready job with claim_token' do
        job = store.fetch(worker_id)

        expect(job).not_to be_nil
        expect(job[:class_name]).to eq('ReadyJob')
        expect(job[:args]).to eq(['arg1'])
        expect(job[:id]).to be_a(Integer)
        expect(job[:claim_token]).to be_a(String)
        expect(job[:claim_token].length).to be >= 16
      end

      it 'marks job as running, locks it, and persists claim_token' do
        job = store.fetch(worker_id)

        row = db.execute(
          "SELECT status, locked_by, locked_at, claim_token, started_at, finished_at " \
          "FROM jobs WHERE id = ?", [job[:id]]
        ).first

        expect(row[0]).to eq('running')
        expect(row[1]).to eq(worker_id)
        expect(row[2]).to be_a(Float)
        expect(row[3]).to eq(job[:claim_token])
        expect(row[4]).to be_nil
        expect(row[5]).to be_nil
      end

      it 'gives each fetch a fresh claim_token even on re-claim after recover' do
        first = store.fetch(worker_id)
        first_token = first[:claim_token]

        store.recover(worker_id)
        # job is back to pending; lower its run_at so we can refetch immediately
        db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 5, first[:id]])

        second = store.fetch(worker_id)
        expect(second[:claim_token]).not_to eq(first_token)
      end

      it 'does not return future jobs' do
        job = store.fetch(worker_id)
        expect(job[:class_name]).to eq('ReadyJob')

        job2 = store.fetch(worker_id)
        expect(job2).to be_nil
      end
    end

    context 'with jobs that have options' do
      before do
        store.enqueue('RetryJob', ['arg1'], Time.now.to_f - 1, options: { retry: 2, retry_delay: 5, attempt: 1 })
      end

      it 'returns symbolized options from the JSON column' do
        job = store.fetch(worker_id)

        expect(job[:options]).to eq(retry: 2, retry_delay: 5, attempt: 1)
      end
    end

    context 'with no ready jobs' do
      before do
        store.enqueue('FutureJob', [], Time.now.to_f + 3600)
      end

      it 'returns nil' do
        job = store.fetch(worker_id)
        expect(job).to be_nil
      end
    end

    context 'with already running jobs' do
      before do
        store.enqueue('TestJob', [], Time.now.to_f - 1)
        store.fetch(2) # locked by other worker
      end

      it 'does not return jobs locked by another worker' do
        job = store.fetch(worker_id)
        expect(job).to be_nil
      end
    end

    context 'with multiple ready jobs' do
      before do
        3.times { |i| store.enqueue("Job#{i}", [i], Time.now.to_f - 1) }
      end

      it 'returns jobs one at a time and exhausts the queue' do
        job1 = store.fetch(worker_id)
        job2 = store.fetch(worker_id)
        job3 = store.fetch(worker_id)
        job4 = store.fetch(worker_id)

        expect([job1, job2, job3]).to all(be_truthy)
        expect(job4).to be_nil

        job_ids = [job1[:id], job2[:id], job3[:id]]
        expect(job_ids.uniq.length).to eq(3)
      end

      it 'returns jobs ordered by run_at then id (FIFO for same run_at)' do
        ids = [store.fetch(worker_id)[:id], store.fetch(worker_id)[:id], store.fetch(worker_id)[:id]]
        expect(ids).to eq(ids.sort)
      end

      it 'gives each fetched job its own unique claim_token' do
        tokens = [store.fetch(worker_id)[:claim_token],
                  store.fetch(worker_id)[:claim_token],
                  store.fetch(worker_id)[:claim_token]]
        expect(tokens.uniq.length).to eq(3)
      end
    end
  end

  describe '#mark_started!' do
    let(:worker_id) { 1 }

    it 'stamps started_at when called with the live lease' do
      store.enqueue('Job', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      before = Time.now.to_f
      expect(store.mark_started!(job[:id], claim_token: job[:claim_token])).to be true
      after = Time.now.to_f

      started_at = db.execute("SELECT started_at FROM jobs WHERE id = ?", [job[:id]]).first[0]
      expect(started_at).to be_between(before, after)
    end

    it 'is idempotent — second call leaves started_at unchanged and returns false' do
      store.enqueue('Job', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      store.mark_started!(job[:id], claim_token: job[:claim_token])
      original = db.execute("SELECT started_at FROM jobs WHERE id = ?", [job[:id]]).first[0]

      sleep 0.01
      expect(store.mark_started!(job[:id], claim_token: job[:claim_token])).to be false
      current = db.execute("SELECT started_at FROM jobs WHERE id = ?", [job[:id]]).first[0]

      expect(current).to eq(original)
    end

    it 'returns false for a stale claim_token' do
      store.enqueue('Job', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      expect(store.mark_started!(job[:id], claim_token: 'wrong-token')).to be false
    end
  end

  describe '#complete' do
    let(:worker_id) { 1 }

    it 'marks job as done and records finished_at + duration_ms' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      result = store.complete(job_id, claim_token: job[:claim_token], duration_ms: 123)
      expect(result).to be true

      row = db.execute("SELECT status, locked_by, locked_at, finished_at, duration_ms FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('done')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
      expect(row[3]).to be_a(Float)
      expect(row[4]).to eq(123)
    end

    it 'returns false for a stale claim_token and does not mutate the row' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      store.fetch(worker_id)

      expect(store.complete(job_id, claim_token: 'wrong')).to be false

      status = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(status).to eq('running')
    end

    it 'is a no-op for non-existent job' do
      expect { store.complete(99_999, claim_token: 'any') }.not_to raise_error
      expect(store.complete(99_999, claim_token: 'any')).to be false
    end

    it 'protects against the overlap-restart race (stale worker cannot close re-claimed row)' do
      job_id = store.enqueue('Job', [], Time.now.to_f - 1)
      old = store.fetch(worker_id)
      store.recover(worker_id)
      db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 5, job_id])
      fresh = store.fetch(worker_id)
      expect(fresh[:claim_token]).not_to eq(old[:claim_token])
      expect(store.complete(job_id, claim_token: old[:claim_token], duration_ms: 1)).to be false

      row = db.execute("SELECT status, claim_token FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('running')
      expect(row[1]).to eq(fresh[:claim_token])

      expect(store.complete(job_id, claim_token: fresh[:claim_token], duration_ms: 2)).to be true
    end
  end

  describe '#fail' do
    let(:worker_id) { 1 }

    it 'marks job as failed and records error fields' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      result = store.fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: RuntimeError,
        error_message: 'database down'
      )
      expect(result).to be true

      row = db.execute(
        "SELECT status, locked_by, locked_at, last_error_class, last_error_message, finished_at " \
        "FROM jobs WHERE id = ?", [job_id]
      ).first
      expect(row[0]).to eq('failed')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
      expect(row[3]).to eq('RuntimeError')
      expect(row[4]).to eq('database down')
      expect(row[5]).to be_a(Float)
    end

    it 'returns false for a stale claim_token' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      store.fetch(worker_id)
      expect(store.fail(job_id, claim_token: 'wrong', error_class: RuntimeError, error_message: 'x')).to be false

      status = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(status).to eq('running')
    end

    it 'truncates oversized error messages' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      big = 'x' * 10_000
      store.fail(job_id, claim_token: job[:claim_token], error_class: StandardError, error_message: big)

      stored = db.execute("SELECT last_error_message FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(stored.length).to be <= Async::Background::Queue::Store::ERROR_MESSAGE_MAX_LEN
    end

    it 'is a no-op for non-existent job' do
      expect {
        store.fail(99_999, claim_token: 'any', error_class: StandardError, error_message: 'x')
      }.not_to raise_error
    end

    it 'leaves other jobs untouched' do
      id_a = store.enqueue('JobA', [], Time.now.to_f - 1)
      id_b = store.enqueue('JobB', [], Time.now.to_f - 1)
      a = store.fetch(worker_id)
      store.fetch(worker_id)

      store.fail(id_a, claim_token: a[:claim_token], error_class: RuntimeError, error_message: 'oops')

      status_a = db.execute("SELECT status FROM jobs WHERE id = ?", [id_a]).first[0]
      status_b = db.execute("SELECT status FROM jobs WHERE id = ?", [id_b]).first[0]

      expect(status_a).to eq('failed')
      expect(status_b).to eq('running')
    end
  end

  describe '#retry_or_fail' do
    let(:worker_id) { 1 }
    let(:retry_options) { Async::Background::Job::Options.new(retry: 2, retry_delay: 5, backoff: :linear) }

    it 'reschedules the job while retries remain and stores attempt inside options' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      job = store.fetch(worker_id)

      result = store.retry_or_fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: StandardError,
        error_message: 'transient',
        fallback_options: retry_options
      )
      expect(result).to eq(:retried)

      row = db.execute(
        "SELECT status, locked_by, locked_at, options, run_at, claim_token, last_error_class, last_error_message " \
        "FROM jobs WHERE id = ?", [job_id]
      ).first
      expect(row[0]).to eq('pending')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
      expect(JSON.parse(row[3])).to include('attempt' => 1, 'retry' => 2, 'retry_delay' => 5.0, 'backoff' => 'linear')
      expect(row[4]).to be > Time.now.to_f
      expect(row[5]).to be_nil
      expect(row[6]).to eq('StandardError')
      expect(row[7]).to eq('transient')
    end

    it 'increments the stored attempt across retries without extra columns' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      job = store.fetch(worker_id)
      store.retry_or_fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: StandardError, error_message: 'r1',
        fallback_options: Async::Background::Job::Options.new(**job[:options])
      )
      db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 1, job_id])

      job = store.fetch(worker_id)
      store.retry_or_fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: StandardError, error_message: 'r2',
        fallback_options: Async::Background::Job::Options.new(**job[:options])
      )

      row = db.execute("SELECT options FROM jobs WHERE id = ?", [job_id]).first
      expect(JSON.parse(row[0])).to include('attempt' => 2)
    end

    it 'marks the job as failed after retry exhaustion' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)

      3.times do |i|
        job = store.fetch(worker_id)
        store.retry_or_fail(
          job_id,
          claim_token: job[:claim_token],
          error_class: StandardError, error_message: "attempt #{i + 1}",
          fallback_options: Async::Background::Job::Options.new(**job[:options])
        )

        db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 1, job_id])
      end

      row = db.execute("SELECT status, options FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('failed')
      expect(JSON.parse(row[1])).to include('attempt' => 2)
    end

    it 'falls back to fail when retries are disabled' do
      job_id = store.enqueue('NoRetryJob', [], Time.now.to_f - 1)
      job = store.fetch(worker_id)

      result = store.retry_or_fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: StandardError, error_message: 'x',
        fallback_options: Async::Background::Job::Options.new
      )
      expect(result).to eq(:failed)

      row = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('failed')
    end

    it 'returns nil and does not mutate state on stale lease' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      store.fetch(worker_id)

      result = store.retry_or_fail(
        job_id,
        claim_token: 'wrong-token',
        error_class: StandardError, error_message: 'x',
        fallback_options: retry_options
      )
      expect(result).to be_nil

      status = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id]).first[0]
      expect(status).to eq('running')
    end

    it 'uses the stored retry policy as the source of truth' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      job = store.fetch(worker_id)

      conflicting_options = Async::Background::Job::Options.new(retry: 0, retry_delay: 99)

      result = store.retry_or_fail(
        job_id,
        claim_token: job[:claim_token],
        error_class: StandardError, error_message: 'x',
        fallback_options: conflicting_options
      )
      expect(result).to eq(:retried)

      row = db.execute("SELECT status, options FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('pending')
      expect(JSON.parse(row[1])).to include('retry' => 2, 'retry_delay' => 5.0, 'attempt' => 1)
    end
  end

  describe '#recover' do
    let(:worker_id) { 1 }

    it 'requeues running jobs locked by the given worker and clears claim_token + started_at' do
      job_id = store.enqueue('StaleJob', [], Time.now.to_f - 1)
      job = store.fetch(worker_id) # lock it
      store.mark_started!(job[:id], claim_token: job[:claim_token])

      recovered = store.recover(worker_id)

      expect(recovered).to eq(1)
      row = db.execute(
        "SELECT status, locked_by, locked_at, claim_token, started_at FROM jobs WHERE id = ?",
        [job_id]
      ).first
      expect(row[0]).to eq('pending')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
      expect(row[3]).to be_nil
      expect(row[4]).to be_nil
    end

    it 'does not touch jobs locked by other workers' do
      job_id = store.enqueue('OtherJob', [], Time.now.to_f - 1)
      store.fetch(2)

      recovered = store.recover(1)

      expect(recovered).to eq(0)
      row = db.execute("SELECT status, locked_by FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('running')
      expect(row[1]).to eq(2)
    end

    it 'returns 0 when there is nothing to recover' do
      expect(store.recover(worker_id)).to eq(0)
    end
  end

  describe '#next_pending_run_at' do
    it 'returns nil for an empty queue' do
      expect(store.next_pending_run_at).to be_nil
    end

    it 'returns the smallest pending run_at across all rows' do
      store.enqueue('J1', [], Time.now.to_f + 10)
      store.enqueue('J2', [], Time.now.to_f + 5)
      store.enqueue('J3', [], Time.now.to_f + 20)

      expect(store.next_pending_run_at).to be_within(0.1).of(Time.now.to_f + 5)
    end

    it 'ignores running, done, and failed rows' do
      store.enqueue('Done',    [], Time.now.to_f - 5)
      store.enqueue('Failed',  [], Time.now.to_f - 5)
      store.enqueue('Running', [], Time.now.to_f - 5)
      store.enqueue('Pending', [], Time.now.to_f + 100)

      done    = store.fetch(1)
      failed  = store.fetch(1)
      running = store.fetch(1)

      store.complete(done[:id], claim_token: done[:claim_token])
      store.fail(failed[:id], claim_token: failed[:claim_token], error_class: StandardError, error_message: 'x')
      _ = running

      expect(store.next_pending_run_at).to be_within(0.1).of(Time.now.to_f + 100)
    end
  end

  describe '#data_version' do
    it 'changes when another connection writes' do
      store.enqueue('Probe', [])
      v1 = store.data_version

      other = described_class.new(path: db_path)
      other.ensure_database!
      other.enqueue('FromOther', [])
      other.close

      v2 = store.data_version
      expect(v2).not_to eq(v1)
    end
  end

  describe 'cleanup retention' do
    before do
      store.instance_variable_set(
        :@last_cleanup_at,
        store.send(:monotonic_now) - Async::Background::Queue::Store::CLEANUP_INTERVAL - 1
      )
    end

    def force_cleanup_window!
      store.instance_variable_set(
        :@last_cleanup_at,
        store.send(:monotonic_now) - Async::Background::Queue::Store::CLEANUP_INTERVAL - 1
      )
    end

    it 'counts deleted done jobs even when no failed jobs were removed' do
      n = 5
      n.times do
        job_id = store.enqueue('OldDone', [])
        job = store.fetch(1)
        store.complete(job[:id], claim_token: job[:claim_token])
        db.execute(
          'UPDATE jobs SET finished_at = ? WHERE id = ?',
          [Time.now.to_f - Async::Background::Queue::Store::CLEANUP_AGE - 1, job_id]
        )
      end

      deleted = store.send(:cleanup_finished_jobs, Time.now.to_f)
      expect(deleted).to be >= n
    end

    it 'deletes done rows by finished_at, not created_at' do
      fresh_id = store.enqueue('Fresh', [], Time.now.to_f - 99_999)
      fresh = store.fetch(1)
      store.complete(fresh[:id], claim_token: fresh[:claim_token])

      old_id = store.enqueue('Old', [], Time.now.to_f - 99_999)
      old = store.fetch(1)
      store.complete(old[:id], claim_token: old[:claim_token])
      db.execute("UPDATE jobs SET finished_at = ? WHERE id = ?",
                 [Time.now.to_f - Async::Background::Queue::Store::CLEANUP_AGE - 1, old_id])

      force_cleanup_window!

      store.enqueue('Trigger', [], Time.now.to_f - 1)
      store.fetch(1)

      ids = db.execute("SELECT id FROM jobs ORDER BY id").map { |r| r[0] }
      expect(ids).to include(fresh_id)
      expect(ids).not_to include(old_id)
    end

    it 'retains failed jobs longer than done jobs (FAILED_RETENTION_AGE)' do
      failed_id = store.enqueue('FailedKept', [], Time.now.to_f - 1)
      job = store.fetch(1)
      store.fail(job[:id], claim_token: job[:claim_token], error_class: StandardError, error_message: 'x')
      db.execute("UPDATE jobs SET finished_at = ? WHERE id = ?",
                 [Time.now.to_f - Async::Background::Queue::Store::CLEANUP_AGE - 1, failed_id])

      force_cleanup_window!
      store.enqueue('Trigger', [], Time.now.to_f - 1)
      store.fetch(1)

      status = db.execute("SELECT status FROM jobs WHERE id = ?", [failed_id]).first
      expect(status).not_to be_nil
      expect(status[0]).to eq('failed')
    end

    it 'eventually purges failed jobs older than FAILED_RETENTION_AGE' do
      failed_id = store.enqueue('FailedExpired', [], Time.now.to_f - 1)
      job = store.fetch(1)
      store.fail(job[:id], claim_token: job[:claim_token], error_class: StandardError, error_message: 'x')
      db.execute("UPDATE jobs SET finished_at = ? WHERE id = ?",
                 [Time.now.to_f - Async::Background::Queue::Store::FAILED_RETENTION_AGE - 1, failed_id])

      force_cleanup_window!
      store.enqueue('Trigger', [], Time.now.to_f - 1)
      store.fetch(1)

      row = db.execute("SELECT id FROM jobs WHERE id = ?", [failed_id]).first
      expect(row).to be_nil
    end
  end

  describe '#close' do
    it 'is idempotent' do
      store.enqueue('Probe', [])
      store.close
      expect { store.close }.not_to raise_error
    end

    it 'allows reopening for new operations' do
      store.enqueue('Probe', [])
      store.close
      # ensure_connection should re-open lazily
      expect { store.enqueue('AfterClose', []) }.not_to raise_error
    end
  end

  describe 'thread safety' do
    it 'handles concurrent enqueue operations' do
      threads = 10.times.map do |i|
        Thread.new { store.enqueue("Job#{i}", [i]) }
      end

      job_ids = threads.map(&:value)

      expect(job_ids.uniq.length).to eq(10)
      expect(job_ids).to all(be_a(Integer))
    end

    it 'guarantees no two workers receive the same job under contention' do
      job_count = 5
      job_count.times { |i| store.enqueue("Job#{i}", [i], Time.now.to_f - 1) }

      threads = (1..job_count).map do |i|
        Thread.new { store.fetch(i) }
      end

      jobs = threads.map(&:value).compact
      job_ids = jobs.map { |j| j[:id] }

      expect(job_ids.uniq.length).to eq(job_ids.length)
      expect(job_ids.length).to be <= job_count
    end
  end
end
