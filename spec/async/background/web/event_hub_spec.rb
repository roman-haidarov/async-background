# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'
require 'timeout'

RSpec.describe Async::Background::Web::EventHub do
  class HubSnapshot
    def initialize(version: 1)
      @mutex = Mutex.new
      @version = version
    end

    def data_version
      @mutex.synchronize { @version }
    end

    def overview(force: false)
      @mutex.synchronize do
        {
          counts: {executing: 0, claimed: 0, pending: @version, done: 0, failed: 0},
          next_pending_run_at: nil,
          data_version: @version,
          generated_at: 1.0
        }
      end
    end

    def advance!
      @mutex.synchronize { @version += 1 }
    end
  end

  class HubSerializer
    def overview(snapshot, _metrics)
      snapshot
    end
  end

  def parse_overview(frame)
    JSON.parse(frame.split("data: ", 2).last, symbolize_names: true)
  end

  def wait_for(timeout: 1)
    Timeout.timeout(timeout) do
      loop do
        value = yield
        return value if value

        sleep(0.005)
      end
    end
  end

  it 'fans one committed change out to every connected stream' do
    snapshot = HubSnapshot.new
    hub = described_class.new(snapshot, HubSerializer.new, poll_seconds: 0.01)
    first, first_frame = hub.subscribe
    second, second_frame = hub.subscribe

    expect(parse_overview(first_frame).fetch(:data_version)).to eq(1)
    expect(parse_overview(second_frame).fetch(:data_version)).to eq(1)

    snapshot.advance!

    first_update = wait_for { first.pop(timeout: 0.02) }
    second_update = wait_for { second.pop(timeout: 0.02) }
    expect(parse_overview(first_update).fetch(:data_version)).to eq(2)
    expect(parse_overview(second_update).fetch(:data_version)).to eq(2)
  ensure
    hub&.close
  end

  it 'keeps only the newest pending frame for a slow subscriber' do
    subscription = described_class::Subscription.new
    subscription.publish('older')
    subscription.publish('newest')

    expect(subscription.pop(timeout: 0)).to eq('newest')
  end

  it 'unblocks a waiting subscriber when it is closed' do
    subscription = described_class::Subscription.new
    waiter = Thread.new { subscription.pop(timeout: 5) }
    sleep(0.01)
    subscription.close

    expect(waiter.join(1)).not_to be_nil
    expect(waiter.value).to be_nil
  end
end
