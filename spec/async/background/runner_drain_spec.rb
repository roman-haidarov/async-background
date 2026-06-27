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
    it 'wires the Semaphore to a Barrier so spawned tasks become its children' do
      barrier   = runner.instance_variable_get(:@drain_barrier)
      semaphore = runner.semaphore

      expect(barrier).to be_a(::Async::Barrier)

      sem_parent = if semaphore.respond_to?(:parent)
        semaphore.parent
      else
        semaphore.instance_variable_get(:@parent)
      end
      expect(sem_parent).to equal(barrier)
    end

    it 'drains all in-flight tasks before tearing down resources' do
      Async do |task|
        barrier = runner.instance_variable_get(:@drain_barrier)
        notif = ::Async::Notification.new
        finished = []

        2.times do |i|
          runner.semaphore.async do
            notif.wait
            finished << i
          end
        end

        task.async do
          notif.signal
          notif.signal
        end

        barrier.wait
        expect(finished.sort).to eq([0, 1])
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
