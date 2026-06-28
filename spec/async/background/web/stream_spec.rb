# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Stream do
  let(:subscription) { instance_double(Async::Background::Web::EventHub::Subscription) }
  let(:hub) { instance_double(Async::Background::Web::EventHub) }

  before do
    allow(hub).to receive(:subscribe).and_return([subscription, "event: overview\ndata: {\"data_version\":1}\n\n"])
    allow(hub).to receive(:unsubscribe)
  end

  it 'starts with a retry directive and an authoritative overview' do
    allow(subscription).to receive(:pop).and_return(nil)
    allow(subscription).to receive(:closed?).and_return(true)
    stream = described_class.new(hub, heartbeat_seconds: 30, retry_ms: 5000)
    frames = []

    stream.each { |frame| frames << frame }

    expect(frames).to eq(
      [
        "retry: 5000\n\n",
        "event: overview\ndata: {\"data_version\":1}\n\n"
      ]
    )
    expect(hub).to have_received(:unsubscribe).with(subscription)
  end

  it 'sends a heartbeat while the connection is idle' do
    allow(subscription).to receive(:pop).and_return(nil)
    allow(subscription).to receive(:closed?).and_return(false)
    stream = described_class.new(hub, heartbeat_seconds: 30, retry_ms: 5000)
    frames = []

    stream.each do |frame|
      frames << frame
      raise StopIteration if frames.length == 3
    end
  rescue StopIteration
    expect(frames.last).to eq(Async::Background::Web::EventHub::HEARTBEAT_FRAME)
  end

  it 'exits cleanly when the client disconnects' do
    allow(subscription).to receive(:pop).and_return('event: overview\ndata: {}\n\n')
    allow(subscription).to receive(:closed?).and_return(false)
    stream = described_class.new(hub, heartbeat_seconds: 30, retry_ms: 5000)

    expect {
      stream.each { |_frame| raise Errno::EPIPE }
    }.not_to raise_error
  end
end
