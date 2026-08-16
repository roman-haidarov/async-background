# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'async/background/queue/socket_waker'

RSpec.describe Async::Background::Queue::SocketWaker, type: :unit do
  let(:path) { temp_socket_path }

  it 'signals when a wake byte arrives, not only when the client disconnects' do
    waker = described_class.new(path)
    waker.open!
    elapsed = nil

    with_scheduler do
      waker.start_accept_loop

      waiter = Async::Background::Runtime.spawn { waker.wait(timeout: 2.0) }
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
