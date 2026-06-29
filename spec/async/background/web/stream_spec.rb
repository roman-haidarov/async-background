# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Stream do
  class FakeHub
    attr_accessor :script

    def initialize
      @script = []
      @current = nil
      @cached_frames = {}
    end

    def initial_frame
      step = next_step!
      raise Async::Background::Web::ClosedError, 'closed' if step == :closed
      raise Async::Background::Web::UnavailableError, 'unavailable' if step == :unavailable

      @current = step
      @cached_frames[step] ||= frame_for_version(step)
      [step, @cached_frames[step]]
    end

    def current_version
      step = next_step!
      raise Async::Background::Web::ClosedError, 'closed' if step == :closed
      raise Async::Background::Web::UnavailableError, 'unavailable' if step == :unavailable

      step
    end

    def frame_for(version)
      @cached_frames[version] ||= frame_for_version(version)
    end

    private

    def next_step!
      raise 'script exhausted' if @script.empty?

      @script.shift
    end

    def frame_for_version(version)
      "event: overview\ndata: {\"data_version\":#{version}}\n\n"
    end
  end

  def build_stream(hub, heartbeat: 30, poll_seconds: 0.5, advance_per_tick: 0.5, logger: nil)
    stream = described_class.new(
      hub,
      heartbeat_seconds: heartbeat,
      retry_ms: 5000,
      poll_seconds: poll_seconds,
      logger: logger
    )

    fake_clock = 0.0
    stream.define_singleton_method(:sleep_for_poll) do
      fake_clock += advance_per_tick
    end
    stream.define_singleton_method(:monotonic_now) { fake_clock }

    stream
  end

  it 'starts with a retry directive and the initial frame' do
    hub = FakeHub.new
    hub.script = [1, :closed]

    stream = build_stream(hub)
    frames = []
    stream.each { |frame| frames << frame }

    expect(frames[0]).to eq("retry: 5000\n\n")
    expect(frames[1]).to include('"data_version":1')
    expect(frames.length).to eq(2)
  end

  it 'emits an overview frame when data_version moves' do
    hub = FakeHub.new
    hub.script = [1, 2, :closed]

    stream = build_stream(hub)
    frames = []
    stream.each { |frame| frames << frame }

    overview_frames = frames.select { |frame| frame.include?('"data_version"') }
    expect(overview_frames.length).to eq(2)
    expect(overview_frames.last).to include('"data_version":2')
  end

  it 'emits a heartbeat when no change has happened for heartbeat_seconds' do
    hub = FakeHub.new
    hub.script = [1, 1, 1, 1, 1, 1, :closed]

    stream = build_stream(hub, heartbeat: 2.0, advance_per_tick: 1.0)
    frames = []
    stream.each { |frame| frames << frame }

    expect(frames).to include(Async::Background::Web::EventHub::HEARTBEAT_FRAME)
  end

  it 'exits cleanly on EPIPE (client disconnect)' do
    hub = FakeHub.new
    hub.script = [1, 2, 3, 4, 5]

    stream = build_stream(hub)

    yields = 0
    expect {
      stream.each do |_frame|
        yields += 1
        raise Errno::EPIPE if yields >= 2
      end
    }.not_to raise_error
  end

  it 'announces unavailable once and keeps polling' do
    hub = FakeHub.new
    hub.script = [1, :unavailable, :unavailable, :unavailable, 2, :closed]

    stream = build_stream(hub, advance_per_tick: 0.5, heartbeat: 60)
    frames = []
    stream.each { |frame| frames << frame }

    unavailable_count = frames.count { |frame| frame == Async::Background::Web::EventHub::UNAVAILABLE_FRAME }
    expect(unavailable_count).to eq(1)
    expect(frames.last).to include('"data_version":2')
  end

  it 'emits unavailable and returns when the very first frame fails' do
    hub = FakeHub.new
    hub.script = [:unavailable]

    stream = build_stream(hub)
    frames = []
    stream.each { |frame| frames << frame }

    expect(frames).to eq([
      "retry: 5000\n\n",
      Async::Background::Web::EventHub::UNAVAILABLE_FRAME
    ])
  end

  it 'logs unexpected stream errors when a logger is configured' do
    hub = FakeHub.new
    hub.script = [1, 2, :closed]

    logger = instance_double('Logger', error: nil, warn: nil)
    stream = build_stream(hub, logger: logger)

    expect {
      stream.each do |frame|
        raise StandardError, 'boom' if frame.include?('"data_version":1')
      end
    }.not_to raise_error
    expect(logger).to have_received(:error).with(/boom/)
  end

  it 'creates no background threads' do
    before = Thread.list.size
    hub = FakeHub.new
    hub.script = [1, 2, :closed]
    stream = build_stream(hub)
    stream.each { |_frame| }
    expect(Thread.list.size).to eq(before)
  end
end
