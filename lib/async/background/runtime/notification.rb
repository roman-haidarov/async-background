# frozen_string_literal: true

module Async
  module Background
    module Runtime
      class Notification
        def initialize
          @waiters = []
        end

        def waiting = @waiters.size

        def wait(timeout = nil)
          wait_until(Runtime.deadline_for(timeout))
        end

        def wait_until(deadline = nil)
          Runtime.with_waiter(self, @waiters) do |waiter|
            Runtime.park(self, waiter, deadline) { false }
          end
        end

        def signal
          while (waiter = @waiters.shift)
            return true if Runtime.wake_dequeued(waiter, self)
          end

          false
        end

        def signal_all
          return nil if @waiters.empty?

          pending, @waiters = @waiters, []
          pending.each { |waiter| Runtime.wake_dequeued(waiter, self) }
          nil
        end
      end
    end
  end
end
