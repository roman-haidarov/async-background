# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Configuration do
  let(:config) { described_class.new }

  def minimal!
    config.queue_path = '/tmp/q.db'
    config.auth = ->(_env) { true }
  end

  describe '#validate!' do
    it 'requires queue_path' do
      config.queue_path = nil
      config.auth = ->(_env) { true }
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /queue_path/)
    end

    it 'rejects empty queue_path' do
      config.queue_path = ''
      config.auth = ->(_env) { true }
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /queue_path/)
    end

    it 'requires auth to be configured' do
      config.queue_path = '/tmp/q.db'
      config.auth = nil
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /auth must be configured/)
    end

    it 'requires auth to be callable' do
      config.queue_path = '/tmp/q.db'
      config.auth = 'not a proc'
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /respond to #call/)
    end

    it 'requires list_limit in range' do
      minimal!
      config.list_limit = 0
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /list_limit/)
      config.list_limit = 500
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /list_limit/)
    end

    it 'requires non-negative counts_cache_ttl' do
      minimal!
      config.counts_cache_ttl = -1
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /counts_cache_ttl/)
    end

    it 'requires poll_interval_ms >= 200' do
      minimal!
      config.poll_interval_ms = 100
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /poll_interval_ms/)
    end

    it 'requires transport to be one of :polling or :sse' do
      minimal!
      config.transport = :ws
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /transport/)
    end

    it 'accepts :sse transport' do
      minimal!
      config.transport = :sse
      expect { config.validate! }.not_to raise_error
    end

    it 'validates SSE timing knobs' do
      minimal!
      config.stream_poll_seconds = 0.05
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /stream_poll_seconds/)

      config.stream_poll_seconds = 0.5
      config.stream_heartbeat_seconds = 4
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /stream_heartbeat_seconds/)

      config.stream_heartbeat_seconds = 25
      config.stream_retry_ms = 100
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /stream_retry_ms/)
    end

    it 'requires total_workers when metrics_path is set' do
      minimal!
      config.metrics_path = '/tmp/m.shm'
      config.total_workers = nil
      expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /total_workers/)
    end

    describe 'mount_path' do
      it 'accepts the empty default' do
        minimal!
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts an absolute path without trailing slash' do
        minimal!
        config.mount_path = '/admin/background'
        expect { config.validate! }.not_to raise_error
      end

      it 'rejects non-string values' do
        minimal!
        config.mount_path = 42
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /must be a String/)
      end

      it 'rejects relative paths without a leading slash' do
        minimal!
        config.mount_path = 'admin'
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /start with "\/"/)
      end

      it 'rejects a trailing slash' do
        minimal!
        config.mount_path = '/admin/'
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /not end with "\/"/)
      end

      it 'rejects control characters' do
        minimal!
        config.mount_path = "/admin\n"
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /control characters/)
      end

      it 'rejects whitespace' do
        minimal!
        config.mount_path = '/admin background'
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /whitespace/)
      end
    end

    describe 'logger' do
      it 'accepts nil (default)' do
        minimal!
        config.logger = nil
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts a logger that responds to #warn and #error' do
        minimal!
        config.logger = instance_double('Logger', warn: nil, error: nil)
        expect { config.validate! }.not_to raise_error
      end

      it 'rejects a logger missing either method' do
        minimal!
        config.logger = Object.new
        expect { config.validate! }.to raise_error(Async::Background::Web::ConfigurationError, /respond to #warn and #error/)
      end
    end

    it 'passes with minimal valid config' do
      minimal!
      expect(config.validate!).to eq(config)
    end
  end

  describe '#limit_for' do
    it 'rejects malformed and non-positive HTTP values' do
      expect { config.limit_for('0') }.to raise_error(Async::Background::Web::RequestError, /positive/)
      expect { config.limit_for('oops') }.to raise_error(Async::Background::Web::RequestError, /positive/)
    end

    it 'caps an oversized value at MAX_LIST_LIMIT' do
      expect(config.limit_for('1000')).to eq(described_class::MAX_LIST_LIMIT)
    end
  end

  describe 'defaults' do
    it 'sets safe defaults' do
      expect(config.expose_args).to eq(false)
      expect(config.list_limit).to eq(50)
      expect(config.counts_cache_ttl).to eq(3.0)
      expect(config.poll_interval_ms).to eq(2000)
      expect(config.transport).to eq(:sse)
      expect(config.stream_poll_seconds).to eq(0.5)
      expect(config.stream_heartbeat_seconds).to eq(25.0)
      expect(config.stream_retry_ms).to eq(5000)
      expect(config.title).to eq('Async::Background')
      expect(config.mount_path).to eq('')
      expect(config.logger).to be_nil
    end
  end
end
