# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Regression specs for the 0.7.2 P0 fixes:
#
#   1) Runner#run must wait for every in-flight job task to finish before tearing
#      down Store and UNIX socket. Pre-0.7.2, `semaphore.acquire {}` returned as
#      soon as a single slot was free, so a still-executing job could be recovered
#      and re-run by an overlapping peer.
#
#   2) The queue listener must wake exactly when the next pending row becomes due,
#      not at the QUEUE_POLL_INTERVAL boundary. Otherwise push_in(2) and
#      retry_delay: 1 both round up to ~5s.
#
RSpec.describe 'Async::Background::Runner 0.7.2 fixes', type: :unit do
  before(:all) do
    unless defined?(::DrainSpec_Job)
      Object.const_set(:DrainSpec_Job, Class.new do
        include Async::Background::Job
        def perform(*); end
      end)
    end
  end

  let(:schedule_path) do
    path = temp_file_path('.yml')
    File.write(path, {
      'placeholder' => { 'class' => 'DrainSpec_Job', 'every' => 60, 'worker' => 1 }
    }.to_yaml)
    path
  end

  let(:runner) do
    Async::Background::Runner.new(
      config_path: schedule_path, job_count: 2, worker_index: 1, total_workers: 1
    )
  end

  describe 'shutdown drain (P0)' do
    it 'tracks job tasks in a TaskGroup and bounds concurrency with a Semaphore' do
      expect(runner.jobs).to be_a(Async::Background::Runtime::TaskGroup)
      expect(runner.services).to be_a(Async::Background::Runtime::TaskGroup)
      expect(runner.semaphore).to be_a(Async::Background::Runtime::Semaphore)
      expect(runner.semaphore.limit).to eq(2)
    end

    it 'registers every spawned job task with the drain group' do
      with_scheduler do
        gate = Latch.new

        2.times { runner.send(:spawn_job) { gate.wait } }
        expect(runner.jobs.size).to eq(2)

        gate.open!
        runner.jobs.wait
        expect(runner.jobs).to be_empty
      end
    end

    it 'drains all in-flight tasks before tearing down resources' do
      with_scheduler do
        gate = Latch.new
        finished = []
        drained = false

        2.times do |i|
          runner.send(:spawn_job) do
            gate.wait
            finished << i
          end
        end

        Async::Background::Runtime.spawn do
          runner.send(:drain_jobs)
          drained = true
        end

        Async::Background::Runtime.spawn { gate.open! }

        runner.jobs.wait
        expect(finished.sort).to eq([0, 1])
        expect(drained).to be(true)
      end
    end

    it 'keeps the job dispatch loop non-blocking when every slot is taken' do
      with_scheduler do
        gate = Latch.new
        started = 0

        4.times do
          runner.send(:spawn_job) do
            started += 1
            gate.wait
          end
        end

        expect(runner.jobs.size).to eq(4)
        expect(started).to eq(2)

        gate.open!
        runner.jobs.wait
        expect(started).to eq(4)
      end
    end

    it 'gives up on a wedged job instead of parking forever' do
      with_scheduler do
        bounded = Async::Background::Runner.new(
          config_path: schedule_path, job_count: 2, worker_index: 1, total_workers: 1,
          drain_timeout: 0.05
        )

        never = Latch.new
        bounded.send(:spawn_job) { never.wait }
        bounded.send(:drain_jobs)

        expect(bounded.jobs).to be_empty
      end
    end

    it 'waits indefinitely when drain_timeout is nil' do
      with_scheduler do
        unbounded = Async::Background::Runner.new(
          config_path: schedule_path, job_count: 2, worker_index: 1, total_workers: 1,
          drain_timeout: nil
        )

        gate = Latch.new
        drained = false
        unbounded.send(:spawn_job) { gate.wait }

        Async::Background::Runtime.spawn do
          unbounded.send(:drain_jobs)
          drained = true
        end
        sleep(0.05)
        expect(drained).to be(false)

        gate.open!
        unbounded.jobs.wait
        sleep(0.01)
        expect(drained).to be(true)
      end
    end

    it 'does not claim more queue rows than the semaphore can run' do
      with_scheduler do
        pending = Array.new(8) do |i|
          {id: i, class_name: 'DrainSpec_Job', claim_token: 't', args: [], options: {}}
        end
        fetched = 0
        store = instance_double('Async::Background::Queue::Store')
        allow(store).to receive(:fetch) do
          fetched += 1
          pending.shift
        end
        runner.instance_variable_set(:@queue_store, store)

        gate = Latch.new
        allow(runner).to receive(:run_queue_job) { gate.wait }

        runner.send(:dispatch_available_queue_jobs)

        expect(fetched).to eq(2)
        expect(runner.jobs.size).to eq(2)
        expect(pending.size).to eq(6)

        gate.open!
        runner.jobs.wait
      end
    end
  end

  describe '#next_wait_timeout precision fix' do
    let(:mock_store) { instance_double('Async::Background::Queue::Store') }

    before do
      runner.instance_variable_set(:@queue_store, mock_store)
    end

    it 'returns QUEUE_POLL_INTERVAL when the queue is empty' do
      allow(mock_store).to receive(:next_pending_run_at).and_return(nil)
      expect(runner.send(:next_wait_timeout)).to eq(Async::Background::QUEUE_POLL_INTERVAL)
    end

    it 'returns the remaining time when the next job is due sooner than the poll interval' do
      due_in = 1.7
      allow(mock_store).to receive(:next_pending_run_at).and_return(Time.now.to_f + due_in)

      timeout = runner.send(:next_wait_timeout)
      expect(timeout).to be < Async::Background::QUEUE_POLL_INTERVAL
      expect(timeout).to be_within(0.2).of(due_in)
    end

    it 'caps at QUEUE_POLL_INTERVAL even for far-future jobs' do
      allow(mock_store).to receive(:next_pending_run_at).and_return(Time.now.to_f + 3600)
      expect(runner.send(:next_wait_timeout)).to eq(Async::Background::QUEUE_POLL_INTERVAL)
    end

    it 'returns the tiny MIN_QUEUE_WAIT floor for an overdue pending row' do
      allow(mock_store).to receive(:next_pending_run_at).and_return(Time.now.to_f - 10)
      expect(runner.send(:next_wait_timeout)).to eq(Async::Background::MIN_QUEUE_WAIT)
    end
  end
end
