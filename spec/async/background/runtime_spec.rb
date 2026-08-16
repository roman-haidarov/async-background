# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Runtime, type: :unit do
  let(:runtime) { Async::Background::Runtime }

  describe '.scheduler!' do
    it 'raises outside a scheduler with a message that says how to install one' do
      expect { runtime.scheduler! }
        .to raise_error(Async::Background::Runtime::SchedulerRequired, /requires an active Fiber scheduler/)
    end

    it 'returns the installed scheduler inside one' do
      with_scheduler do
        expect(runtime.scheduler!).to equal(Fiber.scheduler)
      end
    end
  end

  describe Async::Background::Runtime::Task do
    it 'returns the block value from #wait' do
      with_scheduler do
        expect(runtime.spawn { 6 * 7 }.wait).to eq(42)
      end
    end

    it 're-raises the task error in the waiter' do
      with_scheduler do
        task = runtime.spawn { raise ArgumentError, 'boom' }
        expect { task.wait }.to raise_error(ArgumentError, 'boom')
      end
    end

    it 'yields itself to blocks that accept an argument' do
      with_scheduler do
        expect(runtime.spawn { |task| task }.wait).to be_a(described_class)
      end
    end

    it 'exposes #with_timeout so job code reads the same as under Async::Task' do
      with_scheduler do
        task = runtime.spawn do |t|
          t.with_timeout(5) { :finished }
        end
        expect(task.wait).to eq(:finished)
      end
    end

    it 'releases a task parked on one of our primitives when stopped' do
      with_scheduler do
        notification = Async::Background::Runtime::Notification.new
        reached_end = false

        task = runtime.spawn do
          notification.wait
          reached_end = true
        end

        task.stop
        task.wait

        expect(reached_end).to be(false)
        expect(task).to be_cancelled
        expect(task).to be_finished
      end
    end

    it 'keeps current_task fiber-local so a sibling cannot steal the parent identity' do
      with_scheduler do
        parent_seen = nil
        child_seen = nil
        child_parent = nil

        parent = runtime.spawn do
          parent_seen = runtime.current_task
          child = runtime.spawn do
            child_seen = runtime.current_task
          end
          child.wait
          child_parent = runtime.current_task
          parent_seen
        end

        expect(parent.wait).to equal(parent)
        expect(parent_seen).to equal(parent)
        expect(child_seen).not_to equal(parent)
        expect(child_parent).to equal(parent)
      end
    end
  end

  describe 'bounded waits' do
    it 'does not need the timeout_after hook: they use scheduler#block(blocker, timeout)' do
      with_scheduler do
        expect(Fiber.scheduler).not_to receive(:timeout_after)
        expect(Async::Background::Runtime::Notification.new.wait(0.01)).to be(false)
      end
    end

    it 'treats a zero timeout as a poll rather than an error' do
      with_scheduler do
        expect(Async::Background::Runtime::Notification.new.wait(0)).to be(false)
      end
    end

    it 'keeps one budget across a TaskGroup#wait retry loop' do
      with_scheduler do
        group = Async::Background::Runtime::TaskGroup.new
        gate = Latch.new
        group.spawn { gate.wait }

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { group.wait(0.1) }.to raise_error(Async::Background::Runtime::TimeoutError)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(elapsed).to be < 1
        gate.open!
        group.wait
      end
    end
  end

  describe 'error reporting' do
    around do |example|
      previous = Async::Background::Runtime.error_handler
      example.run
    ensure
      Async::Background::Runtime.error_handler = previous
    end

    it 'reports an exception from a task nobody waits on' do
      with_scheduler do
        seen = []
        Async::Background::Runtime.error_handler = ->(task, error) { seen << [task.name, error.class] }

        Async::Background::Runtime.spawn(name: 'doomed') { raise ArgumentError, 'boom' }
        sleep(0.01)

        expect(seen).to eq([['doomed', ArgumentError]])
      end
    end
  end

  describe Async::Background::Runtime::Notification do
    it 'wakes a single waiter with #signal and every waiter with #signal_all' do
      with_scheduler do
        notification = described_class.new
        woken = []

        3.times { |i| runtime.spawn { notification.wait; woken << i } }

        # sleep(0.01) is the portable yield point: it goes through the
        # scheduler's kernel_sleep hook on every implementation.
        notification.signal
        sleep(0.01)
        expect(woken.size).to eq(1)

        notification.signal_all
        sleep(0.01)
        expect(woken.sort).to eq([0, 1, 2])
      end
    end

    it 'skips a waiter that Task#stop already released' do
      with_scheduler do
        notification = described_class.new
        woken = []

        stopped = runtime.spawn { notification.wait; woken << :stopped }
        runtime.spawn { notification.wait; woken << :live }
        sleep(0.01)

        stopped.stop
        expect(notification.signal).to be(true)
        sleep(0.01)

        expect(woken).to include(:live)
      end
    end

    it 'returns false when the wait times out instead of raising' do
      with_scheduler do
        expect(described_class.new.wait(0.01)).to be(false)
      end
    end

    it 'returns true when signalled before the timeout' do
      with_scheduler do
        notification = described_class.new
        waiter = runtime.spawn { notification.wait(5) }
        notification.signal_all
        expect(waiter.wait).to be(true)
      end
    end

    it 'gives each parked fiber its own waiter so signal_all can wake them all' do
      with_scheduler do
        notification = described_class.new
        waiters = []
        8.times { runtime.spawn { waiters << Fiber.current; notification.wait } }
        sleep(0.01)

        expect(notification.waiting).to eq(8)

        notification.signal_all
        sleep(0.01)
        expect(waiters.size).to eq(8)
        expect(notification.waiting).to eq(0)
      end
    end

    it 'removes a stopped waiter so a later signal does not resume a finished task' do
      with_scheduler do
        notification = described_class.new
        task = runtime.spawn { notification.wait }

        expect(task.stop).to be(true)
        task.wait

        expect(task).to be_finished
        expect(notification.signal).to be(false)
      end
    end
  end

  describe Async::Background::Runtime::Semaphore do
    it 'never lets more than `limit` blocks run at once' do
      with_scheduler do
        semaphore = described_class.new(2)
        gate = Latch.new
        peak = 0
        live = 0
        group = Async::Background::Runtime::TaskGroup.new

        4.times do
          group.spawn do
            semaphore.acquire do
              live += 1
              peak = [peak, live].max
              gate.wait
              live -= 1
            end
          end
        end

        gate.open!
        group.wait

        expect(peak).to eq(2)
        expect(semaphore.available).to eq(2)
      end
    end

    it 'releases the slot when the block raises' do
      with_scheduler do
        semaphore = described_class.new(1)
        task = runtime.spawn { semaphore.acquire { raise 'nope' } }

        expect { task.wait }.to raise_error('nope')
        expect(semaphore.available).to eq(1)
      end
    end

    it 'drains many more tasks than the limit without stranding waiters' do
      with_scheduler do
        semaphore = described_class.new(3)
        group = Async::Background::Runtime::TaskGroup.new
        finished = []

        40.times { |i| group.spawn { semaphore.acquire { finished << i } } }
        group.wait

        expect(finished.size).to eq(40)
        expect(semaphore.available).to eq(3)
      end
    end
  end

  describe 'nested deadlines' do
    it 'raises from TaskGroup#wait instead of parking forever when a member never finishes' do
      with_scheduler do
        group = Async::Background::Runtime::TaskGroup.new
        gate = Latch.new
        group.spawn { gate.wait }

        expect { group.wait(0.05) }.to raise_error(Async::Background::Runtime::TimeoutError)

        gate.open!
        group.wait
      end
    end
  end

  describe Async::Background::Runtime::TaskGroup do
    it 'drains every member before #wait returns' do
      with_scheduler do
        group = described_class.new
        gate = Latch.new
        finished = []

        3.times { |i| group.spawn { gate.wait; finished << i } }
        expect(group.size).to eq(3)

        gate.open!
        group.wait

        expect(finished.sort).to eq([0, 1, 2])
        expect(group).to be_empty
      end
    end

    it 'does not lose a task that finishes before #spawn returns' do
      with_scheduler do
        group = described_class.new
        group.spawn { :immediate }
        group.wait
        expect(group).to be_empty
      end
    end

    it 'releases members through the group pointer, not a per-task finish proc' do
      with_scheduler do
        group = described_class.new
        task = group.spawn { :done }
        task.wait
        expect(group).to be_empty
        expect(task).not_to respond_to(:on_finish)
      end
    end

    it 'raises TimeoutError and leaves members running when the drain times out' do
      with_scheduler do
        group = described_class.new
        gate = Latch.new
        group.spawn { gate.wait }

        expect { group.wait(0.05) }.to raise_error(Async::Background::Runtime::TimeoutError)
        expect(group.size).to eq(1)

        gate.open!
        group.wait
      end
    end
  end

  describe '.with_timeout' do
    it 'yields without a timer when the duration is nil' do
      expect(runtime.with_timeout(nil) { :done }).to eq(:done)
    end

    it 'rejects zero, negative and non-finite durations' do
      expect { runtime.with_timeout(0) { :never } }.to raise_error(ArgumentError)
      expect { runtime.with_timeout(-1) { :never } }.to raise_error(ArgumentError)
      expect { runtime.with_timeout(Float::INFINITY) { :never } }.to raise_error(ArgumentError)
    end

    it 'raises a deadline that user code cannot swallow with rescue => e' do
      with_scheduler do
        expect {
          runtime.with_timeout(0.01) do
            begin
              Async::Background::Runtime::Notification.new.wait
            rescue StandardError
              :swallowed
            end
          end
        }.to raise_error(Async::Background::Runtime::TimeoutError)
      end
    end

    it 'raises Runtime::TimeoutError, never a scheduler-specific error' do
      with_scheduler do
        expect { runtime.with_timeout(0.01) { Async::Background::Runtime::Notification.new.wait } }
          .to raise_error(Async::Background::Runtime::TimeoutError)
      end
    end

    it 'returns the fallback instead of raising when on_timeout is given' do
      with_scheduler do
        expect(runtime.with_timeout(0.01, on_timeout: :expired) { Async::Background::Runtime::Notification.new.wait })
          .to eq(:expired)
      end
    end

    it 'does not let an inner bounded wait swallow an enclosing deadline' do
      with_scheduler do
        expect { runtime.with_timeout(0.05) { Async::Background::Runtime::Notification.new.wait(10) } }
          .to raise_error(Async::Background::Runtime::TimeoutError)
      end
    end

    it 'does not let an enclosing deadline leak out of an inner bounded wait' do
      with_scheduler do
        expect(runtime.with_timeout(5) { Async::Background::Runtime::Notification.new.wait(0.05) })
          .to be(false)
      end
    end

    it 'goes through Timeout.timeout rather than calling the scheduler hook directly' do
      with_scheduler do
        scheduler = Fiber.scheduler
        next unless scheduler.respond_to?(:timeout_after)

        expect(scheduler).to receive(:timeout_after).and_call_original
        runtime.with_timeout(5) { :done }
      end
    end

    it 'does not allocate a new exception class on each call' do
      with_scheduler do
        before = ObjectSpace.count_objects[:T_CLASS]
        32.times { runtime.with_timeout(5) { :done } }
        expect(ObjectSpace.count_objects[:T_CLASS]).to eq(before)
      end
    end
  end
end
