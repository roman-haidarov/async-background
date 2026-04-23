# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Regression tests for fixes applied after the second round of review.
# These lock in the contracts that the earlier refactor had left inconsistent.
RSpec.describe 'Runner consistency fixes', type: :unit do
  before(:all) do
    unless defined?(::ConsistencySpec_Job)
      Object.const_set(:ConsistencySpec_Job, Class.new do
        include Async::Background::Job
        def perform(*); end
      end)
    end
  end

  describe 'class resolution parity between queue and schedule paths' do
    # Before the fix, queue used const_defined?(..., inherit: false) while
    # schedule used Object.const_get, which walks ancestors. These two disagreed
    # on edge cases like nested constants or constants inherited from Object.
    let(:runner) do
      schedule = { 'job' => { 'class' => 'ConsistencySpec_Job', 'every' => 60, 'worker' => 1 } }
      path = temp_file_path('.yml')
      File.write(path, schedule.to_yaml)
      Async::Background::Runner.new(
        config_path: path, job_count: 1, worker_index: 1, total_workers: 1
      )
    end

    it 'rejects unknown classes in schedule config with the same walker as queue' do
      bad_schedule = { 'job' => { 'class' => 'NoSuchConsistencyClass', 'every' => 60, 'worker' => 1 } }
      path = temp_file_path('.yml')
      File.write(path, bad_schedule.to_yaml)

      expect {
        Async::Background::Runner.new(
          config_path: path, job_count: 1, worker_index: 1, total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /unknown class: NoSuchConsistencyClass/)
    end

    it 'rejects empty class name in schedule config via the shared resolver' do
      bad_schedule = { 'job' => { 'class' => '   ', 'every' => 60, 'worker' => 1 } }
      path = temp_file_path('.yml')
      File.write(path, bad_schedule.to_yaml)

      expect {
        Async::Background::Runner.new(
          config_path: path, job_count: 1, worker_index: 1, total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /missing class/)
    end
  end

  describe 'schedule timeout validation' do
    # Before the fix, schedule config accepted timeout: 0 (or -1) silently while
    # queue jobs would raise. Now both paths use Job::Options for validation.
    it 'rejects timeout: 0 in schedule config' do
      path = temp_file_path('.yml')
      File.write(path, {
        'job' => { 'class' => 'ConsistencySpec_Job', 'every' => 60, 'worker' => 1, 'timeout' => 0 }
      }.to_yaml)

      expect {
        Async::Background::Runner.new(
          config_path: path, job_count: 1, worker_index: 1, total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /timeout must be > 0/)
    end

    it 'rejects negative timeout in schedule config' do
      path = temp_file_path('.yml')
      File.write(path, {
        'job' => { 'class' => 'ConsistencySpec_Job', 'every' => 60, 'worker' => 1, 'timeout' => -5 }
      }.to_yaml)

      expect {
        Async::Background::Runner.new(
          config_path: path, job_count: 1, worker_index: 1, total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /timeout must be > 0/)
    end
  end

  describe '#run_queue_job hardening against malformed options' do
    # Before the fix, if Job::Options.new raised on persisted data, the local
    # `options` variable was nil and a generic rescue would blow up with a
    # NoMethodError inside handle_queue_failure. Now malformed options become
    # ConfigError and go straight to fail (no retry).
    let(:schedule_path) do
      path = temp_file_path('.yml')
      File.write(path, {
        'placeholder' => { 'class' => 'ConsistencySpec_Job', 'every' => 60, 'worker' => 1 }
      }.to_yaml)
      path
    end

    let(:runner) do
      Async::Background::Runner.new(
        config_path: schedule_path, job_count: 1, worker_index: 1, total_workers: 1
      )
    end

    let(:mock_store) { instance_double('Async::Background::Queue::Store') }
    let(:passthrough_task) { Class.new { def with_timeout(_); yield; end }.new }

    before do
      runner.instance_variable_set(:@queue_store, mock_store)
    end

    it 'fails (does not retry) when persisted options are invalid' do
      # retry: 2 without retry_delay is a validation error at Options.new time
      bad_job = { id: 99, class_name: 'ConsistencySpec_Job', args: [], options: { retry: 2 } }

      expect(mock_store).to receive(:fail).with(99)
      expect(mock_store).not_to receive(:retry_or_fail)

      expect {
        runner.send(:run_queue_job, passthrough_task, bad_job)
      }.not_to raise_error
    end

    it 'fails (does not retry) when backoff value is not in the allowed set' do
      bad_job = { id: 100, class_name: 'ConsistencySpec_Job', args: [], options: { backoff: :nonsense } }

      expect(mock_store).to receive(:fail).with(100)
      expect(mock_store).not_to receive(:retry_or_fail)

      expect {
        runner.send(:run_queue_job, passthrough_task, bad_job)
      }.not_to raise_error
    end
  end
end
