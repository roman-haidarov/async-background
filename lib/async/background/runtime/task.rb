# frozen_string_literal: true

module Async
  module Background
    module Runtime
      class Task
        attr_reader :fiber, :name, :error

        def self.spawn(name: nil, on_error: UNSET, &block)
          task = new(name: name, on_error: on_error)
          task.start(&block)
          task
        end

        def initialize(name: nil, group: nil, on_error: UNSET)
          @fiber = @scheduler = @blocker = @result = @error = nil
          @done = @cancelled = false

          @name = name
          @group = group
          @on_error = on_error
          @waiters = nil
        end

        def start(&block)
          raise ArgumentError, 'block required' unless block
          raise Error, 'task already started' if @fiber || @done

          @scheduler = Runtime.scheduler!
          takes_task = !block.arity.zero?

          scheduled = Fiber.schedule do
            adopt_fiber(Fiber.current)
            previous = Runtime.current_task
            Runtime.current_task = self
            begin
              complete(takes_task ? block.call(self) : block.call, nil)
            rescue Cancel
              complete(nil, nil)
            rescue Exception => e # rubocop:disable Lint/RescueException
              complete(nil, e)
            ensure
              Runtime.current_task = previous
            end
          end

          @fiber ||= scheduled if scheduled.is_a?(Fiber)
          self
        end

        def wait(timeout = nil)
          unless @done
            deadline = Runtime.deadline_for(timeout)
            raise TimeoutError, 'task did not finish in time' unless join(deadline)
          end

          raise @error if @error

          @result
        end

        def with_timeout(duration, &block)
          Runtime.with_timeout(duration, &block)
        end

        def stop
          return false if @done

          @cancelled = true

          return true if interrupt_fiber
          return true if release_blocker

          false
        end

        def cancelled? = @cancelled
        def finished? = @done
        def waiting = @waiters ? @waiters.size : 0

        def raise_if_cancelled!
          raise Cancel, 'task stopped' if @cancelled
        end

        def enter_block(waiter)
          @blocker = waiter
        end

        def exit_block
          @blocker = nil
        end

        private

        def adopt_fiber(fiber)
          @fiber ||= fiber
        end

        def interrupt_fiber
          fiber = @fiber
          scheduler = @scheduler
          return false unless fiber&.alive?
          return false unless scheduler&.respond_to?(:fiber_interrupt)

          result = scheduler.fiber_interrupt(fiber, Cancel.new('task stopped'))
          result != false
        rescue FiberError
          false
        end

        def release_blocker
          waiter = @blocker or return false

          Runtime.wake(waiter, waiter[:blocker]) && waiter[:fiber].alive?
        end

        def complete(result, error)
          return if @done

          @result = result
          @error = error
          @done = true

          Runtime.report_error(self, error, @on_error) if error && waiting.zero?
          @group&.release(self)
          wake_waiters
        end

        def join(deadline)
          waiters = (@waiters ||= [])
          Runtime.with_waiter(self, waiters) do |waiter|
            Runtime.park(self, waiter, deadline) { @done }
          end
        end

        def wake_waiters
          return if @waiters.nil? || @waiters.empty?

          pending, @waiters = @waiters, []
          pending.each { |waiter| Runtime.wake_dequeued(waiter, self) }
        end
      end
    end
  end
end
