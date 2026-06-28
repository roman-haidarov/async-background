# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Serializer do
  let(:config) { Async::Background::Web::Configuration.new.tap { |c| c.queue_path = '/tmp/x.db'; c.auth = ->(_) { true } } }
  let(:serializer) { described_class.new(config) }

  describe 'args redaction by default' do
    let(:row) do
      {
        id: 1,
        class_name: 'MyJob',
        args_raw: JSON.generate(['secret-token', { 'email' => 'user@example.com' }]),
        options_raw: nil,
        finished_at: 1.0,
        duration_ms: 10
      }
    end

    it 'does not include args when expose_args is false' do
      result = serializer.done([row])[:items].first
      expect(result[:args]).to be_nil
      expect(result[:args_count]).to eq(2)
    end

    it 'exposes raw args when expose_args is true and no redactor is set' do
      config.expose_args = true
      config.redact_args = nil
      result = serializer.done([row])[:items].first
      expect(result[:args]).to eq(['secret-token', { 'email' => 'user@example.com' }])
    end

    it 'keeps zero-argument jobs visible as an empty array when args are exposed' do
      config.expose_args = true
      config.redact_args = nil
      row = { id: 1, class_name: 'J', args_raw: '[]', options_raw: nil, finished_at: 1.0, duration_ms: 1 }

      result = serializer.done([row])[:items].first
      expect(result[:args]).to eq([])
      expect(result[:args_count]).to eq(0)
    end

    it 'applies custom redactor when expose_args is true' do
      config.expose_args = true
      config.redact_args = ->(args) { args.map { |_| '[REDACTED]' } }
      result = serializer.done([row])[:items].first
      expect(result[:args]).to eq(['[REDACTED]', '[REDACTED]'])
    end
  end

  describe 'paging shape' do
    it 'returns items array and next_cursor for done' do
      row = { id: 1, class_name: 'J', args_raw: '[]', options_raw: nil, finished_at: 99.0, duration_ms: 1 }
      result = serializer.done([row])
      expect(result).to have_key(:items)
      expect(result).to have_key(:next_cursor)
      expect(result[:next_cursor]).not_to be_nil
    end

    it 'next_cursor is nil when items is empty' do
      result = serializer.done([])
      expect(result[:next_cursor]).to be_nil
    end
  end

  describe 'parsing args' do
    it 'handles malformed JSON without raising' do
      row = { id: 1, class_name: 'J', args_raw: 'not json', options_raw: nil, finished_at: 1.0, duration_ms: 1 }
      expect { serializer.done([row]) }.not_to raise_error
    end

    it 'treats empty string as no args' do
      row = { id: 1, class_name: 'J', args_raw: '', options_raw: nil, finished_at: 1.0, duration_ms: 1 }
      result = serializer.done([row])[:items].first
      expect(result[:args_count]).to eq(0)
    end
  end

  describe 'overview shape' do
    it 'includes metrics when provided' do
      snap = { counts: { done: 1 }, next_pending_run_at: 99.0, data_version: 7, generated_at: 100.0 }
      metrics = { workers: [], totals: { total_runs: 5 } }
      result = serializer.overview(snap, metrics)
      expect(result[:metrics]).to eq(metrics)
      expect(result[:counts]).to eq(done: 1)
      expect(result[:data_version]).to eq(7)
    end

    it 'omits metrics when nil' do
      snap = { counts: { done: 1 }, next_pending_run_at: nil, data_version: 7, generated_at: 100.0 }
      result = serializer.overview(snap, nil)
      expect(result).not_to have_key(:metrics)
    end
  end
end
