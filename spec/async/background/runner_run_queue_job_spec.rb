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

  describe 'success path' do
    let(:job) { { id: 42, class_name: 'RunQueueJobSpec_Ok', args: ['hello', 1], options: {} } }

    it 'calls perform on the resolved job class with the stored args' do
      expect(mock_store).to receive(:complete).with(42)

      runner.send(:run_queue_job, passthrough_task, job)

      expect(RunQueueJobSpec_Ok.captured_args).to eq([['hello', 1]])
    end

    it 'marks the job as complete in the store' do
      expect(mock_store).to receive(:complete).with(42)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does not call retry_or_fail on success' do
      expect(mock_store).to receive(:complete).with(42)
      expect(mock_store).not_to receive(:retry_or_fail)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'updates metrics on success (job_started + job_finished)' do
      allow(mock_store).to receive(:complete)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_finished).with(nil, kind_of(Numeric)).ordered

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'handles a job with no arguments' do
      job_no_args = { id: 7, class_name: 'RunQueueJobSpec_Ok', args: [], options: {} }
      expect(mock_store).to receive(:complete).with(7)

      runner.send(:run_queue_job, passthrough_task, job_no_args)

      expect(RunQueueJobSpec_Ok.captured_args).to eq([[]])
    end
  end

  describe 'timeout path' do
    let(:job) { { id: 100, class_name: 'RunQueueJobSpec_Slow', args: [], options: {} } }

    it 'delegates timeout handling to retry_or_fail' do
      expect(mock_store).to receive(:retry_or_fail).with(100, options: kind_of(Async::Background::Job::Options)).and_return(:failed)
      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, timeout_task, job)
    end

    it 'updates metrics with job_timed_out' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_timed_out).with(nil).ordered
      expect(runner.metrics).not_to receive(:job_finished)
      expect(runner.metrics).not_to receive(:job_failed)

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
    let(:job) { { id: 200, class_name: 'RunQueueJobSpec_Raises', args: ['x'], options: {} } }

    it 'delegates errors to retry_or_fail when perform raises' do
      expect(mock_store).to receive(:retry_or_fail).with(200, options: kind_of(Async::Background::Job::Options)).and_return(:failed)
      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'updates metrics with job_failed' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).with(nil).ordered
      expect(runner.metrics).to receive(:job_failed).with(nil, kind_of(StandardError)).ordered
      expect(runner.metrics).not_to receive(:job_finished)
      expect(runner.metrics).not_to receive(:job_timed_out)

      runner.send(:run_queue_job, passthrough_task, job)
    end

    it 'does not propagate the exception to the caller' do
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect {
        runner.send(:run_queue_job, passthrough_task, job)
      }.not_to raise_error
    end

    it 'fails fast for unknown job classes instead of retrying them' do
      job_unknown = { id: 300, class_name: 'NoSuchJobClassXYZ', args: [], options: {} }

      expect(mock_store).to receive(:fail).with(300)
      expect(mock_store).not_to receive(:retry_or_fail)

      expect {
        runner.send(:run_queue_job, passthrough_task, job_unknown)
      }.not_to raise_error
    end
  end

  describe 'retry behavior' do
    let(:job) do
      {
        id: 500,
        class_name: 'RunQueueJobSpec_Raises',
        args: ['x'],
        options: { retry: 3, retry_delay: 5, backoff: :exponential, attempt: 1 }
      }
    end

    it 'delegates retry scheduling to the store when retries remain' do
      expect(mock_store).to receive(:retry_or_fail).with(500, options: kind_of(Async::Background::Job::Options)).and_return(:retried)
      expect(mock_store).not_to receive(:complete)

      runner.send(:run_queue_job, passthrough_task, job)
    end
  end

  describe 'metrics interaction across all paths' do
    it 'always calls job_started before any terminal metric' do
      allow(mock_store).to receive(:complete)
      allow(mock_store).to receive(:retry_or_fail).and_return(:failed)

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_finished).ordered
      runner.send(:run_queue_job, passthrough_task, { id: 1, class_name: 'RunQueueJobSpec_Ok', args: [], options: {} })

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_timed_out).ordered
      runner.send(:run_queue_job, timeout_task, { id: 2, class_name: 'RunQueueJobSpec_Slow', args: [], options: {} })

      expect(runner.metrics).to receive(:job_started).ordered
      expect(runner.metrics).to receive(:job_failed).ordered
      runner.send(:run_queue_job, passthrough_task, { id: 3, class_name: 'RunQueueJobSpec_Raises', args: [], options: {} })
    end
  end
end
