#!/usr/bin/env ruby
# frozen_string_literal: true

# CI scenario test for async-background.
#
# Unlike the RSpec suite, this is a whole-gem integration test: it forks
# real workers, runs the real queue, and verifies end-to-end properties
# that unit tests can't cover (exit codes, multi-worker distribution,
# crash recovery, no-duplicate-execution guarantees).
#
# Four scenarios run in sequence:
#   1. `normal`        — enqueue fast/slow/failing jobs, verify everything
#                        completed exactly once, each worker did work, and
#                        all workers exited cleanly.
#   2. `recovery`      — enqueue long-running jobs, SIGKILL one worker
#                        mid-execution, verify the remaining workers picked
#                        up and completed the killed worker's jobs.
#   3. `enqueue_perf`  — high-rate enqueue stress test. Regression guard
#                        for the SocketNotifier hot-path fix in 0.6.1:
#                        ensures bulk enqueue does not block the caller
#                        AND that workers actually wake up promptly
#                        (drain time should be << total_jobs / poll).
#   4. `overlap`       — scheduler regression guard for the skip-branch
#                        reschedule fix in 0.6.1: a job with `every: 1`
#                        that sleeps 3s must run roughly every 3s, NOT
#                        busy-loop every 100ms with skipped warnings.
#
# Exit code is 0 iff all scenarios pass.

require 'async/background'
require 'async/background/job'
require 'async/background/queue/store'
require 'async/background/queue/client'
require 'console'
require 'fileutils'
require 'json'
require 'sqlite3'
require 'timeout'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require_relative 'fixtures/jobs'

