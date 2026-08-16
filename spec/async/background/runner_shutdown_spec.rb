# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Signal.trap only clears the running flag and pokes the pipe; the watcher fiber
# is what actually signals the shutdown notification. If the watcher checks
# running? before signalling, it exits without waking the main fiber, which then
# stays parked in shutdown.wait until the next scheduled entry is due — months,
# for a `cron: '0 0 1 1 *'` schedule. That is a hang, not a slowdown.
#
# Note these specs must NOT go through Runner#stop: #stop signals the
# notification itself, so it hides the bug entirely.
RSpec.describe Async::Background::Runner, 'shutdown', type: :unit do
  before(:all) do
    unless defined?(::ShutdownSpecJob)
      job_class = Class.new do
        include Async::Background::Job
        def perform(*); end
      end
      Object.const_set(:ShutdownSpecJob, job_class)
    end
  end

  def far_future_schedule
    path = temp_file_path('.yml')
    File.write(path, {
      'never_due' => {'class' => 'ShutdownSpecJob', 'every' => 3600, 'worker' => 1}
    }.to_yaml)
    path
  end

  def build_runner
    described_class.new(
      config_path: far_future_schedule,
      job_count: 1,
      worker_index: 1,
      total_workers: 1,
      metrics_shm_path: temp_file_path('.shm')
    )
  end

  def simulate_sigterm(runner)
    runner.instance_variable_set(:@running, false)
    runner.instance_variable_get(:@signal_w).write_nonblock('.')
  end

  it 'signals shutdown from the watcher even though the trap already cleared running?' do
    with_scheduler do
      runner = build_runner
      runner.send(:setup_signal_handlers)
      runner.send(:start_signal_watcher)

      woken = false
      Async::Background::Runtime.spawn do
        runner.shutdown.wait
        woken = true
      end
      sleep(0.01)

      simulate_sigterm(runner)
      sleep(0.05)

      expect(woken).to be(true)
      runner.send(:close_signal_pipe)
    end
  end

  it 'returns from #run promptly when the next scheduled entry is far away' do
    with_scheduler do
      runner = build_runner

      Async::Background::Runtime.spawn do
        sleep(0.05)
        simulate_sigterm(runner)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Async::Background::Runtime.with_timeout(5) { runner.run }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 3
    end
  end

  it 'leaves no service task behind once #run returns' do
    with_scheduler do
      runner = build_runner

      Async::Background::Runtime.spawn do
        sleep(0.05)
        simulate_sigterm(runner)
      end

      Async::Background::Runtime.with_timeout(5) { runner.run }

      expect(runner.services).to be_empty
      expect(runner.jobs).to be_empty
    end
  end
end
