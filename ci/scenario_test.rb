#!/usr/bin/env ruby

require 'async/background'
require 'async/background/job'
require 'fileutils'
require 'json'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require_relative 'fixtures/jobs'

TOTAL_WORKERS    = ENV.fetch('SCENARIO_WORKERS', '3').to_i
TOTAL_JOBS       = ENV.fetch('SCENARIO_JOBS', '200').to_i
SCENARIO_TIMEOUT = ENV.fetch('SCENARIO_TIMEOUT', '60').to_i

QUEUE_DB_PATH    = File.expand_path('../tmp/ci_queue.db', __dir__)
LEDGER_PATH      = File.expand_path('../tmp/ci_ledger.log', __dir__)
SCHEDULE_PATH    = File.expand_path('fixtures/schedule.yml', __dir__)

FAST_COUNT    = (TOTAL_JOBS * 0.7).to_i
SLOW_COUNT    = (TOTAL_JOBS * 0.2).to_i
FAILING_COUNT = TOTAL_JOBS - FAST_COUNT - SLOW_COUNT

module ScenarioTest
  class << self
    def run!
      header("ASYNC-BACKGROUND CI SCENARIO TEST")
      info("Workers: #{TOTAL_WORKERS}, Jobs: #{TOTAL_JOBS} (fast=#{FAST_COUNT} slow=#{SLOW_COUNT} fail=#{FAILING_COUNT}), Timeout: #{SCENARIO_TIMEOUT}s")

      setup!
      pids = start_workers!
      enqueue_jobs!
      wait_for_completion!
      stop_workers!(pids)
      validate!
    rescue => e
      error("Scenario failed: #{e.class}: #{e.message}")
      e.backtrace.first(10).each { |line| error("  #{line}") }
      exit(1)
    end

    private

    def setup!
      header("SETUP")

      FileUtils.mkdir_p(File.dirname(QUEUE_DB_PATH))
      FileUtils.mkdir_p(File.dirname(LEDGER_PATH))
      FileUtils.rm_f(Dir.glob("#{QUEUE_DB_PATH}*"))
      FileUtils.rm_f(LEDGER_PATH)

      require 'async/background/queue/store'
      store = Async::Background::Queue::Store.new(path: QUEUE_DB_PATH)
      store.ensure_database!
      store.close

      ENV['LEDGER_PATH'] = LEDGER_PATH
      CIJobs.setup_ledger!

      require 'async/background/queue/notifier'
      @notifier = Async::Background::Queue::Notifier.new

      info("Queue DB: #{QUEUE_DB_PATH}")
      info("Ledger:   #{LEDGER_PATH}")
      info("Schedule: #{SCHEDULE_PATH}")
      ok("Setup complete")
    end

    def start_workers!
      header("STARTING #{TOTAL_WORKERS} WORKERS (fork)")

      pids = []

      TOTAL_WORKERS.times do |i|
        worker_index = i + 1

        pid = fork do
          @notifier.for_consumer!

          runner = Async::Background::Runner.new(
            config_path:    SCHEDULE_PATH,
            job_count:      5,
            worker_index:   worker_index,
            total_workers:  TOTAL_WORKERS,
            queue_notifier: @notifier,
            queue_db_path:  QUEUE_DB_PATH,
            queue_mmap:     true
          )

          Signal.trap('TERM') { runner.stop }
          Signal.trap('INT')  { runner.stop }

          runner.run
        end

        pids << pid
        info("Worker #{worker_index} started: pid=#{pid}")
      end

      @notifier.for_producer!

      sleep(1)
      ok("All #{TOTAL_WORKERS} workers running")

      pids
    end

    def enqueue_jobs!
      header("ENQUEUING #{TOTAL_JOBS} JOBS")

      require 'async/background/queue/store'
      require 'async/background/queue/client'

      store  = Async::Background::Queue::Store.new(path: QUEUE_DB_PATH)
      client = Async::Background::Queue::Client.new(store: store, notifier: @notifier)
      Async::Background::Queue.default_client = client

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      job_id = 0

      FAST_COUNT.times do
        job_id += 1
        CIJobs::FastJob.perform_async(job_id)
      end
      info("Enqueued #{FAST_COUNT} fast jobs")

      SLOW_COUNT.times do
        job_id += 1
        CIJobs::SlowJob.perform_async(job_id)
      end
      info("Enqueued #{SLOW_COUNT} slow jobs")

      FAILING_COUNT.times do
        job_id += 1
        CIJobs::FailingJob.perform_async(job_id)
      end
      info("Enqueued #{FAILING_COUNT} failing jobs")

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      ok("All #{TOTAL_JOBS} jobs enqueued in #{duration.round(2)}s")

      store.close
    end

    def wait_for_completion!
      header("WAITING FOR COMPLETION (timeout: #{SCENARIO_TIMEOUT}s)")

      require 'sqlite3'
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SCENARIO_TIMEOUT

      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now >= deadline
          counts = job_counts
          error("TIMEOUT! Jobs remaining: #{counts}")
          exit(1)
        end

        counts = job_counts
        pending = counts['pending'].to_i
        running = counts['running'].to_i
        done    = counts['done'].to_i
        failed  = counts['failed'].to_i

        remaining = pending + running
        info("pending=#{pending} running=#{running} done=#{done} failed=#{failed} | remaining=#{remaining}")

        if remaining == 0
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - (deadline - SCENARIO_TIMEOUT)
          ok("All jobs processed in #{elapsed.round(2)}s")
          return
        end

        sleep(1)
      end
    end

    def stop_workers!(pids)
      header("STOPPING WORKERS")

      pids.each do |pid|
        Process.kill('TERM', pid)
        info("Sent SIGTERM to pid=#{pid}")
      rescue Errno::ESRCH
        info("pid=#{pid} already exited")
      end

      pids.each do |pid|
        Timeout.timeout(10) { Process.waitpid(pid) }
        info("Worker pid=#{pid} exited cleanly")
      rescue Timeout::Error
        Process.kill('KILL', pid) rescue nil
        Process.waitpid(pid) rescue nil
        warn("Worker pid=#{pid} killed (didn't exit in 10s)")
      rescue Errno::ECHILD
      end

      ok("All workers stopped")
    end

    def validate!
      header("VALIDATION")

      errors  = []
      counts  = job_counts
      pending = counts['pending'].to_i
      running = counts['running'].to_i
      done    = counts['done'].to_i
      failed  = counts['failed'].to_i

      info("Final queue state: done=#{done} failed=#{failed} pending=#{pending} running=#{running}")

      errors << "#{pending} jobs still pending" if pending > 0
      errors << "#{running} jobs still running (not recovered)" if running > 0

      expected_successful = FAST_COUNT + SLOW_COUNT
      expected_failed     = FAILING_COUNT

      errors << "Expected #{expected_successful} done, got #{done}" if done != expected_successful
      errors << "Expected #{expected_failed} failed, got #{failed}" if failed != expected_failed

      rows = CIJobs.read_ledger

      groups     = rows.group_by { |r| [r['job_class'], r['job_arg']] }
      duplicates = groups.select { |_, v| v.size > 1 }

      if duplicates.any?
        errors << "#{duplicates.size} duplicate executions detected:"
        duplicates.first(5).each do |(klass, arg), v|
          errors << "  #{klass} arg=#{arg} count=#{v.size}"
        end
      else
        info("0 duplicate executions ✓")
      end

      total_executions = rows.size
      info("Total executions in ledger: #{total_executions}")

      if total_executions != TOTAL_JOBS
        errors << "Expected #{TOTAL_JOBS} executions in ledger, got #{total_executions}"
      end

      worker_dist = rows.group_by { |r| r['worker_pid'] }
                        .map { |pid, v| [pid, v.size] }
                        .sort_by(&:first)

      info("Worker distribution:")
      worker_dist.each do |pid, count|
        info("  pid=#{pid}: #{count} jobs")
      end

      if worker_dist.size < [TOTAL_WORKERS, 2].min && TOTAL_JOBS >= 10
        errors << "Jobs only executed on #{worker_dist.size} workers (expected at least 2)"
      end

      if errors.empty?
        header("✅ ALL CHECKS PASSED")
        exit(0)
      else
        header("❌ CHECKS FAILED")
        errors.each { |e| error(e) }
        exit(1)
      end
    end

    def job_counts
      require 'sqlite3'
      db = SQLite3::Database.new(QUEUE_DB_PATH)
      db.execute("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")
      rows = db.execute("SELECT status, COUNT(*) FROM jobs GROUP BY status")
      db.close
      rows.to_h
    end

    def header(msg)
      puts "\n#{'=' * 60}"
      puts "  #{msg}"
      puts '=' * 60
    end

    def info(msg)
      puts "  [INFO]  #{msg}"
    end

    def ok(msg)
      puts "  [  OK]  #{msg}"
    end

    def error(msg)
      $stderr.puts "  [FAIL]  #{msg}"
    end

    def warn(msg)
      $stderr.puts "  [WARN]  #{msg}"
    end
  end
end

require 'timeout'
ScenarioTest.run!
