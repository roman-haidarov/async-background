#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'async/background/runtime'

Runtime = Async::Background::Runtime

class StubScheduler
  attr_reader :hook_calls

  def initialize
    @ready = []
    @hook_calls = []
    @timeouts = []
    @blocked = []
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def fiber(&block)
    fiber = Fiber.new(blocking: false, &block)
    fiber.resume
    fiber
  end

  def block(_blocker, timeout = nil)
    @blocked << [monotonic + timeout, Fiber.current] if timeout
    Fiber.yield
  end
  def unblock(_blocker, fiber)
    @blocked.reject! { |(_, blocked)| blocked == fiber }
    @ready << fiber
  end
  def kernel_sleep(_duration = nil) = nil
  def io_wait(_io, _events, _timeout) = nil
  def close = drain

  def drain
    while true
      until @ready.empty?
        fiber = @ready.shift
        next if fiber.nil? || fiber.equal?(Fiber.current)

        fiber.resume if fiber.alive?
      end

      next_block = @blocked.min_by(&:first)
      next_timeout = @timeouts.min_by(&:first)
      break if next_block.nil? && next_timeout.nil?

      if next_timeout && (next_block.nil? || next_timeout.first <= next_block.first)
        expire_timeout(next_timeout)
      else
        resume_blocked(next_block)
      end
    end
  end

  def resume_blocked(entry)
    @blocked.delete(entry)
    fiber = entry[1]
    @ready << fiber if fiber.alive?
  end

  def expire_timeout(entry)
    @timeouts.delete(entry)
    _, fiber, klass, message = entry
    return unless fiber.alive?

    @ready.delete(fiber)
    fiber.raise(klass, message)
  end

  def timeout_after(duration, exception, message, &block)
    @hook_calls << [duration, exception, message]
    entry = [monotonic + duration, Fiber.current, exception, message]
    @timeouts << entry
    begin
      yield(duration)
    ensure
      @timeouts.delete(entry)
    end
  end
end

class BareScheduler < StubScheduler
  undef_method :timeout_after
end

$failures = 0

def check(description)
  ok = yield
  puts(ok ? "  ok   #{description}" : "  FAIL #{description}")
  $failures += 1 unless ok
rescue StandardError, Async::Background::Runtime::Error => e
  puts "  FAIL #{description} (#{e.class}: #{e.message})"
  puts e.backtrace.first(12).map { |l| "       #{l}" } if ENV['VERIFY_TRACE']
  $failures += 1
end

def with_scheduler(scheduler)
  thread = Thread.new do
    Fiber.set_scheduler(scheduler)
    Fiber.schedule { yield }
    scheduler.drain
  end
  thread.join
end

puts 'no scheduler installed'
check 'scheduler! raises SchedulerRequired' do
  Runtime.scheduler!
  false
rescue Async::Background::Runtime::SchedulerRequired
  true
end

