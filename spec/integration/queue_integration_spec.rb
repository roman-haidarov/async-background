# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Queue Integration', type: :integration do
  let(:db_path) { temp_db_path }
  let(:store) { Async::Background::Queue::Store.new(path: db_path) }
  let(:notifier) { instance_double('Async::Background::Queue::Notifier', notify_all: nil) }
  let(:client) { Async::Background::Queue::Client.new(store: store, notifier: notifier) }

  let(:test_job_class) do
    Class.new do
      include Async::Background::Job

      def self.name
        'IntegrationTestJob'
      end

      def self.perform_now(*args)
        "Integration test executed with #{args}"
      end
    end
  end

  before do
    @previous_client = Async::Background::Queue.default_client
    store.ensure_database!
    Async::Background::Queue.default_client = client
  end

  after do
    store&.close
    Async::Background::Queue.default_client = @previous_client
  end

  describe 'end-to-end job flow' do
    it 'successfully enqueues and retrieves jobs' do
      job_id1 = test_job_class.perform_async('arg1', 'arg2')
      job_id2 = test_job_class.perform_in(1, 'delayed_arg')
      job_id3 = test_job_class.perform_at(Time.now + 2, 'scheduled_arg')

      expect(job_id1).to be_a(Integer)
      expect(job_id2).to be_a(Integer)
      expect(job_id3).to be_a(Integer)
      expect([job_id1, job_id2, job_id3].uniq.size).to eq(3)

      worker_id = 1
      job = store.fetch(worker_id)

      expect(job).not_to be_nil
      expect(job[:id]).to eq(job_id1)
      expect(job[:class_name]).to eq('IntegrationTestJob')
      expect(job[:args]).to eq(['arg1', 'arg2'])

      store.complete(job[:id])

      db = store.instance_variable_get(:@db)
      status = db.execute('SELECT status FROM jobs WHERE id = ?', [job[:id]]).first[0]
      expect(status).to eq('done')

      # Delayed job is not yet runnable
      delayed_job = store.fetch(worker_id)
      expect(delayed_job).to be_nil

      sleep(1.2)
      delayed_job = store.fetch(worker_id)
      expect(delayed_job).not_to be_nil
      expect(delayed_job[:id]).to eq(job_id2)
      expect(delayed_job[:args]).to eq(['delayed_arg'])
    end

    it 'marks failed jobs with the failed status' do
      job_id = test_job_class.perform_async('test_failure')

      worker_id = 1
      job = store.fetch(worker_id)
      expect(job[:id]).to eq(job_id)

      store.fail(job_id)

      db = store.instance_variable_get(:@db)
      status = db.execute('SELECT status FROM jobs WHERE id = ?', [job_id]).first[0]
      expect(status).to eq('failed')
    end

    it 'recovers stale running jobs after worker restart' do
      job_id = test_job_class.perform_async('recoverable')
      worker_id = 1

      job = store.fetch(worker_id)
      expect(job[:id]).to eq(job_id)

      # Simulate worker crash: don't complete or fail, just recover.
      recovered = store.recover(worker_id)
      expect(recovered).to eq(1)

      # The same job should now be fetchable again.
      refetched = store.fetch(worker_id)
      expect(refetched).not_to be_nil
      expect(refetched[:id]).to eq(job_id)
    end
  end

  describe 'concurrent access' do
    it 'distributes jobs to multiple workers without duplication' do
      job_count = 5
      job_count.times { |i| test_job_class.perform_async("job_#{i}") }

      workers = [1, 2, 3]
      fetched_jobs = workers.map { |w| store.fetch(w) }.compact

      # Each fetch returns a unique job (no double-fetch).
      expect(fetched_jobs.map { |j| j[:id] }.uniq.size).to eq(fetched_jobs.size)
      expect(fetched_jobs.size).to eq(workers.size)

      fetched_jobs.each { |job| store.complete(job[:id]) }

      db = store.instance_variable_get(:@db)
      completed_jobs = fetched_jobs.map do |job|
        db.execute('SELECT status FROM jobs WHERE id = ?', [job[:id]]).first[0]
      end

      expect(completed_jobs).to all(eq('done'))

      # Two jobs remain pending — drain them with one worker.
      remaining = []
      while (j = store.fetch(1))
        remaining << j
      end
      expect(remaining.size).to eq(job_count - workers.size)
    end
  end

  describe 'queue configuration scenarios' do
    context 'without default client configured' do
      it 'raises error when trying to enqueue jobs' do
        Async::Background::Queue.default_client = nil
        expect { test_job_class.perform_async }.to raise_error(/Queue not configured/)
      end
    end

    context 'with client but no notifier' do
      it 'still works for job enqueuing' do
        client_without_notifier = Async::Background::Queue::Client.new(store: store)
        Async::Background::Queue.default_client = client_without_notifier

        job_id = test_job_class.perform_async('no_notifier_test')
        expect(job_id).to be_a(Integer)

        job = store.fetch(1)
        expect(job).not_to be_nil
        expect(job[:id]).to eq(job_id)
      end
    end
  end

  describe 'different job argument types' do
    it 'preserves various argument types through the pipeline' do
      complex_args = [
        42,
        'string value',
        { 'hash' => 'value', 'nested' => { 'key' => 'nested_value' } },
        [1, 2, 3, 'array_string'],
        true,
        false,
        nil,
        3.14159
      ]

      job_id = test_job_class.perform_async(*complex_args)
      job = store.fetch(1)

      expect(job[:id]).to eq(job_id)
      # JSON round-trip stringifies hash keys, so we compare against the
      # JSON-normalized form rather than the original Ruby symbols.
      expect(job[:args]).to eq(JSON.parse(JSON.generate(complex_args)))
      expect(job[:args][0]).to be_a(Integer)
      expect(job[:args][1]).to be_a(String)
      expect(job[:args][2]).to be_a(Hash)
      expect(job[:args][3]).to be_a(Array)
      expect(job[:args][4]).to be true
      expect(job[:args][5]).to be false
      expect(job[:args][6]).to be_nil
      expect(job[:args][7]).to be_a(Float)
    end
  end

  describe 'timing precision' do
    it 'respects timing for scheduled jobs' do
      future_time = Time.now + 0.5
      job_id = test_job_class.perform_at(future_time, 'precise_timing')

      job = store.fetch(1)
      expect(job).to be_nil

      sleep(0.7)

      job = store.fetch(1)
      expect(job).not_to be_nil
      expect(job[:id]).to eq(job_id)
      expect(job[:args]).to eq(['precise_timing'])
    end
  end

  describe 'retry option persistence' do
    let(:retrying_job_class) do
      Class.new do
        include Async::Background::Job

        options retry: 2, retry_delay: 3, backoff: :exponential

        def self.name
          'IntegrationRetryingJob'
        end

        def self.perform_now(*); end
      end
    end

    it 'persists retry options through enqueue and fetch' do
      job_id = retrying_job_class.perform_async('retryable', options: { timeout: 9 })
      job = store.fetch(1)

      expect(job[:id]).to eq(job_id)
      expect(job[:options]).to eq(timeout: 9, retry: 2, retry_delay: 3.0, backoff: 'exponential')
    end

    it 'stores retry attempts inside options instead of separate columns' do
      job_id = retrying_job_class.perform_async('retryable')
      job = store.fetch(1)

      store.retry_or_fail(job_id, fallback_options: Async::Background::Job::Options.new(**job[:options]))

      db = store.instance_variable_get(:@db)
      db.execute('UPDATE jobs SET run_at = ? WHERE id = ?', [Time.now.to_f - 1, job_id])

      retried_job = store.fetch(1)
      expect(retried_job[:options]).to eq(timeout: 120, retry: 2, retry_delay: 3.0, backoff: 'exponential', attempt: 1)
    end
  end
end
