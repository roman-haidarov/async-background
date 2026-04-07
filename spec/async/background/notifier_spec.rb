# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Queue::Notifier, type: :unit do
  let(:notifier) { described_class.new }

  after do
    notifier.close rescue nil
  end

  describe '#initialize' do
    it 'creates a binmode pipe pair' do
      expect(notifier.reader).to be_a(IO)
      expect(notifier.writer).to be_a(IO)
      expect(notifier.reader.binmode?).to be true
      expect(notifier.writer.binmode?).to be true
    end

    it 'reader and writer are distinct fds' do
      expect(notifier.reader.fileno).not_to eq(notifier.writer.fileno)
    end
  end

  describe '#notify and #wait' do
    it 'wait returns after notify' do
      Thread.new do
        sleep(0.05)
        notifier.notify
      end

      thread = Thread.new { notifier.wait(timeout: 2.0) }
      thread.join(2.5)

      expect(thread).not_to be_alive
    end

    it 'wait returns immediately if notify was already called' do
      notifier.notify

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      notifier.wait(timeout: 2.0)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      expect(elapsed).to be < 0.5
    end

    it 'wait with timeout returns even when no notify happens' do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      notifier.wait(timeout: 0.1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      expect(elapsed).to be >= 0.1
      expect(elapsed).to be < 1.0
    end

    it 'drains multiple pending notifies into a single wait' do
      10.times { notifier.notify }

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      notifier.wait(timeout: 2.0)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      expect(elapsed).to be < 0.5

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      notifier.wait(timeout: 0.1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      expect(elapsed).to be >= 0.1
    end

    it 'is safe to call notify many times in a row (does not raise on full pipe)' do
      expect {
        100_000.times { notifier.notify }
      }.not_to raise_error
    end
  end

  describe '#close and partial close' do
    it 'close shuts both ends and is idempotent' do
      notifier.close
      expect(notifier.reader.closed?).to be true
      expect(notifier.writer.closed?).to be true
      expect { notifier.close }.not_to raise_error
    end

    it 'notify after close does not raise (pipe closed)' do
      notifier.close
      expect { notifier.notify }.not_to raise_error
    end

    it 'close_reader leaves writer open' do
      notifier.close_reader
      expect(notifier.reader.closed?).to be true
      expect(notifier.writer.closed?).to be false
    end

    it 'close_writer leaves reader open' do
      notifier.close_writer
      expect(notifier.writer.closed?).to be true
      expect(notifier.reader.closed?).to be false
    end

    it 'for_producer! closes the reader end' do
      notifier.for_producer!
      expect(notifier.reader.closed?).to be true
      expect(notifier.writer.closed?).to be false
    end

    it 'silently swallows notify when the reader end has been closed' do
      notifier.for_producer!
      expect { notifier.notify }.not_to raise_error
    end

    it 'for_consumer! closes the writer end' do
      notifier.for_consumer!
      expect(notifier.writer.closed?).to be true
      expect(notifier.reader.closed?).to be false
    end
  end

  describe 'cross-process semantics (the actual use case)' do
    it 'producer in a forked process can wake up consumer' do
      skip 'fork unavailable on this platform' unless Process.respond_to?(:fork)

      n = described_class.new

      pid = fork do
        n.for_producer!
        sleep(0.05)
        n.notify
        exit!(0)
      end

      n.for_consumer!

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      n.wait(timeout: 2.0)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      expect(elapsed).to be < 1.0

      Process.waitpid(pid)
      n.close
    end
  end
end
