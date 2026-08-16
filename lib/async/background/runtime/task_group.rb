# frozen_string_literal: true

module Async
  module Background
    module Runtime
      class TaskGroup
        attr_accessor :on_release

        def initialize(on_error: UNSET, on_release: nil)
          @members = {}
          @drained = Notification.new
          @on_error = on_error
          @on_release = on_release
        end

        def size = @members.size
        def empty? = @members.empty?
        def tasks = @members.keys

        def spawn(name: nil, &block)
          raise ArgumentError, 'block required' unless block

          task = Task.new(name: name, group: self, on_error: @on_error)
          @members[task] = true

          begin
            task.start(&block)
          rescue Exception
            release(task)
            raise
          end

          task
        end

        def wait(timeout = nil)
          deadline = Runtime.deadline_for(timeout)

          until @members.empty?
            raise TimeoutError, 'tasks did not finish in time' unless @drained.wait_until(deadline)
          end

          true
        end

        def stop_all(grace = nil)
          tasks.each do |task|
            task.stop
          rescue StandardError
            nil
          end

          return @members.empty? if grace.nil?

          begin
            wait(grace)
          rescue TimeoutError
            false
          end
        end

        def release(task)
          return unless @members.delete(task)

          @drained.signal_all if @members.empty?
          notify_release(task)
        end

        private

        def notify_release(task)
          handler = @on_release or return

          handler.call(task)
        rescue StandardError => error
          Runtime.report_error(task, error, @on_error)
        end
      end
    end
  end
end
