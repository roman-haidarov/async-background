# frozen_string_literal: true

require 'timeout'

module Async
  module Background
    class Error < StandardError; end

    module Runtime
      class Error < Background::Error; end
      class SchedulerRequired < Error; end
      class TimeoutError < Error; end
      class Cancel < Exception; end
      class Deadline < Exception; end

      UNSET = Object.new

      CURRENT_TASK_KEY = :async_background_current_task
      WAITER_KEY = :async_background_waiter

      DEADLINE_MESSAGE = 'execution expired'

      NO_SCHEDULER_MESSAGE = <<~MESSAGE
        Async::Background requires an active Fiber scheduler.

        Install one in the host process before calling this, for example:

          require "async/background/scheduler"
          Async::Background::Scheduler.run { runner.run }

        or install one yourself:

          Fiber.set_scheduler(Itsi::Scheduler.new)   # itsi-scheduler
          Async { runner.run }                       # async / falcon
      MESSAGE

      MISSING_TIMEOUT_HOOK_WARNING = <<~MESSAGE
        Async::Background: %s does not implement #timeout_after.

        Falling back to stdlib Timeout, which uses Thread#raise and can deliver
        the timeout to an unrelated fiber. Job timeouts are therefore not safe
        on this scheduler. Use a scheduler that implements #timeout_after
        (async, itsi-scheduler) or run jobs with `timeout: nil`.
      MESSAGE

      @error_handler = nil
      @warned_schedulers = {}

      module_function

      def spawn(name: nil, on_error: UNSET, &block)
        Task.spawn(name: name, on_error: on_error, &block)
      end

      def scheduler
        Fiber.scheduler
      end

      def scheduler!
        Fiber.scheduler or raise SchedulerRequired, NO_SCHEDULER_MESSAGE
      end

      def native_timeouts?(target = Fiber.scheduler)
        !target.nil? && target.respond_to?(:timeout_after)
      end

      def current_task
        fiber_local(CURRENT_TASK_KEY)
      end

      def current_task=(task)
        set_fiber_local(CURRENT_TASK_KEY, task)
      end

      def build_waiter(blocker)
        existing = fiber_local(WAITER_KEY)
        if existing&.[](:blocker)
          raise Error, "waiter already parked on #{existing[:blocker].class}; " \
                       'a fiber may only park in one place at a time'
        end

        waiter = {
          fiber: Fiber.current,
          scheduler: scheduler!,
          ready: false,
          queued: false,
          blocker: blocker
        }
        set_fiber_local(WAITER_KEY, waiter)
        waiter
      end

      def park(blocker, waiter, deadline = nil)
        scheduler = waiter[:scheduler]
        task = current_task
        task&.enter_block(waiter)

        until waiter[:ready] || yield
          if deadline
            remaining = deadline - monotonic_now
            return false if remaining <= 0

            scheduler.block(blocker, remaining)
          else
            scheduler.block(blocker, nil)
          end

          task&.raise_if_cancelled!
        end

        true
      ensure
        waiter[:blocker] = nil
        clear_fiber_local(WAITER_KEY, waiter)
        task&.exit_block
      end

      def with_waiter(blocker, waiters)
        waiter = build_waiter(blocker)
        waiter[:queued] = true
        waiters << waiter
        yield waiter
      ensure
        waiters.delete(waiter) if waiter[:queued]
      end

      def wake_dequeued(waiter, blocker)
        waiter[:queued] = false
        wake(waiter, blocker)
      end

      def wake(waiter, blocker)
        return false if waiter[:ready]

        waiter[:ready] = true
        fiber = waiter[:fiber]
        return false unless fiber.alive?

        waiter[:scheduler].unblock(blocker, fiber)
        true
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def deadline_for(timeout)
        return nil if timeout.nil?

        seconds = Float(timeout)
        raise ArgumentError, 'timeout must be non-negative and finite' unless seconds.finite? && seconds >= 0

        monotonic_now + seconds
      end

      def error_handler=(handler)
        @error_handler = handler
      end

      def error_handler
        @error_handler
      end

      def with_error_handler(handler)
        previous = @error_handler
        @error_handler = handler
        yield
      ensure
        @error_handler = previous
      end

      def report_error(task, error, handler = UNSET)
        handler = @error_handler if UNSET.equal?(handler)
        return false unless handler

        handler.call(task, error)
        true
      rescue StandardError
        false
      end

      def fiber_local(key)
        Fiber[key]
      rescue ArgumentError, FiberError
        fiber_local_fallback[key]
      end

      def set_fiber_local(key, value)
        Fiber[key] = value
      rescue ArgumentError, FiberError
        fiber_local_fallback[key] = value
      end

      def clear_fiber_local(key, expected)
        current = fiber_local(key)
        set_fiber_local(key, nil) if current.equal?(expected)
      end

      def fiber_local_fallback
        fiber = Fiber.current
        store = fiber.instance_variable_get(:@async_background_locals)
        store || fiber.instance_variable_set(:@async_background_locals, {})
      end

      def with_timeout(duration, on_timeout: UNSET)
        return yield if duration.nil?

        seconds = Float(duration)
        raise ArgumentError, 'timeout must be positive and finite' unless seconds.finite? && seconds.positive?

        begin
          arm_deadline(seconds) { yield }
        rescue Deadline => e
          raise TimeoutError, e.message if UNSET.equal?(on_timeout)

          on_timeout
        end
      end

      def arm_deadline(seconds, &block)
        target = scheduler!

        return target.timeout_after(seconds, Deadline, DEADLINE_MESSAGE, &block) if native_timeouts?(target)

        warn_missing_timeout_hook(target)
        ::Timeout.timeout(seconds, Deadline, DEADLINE_MESSAGE, &block)
      end

      def warn_missing_timeout_hook(target)
        key = target.class
        return if @warned_schedulers[key]

        @warned_schedulers[key] = true
        warn(format(MISSING_TIMEOUT_HOOK_WARNING, key))
      end
    end
  end
end

require_relative 'runtime/notification'
require_relative 'runtime/semaphore'
require_relative 'runtime/task'
require_relative 'runtime/task_group'
