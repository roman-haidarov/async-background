# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'async'
require 'async/background/queue/socket_waker'

RSpec.describe Async::Background::Queue::SocketWaker, type: :unit do
  let(:path) do
    sock = temp_file_path('.sock')
    File.unlink(sock) if File.exist?(sock)
    sock
  end

  it 'signals when a wake byte arrives, not only when the client disconnects' do
    waker = described_class.new(path)
    waker.open!
    elapsed = nil

    Async do |task|
      waker.start_accept_loop(task)

      waiter = task.async { waker.wait(timeout: 2.0) }
      client = UNIXSocket.new(path)
      begin
        client.write("\x01")
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        waiter.wait
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      ensure
        client.close
        waker.close
      end
    end

    expect(elapsed).to be < 0.5
  end
end
