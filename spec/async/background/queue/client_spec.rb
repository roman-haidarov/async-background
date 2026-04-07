# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Queue::Client, type: :unit do
  let(:mock_store) { instance_double('Async::Background::Queue::Store') }
  let(:mock_notifier) { instance_double('Async::Background::Queue::Notifier') }
  let(:client) { described_class.new(store: mock_store, notifier: mock_notifier) }

  describe '#initialize' do
    it 'creates client with store and notifier' do
      expect(client).to be_a(described_class)
    end

    it 'can be created without notifier' do
      client_without_notifier = described_class.new(store: mock_store)
      expect(client_without_notifier).to be_a(described_class)
    end
  end

  describe '#push' do
    it 'enqueues job with immediate execution' do
      expect(mock_store).to receive(:enqueue).with('TestJob', ['arg1', 'arg2'], nil).and_return(42)
      expect(mock_notifier).to receive(:notify_all)

      result = client.push('TestJob', ['arg1', 'arg2'])
      expect(result).to eq(42)
    end

    it 'enqueues job with specific run_at time' do
      future_time = Time.now.to_f + 3600
      expect(mock_store).to receive(:enqueue).with('DelayedJob', ['arg'], future_time).and_return(24)
      expect(mock_notifier).to receive(:notify_all)

      result = client.push('DelayedJob', ['arg'], future_time)
      expect(result).to eq(24)
    end

    it 'handles empty arguments' do
      expect(mock_store).to receive(:enqueue).with('EmptyJob', [], nil).and_return(1)
      expect(mock_notifier).to receive(:notify_all)

      client.push('EmptyJob', [])
    end

    it 'works without notifier' do
      client_without_notifier = described_class.new(store: mock_store)
      expect(mock_store).to receive(:enqueue).with('TestJob', [], nil).and_return(1)

      expect { client_without_notifier.push('TestJob', []) }.not_to raise_error
    end

    it 'preserves complex arguments' do
      complex_args = [
        42,
        'string',
        { key: 'value', nested: { array: [1, 2, 3] } },
        [true, false, nil]
      ]

      expect(mock_store).to receive(:enqueue).with('ComplexJob', complex_args, nil).and_return(99)
      expect(mock_notifier).to receive(:notify_all)

      client.push('ComplexJob', complex_args)
    end

    it 'returns the id from the store even when notifier is nil' do
      client_without_notifier = described_class.new(store: mock_store)
      expect(mock_store).to receive(:enqueue).and_return(7)

      expect(client_without_notifier.push('TestJob', [])).to eq(7)
    end
  end

  describe '#push_in' do
    it 'calculates correct run_at time for delay' do
      delay = 300
      before_time = Time.now.to_f

      expect(mock_store).to receive(:enqueue) do |class_name, args, run_at|
        expect(class_name).to eq('DelayedJob')
        expect(args).to eq(['arg1'])
        expect(run_at).to be_within(1.0).of(before_time + delay)
        42
      end
      expect(mock_notifier).to receive(:notify_all)

      result = client.push_in(delay, 'DelayedJob', ['arg1'])
      expect(result).to eq(42)
    end

    it 'handles float delays' do
      delay = 30.5
      before_time = Time.now.to_f

      expect(mock_store).to receive(:enqueue) do |_class_name, _args, run_at|
        expect(run_at).to be_within(1.0).of(before_time + delay)
        1
      end
      expect(mock_notifier).to receive(:notify_all)

      client.push_in(delay, 'FloatDelayJob', [])
    end

    it 'handles zero delay' do
      before_time = Time.now.to_f

      expect(mock_store).to receive(:enqueue) do |_class_name, _args, run_at|
        expect(run_at).to be_within(1.0).of(before_time)
        1
      end
      expect(mock_notifier).to receive(:notify_all)

      client.push_in(0, 'ImmediateJob', [])
    end

    it 'handles negative delay (job runs immediately)' do
      before_time = Time.now.to_f

      expect(mock_store).to receive(:enqueue) do |_class_name, _args, run_at|
        expect(run_at).to be_within(1.0).of(before_time - 10)
        1
      end
      expect(mock_notifier).to receive(:notify_all)

      client.push_in(-10, 'PastJob', [])
    end
  end

  describe '#push_at' do
    context 'with Time object' do
      it 'converts Time to float timestamp' do
        time = Time.parse('2025-12-25 12:00:00 UTC')
        expected_timestamp = time.to_f

        expect(mock_store).to receive(:enqueue).with('ChristmasJob', ['ho ho ho'], expected_timestamp).and_return(25)
        expect(mock_notifier).to receive(:notify_all)

        result = client.push_at(time, 'ChristmasJob', ['ho ho ho'])
        expect(result).to eq(25)
      end
    end

    context 'with timestamp' do
      it 'converts float timestamp via to_f' do
        timestamp = 1735128000.0

        expect(mock_store).to receive(:enqueue).with('TimestampJob', ['arg'], timestamp).and_return(100)
        expect(mock_notifier).to receive(:notify_all)

        result = client.push_at(timestamp, 'TimestampJob', ['arg'])
        expect(result).to eq(100)
      end

      it 'converts integer timestamps to float' do
        timestamp = 1735128000

        expect(mock_store).to receive(:enqueue).with('IntegerJob', [], timestamp.to_f).and_return(101)
        expect(mock_notifier).to receive(:notify_all)

        client.push_at(timestamp, 'IntegerJob', [])
      end
    end

    context 'with other time-like objects' do
      it 'converts objects that respond to to_f' do
        time_like = double('TimeObject', to_f: 1735128000.0)

        expect(mock_store).to receive(:enqueue).with('TimelikeJob', [], 1735128000.0).and_return(102)
        expect(mock_notifier).to receive(:notify_all)

        client.push_at(time_like, 'TimelikeJob', [])
      end

      it 'accepts numeric values directly without to_f when not respond_to' do
        opaque = Object.new
        def opaque.respond_to?(_, _ = false); false; end

        expect(mock_store).to receive(:enqueue).with('OpaqueJob', [], opaque).and_return(103)
        expect(mock_notifier).to receive(:notify_all)

        client.push_at(opaque, 'OpaqueJob', [])
      end
    end
  end

  describe 'error handling' do
    it 'propagates store errors' do
      expect(mock_store).to receive(:enqueue).and_raise(StandardError, 'Database error')

      expect { client.push('FailingJob', []) }.to raise_error(StandardError, 'Database error')
    end

    it 'currently propagates notifier errors after the job has been persisted' do
      expect(mock_store).to receive(:enqueue).with('TestJob', [], nil).and_return(1)
      expect(mock_notifier).to receive(:notify_all).and_raise(StandardError, 'Notification failed')

      expect { client.push('TestJob', []) }.to raise_error(StandardError, 'Notification failed')
    end
  end

  describe 'integration scenarios' do
    it 'handles rapid successive enqueues' do
      received_classes = []
      allow(mock_store).to receive(:enqueue) do |class_name, _args, _run_at|
        received_classes << class_name
        received_classes.size
      end
      expect(mock_notifier).to receive(:notify_all).exactly(100).times

      100.times { |i| client.push("Job#{i}", [i]) }

      expect(received_classes.size).to eq(100)
      expect(received_classes.first).to eq('Job0')
      expect(received_classes.last).to eq('Job99')
    end

    it 'handles mixed job types' do
      before_time = Time.now.to_f

      expect(mock_store).to receive(:enqueue).with('ImmediateJob', ['now'], nil).and_return(1)
      expect(mock_store).to receive(:enqueue) do |class_name, args, run_at|
        expect(class_name).to eq('DelayedJob')
        expect(args).to eq(['later'])
        expect(run_at).to be_within(1.0).of(before_time + 60)
        2
      end
      expect(mock_store).to receive(:enqueue).with('ScheduledJob', ['scheduled'], 1735128000.0).and_return(3)
      expect(mock_notifier).to receive(:notify_all).exactly(3).times

      client.push('ImmediateJob', ['now'])
      client.push_in(60, 'DelayedJob', ['later'])
      client.push_at(1735128000.0, 'ScheduledJob', ['scheduled'])
    end
  end

  describe 'Async::Background::Queue module API' do
    let(:job_class) do
      Class.new do
        include Async::Background::Job
        def self.name; 'ModuleApiTestJob'; end
        def self.perform_now(*); end
      end
    end

    before do
      @previous_client = Async::Background::Queue.default_client
      Async::Background::Queue.default_client = client
    end

    after do
      Async::Background::Queue.default_client = @previous_client
    end

    it 'enqueue raises when default_client is nil' do
      Async::Background::Queue.default_client = nil
      expect {
        Async::Background::Queue.enqueue(job_class)
      }.to raise_error(/Queue not configured/)
    end

    it 'enqueue accepts a class' do
      expect(mock_store).to receive(:enqueue).with('ModuleApiTestJob', [1, 2], nil).and_return(1)
      expect(mock_notifier).to receive(:notify_all)
      Async::Background::Queue.enqueue(job_class, 1, 2)
    end

    it 'enqueue accepts a string class name' do
      expect(mock_store).to receive(:enqueue).with('SomeJob', ['x'], nil).and_return(1)
      expect(mock_notifier).to receive(:notify_all)
      Async::Background::Queue.enqueue('SomeJob', 'x')
    end

    it 'enqueue rejects classes that do not include Job' do
      bad = Class.new
      expect {
        Async::Background::Queue.enqueue(bad)
      }.to raise_error(ArgumentError, /must include Async::Background::Job/)
    end
  end
end
