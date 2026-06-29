# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

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

  describe '#current_version' do
    it 'reads the snapshot data_version' do
      hub = described_class.new(HubSnapshot.new(version: 7), HubSerializer.new)
      expect(hub.current_version).to eq(7)
    end

    it 'raises ClosedError when the hub is closed' do
      hub = described_class.new(HubSnapshot.new, HubSerializer.new)
      hub.close
      expect { hub.current_version }.to raise_error(Async::Background::Web::ClosedError)
    end
  end

  describe '#initial_frame' do
    it 'returns the current version and a rendered overview frame' do
      snapshot = HubSnapshot.new(version: 3)
      hub = described_class.new(snapshot, HubSerializer.new)
      version, frame = hub.initial_frame
      expect(version).to eq(3)
      expect(parse_overview(frame).fetch(:data_version)).to eq(3)
    end

    it 'always refreshes — does not serve a frame older than now' do
      snapshot = HubSnapshot.new(version: 1)
      hub = described_class.new(snapshot, HubSerializer.new)
      hub.initial_frame
      snapshot.advance!
      version, frame = hub.initial_frame
      expect(version).to eq(2)
      expect(parse_overview(frame).fetch(:data_version)).to eq(2)
    end

    it 'raises ClosedError when closed' do
      hub = described_class.new(HubSnapshot.new, HubSerializer.new)
      hub.close
      expect { hub.initial_frame }.to raise_error(Async::Background::Web::ClosedError)
    end
  end

  describe '#frame_for' do
    it 'caches the rendered frame by data_version' do
      snapshot = HubSnapshot.new(version: 5)
      serializer = HubSerializer.new
      expect(serializer).to receive(:overview).once.and_call_original

      hub = described_class.new(snapshot, serializer)
      first  = hub.frame_for(5)
      second = hub.frame_for(5)

      expect(first).to eq(second)
    end

    it 'refreshes when the requested version differs from cache' do
      snapshot = HubSnapshot.new(version: 1)
      hub = described_class.new(snapshot, HubSerializer.new)

      hub.frame_for(1)
      snapshot.advance!
      frame = hub.frame_for(snapshot.data_version)

      expect(parse_overview(frame).fetch(:data_version)).to eq(2)
    end

    it 'raises ClosedError when closed' do
      hub = described_class.new(HubSnapshot.new, HubSerializer.new)
      hub.close
      expect { hub.frame_for(1) }.to raise_error(Async::Background::Web::ClosedError)
    end
  end

  describe 'no background thread' do
    it 'creates no additional threads on construction or use' do
      before = Thread.list.size
      hub = described_class.new(HubSnapshot.new, HubSerializer.new)
      10.times { hub.frame_for(1) }
      hub.initial_frame
      expect(Thread.list.size).to eq(before)
    ensure
      hub&.close
    end
  end
end
