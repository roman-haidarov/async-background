# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# When every slot is busy and the backlog is overdue, next_wait_timeout used to
# see MIN(run_at) in the past and return MIN_QUEUE_WAIT, so the listener woke
# ~1000x/s to run a fetch it could not use. 1.0.2 did not have this: it blocked
# inside semaphore.async instead. The saturation flag restores that property
# without giving up the drain bookkeeping.
RSpec.describe Async::Background::Runner, 'queue saturation', type: :unit do
  before(:all) do
    unless defined?(::SaturationSpecJob)
      job_class = Class.new do
        include Async::Background::Job
        def perform(*); end
      end
      Object.const_set(:SaturationSpecJob, job_class)
    end
  end

  # Always returns a job, and always reports an overdue next run: the shape that
  # produced the spin.
  let(:backlog_store) do
    Class.new do
      attr_reader :fetches, :min_run_at_calls

      def initialize
        @fetches = 0
        @min_run_at_calls = 0
      end

      def fetch(_worker_index)
        @fetches += 1
        {'id' => @fetches, 'class_name' => 'SaturationSpecJob', 'args' => '[]', 'options' => nil, 'attempts' => 0}
      end

      def next_pending_run_at
        @min_run_at_calls += 1
        Time.now.to_f - 100
      end

      def close; end
    end.new
  end

  let(:runner) do
    path = temp_file_path('.yml')
    File.write(path, {
      'idle' => {'class' => 'SaturationSpecJob', 'every' => 3600, 'worker' => 1}
    }.to_yaml)

    described_class.new(
      config_path: path,
      job_count: 2,
      worker_index: 1,
      total_workers: 1,
      metrics_shm_path: temp_file_path('.shm')
    )
  end

  def saturate(runner, gate)
    runner.instance_variable_set(:@queue_store, backlog_store)
    runner.instance_variable_set(:@listen_queue, true)
    runner.define_singleton_method(:run_queue_job) { |_task, _job| gate.wait }
    runner.send(:dispatch_available_queue_jobs)
  end

  it 'stops dispatching at the concurrency limit and records saturation' do
    with_scheduler do
      gate = Latch.new
      saturate(runner, gate)

      expect(runner.jobs.size).to eq(2)
      expect(runner.instance_variable_get(:@queue_saturated)).to be(true)

      gate.open!
      runner.jobs.wait
    end
  end

  it 'parks on the poll interval instead of MIN_QUEUE_WAIT while saturated' do
    with_scheduler do
      gate = Latch.new
      saturate(runner, gate)

      expect(runner.send(:next_wait_timeout)).to eq(Async::Background::QUEUE_POLL_INTERVAL)

      gate.open!
      runner.jobs.wait
    end
  end

  it 'does not touch the database while saturated' do
    with_scheduler do
      gate = Latch.new
      saturate(runner, gate)

      before_fetches = backlog_store.fetches
      before_queries = backlog_store.min_run_at_calls
      3.times { runner.send(:next_wait_timeout) }

      expect(backlog_store.fetches).to eq(before_fetches)
      expect(backlog_store.min_run_at_calls).to eq(before_queries)

      gate.open!
      runner.jobs.wait
    end
  end

  it 'signals the waker only once the finished job has left the drain group' do
    with_scheduler do
      gate = Latch.new
      saturate(runner, gate)

      observed = []
      jobs = runner.jobs
      waker = Object.new
      waker.define_singleton_method(:signal) { observed << jobs.size }
      runner.instance_variable_set(:@queue_waker, waker)

      gate.open!
      runner.jobs.wait

      expect(observed).not_to be_empty
      expect(observed.max).to be < runner.semaphore.limit
    end
  end

  it 'does not signal the waker while the queue is not saturated' do
    with_scheduler do
      signals = 0
      waker = Object.new
      waker.define_singleton_method(:signal) { signals += 1 }
      runner.instance_variable_set(:@queue_waker, waker)
      runner.instance_variable_set(:@queue_saturated, false)

      gate = Latch.new
      runner.send(:spawn_job) { gate.wait }
      gate.open!
      runner.jobs.wait

      expect(signals).to eq(0)
    end
  end

  it 'goes back to the due-based timeout once slots free up' do
    with_scheduler do
      gate = Latch.new
      saturate(runner, gate)

      gate.open!
      runner.jobs.wait
      runner.instance_variable_set(:@queue_saturated, false)

      expect(runner.send(:next_wait_timeout)).to be < Async::Background::QUEUE_POLL_INTERVAL
    end
  end
end