module ScenarioTest
  module Config
    TOTAL_WORKERS    = ENV.fetch('SCENARIO_WORKERS', '3').to_i
    TOTAL_JOBS       = ENV.fetch('SCENARIO_JOBS', '200').to_i
    SCENARIO_TIMEOUT = ENV.fetch('SCENARIO_TIMEOUT', '60').to_i

    RECOVERY_JOBS     = ENV.fetch('RECOVERY_JOBS', '6').to_i
    RECOVERY_TIMEOUT  = ENV.fetch('RECOVERY_TIMEOUT', '30').to_i
    RECOVERY_SLEEP    = ENV.fetch('RECOVERY_SLEEP', '2').to_f

    PERF_JOBS                  = ENV.fetch('PERF_JOBS', '1000').to_i
    PERF_ENQUEUE_BUDGET        = ENV.fetch('PERF_ENQUEUE_BUDGET', '2.0').to_f
    PERF_DRAIN_TIMEOUT         = ENV.fetch('PERF_DRAIN_TIMEOUT', '60').to_i
    OVERLAP_OBSERVE_SECONDS    = ENV.fetch('OVERLAP_OBSERVE_SECONDS', '10').to_f
    OVERLAP_JOB_DURATION       = ENV.fetch('OVERLAP_JOB_DURATION', '3').to_f
    OVERLAP_INTERVAL           = ENV.fetch('OVERLAP_INTERVAL', '1').to_i
    OVERLAP_MAX_STARTS         = ENV.fetch('OVERLAP_MAX_STARTS', '8').to_i

    WORKER_STARTUP_TIMEOUT = 10
    POLL_INTERVAL          = 0.5

    QUEUE_DB_PATH        = File.expand_path('../tmp/ci_queue.db', __dir__)
    SOCKET_DIR           = File.expand_path('../tmp/ci_sockets', __dir__)
    LEDGER_PATH          = File.expand_path('../tmp/ci_ledger.log', __dir__)
    SCHEDULE_PATH        = File.expand_path('fixtures/schedule.yml', __dir__)
    OVERLAP_SCHEDULE_PATH = File.expand_path('../tmp/ci_overlap_schedule.yml', __dir__)

    FAST_COUNT    = (TOTAL_JOBS * 0.7).to_i
    SLOW_COUNT    = (TOTAL_JOBS * 0.2).to_i
    FAILING_COUNT = TOTAL_JOBS - FAST_COUNT - SLOW_COUNT
  end

  module Log
    module_function

    def header(msg)
      puts
      puts '=' * 70
      puts "  #{msg}"
      puts '=' * 70
    end

    def info(msg)
      ::Console.logger.info('scenario') { msg }
    end

    def ok(msg)
      ::Console.logger.info('scenario') { "✓ #{msg}" }
    end

    def warn(msg)
      ::Console.logger.warn('scenario') { msg }
    end

    def error(msg)
      ::Console.logger.error('scenario') { msg }
    end
  end

  class QueueInspector
    def initialize(path)
      @db = SQLite3::Database.new(path)
      @db.execute('PRAGMA journal_mode = WAL')
      @db.execute('PRAGMA busy_timeout = 5000')
    end

    # => { 'pending' => Int, 'running' => Int, 'done' => Int, 'failed' => Int }
    def counts_by_status
      rows = @db.execute("SELECT status, COUNT(*) FROM jobs GROUP BY status")
      Hash.new(0).merge(rows.to_h)
    end

    def ids_by_status
      rows = @db.execute("SELECT id, status FROM jobs")
      rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(id, status), acc|
        acc[status] << id
      end
    end

    def close
      @db&.close
      @db = nil
    end
  end

  class WorkerPool
    Worker = Struct.new(:pid, :index, :exit_status, :killed)

    attr_reader :total_workers

    def initialize(socket_dir:, total_workers:, schedule_path: Config::SCHEDULE_PATH)
      @socket_dir    = socket_dir
      @schedule_path = schedule_path
      @workers       = []
      @total_workers = total_workers
    end

    def start_initial_cohort!
      (1..@total_workers).each do |index|
        spawn_worker(index)
        sleep(0.05) if index < @total_workers
      end
      wait_until_all_alive!
    end

    def spawn_replacement!(index)
      spawn_worker(index)
      wait_until_all_alive!
    end

    def pids
      @workers.map(&:pid)
    end

    def alive_workers
      @workers.reject { |w| w.exit_status }
    end

    def kill!(worker_index)
      worker = @workers.find { |w| w.index == worker_index }
      raise "no such worker: #{worker_index}" unless worker

      Process.kill('KILL', worker.pid)
      worker.killed = true
      Log.info("worker #{worker_index} (pid=#{worker.pid}) SIGKILLed")

      begin
        Process.waitpid(worker.pid)
        worker.exit_status = $?.exitstatus || (128 + ($?.termsig || 0))
      rescue Errno::ECHILD
        worker.exit_status = -1
      end
    end

    def stop_gracefully!
      alive_workers.each do |worker|
        Process.kill('TERM', worker.pid)
        Log.info("SIGTERM → pid=#{worker.pid}")
      rescue Errno::ESRCH
        worker.exit_status ||= -1
      end

      alive_workers.each do |worker|
        begin
          Timeout.timeout(10) { Process.waitpid(worker.pid) }
          worker.exit_status = $?.exitstatus
          Log.info("worker #{worker.index} (pid=#{worker.pid}) exited status=#{worker.exit_status}")
        rescue Timeout::Error
          Log.warn("worker #{worker.index} (pid=#{worker.pid}) didn't exit in 10s, SIGKILL")
          Process.kill('KILL', worker.pid) rescue nil
          Process.waitpid(worker.pid) rescue nil
          worker.exit_status = -1
        rescue Errno::ECHILD
          worker.exit_status ||= -1
        end
      end
    end

    def unexpected_failures
      @workers.reject(&:killed).select { |w| w.exit_status && w.exit_status != 0 }
    end

    private

    def spawn_worker(index)
      pid = fork do
        runner = Async::Background::Runner.new(
          config_path:      @schedule_path,
          job_count:        5,
          worker_index:     index,
          total_workers:    @total_workers,
          queue_socket_dir: @socket_dir,
          queue_db_path:    Config::QUEUE_DB_PATH,
          queue_mmap:       true
        )

        Signal.trap('TERM') { runner.stop }
        Signal.trap('INT')  { runner.stop }

        runner.run
      end

      @workers << Worker.new(pid, index, nil, false)
      Log.info("worker #{index} spawned pid=#{pid}")
    end

    def wait_until_all_alive!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Config::WORKER_STARTUP_TIMEOUT

      loop do
        all_alive = alive_workers.all? do |w|
          begin
            Process.kill(0, w.pid)
            true
          rescue Errno::ESRCH
            false
          end
        end

        if all_alive
          Log.ok("#{alive_workers.size} worker(s) alive")
          return
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "workers didn't all come up in #{Config::WORKER_STARTUP_TIMEOUT}s"
        end

        sleep(0.05)
      end
    end
  end

  class Validator
    def initialize(inspector:, pool:, expected_done:, expected_failed:, expected_total:)
      @inspector       = inspector
      @pool            = pool
      @expected_done   = expected_done
      @expected_failed = expected_failed
      @expected_total  = expected_total
    end

    def validate_normal_scenario
      errors = []
      errors.concat(check_queue_state)
      errors.concat(check_no_duplicate_executions)
      errors.concat(check_ledger_matches_queue)
      errors.concat(check_ledger_not_corrupted)
      errors.concat(check_worker_distribution)
      errors.concat(check_worker_exit_codes)
      errors
    end

    def validate_recovery_scenario(killed_worker_index:)
      errors = []
      errors.concat(check_queue_state)
      errors.concat(check_no_duplicate_executions)
      errors.concat(check_ledger_matches_queue)
      errors.concat(check_ledger_not_corrupted)
      errors.concat(check_recovery_worker_exit(killed_worker_index))
      errors
    end

    def validate_perf_scenario
      errors = []
      errors.concat(check_queue_state)
      errors.concat(check_no_duplicate_executions)
      errors.concat(check_ledger_not_corrupted)
      errors.concat(check_worker_exit_codes)
      errors
    end

    private

    def check_queue_state
      errors = []
      counts = @inspector.counts_by_status

      pending = counts['pending']
      running = counts['running']
      done    = counts['done']
      failed  = counts['failed']

      Log.info("final queue: done=#{done} failed=#{failed} pending=#{pending} running=#{running}")

      errors << "#{pending} jobs still pending" if pending > 0
      errors << "#{running} jobs still running (not recovered)" if running > 0

      if done != @expected_done
        errors << "expected done=#{@expected_done}, got #{done}"
      end
      if failed != @expected_failed
        errors << "expected failed=#{@expected_failed}, got #{failed}"
      end

      errors
    end

    def check_no_duplicate_executions
      ledger = CIJobs.read_ledger
      relevant = ledger[:entries].reject { |e| e['job_class'] == 'CIJobs::HeartbeatJob' }

      groups = relevant.group_by { |e| [e['job_class'], e['job_arg']] }
      duplicates = groups.select { |_, es| es.size > 1 }

      if duplicates.empty?
        Log.ok("no duplicate executions")
        return []
      end

      errors = ["#{duplicates.size} duplicate executions detected:"]
      duplicates.first(5).each do |(klass, arg), es|
        pids = es.map { |e| e['worker_pid'] }.uniq.join(',')
        errors << "  #{klass}##{arg} ran #{es.size}x across pids=[#{pids}]"
      end
      errors
    end

    def check_ledger_matches_queue
      errors = []
      ledger = CIJobs.read_ledger
      relevant = ledger[:entries].reject { |e| e['job_class'] == 'CIJobs::HeartbeatJob' }

      ledger_args = relevant.map { |e| e['job_arg'].to_i }.sort
      expected_args = (1..@expected_total).to_a

      missing = expected_args - ledger_args
      extra   = ledger_args - expected_args

      errors << "#{missing.size} job args missing from ledger: #{missing.first(10).inspect}" unless missing.empty?
      errors << "#{extra.size} unexpected job args in ledger: #{extra.first(10).inspect}" unless extra.empty?

      if missing.empty? && extra.empty? && ledger_args.size == @expected_total
        Log.ok("ledger matches expected job set (#{@expected_total} entries)")
      end

      errors
    end

    def check_ledger_not_corrupted
      ledger = CIJobs.read_ledger
      if ledger[:skipped] > 0
        Log.warn("#{ledger[:skipped]} malformed ledger lines were skipped")
      end
      []
    end

    def check_worker_distribution
      ledger = CIJobs.read_ledger
      relevant = ledger[:entries].reject { |e| e['job_class'] == 'CIJobs::HeartbeatJob' }

      by_pid = relevant.group_by { |e| e['worker_pid'] }
      dist   = by_pid.transform_values(&:size).sort.to_h

      Log.info('worker distribution:')
      dist.each { |pid, count| Log.info("  pid=#{pid}: #{count} jobs") }

      active_pids = dist.keys.size
      expected_pids = @pool.pids.size

      if active_pids < expected_pids
        idle_count = expected_pids - active_pids
        ["#{idle_count} worker(s) did not execute any jobs (only #{active_pids}/#{expected_pids} active)"]
      else
        Log.ok("all #{expected_pids} workers did work")
        []
      end
    end

    def check_worker_exit_codes
      failures = @pool.unexpected_failures
      return [] if failures.empty?

      failures.map do |w|
        "worker #{w.index} (pid=#{w.pid}) exited with status=#{w.exit_status}"
      end
    end

    def check_recovery_worker_exit(killed_index)
      errors = []
      @pool.instance_variable_get(:@workers).each do |w|
        next if w.index == killed_index
        next if w.exit_status.nil? || w.exit_status.zero?

        errors << "non-killed worker #{w.index} exited with status=#{w.exit_status}"
      end
      errors
    end
  end

  class Runner
    def self.run_all!
      new.run_all!
    end

    def run_all!
      results = {}
      results[:normal]       = run_normal_scenario
      results[:recovery]     = run_recovery_scenario
      results[:enqueue_perf] = run_enqueue_perf_scenario
      results[:overlap]      = run_overlap_scenario

      if results.values.all?
        Log.header('✅ ALL SCENARIOS PASSED')
        exit(0)
      else
        failed = results.select { |_, v| !v }.keys
        Log.header("❌ SCENARIOS FAILED: #{failed.join(', ')}")
        exit(1)
      end
    end

    private

    def run_normal_scenario
      Log.header('SCENARIO 1: NORMAL (fast + slow + failing)')

      setup_clean_state!

      pool = WorkerPool.new(socket_dir: Config::SOCKET_DIR, total_workers: Config::TOTAL_WORKERS)
      pool.start_initial_cohort!

      enqueue_normal_jobs
      wait_for_completion(Config::TOTAL_JOBS, Config::SCENARIO_TIMEOUT)

      pool.stop_gracefully!

      inspector = QueueInspector.new(Config::QUEUE_DB_PATH)
      validator = Validator.new(
        inspector:       inspector,
        pool:            pool,
        expected_done:   Config::FAST_COUNT + Config::SLOW_COUNT,
        expected_failed: Config::FAILING_COUNT,
        expected_total:  Config::TOTAL_JOBS
      )

      errors = validator.validate_normal_scenario
      inspector.close

      report_scenario_result('normal', errors)
    rescue => e
      Log.error("normal scenario crashed: #{e.class}: #{e.message}")
      e.backtrace.first(10).each { |line| Log.error("  #{line}") }
      false
    end

    def run_recovery_scenario
      Log.header('SCENARIO 2: RECOVERY (SIGKILL mid-flight)')

      setup_clean_state!

      pool = WorkerPool.new(socket_dir: Config::SOCKET_DIR, total_workers: Config::TOTAL_WORKERS)
      pool.start_initial_cohort!

      enqueue_recovery_jobs

      sleep(Config::RECOVERY_SLEEP / 2.0)

      killed_index = 1
      pool.kill!(killed_index)

      Log.info("spawning replacement worker ##{killed_index} to trigger recovery path")
      pool.spawn_replacement!(killed_index)

      wait_for_completion(Config::RECOVERY_JOBS, Config::RECOVERY_TIMEOUT)

      pool.stop_gracefully!

      inspector = QueueInspector.new(Config::QUEUE_DB_PATH)
      validator = Validator.new(
        inspector:       inspector,
        pool:            pool,
        expected_done:   Config::RECOVERY_JOBS,
        expected_failed: 0,
        expected_total:  Config::RECOVERY_JOBS
      )

      errors = validator.validate_recovery_scenario(killed_worker_index: killed_index)
      inspector.close

      report_scenario_result('recovery', errors)
    rescue => e
      Log.error("recovery scenario crashed: #{e.class}: #{e.message}")
      e.backtrace.first(10).each { |line| Log.error("  #{line}") }
      false
    end

    def run_enqueue_perf_scenario
      Log.header("SCENARIO 3: ENQUEUE PERF (#{Config::PERF_JOBS} jobs, budget #{Config::PERF_ENQUEUE_BUDGET}s)")

      setup_clean_state!

      pool = WorkerPool.new(socket_dir: Config::SOCKET_DIR, total_workers: Config::TOTAL_WORKERS)
      pool.start_initial_cohort!

      sleep(0.5)

      enqueue_duration = enqueue_perf_jobs

      perf_errors = []
      if enqueue_duration > Config::PERF_ENQUEUE_BUDGET
        perf_errors << "enqueue took #{enqueue_duration.round(3)}s, budget #{Config::PERF_ENQUEUE_BUDGET}s " \
                       "(possible SocketNotifier regression — broadcast on hot path?)"
      else
        Log.ok("enqueue stayed within budget: #{enqueue_duration.round(3)}s ≤ #{Config::PERF_ENQUEUE_BUDGET}s")
      end

      drain_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wait_for_completion(Config::PERF_JOBS, Config::PERF_DRAIN_TIMEOUT)
      drain_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - drain_start

      drain_ceiling = [Config::PERF_JOBS / 50.0, 5.0].max
      if drain_duration > drain_ceiling
        perf_errors << "drain took #{drain_duration.round(2)}s, expected ≤ #{drain_ceiling.round(2)}s " \
                       "(possible wake-up delivery regression — workers polling instead?)"
      else
        Log.ok("drain completed in #{drain_duration.round(2)}s (ceiling #{drain_ceiling.round(2)}s)")
      end

      pool.stop_gracefully!

      inspector = QueueInspector.new(Config::QUEUE_DB_PATH)
      validator = Validator.new(
        inspector:       inspector,
        pool:            pool,
        expected_done:   Config::PERF_JOBS,
        expected_failed: 0,
        expected_total:  Config::PERF_JOBS
      )

      errors = perf_errors + validator.validate_perf_scenario
      inspector.close

      report_scenario_result('enqueue_perf', errors)
    rescue => e
      Log.error("enqueue_perf scenario crashed: #{e.class}: #{e.message}")
      e.backtrace.first(10).each { |line| Log.error("  #{line}") }
      false
    end

    def run_overlap_scenario
      Log.header("SCENARIO 4: OVERLAP (every: #{Config::OVERLAP_INTERVAL}s, sleeps #{Config::OVERLAP_JOB_DURATION}s)")

      setup_clean_state!
      write_overlap_schedule!

      ENV['OVERLAP_JOB_DURATION'] = Config::OVERLAP_JOB_DURATION.to_s

      pool = WorkerPool.new(
        socket_dir:    Config::SOCKET_DIR,
        total_workers: 1,
        schedule_path: Config::OVERLAP_SCHEDULE_PATH
      )
      pool.start_initial_cohort!

      Log.info("observing for #{Config::OVERLAP_OBSERVE_SECONDS}s …")
      sleep(Config::OVERLAP_OBSERVE_SECONDS)

      pool.stop_gracefully!

      errors = validate_overlap_ledger(pool)

      report_scenario_result('overlap', errors)
    rescue => e
      Log.error("overlap scenario crashed: #{e.class}: #{e.message}")
      e.backtrace.first(10).each { |line| Log.error("  #{line}") }
      false
    end

    def setup_clean_state!
      FileUtils.mkdir_p(File.dirname(Config::QUEUE_DB_PATH))
      FileUtils.mkdir_p(Config::SOCKET_DIR)
      FileUtils.mkdir_p(File.dirname(Config::LEDGER_PATH))
      FileUtils.rm_f(Dir.glob("#{Config::QUEUE_DB_PATH}*"))
      FileUtils.rm_f(Dir.glob("#{Config::SOCKET_DIR}/*.sock"))
      FileUtils.rm_f(Config::LEDGER_PATH)

      store = Async::Background::Queue::Store.new(path: Config::QUEUE_DB_PATH)
      store.ensure_database!
      store.close

      ENV['LEDGER_PATH'] = Config::LEDGER_PATH
      CIJobs.setup_ledger!

      Log.info("queue db: #{Config::QUEUE_DB_PATH}")
      Log.info("ledger:   #{Config::LEDGER_PATH}")
    end

    def write_overlap_schedule!
      yaml = <<~YAML
        overlap_test:
          class: CIJobs::OverlapJob
          every: #{Config::OVERLAP_INTERVAL}
          timeout: #{(Config::OVERLAP_JOB_DURATION * 3).to_i}
          worker: 1
      YAML
      FileUtils.mkdir_p(File.dirname(Config::OVERLAP_SCHEDULE_PATH))
      File.write(Config::OVERLAP_SCHEDULE_PATH, yaml)
      Log.info("overlap schedule: #{Config::OVERLAP_SCHEDULE_PATH}")
    end

    def build_client
      require_relative '../lib/async/background/queue/socket_notifier'

      store    = Async::Background::Queue::Store.new(path: Config::QUEUE_DB_PATH)
      notifier = Async::Background::Queue::SocketNotifier.new(
        socket_dir:    Config::SOCKET_DIR,
        total_workers: Config::TOTAL_WORKERS
      )
      client = Async::Background::Queue::Client.new(store: store, notifier: notifier)
      Async::Background::Queue.default_client = client
      store
    end

    def enqueue_normal_jobs
      store = build_client
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      job_plan = [
        [Config::FAST_COUNT,    CIJobs::FastJob,    'fast'],
        [Config::SLOW_COUNT,    CIJobs::SlowJob,    'slow'],
        [Config::FAILING_COUNT, CIJobs::FailingJob, 'failing']
      ]

      job_id = 0
      job_plan.each do |count, klass, label|
        count.times { klass.perform_async(job_id += 1) }
        Log.info("enqueued #{count} #{label} jobs")
      end

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      Log.ok("all #{Config::TOTAL_JOBS} jobs enqueued in #{duration.round(2)}s")

      store.close
    end

    def enqueue_recovery_jobs
      store = build_client

      (1..Config::RECOVERY_JOBS).each do |i|
        CIJobs::RecoveryTestJob.perform_async(i)
      end
      Log.ok("enqueued #{Config::RECOVERY_JOBS} recovery jobs (each sleeps #{Config::RECOVERY_SLEEP}s)")

      store.close
    end

    def enqueue_perf_jobs
      store = build_client

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      (1..Config::PERF_JOBS).each do |i|
        CIJobs::FastJob.perform_async(i)
      end
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      Log.ok("enqueued #{Config::PERF_JOBS} jobs in #{duration.round(3)}s " \
             "(#{(Config::PERF_JOBS / duration).round(0)}/s)")

      store.close
      duration
    end

    def validate_overlap_ledger(pool)
      errors = []
      ledger = CIJobs.read_ledger
      starts = ledger[:entries].count { |e| e['job_class'] == 'CIJobs::OverlapJob' && e['job_arg'] == 'start' }
      finishes = ledger[:entries].count { |e| e['job_class'] == 'CIJobs::OverlapJob' && e['job_arg'] == 'finish' }

      Log.info("overlap ledger: starts=#{starts} finishes=#{finishes}")

      if starts < 2
        errors << "expected ≥2 OverlapJob starts in #{Config::OVERLAP_OBSERVE_SECONDS}s, got #{starts} " \
                  "(scheduler may be stuck)"
      end

      if starts > Config::OVERLAP_MAX_STARTS
        errors << "got #{starts} OverlapJob starts in #{Config::OVERLAP_OBSERVE_SECONDS}s, " \
                  "expected ≤ #{Config::OVERLAP_MAX_STARTS} " \
                  "(possible skip-branch reschedule regression — busy-loop?)"
      end

      if errors.empty?
        Log.ok("overlap behaved correctly: #{starts} start(s), #{finishes} finish(es)")
      end

      errors.concat(check_overlap_worker_exit(pool))
      errors
    end

    def check_overlap_worker_exit(pool)
      pool.unexpected_failures.map do |w|
        "overlap worker #{w.index} (pid=#{w.pid}) exited with status=#{w.exit_status}"
      end
    end

    def wait_for_completion(expected_total, timeout_seconds)
      inspector = QueueInspector.new(Config::QUEUE_DB_PATH)
      start     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline  = start + timeout_seconds
      last_log  = start

      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        if now >= deadline
          counts = inspector.counts_by_status
          Log.error("TIMEOUT after #{timeout_seconds}s! counts=#{counts.inspect}")
          inspector.close
          raise "scenario timed out waiting for #{expected_total} jobs"
        end

        counts = inspector.counts_by_status
        pending = counts['pending']
        running = counts['running']
        done    = counts['done']
        failed  = counts['failed']
        remaining = pending + running

        if now - last_log >= 1.0
          Log.info("pending=#{pending} running=#{running} done=#{done} failed=#{failed}")
          last_log = now
        end

        if remaining == 0 && (done + failed) >= expected_total
          elapsed = now - start
          Log.ok("all #{expected_total} jobs processed in #{elapsed.round(2)}s")
          inspector.close
          return
        end

        sleep(Config::POLL_INTERVAL)
      end
    end

    def report_scenario_result(name, errors)
      if errors.empty?
        Log.ok("scenario '#{name}' passed")
        true
      else
        Log.error("scenario '#{name}' failed with #{errors.size} error(s):")
        errors.each { |e| Log.error("  #{e}") }
        false
      end
    end
  end
end

ScenarioTest::Runner.run_all!
