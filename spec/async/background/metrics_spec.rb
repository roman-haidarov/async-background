# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Metrics, type: :unit do
  let(:shm_path) { temp_file_path('.shm') }

  describe 'without async-utilization' do
    before do
      allow(described_class).to receive(:load_utilization!).and_raise(
        LoadError,
        'cannot load such file -- async/utilization'
      )
    end

    it 'keeps the runner-facing API as no-ops' do
      metrics = described_class.new(worker_index: 1, total_workers: 1, shm_path: shm_path)

      expect(metrics).not_to be_enabled
      expect(metrics.registry).to be_nil
      expect(metrics.values).to eq({})
      expect(metrics.unavailable_reason).to include('async/utilization')

      expect {
        metrics.job_started(nil)
        metrics.job_succeeded(nil, 0.25)
        metrics.job_failed(nil, StandardError.new('boom'))
        metrics.job_timed_out(nil)
        metrics.job_stopped(nil)
        metrics.job_skipped(nil)
      }.not_to raise_error
    end

    it 'reports that the optional integration is unavailable' do
      expect(described_class.available?).to be(false)
    end

    it 'lets optional observers treat missing metrics as an empty snapshot' do
      expect(described_class.read_all(total_workers: 1, path: shm_path)).to eq([])
    end
  end

  describe 'with the metric-handle API from async-utilization 0.3+' do
    let(:metric_class) do
      Class.new do
        attr_reader :value

        def initialize
          @value = 0
        end

        def increment
          @value += 1
        end

        def decrement
          @value -= 1
        end

        def set(value)
          @value = value
        end
      end
    end

    let(:registry_class) do
      metric = metric_class

      Class.new do
        attr_accessor :observer

        def initialize
          @metrics = {}
        end

        def metric(name)
          @metrics[name] ||= self.class.metric_class.new
        end

        def values
          @metrics.transform_values(&:value)
        end

        define_singleton_method(:metric_class) { metric }
      end
    end

    let(:schema_class) do
      field_class = Struct.new(:name, :type, :offset, keyword_init: true)

      Class.new do
        define_singleton_method(:build) do |fields|
          offset = 0
          rows = fields.map do |name, type|
            field = field_class.new(name: name, type: type, offset: offset)
            offset += IO::Buffer.size_of(type)
            field
          end
          Struct.new(:fields).new(rows)
        end
      end
    end

    let(:observer_class) do
      Class.new do
        class << self
          attr_reader :calls

          def open(*arguments)
            @calls ||= []
            @calls << arguments
            Object.new
          end
        end
      end
    end

    before do
      utilization = Module.new
      utilization.const_set(:Registry, registry_class)
      utilization.const_set(:Schema, schema_class)
      utilization.const_set(:Observer, observer_class)
      stub_const('Async::Utilization', utilization)
      allow(described_class).to receive(:load_utilization!).and_return(true)
    end

    it 'writes through cached metric handles instead of removed Registry shortcuts' do
      metrics = described_class.new(worker_index: 1, total_workers: 1, shm_path: shm_path)

      metrics.job_started(nil)
      metrics.job_succeeded(nil, 1.234)
      metrics.job_stopped(nil)
      metrics.job_skipped(nil)

      expect(metrics).to be_enabled
      expect(metrics.registry).to respond_to(:metric)
      expect(metrics.registry).not_to respond_to(:increment)
      values = metrics.values
      expect(values).to include(
        total_runs: 1,
        total_successes: 1,
        total_failures: 0,
        total_timeouts: 0,
        total_skips: 1,
        active_jobs: 0,
        last_duration_ms: 1234
      )
      expect(values.fetch(:last_run_at)).to be_a(Integer)
    end

    it 'keeps active_jobs balanced when a started job loses its terminal lease' do
      metrics = described_class.new(worker_index: 1, total_workers: 1, shm_path: shm_path)

      metrics.job_started(nil)
      metrics.job_stopped(nil)

      expect(metrics.values).to include(total_runs: 1, active_jobs: 0, total_successes: 0)
    end
  end

  describe '.read_all' do
    it 'rejects an invalid worker count before touching the filesystem' do
      expect {
        described_class.read_all(total_workers: 0, path: shm_path)
      }.to raise_error(ArgumentError, 'total_workers must be a positive Integer')
    end

    it 'maps an observer snapshot read-only' do
      field_class = Struct.new(:name, :type, :offset, keyword_init: true)
      schema_class = Class.new do
        define_singleton_method(:build) do |fields|
          offset = 0
          rows = fields.map do |name, type|
            field = field_class.new(name: name, type: type, offset: offset)
            offset += IO::Buffer.size_of(type)
            field
          end
          Struct.new(:fields).new(rows)
        end
      end

      utilization = Module.new
      utilization.const_set(:Schema, schema_class)
      stub_const('Async::Utilization', utilization)
      allow(described_class).to receive(:load_utilization!).and_return(true)

      layout = described_class.schema
      size = described_class.segment_size * 2
      File.binwrite(shm_path, "\0" * size)

      File.open(shm_path, 'r+b') do |file|
        buffer = IO::Buffer.map(file, size, 0)
        layout.fields.each do |field|
          buffer.set_value(field.type, field.offset, field.name == :total_runs ? 7 : 0)
        end
      end

      expect(described_class.read_all(total_workers: 2, path: shm_path)).to eq([
        {
          worker: 1,
          total_runs: 7,
          total_successes: 0,
          total_failures: 0,
          total_timeouts: 0,
          total_skips: 0,
          active_jobs: 0,
          last_run_at: 0,
          last_duration_ms: 0
        },
        {
          worker: 2,
          total_runs: 0,
          total_successes: 0,
          total_failures: 0,
          total_timeouts: 0,
          total_skips: 0,
          active_jobs: 0,
          last_run_at: 0,
          last_duration_ms: 0
        }
      ])
    end
  end
end
