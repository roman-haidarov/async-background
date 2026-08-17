# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'async/background/queue/socket_notifier'

RSpec.describe Async::Background::Queue::SocketNotifier, type: :unit do
  let(:total_workers) { 4 }
  let(:live_worker) { 2 }
  let(:socket_dir) { temp_socket_dir }
  let(:notifier) { described_class.new(socket_dir: socket_dir, total_workers: total_workers) }

  def socket_path(worker_index)
    File.join(socket_dir, "async_bg_worker_#{worker_index}.sock")
  end

  def listen!(worker_index)
    server = UNIXServer.new(socket_path(worker_index))
    bytes = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        bytes << client.read(1)
        client.close
      end
    rescue IOError, Errno::EBADF, Errno::EINVAL
    end
    [server, thread, bytes]
  end

  def count_connects
    opens = 0
    allow(UNIXSocket).to receive(:new).and_wrap_original do |method, *args|
      opens += 1
      method.call(*args)
    end
    yield
    opens
  end

  it 'delivers the wake byte to a live worker' do
    server, thread, bytes = listen!(live_worker)

    expect(notifier.notify_all).to be true
    expect(bytes.pop).to eq(described_class::WAKE_BYTE)
  ensure
    server&.close
    thread&.join(1)
  end

  it 'builds socket paths once' do
    paths = notifier.instance_variable_get(:@paths)
    expect(paths).to be_frozen
    expect(paths.size).to eq(total_workers)

    server, thread, = listen!(live_worker)
    5.times { notifier.notify_all }
    expect(notifier.instance_variable_get(:@paths)).to equal(paths)
  ensure
    server&.close
    thread&.join(1)
  end

  it 'does not reconnect to workers already marked unreachable' do
    server, thread, bytes = listen!(1)
    notifier.notify_all
    bytes.pop

    opens = count_connects { 10.times { notifier.notify_all } }

    expect(opens).to eq(10)
    expect(Array.new(10) { bytes.pop }).to all(eq(described_class::WAKE_BYTE))
  ensure
    server&.close
    thread&.join(1)
  end
end
