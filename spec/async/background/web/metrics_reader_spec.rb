# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::MetricsReader do
  let(:reader) { described_class.new(path: '/tmp/async-background-metrics-test.shm', total_workers: 2, ttl: 0) }

  it 'reports unavailable metrics explicitly when the optional integration is absent' do
    allow(Async::Background::Metrics).to receive(:available?).and_return(false)

    expect(reader.aggregated).to eq(
      available: false,
      workers: [],
      totals: described_class::EMPTY_TOTALS
    )
  end

  it 'aggregates available worker snapshots without changing their per-worker values' do
    workers = [
      {worker: 1, total_runs: 4, total_successes: 3, total_failures: 1, total_timeouts: 0, total_skips: 2,
       active_jobs: 1, last_run_at: 10, last_duration_ms: 25},
      {worker: 2, total_runs: 5, total_successes: 5, total_failures: 0, total_timeouts: 1, total_skips: 0,
       active_jobs: 2, last_run_at: 20, last_duration_ms: 50}
    ].freeze
    allow(File).to receive(:file?).with('/tmp/async-background-metrics-test.shm').and_return(true)
    allow(Async::Background::Metrics).to receive(:available?).and_return(true)
    allow(Async::Background::Metrics).to receive(:read_all).with(total_workers: 2, path: '/tmp/async-background-metrics-test.shm')
      .and_return(workers)

    result = reader.aggregated
    expect(result[:available]).to eq(true)
    expect(result[:workers]).to eq(workers)
    expect(result[:totals]).to include(
      total_runs: 9,
      total_successes: 8,
      total_failures: 1,
      total_timeouts: 1,
      total_skips: 2,
      active_jobs: 3,
      last_run_at: 20,
      last_duration_ms: 50
    )
  end
end
