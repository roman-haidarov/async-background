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
      store_with_mmap = described_class.new(path: mmap_path, mmap: true)
      store_with_mmap.ensure_database!
      expect(store_with_mmap).to be_a(described_class)
      store_with_mmap.close
    end

    it 'accepts mmap: false' do
      no_mmap_path = temp_db_path
      store_no_mmap = described_class.new(path: no_mmap_path, mmap: false)
      store_no_mmap.ensure_database!
      store_no_mmap.enqueue('NoMmapJob', [])
      store_no_mmap.close
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

    it 'creates proper table structure' do
      store.enqueue('Probe', [])
      columns = db.execute("PRAGMA table_info(jobs)")
      column_names = columns.map { |col| col[1] }

      %w[id class_name args options status created_at run_at locked_by locked_at].each do |required|
        expect(column_names).to include(required)
      end
    end

    it 'creates indexes for performance' do
      store.enqueue('Probe', [])
      indexes = db.execute(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='jobs'"
      )
      index_names = indexes.map { |idx| idx[0] }

      expect(index_names).to include('idx_jobs_pending')
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
  end

  describe '#fetch' do
    let(:worker_id) { 1 }

    context 'with ready jobs' do
      before do
        store.enqueue('ReadyJob', ['arg1'], Time.now.to_f - 1)
        store.enqueue('FutureJob', ['arg2'], Time.now.to_f + 3600)
      end

      it 'returns ready job' do
        job = store.fetch(worker_id)

        expect(job).not_to be_nil
        expect(job[:class_name]).to eq('ReadyJob')
        expect(job[:args]).to eq(['arg1'])
        expect(job[:id]).to be_a(Integer)
      end

      it 'marks job as running and locks it' do
        job = store.fetch(worker_id)

        row = db.execute(
          "SELECT status, locked_by, locked_at FROM jobs WHERE id = ?", [job[:id]]
        ).first

        expect(row[0]).to eq('running')
        expect(row[1]).to eq(worker_id)
        expect(row[2]).to be_a(Float)
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
    end
  end

  describe '#complete' do
    let(:worker_id) { 1 }

    it 'marks job as done' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      store.fetch(worker_id)

      store.complete(job_id)

      row = db.execute("SELECT status, locked_by, locked_at FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('done')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
    end

    it 'is a no-op for non-existent job' do
      expect { store.complete(99_999) }.not_to raise_error
    end
  end

  describe '#fail' do
    let(:worker_id) { 1 }

    it 'marks job as failed' do
      job_id = store.enqueue('TestJob', [], Time.now.to_f - 1)
      store.fetch(worker_id)

      store.fail(job_id)

      row = db.execute("SELECT status, locked_by, locked_at FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('failed')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
    end

    it 'is a no-op for non-existent job' do
      expect { store.fail(99_999) }.not_to raise_error
    end

    it 'leaves other jobs untouched' do
      id_a = store.enqueue('JobA', [], Time.now.to_f - 1)
      id_b = store.enqueue('JobB', [], Time.now.to_f - 1)
      store.fetch(worker_id)
      store.fetch(worker_id)

      store.fail(id_a)

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
      store.fetch(worker_id)

      expect(store.retry_or_fail(job_id, options: retry_options)).to eq(:retried)

      row = db.execute("SELECT status, locked_by, locked_at, options, run_at FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('pending')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
      expect(JSON.parse(row[3])).to include('attempt' => 1, 'retry' => 2, 'retry_delay' => 5.0, 'backoff' => 'linear')
      expect(row[4]).to be > Time.now.to_f
    end

    it 'increments the stored attempt across retries without extra columns' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      job = store.fetch(worker_id)
      store.retry_or_fail(job_id, options: Async::Background::Job::Options.new(**job[:options]))
      db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 1, job_id])

      job = store.fetch(worker_id)
      store.retry_or_fail(job_id, options: Async::Background::Job::Options.new(**job[:options]))

      row = db.execute("SELECT options FROM jobs WHERE id = ?", [job_id]).first
      expect(JSON.parse(row[0])).to include('attempt' => 2)
    end

    it 'marks the job as failed after retry exhaustion' do
      job_id = store.enqueue('RetryJob', [], Time.now.to_f - 1, options: retry_options.to_h.compact)
      job = store.fetch(worker_id)
      store.retry_or_fail(job_id, options: Async::Background::Job::Options.new(**job[:options]))
      db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 1, job_id])

      job = store.fetch(worker_id)
      store.retry_or_fail(job_id, options: Async::Background::Job::Options.new(**job[:options]))
      db.execute("UPDATE jobs SET run_at = ? WHERE id = ?", [Time.now.to_f - 1, job_id])

      job = store.fetch(worker_id)
      expect(store.retry_or_fail(job_id, options: Async::Background::Job::Options.new(**job[:options]))).to eq(:failed)

      row = db.execute("SELECT status, options FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('failed')
      expect(JSON.parse(row[1])).to include('attempt' => 2)
    end

    it 'falls back to fail when retries are disabled' do
      job_id = store.enqueue('NoRetryJob', [], Time.now.to_f - 1)
      store.fetch(worker_id)

      expect(store.retry_or_fail(job_id, options: Async::Background::Job::Options.new)).to eq(:failed)

      row = db.execute("SELECT status FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('failed')
    end
  end

  describe '#recover' do
    let(:worker_id) { 1 }

    it 'requeues running jobs locked by the given worker' do
      job_id = store.enqueue('StaleJob', [], Time.now.to_f - 1)
      store.fetch(worker_id) # lock it

      recovered = store.recover(worker_id)

      expect(recovered).to eq(1)
      row = db.execute("SELECT status, locked_by, locked_at FROM jobs WHERE id = ?", [job_id]).first
      expect(row[0]).to eq('pending')
      expect(row[1]).to be_nil
      expect(row[2]).to be_nil
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
