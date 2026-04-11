# frozen_string_literal: true

require 'async/background/job'
require 'json'
require 'fileutils'

module CIJobs
  LEDGER_PATH = ENV.fetch('LEDGER_PATH', 'tmp/ci_ledger.log')

  class << self
    def setup_ledger!
      FileUtils.mkdir_p(File.dirname(LEDGER_PATH))
      File.write(LEDGER_PATH, '')
    end

    def record_execution!(job_class, job_arg)
      line = JSON.generate(
        job_class:   job_class,
        job_arg:     job_arg.to_s,
        worker_pid:  Process.pid,
        executed_at: Process.clock_gettime(Process::CLOCK_REALTIME)
      ) + "\n"

      File.open(LEDGER_PATH, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        f.write(line)
        f.flush
      end
    end

    def read_ledger
      return { entries: [], skipped: 0 } unless File.exist?(LEDGER_PATH)

      entries = []
      skipped = 0

      File.foreach(LEDGER_PATH) do |line|
        next if line.strip.empty?

        begin
          entries << JSON.parse(line)
        rescue JSON::ParserError
          skipped += 1
        end
      end

      { entries: entries, skipped: skipped }
    end
  end

  class FastJob
    include Async::Background::Job
    def perform(n)
      sleep(0.005)
      CIJobs.record_execution!(self.class.name, n)
    end
  end

  class SlowJob
    include Async::Background::Job
    def perform(n)
      sleep(0.5 + rand * 0.5)
      CIJobs.record_execution!(self.class.name, n)
    end
  end

  class FailingJob
    include Async::Background::Job
    def perform(n)
      CIJobs.record_execution!(self.class.name, n)
      raise "CIJobs::FailingJob intentional error for job #{n}"
    end
  end

  class RecoveryTestJob
    include Async::Background::Job
    def perform(n)
      sleep(ENV.fetch('RECOVERY_SLEEP', '2').to_f)
      CIJobs.record_execution!(self.class.name, n)
    end
  end

  class HeartbeatJob
    include Async::Background::Job
    def perform
      CIJobs.record_execution!(self.class.name, 'heartbeat')
    end
  end

  class OverlapJob
    include Async::Background::Job
    def perform
      CIJobs.record_execution!(self.class.name, 'start')
      sleep(ENV.fetch('OVERLAP_JOB_DURATION', '3').to_f)
      CIJobs.record_execution!(self.class.name, 'finish')
    end
  end
end