[StubScheduler, BareScheduler].each do |klass|
  puts "\n#{klass} (timeout_after hook: #{klass.instance_methods.include?(:timeout_after)})"
  scheduler = klass.new

  with_scheduler(scheduler) do
    check 'Task#wait returns the block value' do
      Runtime.spawn { 41 + 1 }.wait == 42
    end

    check 'Task#wait re-raises the task error' do
      Runtime.spawn { raise ArgumentError, 'boom' }.wait
      false
    rescue ArgumentError => e
      e.message == 'boom'
    end

    check 'Task yields itself to blocks that take an argument' do
      Runtime.spawn { |task| task.is_a?(Runtime::Task) }.wait
    end

    check 'Notification#wait resumes on signal_all' do
      notification = Runtime::Notification.new
      woken = []
      2.times { |i| Runtime.spawn { notification.wait; woken << i } }
      notification.signal_all
      scheduler.drain
      woken.sort == [0, 1]
    end

    check 'Semaphore limits concurrency' do
      semaphore = Runtime::Semaphore.new(2)
      peak = 0
      live = 0
      release = Runtime::Notification.new

      4.times do
        Runtime.spawn do
          semaphore.acquire do
            live += 1
            peak = [peak, live].max
            release.wait
            live -= 1
          end
        end
      end

      4.times { release.signal_all; scheduler.drain }
      peak == 2
    end

    check 'Semaphore releases the slot when the block raises' do
      semaphore = Runtime::Semaphore.new(1)
      Runtime.spawn { semaphore.acquire { raise 'nope' } }
      scheduler.drain
      semaphore.available == 1
    end

    check 'TaskGroup#wait drains every member' do
      group = Runtime::TaskGroup.new
      gate = Runtime::Notification.new
      finished = []

      2.times { |i| group.spawn { gate.wait; finished << i } }

      drained = false
      Runtime.spawn { group.wait; drained = true }

      gate.signal_all
      scheduler.drain
      drained && finished.sort == [0, 1] && group.empty?
    end

    check 'TaskGroup registers a task that finishes synchronously' do
      group = Runtime::TaskGroup.new
      group.spawn { :immediate }
      scheduler.drain
      group.empty?
    end

    check 'with_timeout(nil) just yields' do
      Runtime.with_timeout(nil) { :done } == :done
    end

    check 'with_timeout rejects negative durations' do
      Runtime.with_timeout(-1) { :never }
      false
    rescue ArgumentError
      true
    end

    check 'Notification#wait(timeout) returns false without the timeout_after hook' do
      Runtime::Notification.new.wait(0.01) == false
    end

    check 'Notification#wait(0) polls instead of parking' do
      Runtime::Notification.new.wait(0) == false
    end

    check 'Task#wait(timeout) raises TimeoutError' do
      parked = Runtime::Notification.new
      task = Runtime.spawn { parked.wait }
      begin
        task.wait(0.01)
        false
      rescue Async::Background::Runtime::TimeoutError
        parked.signal_all
        true
      end
    end

    check 'TaskGroup#wait(timeout) raises rather than parking forever' do
      group = Runtime::TaskGroup.new
      parked = Runtime::Notification.new
      group.spawn { parked.wait }
      begin
        group.wait(0.05)
        false
      rescue Async::Background::Runtime::TimeoutError
        parked.signal_all
        true
      end
    end

    check 'signal skips a waiter already released by Task#stop' do
      notification = Runtime::Notification.new
      woken = []
      stopped = Runtime.spawn { notification.wait; woken << :stopped }
      Runtime.spawn { notification.wait; woken << :live }
      stopped.stop
      notification.signal
      scheduler.drain
      woken.include?(:live)
    end

    check 'a dead task reports its error to the error handler' do
      seen = nil
      Runtime.error_handler = ->(task, error) { seen = [task.name, error.class] }
      Runtime.spawn(name: 'doomed') { raise ArgumentError, 'boom' }
      scheduler.drain
      Runtime.error_handler = nil
      seen == ['doomed', ArgumentError]
    end

    check 'Deadline is not a StandardError' do
      !(Async::Background::Runtime::Deadline <= StandardError)
    end

    check 'with_timeout rejects a zero duration' do
      Runtime.with_timeout(0) { :never }
      false
    rescue ArgumentError
      true
    end

    if scheduler.respond_to?(:timeout_after)
      check 'a bounded inner wait does not swallow an enclosing deadline' do
        Runtime.with_timeout(0.05) { Runtime::Notification.new.wait(10) }
        false
      rescue Async::Background::Runtime::TimeoutError
        true
      end

      check 'an enclosing deadline does not leak out of a bounded inner wait' do
        Runtime.with_timeout(5) { Runtime::Notification.new.wait(0.01) } == false
      end

      check 'on_timeout returns a fallback instead of raising' do
        Runtime.with_timeout(0.01, on_timeout: :expired) { Runtime::Notification.new.wait } == :expired
      end

    end

    check 'with_timeout uses the scheduler hook when the scheduler has one' do
      if scheduler.respond_to?(:timeout_after)
        before = scheduler.hook_calls.size
        Runtime.with_timeout(5) { :done }
        scheduler.hook_calls.size > before
      else
        Runtime.with_timeout(5) { :done } == :done
      end
    end

    check 'native_timeouts? reports whether deadlines are fiber-scoped' do
      Runtime.native_timeouts? == scheduler.respond_to?(:timeout_after)
    end

    check 'Semaphore rejects a zero limit instead of deadlocking' do
      Runtime::Semaphore.new(0)
      false
    rescue ArgumentError
      true
    end

    check 'on_release runs after the task has left the group' do
      group = nil
      observed = nil
      group = Runtime::TaskGroup.new(on_release: ->(_task) { observed = group.size })
      group.spawn { :done }
      scheduler.drain unless group.empty?
      observed == 0 && group.empty?
    end

    check 'stop_all(grace) cancels and drains' do
      group = Runtime::TaskGroup.new
      parked = Runtime::Notification.new
      group.spawn { parked.wait }

      drained = nil
      Runtime.spawn { drained = group.stop_all(0.5) }
      scheduler.drain
      drained == true && group.empty?
    end

    check 'a group reports through its own handler, not the global one' do
      group_seen = nil
      global_seen = nil

      Runtime.with_error_handler(->(_task, error) { global_seen = error.class }) do
        group = Runtime::TaskGroup.new(on_error: ->(_task, error) { group_seen = error.class })
        group.spawn { raise ArgumentError, 'boom' }
        scheduler.drain
      end

      group_seen == ArgumentError && global_seen.nil?
    end

    check 'with_error_handler restores the previous handler' do
      Runtime.error_handler = :outer
      Runtime.with_error_handler(:inner) { nil }
      restored = Runtime.error_handler
      Runtime.error_handler = nil
      restored == :outer
    end

    check 'an awaited failure is not also sent to the error handler' do
      reports = 0

      Runtime.with_error_handler(->(_task, _error) { reports += 1 }) do
        parked = Runtime::Notification.new
        task = Runtime.spawn { parked.wait; raise ArgumentError, 'boom' }
        Runtime.spawn do
          task.wait
        rescue ArgumentError
          nil
        end
        parked.signal_all
        scheduler.drain
      end

      reports.zero?
    end
  end
end

puts
if $failures.zero?
  puts 'all runtime checks passed'
  exit 0
else
  puts "#{$failures} check(s) failed"
  exit 1
end
