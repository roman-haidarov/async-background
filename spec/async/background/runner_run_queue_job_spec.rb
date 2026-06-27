# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'Async::Background::Runner#run_queue_job', type: :unit do
  before(:all) do
    unless defined?(::RunQueueJobSpec_Ok)
      Object.const_set(:RunQueueJobSpec_Ok, Class.new do
        include Async::Background::Job

        @captured_args = []
        class << self
          attr_accessor :captured_args
        end

        def perform(*args)
          self.class.captured_args << args
        end
      end)
    end

    unless defined?(::RunQueueJobSpec_Raises)
      Object.const_set(:RunQueueJobSpec_Raises, Class.new do
        include Async::Background::Job
        def perform(*)
          raise StandardError, 'boom from spec'
        end
      end)
    end

    unless defined?(::RunQueueJobSpec_Slow)
      Object.const_set(:RunQueueJobSpec_Slow, Class.new do
        include Async::Background::Job
        def perform(*); end
      end)
    end
  end

  before do
    RunQueueJobSpec_Ok.captured_args = []
  end

  let(:schedule_path) do
    path = temp_file_path('.yml')
    File.write(path, {
      'placeholder' => {
        'class'  => 'RunQueueJobSpec_Ok',
        'every'  => 60,
        'worker' => 1
      }
    }.to_yaml)
    path
  end

  let(:runner) do
    Async::Background::Runner.new(
      config_path:   schedule_path,
      job_count:     1,
      worker_index:  1,
      total_workers: 1
    )
  end

  let(:mock_store) { instance_double('Async::Background::Queue::Store') }

  before do
    runner.instance_variable_set(:@queue_store, mock_store)
    allow(mock_store).to receive(:mark_started!).and_return(true)
  end

  let(:passthrough_task) do
    Class.new do
      def with_timeout(_seconds)
        yield
      end
    end.new
  end

  let(:timeout_task) do
    Class.new do
      def with_timeout(_seconds)
        raise ::Async::TimeoutError, 'simulated timeout'
      end
    end.new
  end

  def job_hash(id:, class_name:, args: [], options: {}, claim_token: "tok-#{id}")
    { id: id, class_name: class_name, args: args, options: options, claim_token: claim_token }
  end

  describe 'success path' do
    let(:job) { job_hash(id: 42, class_name: 'RunQueueJobSpec_Ok', args: ['hello', 1]) }

    it 'calls perform on the resolved job class with the stored args' do
      expect(mock_store).to receive(:complete).
        with(42, claim_token: 'tok-42', duration_ms: kind_of(Integer)).and_return(true)

      runner.send(:run_queue_job, passthrough_task, job)

      expect(RunQueueJobSpec_Ok.captured_args).to eq([['hello', 1]])
    end

    it 'threads claim_token through mark_started! and complete' do
      expect(mock_store).to receive(:mark_started!).with(42, claim_token: 'tok-42').and_return(true)
      expect(mock_store).to receive(:complete).
        with(42, claim_token: 'tok-42', duration_ms: kind_of(Integer)).and_return(true)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does not call retry_or_fail on success' do
      expect(mock_store).to receive(:complete).
        with(42, claim_token: 'tok-42', duration_ms: kind_of(Integer)).and_return(true)
      expect(mock_store).not_to receive(:retry_or_fail)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'updates metrics on success only AFTER successful CAS' do
      expect(mock_store).to receive(:complete).and_return(true)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_succeeded).with(nil, kind_of(Numeric)).ordered
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does NOT increment job_succeeded if CAS lost (stale lease)' do
      allow(mock_store).to receive(:complete).and_return(false)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_succeeded)
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered

      runner.send(:run_queue_job, passthrough_task, job)
    end


    it 'does not execute a job when its lease is lost before start' do
      allow(mock_store).to receive(:mark_started!).and_return(false)

      expect(mock_store).not_to receive(:complete)
      expect(mock_store).not_to receive(:retry_or_fail)
      expect(runner.metrics).not_to receive(:job_started)
      expect(runner.metrics).not_to receive(:job_stopped)

      runner.send(:run_queue_job, passthrough_task, job)

      expect(RunQueueJobSpec_Ok.captured_args).to be_empty
    end

    it 'handles a job with no arguments' do
      job_no_args = job_hash(id: 7, class_name: 'RunQueueJobSpec_Ok')
      expect(mock_store).to receive(:complete).
        with(7, claim_token: 'tok-7', duration_ms: kind_of(Integer)).and_return(true)

      runner.send(:run_queue_job, passthrough_task, job_no_args)

      expect(RunQueueJobSpec_Ok.captured_args).to eq([[]])
    end
  end

  describe 'timeout path' do
    let(:job) { job_hash(id: 100, class_name: 'RunQueueJobSpec_Slow') }

    it 'delegates timeout handling to retry_or_fail' do
      expect(mock_store).to receive(:retry_or_fail).
        with(100,
             claim_token: 'tok-100',
             error_class: ::Async::TimeoutError,
             error_message: kind_of(String),
             fallback_options: kind_of(Async::Background::Job::Options),
             duration_ms: kind_of(Integer)).and_return(:failed)

      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, timeout_task, job)
    end

    it 'updates metrics with job_timed_out only after CAS success' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_timed_out).with(nil).ordered
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_succeeded)
      expect(runner.metrics).not_to receive(:job_failed)

      runner.send(:run_queue_job, timeout_task, job)
    end

    it 'does NOT bump metrics on stale-lease timeout (CAS returns nil)' do
      allow(mock_store).to receive(:retry_or_fail).and_return(nil)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_timed_out)
      expect(runner.metrics).not_to receive(:job_failed)
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered

      runner.send(:run_queue_job, timeout_task, job)
    end

    it 'does not propagate the TimeoutError to the caller' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect {
        runner.send(:run_queue_job, timeout_task, job)
      }.not_to raise_error
    end
  end

  describe 'generic exception path' do
    let(:job) { job_hash(id: 200, class_name: 'RunQueueJobSpec_Raises', args: ['x']) }

    it 'delegates errors to retry_or_fail when perform raises' do
      expect(mock_store).to receive(:retry_or_fail).
        with(200,
             claim_token: 'tok-200',
             error_class: StandardError,
             error_message: 'boom from spec',
             fallback_options: kind_of(Async::Background::Job::Options),
             duration_ms: kind_of(Integer)).and_return(:failed)

      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'updates metrics with job_failed only after CAS success' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_failed).with(nil, kind_of(StandardError)).ordered
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_succeeded)
      expect(runner.metrics).not_to receive(:job_timed_out)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does NOT bump metrics on stale-lease failure (CAS returns nil)' do
      allow(mock_store).to receive(:retry_or_fail).and_return(nil)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_failed)
      expect(runner.metrics).to receive(:job_stopped).with(nil).ordered

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does not propagate the exception to the caller' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect {
        runner.send(:run_queue_job, passthrough_task, job)
      }.not_to raise_error
    end

    it 'fails fast for unknown job classes via Store#fail with claim_token' do
      job_unknown = job_hash(id: 300, class_name: 'NoSuchJobClassXYZ')

      expect(mock_store).to receive(:fail).
        with(300,
             claim_token: 'tok-300',
             error_class: Async::Background::ConfigError,
             error_message: kind_of(String)).and_return(true)
      expect(mock_store).not_to receive(:retry_or_fail)
      expect(runner.metrics).to receive(:job_failed).with(nil, instance_of(Async::Background::ConfigError))
      expect(runner.metrics).not_to receive(:job_stopped)

      expect {
        runner.send(:run_queue_job, passthrough_task, job_unknown)
      }.not_to raise_error
    end
  end

  describe 'retry behavior' do
    let(:job) do
      job_hash(
        id: 500,
        class_name: 'RunQueueJobSpec_Raises',
        args: ['x'],
        options: { retry: 3, retry_delay: 5, backoff: :exponential, attempt: 1 }
      )
    end

    it 'delegates retry scheduling to the store when retries remain' do
      expect(mock_store).to receive(:retry_or_fail).
        with(500,
             claim_token: 'tok-500',
             error_class: StandardError,
             error_message: 'boom from spec',
             fallback_options: kind_of(Async::Background::Job::Options),
             duration_ms: kind_of(Integer)).and_return(:retried)

      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, passthrough_task, job)
    end
  end

  describe 'metrics interaction across all paths' do
    it 'always calls job_started before any terminal metric (when CAS succeeds)' do
      allow(mock_store).to receive(:complete).and_return(true)
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_succeeded).ordered
      expect(runner.metrics).to receive(:job_stopped).ordered
      runner.send(:run_queue_job, passthrough_task, job_hash(id: 1, class_name: 'RunQueueJobSpec_Ok'))

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_timed_out).ordered
      expect(runner.metrics).to receive(:job_stopped).ordered
      runner.send(:run_queue_job, timeout_task, job_hash(id: 2, class_name: 'RunQueueJobSpec_Slow'))

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_failed).ordered
      expect(runner.metrics).to receive(:job_stopped).ordered
      runner.send(:run_queue_job, passthrough_task, job_hash(id: 3, class_name: 'RunQueueJobSpec_Raises'))
    end
  end
end
