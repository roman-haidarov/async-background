# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe Async::Background::Runner, type: :unit do
  before(:all) do
    unless defined?(::RunnerSpecJob)
      job_class = Class.new do
        include Async::Background::Job
        def perform(*); end
      end
      Object.const_set(:RunnerSpecJob, job_class)
    end

    unless defined?(::RunnerSpecNamespace)
      Object.const_set(:RunnerSpecNamespace, Module.new)
      nested_job = Class.new do
        include Async::Background::Job
        def perform(*); end
      end
      ::RunnerSpecNamespace.const_set(:NestedJob, nested_job)
    end

    unless defined?(::RunnerSpecPlainClass)
      Object.const_set(:RunnerSpecPlainClass, Class.new)
    end
  end

  def write_schedule(yaml_hash)
    path = temp_file_path('.yml')
    File.write(path, yaml_hash.to_yaml)
    path
  end

  def minimal_schedule
    {
      'job_one' => {
        'class'  => 'RunnerSpecJob',
        'every'  => 60,
        'worker' => 1
      }
    }
  end

  def build_runner(schedule: minimal_schedule, worker_index: 1, total_workers: 1)
    Async::Background::Runner.new(
      config_path:   write_schedule(schedule),
      job_count:     1,
      worker_index:  worker_index,
      total_workers: total_workers
    )
  end

  let(:runner) { build_runner }

  describe '#resolve_job_class (private)' do
    it 'resolves a top-level Job class by name' do
      klass = runner.send(:resolve_job_class, 'RunnerSpecJob')
      expect(klass).to eq(RunnerSpecJob)
    end

    it 'resolves a namespaced Job class by qualified name' do
      klass = runner.send(:resolve_job_class, 'RunnerSpecNamespace::NestedJob')
      expect(klass).to eq(RunnerSpecNamespace::NestedJob)
    end

    it 'raises ConfigError for nil class name' do
      expect {
        runner.send(:resolve_job_class, nil)
      }.to raise_error(Async::Background::ConfigError, /empty class name/)
    end

    it 'raises ConfigError for empty class name' do
      expect {
        runner.send(:resolve_job_class, '')
      }.to raise_error(Async::Background::ConfigError, /empty class name/)
    end

    it 'raises ConfigError for whitespace-only class name' do
      expect {
        runner.send(:resolve_job_class, '   ')
      }.to raise_error(Async::Background::ConfigError, /empty class name/)
    end

    it 'raises ConfigError for an unknown class' do
      expect {
        runner.send(:resolve_job_class, 'NoSuchClassExistsAnywhere')
      }.to raise_error(Async::Background::ConfigError, /unknown class/)
    end

    it 'raises ConfigError when an intermediate namespace exists but the leaf does not' do
      expect {
        runner.send(:resolve_job_class, 'RunnerSpecNamespace::NoSuchInner')
      }.to raise_error(Async::Background::ConfigError, /unknown class/)
    end

    it 'raises ConfigError when the resolved class does not include Job' do
      expect {
        runner.send(:resolve_job_class, 'RunnerSpecPlainClass')
      }.to raise_error(Async::Background::ConfigError, /must include Async::Background::Job/)
    end

    it 'rejects "Object" because Object does not respond to perform_now' do
      expect {
        runner.send(:resolve_job_class, 'Object')
      }.to raise_error(Async::Background::ConfigError, /must include Async::Background::Job/)
    end

    it 'rejects "Kernel" because Kernel does not respond to perform_now' do
      expect {
        runner.send(:resolve_job_class, 'Kernel')
      }.to raise_error(Async::Background::ConfigError, /must include Async::Background::Job/)
    end

    it 'does not climb the ancestor chain (inherit: false)' do
      expect {
        runner.send(:resolve_job_class, 'String::Comparable')
      }.to raise_error(Async::Background::ConfigError, /unknown class/)
    end
  end

  describe '#build_task_config (private)' do
    it 'returns a hash with job_class, interval, cron, timeout for an interval job' do
      cfg = runner.send(:build_task_config, 'job_one', {
        'class' => 'RunnerSpecJob',
        'every' => 30
      })

      expect(cfg[:job_class]).to eq(RunnerSpecJob)
      expect(cfg[:interval]).to eq(30)
      expect(cfg[:cron]).to be_nil
      expect(cfg[:timeout]).to eq(Async::Background::DEFAULT_TIMEOUT)
    end

    it 'parses a cron expression via Fugit::Cron' do
      cfg = runner.send(:build_task_config, 'cron_job', {
        'class' => 'RunnerSpecJob',
        'cron'  => '*/5 * * * *'
      })

      expect(cfg[:job_class]).to eq(RunnerSpecJob)
      expect(cfg[:interval]).to be_nil
      expect(cfg[:cron]).to be_a(Fugit::Cron)
    end

    it 'honors a custom timeout' do
      cfg = runner.send(:build_task_config, 'job_one', {
        'class'   => 'RunnerSpecJob',
        'every'   => 60,
        'timeout' => 5
      })

      expect(cfg[:timeout]).to eq(5)
    end

    it 'raises ConfigError when class key is missing' do
      expect {
        runner.send(:build_task_config, 'broken', { 'every' => 60 })
      }.to raise_error(Async::Background::ConfigError, /\[broken\] missing class/)
    end

    it 'raises ConfigError when class key is an empty string' do
      expect {
        runner.send(:build_task_config, 'broken', { 'class' => '', 'every' => 60 })
      }.to raise_error(Async::Background::ConfigError, /\[broken\] missing class/)
    end

    it 'raises ConfigError when config is nil' do
      expect {
        runner.send(:build_task_config, 'broken', nil)
      }.to raise_error(Async::Background::ConfigError, /\[broken\] missing class/)
    end

    it 'raises ConfigError for unknown class' do
      expect {
        runner.send(:build_task_config, 'broken', {
          'class' => 'NoSuchClassXYZ',
          'every' => 60
        })
      }.to raise_error(Async::Background::ConfigError, /\[broken\] unknown class/)
    end

    it 'raises ConfigError when class does not include Job' do
      expect {
        runner.send(:build_task_config, 'broken', {
          'class' => 'RunnerSpecPlainClass',
          'every' => 60
        })
      }.to raise_error(Async::Background::ConfigError, /must include Async::Background::Job/)
    end

    it 'raises ConfigError when neither every nor cron is specified' do
      expect {
        runner.send(:build_task_config, 'broken', { 'class' => 'RunnerSpecJob' })
      }.to raise_error(Async::Background::ConfigError, /specify 'every' or 'cron'/)
    end

    it 'raises ConfigError when every is zero' do
      expect {
        runner.send(:build_task_config, 'broken', {
          'class' => 'RunnerSpecJob',
          'every' => 0
        })
      }.to raise_error(Async::Background::ConfigError, /'every' must be > 0/)
    end

    it 'raises ConfigError when every is negative' do
      expect {
        runner.send(:build_task_config, 'broken', {
          'class' => 'RunnerSpecJob',
          'every' => -10
        })
      }.to raise_error(Async::Background::ConfigError, /'every' must be > 0/)
    end

    it 'raises ConfigError for an invalid cron expression' do
      expect {
        runner.send(:build_task_config, 'broken', {
          'class' => 'RunnerSpecJob',
          'cron'  => 'this is not cron'
        })
      }.to raise_error(StandardError)
    end
  end

  describe '#build_heap (via Runner.new)' do
    it 'builds a heap containing the configured jobs' do
      r = build_runner(
        schedule: {
          'job_one' => { 'class' => 'RunnerSpecJob', 'every' => 60, 'worker' => 1 },
          'job_two' => { 'class' => 'RunnerSpecJob', 'every' => 30, 'worker' => 1 }
        }
      )

      expect(r.heap.size).to eq(2)
    end

    it 'raises ConfigError when the schedule file does not exist' do
      expect {
        Async::Background::Runner.new(
          config_path:   '/nonexistent/path/to/schedule.yml',
          job_count:     1,
          worker_index:  1,
          total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /Schedule file not found/)
    end

    it 'raises ConfigError when the schedule file is empty' do
      empty_path = temp_file_path('.yml')
      File.write(empty_path, '')

      expect {
        Async::Background::Runner.new(
          config_path:   empty_path,
          job_count:     1,
          worker_index:  1,
          total_workers: 1
        )
      }.to raise_error(Async::Background::ConfigError, /Empty schedule/)
    end

    describe 'sharding by worker_index' do
      it 'pins jobs to a specific worker via the explicit "worker" key' do
        schedule = {
          'mine'    => { 'class' => 'RunnerSpecJob', 'every' => 60, 'worker' => 1 },
          'theirs'  => { 'class' => 'RunnerSpecJob', 'every' => 60, 'worker' => 2 }
        }

        worker1 = build_runner(schedule: schedule, worker_index: 1, total_workers: 2)
        worker2 = build_runner(schedule: schedule, worker_index: 2, total_workers: 2)

        expect(worker1.heap.size).to eq(1)
        expect(worker2.heap.size).to eq(1)
      end

      it 'distributes jobs deterministically via crc32 when no explicit worker is set' do
        schedule = {
          'a' => { 'class' => 'RunnerSpecJob', 'every' => 60 },
          'b' => { 'class' => 'RunnerSpecJob', 'every' => 60 },
          'c' => { 'class' => 'RunnerSpecJob', 'every' => 60 },
          'd' => { 'class' => 'RunnerSpecJob', 'every' => 60 }
        }

        w1 = build_runner(schedule: schedule, worker_index: 1, total_workers: 2)
        w2 = build_runner(schedule: schedule, worker_index: 2, total_workers: 2)

        total = w1.heap.size + w2.heap.size
        expect(total).to eq(4)
      end

      it 'sharding is stable across runs (same name → same worker)' do
        schedule = {
          'stable_name' => { 'class' => 'RunnerSpecJob', 'every' => 60 }
        }

        r1a = build_runner(schedule: schedule, worker_index: 1, total_workers: 3)
        r1b = build_runner(schedule: schedule, worker_index: 1, total_workers: 3)
        expect(r1a.heap.size).to eq(r1b.heap.size)
      end
    end

    it 'sets next_run_at in the future for interval jobs' do
      r = build_runner(
        schedule: {
          'fast' => { 'class' => 'RunnerSpecJob', 'every' => 60, 'worker' => 1 }
        }
      )

      entry = r.heap.peek
      expect(entry).not_to be_nil
      expect(entry.name).to eq('fast')
      expect(entry.interval).to eq(60)
      expect(entry.next_run_at).to be > r.send(:monotonic_now)
    end

    it 'sets cron field for cron-based jobs' do
      r = build_runner(
        schedule: {
          'cronjob' => { 'class' => 'RunnerSpecJob', 'cron' => '*/5 * * * *', 'worker' => 1 }
        }
      )

      entry = r.heap.peek
      expect(entry.cron).to be_a(Fugit::Cron)
      expect(entry.interval).to be_nil
    end
  end

  describe 'public API after construction' do
    it 'is running? immediately after construction' do
      expect(runner.running?).to be true
    end

    it 'transitions to not running? after #stop' do
      runner.stop
      expect(runner.running?).to be false
    end

    it '#stop is idempotent' do
      runner.stop
      expect { runner.stop }.not_to raise_error
      expect(runner.running?).to be false
    end

    it 'exposes worker_index and total_workers' do
      r = build_runner(worker_index: 2, total_workers: 5,
                       schedule: { 'j' => { 'class' => 'RunnerSpecJob', 'every' => 60, 'worker' => 2 } })
      expect(r.worker_index).to eq(2)
      expect(r.total_workers).to eq(5)
    end
  end
end
