# frozen_string_literal: true

module Async
  module Background
    module Runtime
      class Semaphore
        attr_reader :limit

        def initialize(limit)
          @limit = Integer(limit)
          raise ArgumentError, 'limit must be >= 1' unless @limit.positive?

          @available = @limit
          @waiting = WaitList.new
        end

        def available = @available
        def waiting = @waiting.size

        def acquire
          wait
          return @available unless block_given?

          begin
            yield
          ensure
            release
          end
        end

        def release
          while (node = @waiting.shift)
            node.grant!
            return @available if node.resume
          end

          @available += 1
          @available
        end

        private

        def wait
          return (@available -= 1) if @available.positive?

          task = Runtime.current_task
          node = FiberNode.new(Fiber.current, self)
          @waiting.push(node)
          task&.enter_block(node.waiter)

          begin
            until node.granted?
              node.suspend
              abandon_wait!(node, task) if task&.cancelled?
            end
            abandon_wait!(node, task) if task&.cancelled?
          ensure
            task&.exit_block
            @waiting.remove(node) unless node.granted? || node.list.nil?
          end
        end

        def abandon_wait!(node, task)
          node.granted? ? release : @waiting.remove(node)
          task.raise_if_cancelled!
        end

        class WaitList
          attr_reader :size

          def initialize
            @head = @tail = nil
            @size = 0
          end

          def first = @head
          def empty? = @head.nil?

          def push(node)
            raise ArgumentError, 'node already queued' if node.list

            node.list = self
            node.prev = @tail
            node.next = nil
            @tail ? (@tail.next = node) : (@head = node)
            @tail = node
            @size += 1
            node
          end

          def shift
            node = @head or return nil

            remove(node)
          end

          def remove(node)
            return nil unless node.list.equal?(self)

            node.prev ? (node.prev.next = node.next) : (@head = node.next)
            node.next ? (node.next.prev = node.prev) : (@tail = node.prev)
            node.list = node.prev = node.next = nil
            @size -= 1
            node
          end
        end

        class FiberNode
          attr_accessor :list, :prev, :next
          attr_reader :fiber, :waiter, :blocker

          def initialize(fiber, blocker)
            @fiber = fiber
            @blocker = blocker
            @list = @prev = @next = nil
            @granted = false
            @scheduler = Runtime.scheduler!
            @waiter = {fiber: fiber, scheduler: @scheduler, ready: false, blocker: blocker, queued: true}
          end

          def granted? = @granted

          def grant!
            @granted = true
            @waiter[:ready] = true
            @waiter[:queued] = false
            self
          end

          def suspend
            @scheduler.block(@blocker, nil)
          end

          def resume
            fiber = @fiber
            return false unless fiber.alive?

            @scheduler.unblock(@blocker, fiber)
            true
          end
        end

        private_constant :WaitList, :FiberNode
      end
    end
  end
end
