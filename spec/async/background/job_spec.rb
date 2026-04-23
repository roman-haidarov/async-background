# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Job, type: :unit do
  let(:test_job_class) do
    Class.new do
      include Async::Background::Job

      def self.name
        'TestJob'
      end

      def self.perform_now(*args)
        "performed with #{args}"
      end
    end
  end

  let(:mock_client) { instance_double('Async::Background::Queue::Client') }

  before do
    @previous_client = Async::Background::Queue.default_client
    Async::Background::Queue.default_client = mock_client
  end

  after do
    Async::Background::Queue.default_client = @previous_client
  end

  describe '.perform_async' do
    it 'enqueues job with correct parameters' do
      expect(mock_client).to receive(:push).with('TestJob', ['arg1', 'arg2'], nil, options: {})

      test_job_class.perform_async('arg1', 'arg2')
    end

    it 'raises error when queue is not configured' do
      Async::Background::Queue.default_client = nil

      expect { test_job_class.perform_async }.to raise_error(/Queue not configured/)
    end

    it 'returns job id from client' do
      allow(mock_client).to receive(:push).and_return(42)

      result = test_job_class.perform_async('arg1')
      expect(result).to eq(42)
    end
  end

  describe '.perform_in' do
    it 'enqueues job with delay' do
      expect(mock_client).to receive(:push_in).with(300, 'TestJob', ['arg1'], options: {})

      test_job_class.perform_in(300, 'arg1')
    end

    it 'accepts delay as integer seconds' do
      expect(mock_client).to receive(:push_in).with(60, 'TestJob', [], options: {})

      test_job_class.perform_in(60)
    end

    it 'accepts delay as float seconds' do
      expect(mock_client).to receive(:push_in).with(30.5, 'TestJob', ['test'], options: {})

      test_job_class.perform_in(30.5, 'test')
    end
  end

  describe '.perform_at' do
    let(:future_time) { Time.now + 3600 }

    it 'enqueues job at specific time' do
      expect(mock_client).to receive(:push_at).with(future_time, 'TestJob', ['arg1'], options: {})

      test_job_class.perform_at(future_time, 'arg1')
    end

    it 'accepts Time object' do
      time = Time.parse('2025-01-01 12:00:00')
      expect(mock_client).to receive(:push_at).with(time, 'TestJob', [], options: {})

      test_job_class.perform_at(time)
    end

    it 'accepts timestamp as float' do
      timestamp = 1735732800.0
      expect(mock_client).to receive(:push_at).with(timestamp, 'TestJob', ['test'], options: {})

      test_job_class.perform_at(timestamp, 'test')
    end
  end

  describe '.perform_now' do
    it 'can be implemented by job class' do
      result = test_job_class.perform_now('test_arg')
      expect(result).to eq('performed with ["test_arg"]')
    end

    it 'raises NotImplementedError when #perform is not overridden' do
      abstract_job = Class.new { include Async::Background::Job }

      expect { abstract_job.perform_now }.to raise_error(NotImplementedError, /must implement #perform/)
    end
  end

  describe 'class name detection' do
    context 'with named class' do
      let(:named_job) do
        stub_const('MySpecialJob', Class.new do
          include Async::Background::Job

          def self.perform_now(*); end
        end)
      end

      it 'uses actual class name' do
        expect(mock_client).to receive(:push).with('MySpecialJob', ['test'], nil, options: {})

        named_job.perform_async('test')
      end
    end

    context 'with anonymous class that defines name' do
      it 'uses class name method if available' do
        anonymous_job = Class.new do
          include Async::Background::Job

          def self.name
            'CustomJobName'
          end

          def self.perform_now(*); end
        end

        expect(mock_client).to receive(:push).with('CustomJobName', ['test'], nil, options: {})

        anonymous_job.perform_async('test')
      end
    end
  end

  describe 'argument handling' do
    it 'handles no arguments' do
      expect(mock_client).to receive(:push).with('TestJob', [], nil, options: {})

      test_job_class.perform_async
    end

    it 'handles multiple arguments' do
      expect(mock_client).to receive(:push).with('TestJob', [1, 'string', { key: 'value' }, [1, 2, 3]], nil, options: {})

      test_job_class.perform_async(1, 'string', { key: 'value' }, [1, 2, 3])
    end

    it 'preserves argument types' do
      captured_args = nil
      expect(mock_client).to receive(:push) do |class_name, args, _run_at, **_opts|
        expect(class_name).to eq('TestJob')
        captured_args = args
      end

      test_job_class.perform_async(42, 'test', { a: 1 }, [1, 2])

      expect(captured_args[0]).to be_a(Integer)
      expect(captured_args[1]).to be_a(String)
      expect(captured_args[2]).to be_a(Hash)
      expect(captured_args[3]).to be_a(Array)
    end
  end

  describe 'job options' do
    let(:configurable_job_class) do
      Class.new do
        include Async::Background::Job

        options timeout: 45, retry: 3, retry_delay: 10, backoff: :linear

        def self.name
          'ConfigurableJob'
        end

        def self.perform_now(*); end
      end
    end

    it 'stores class-level retry-related options' do
      expect(configurable_job_class.resolve_options).to eq(
        timeout: 45,
        retry: 3,
        retry_delay: 10.0,
        backoff: :linear
      )
    end

    it 'passes merged retry-related options to the queue client' do
      expect(mock_client).to receive(:push).with(
        'ConfigurableJob',
        ['arg1'],
        nil,
        options: {
          timeout: 45,
          retry: 5,
          retry_delay: 2.5,
          backoff: :exponential
        }
      )

      configurable_job_class.perform_async(
        'arg1',
        options: { retry: 5, retry_delay: 2.5, backoff: :exponential }
      )
    end

    it 'requires retry_delay when retry is enabled' do
      expect {
        Class.new do
          include Async::Background::Job
          options retry: 2
        end
      }.to raise_error(ArgumentError, /retry_delay is required/)
    end

    it 'requires retry_delay to be strictly positive when retry is enabled' do
      expect {
        Class.new do
          include Async::Background::Job
          options retry: 2, retry_delay: 0
        end
      }.to raise_error(ArgumentError, /retry_delay must be > 0/)
    end

    it 'tracks retry attempts inside options' do
      options = Async::Background::Job::Options.new(retry: 2, retry_delay: 4, backoff: :linear)

      expect(options.next_attempt).to eq(1)
      expect(options.with_attempt(1).to_h.compact).to eq(
        timeout: 120,
        retry: 2,
        retry_delay: 4.0,
        backoff: :linear,
        attempt: 1
      )
    end
  end
end
