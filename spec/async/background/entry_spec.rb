# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::Entry, type: :unit do
  let(:job_class) do
    Class.new do
      include Async::Background::Job
      def perform(*); end
    end
  end

  def build_entry(interval: nil, cron: nil, next_run_at: 1000.0, timeout: 30)
    described_class.new(
      name:        'test_entry',
      job_class:   job_class,
      interval:    interval,
      cron:        cron,
      timeout:     timeout,
      next_run_at: next_run_at
    )
  end

  describe '#initialize' do
    it 'stores all attributes' do
      entry = build_entry(interval: 60, next_run_at: 12345.6, timeout: 10)

      expect(entry.name).to eq('test_entry')
      expect(entry.job_class).to eq(job_class)
      expect(entry.interval).to eq(60)
      expect(entry.cron).to be_nil
      expect(entry.timeout).to eq(10)
      expect(entry.next_run_at).to eq(12345.6)
    end

    it 'starts in non-running state' do
      entry = build_entry(interval: 60)
      expect(entry.running).to be false
    end
  end

  describe '#running accessor' do
    it 'can be toggled to true and back' do
      entry = build_entry(interval: 60)
      entry.running = true
      expect(entry.running).to be true
      entry.running = false
      expect(entry.running).to be false
    end
  end

  describe '#reschedule with interval (normal case)' do
    it 'advances next_run_at by exactly the interval when not behind schedule' do
      entry = build_entry(interval: 30, next_run_at: 1000.0)

      # monotonic_now is 990 — entry hasn't fired yet, no catch-up needed.
      # New next_run_at should be 1000 + 30 = 1030, NOT 990 + 30.
      entry.reschedule(990.0)

      expect(entry.next_run_at).to eq(1030.0)
    end

    it 'advances by interval even when monotonic_now equals previous next_run_at' do
      entry = build_entry(interval: 30, next_run_at: 1000.0)

      # Edge: now is exactly when the entry should have fired. This is
      # the "just fired" moment. Increment normally — 1000 + 30 = 1030.
      # 1030 > 1000, so no catch-up.
      entry.reschedule(1000.0)

      expect(entry.next_run_at).to eq(1030.0)
    end
  end

  describe '#reschedule with interval (catch-up branch)' do
    # The catch-up branch protects against drift when a worker was busy
    # for longer than the interval. Without it, the heap would accumulate
    # entries with next_run_at far in the past and the scheduler would
    # spin trying to "catch up" by firing the job back-to-back.
    it 'jumps next_run_at into the future when the worker is more than one interval behind' do
      entry = build_entry(interval: 30, next_run_at: 1000.0)

      # Worker was blocked: now is 5000, way past the original next_run_at.
      # 1000 + 30 = 1030, which is still <= 5000, so catch-up triggers.
      # Result: next_run_at = monotonic_now + interval = 5000 + 30 = 5030.
      entry.reschedule(5000.0)

      expect(entry.next_run_at).to eq(5030.0)
    end

    it 'triggers catch-up when next_run_at + interval exactly equals monotonic_now' do
      entry = build_entry(interval: 30, next_run_at: 1000.0)

      # 1000 + 30 = 1030, and now is also 1030 — the condition is `<=`,
      # so this is the boundary case. Catch-up fires: 1030 + 30 = 1060.
      entry.reschedule(1030.0)

      expect(entry.next_run_at).to eq(1060.0)
    end

    it 'never schedules in the past after catch-up' do
      entry = build_entry(interval: 10, next_run_at: 100.0)

      entry.reschedule(10_000.0)

      expect(entry.next_run_at).to be > 10_000.0
    end

    it 'is idempotent across many catch-ups (no drift)' do
      entry = build_entry(interval: 5, next_run_at: 0.0)

      # Simulate the scheduler calling reschedule repeatedly with a
      # monotonic_now that keeps moving forward in big jumps.
      [100.0, 200.0, 350.0, 500.0].each do |now|
        entry.reschedule(now)
        expect(entry.next_run_at).to be > now
      end
    end
  end

  describe '#reschedule with cron' do
    let(:every_minute_cron) { Fugit::Cron.new('* * * * *') }
    let(:every_5_minutes_cron) { Fugit::Cron.new('*/5 * * * *') }

    it 'sets next_run_at based on cron.next_time and monotonic_now' do
      entry = build_entry(cron: every_minute_cron, next_run_at: 0.0)

      monotonic_now = 1000.0
      entry.reschedule(monotonic_now)

      # The new next_run_at must be in the future relative to monotonic_now.
      expect(entry.next_run_at).to be > monotonic_now
      # And within reasonable bounds for a "* * * * *" cron — at most ~60
      # seconds away (next minute boundary), plus a small slack.
      expect(entry.next_run_at - monotonic_now).to be <= 61.0
    end

    it 'sets a sensible delay for a less-frequent cron' do
      entry = build_entry(cron: every_5_minutes_cron, next_run_at: 0.0)

      monotonic_now = 2000.0
      entry.reschedule(monotonic_now)

      # */5 * * * * fires every 5 minutes, so the next fire is at most
      # 5 minutes (300s) away.
      delta = entry.next_run_at - monotonic_now
      expect(delta).to be > 0
      expect(delta).to be <= 301.0
    end

    it 'enforces MIN_SLEEP_TIME as a lower bound' do
      # Build a cron entry, then manipulate the cron to return a "next_time"
      # that's basically right now — we expect the entry to still wait at
      # least MIN_SLEEP_TIME to avoid a tight loop.
      fake_cron = double('Cron')
      # next_time returns a Time that's only 0.001s ahead of Time.now —
      # below MIN_SLEEP_TIME (0.1s).
      allow(fake_cron).to receive(:next_time) do |now|
        now + 0.001
      end

      entry = build_entry(cron: fake_cron, next_run_at: 0.0)

      monotonic_now = 1000.0
      entry.reschedule(monotonic_now)

      delta = entry.next_run_at - monotonic_now
      expect(delta).to be >= Async::Background::MIN_SLEEP_TIME
    end

    it 'still works when cron.next_time returns a time in the past' do
      # Pathological cron that returns a time slightly behind now —
      # MIN_SLEEP_TIME must still kick in.
      fake_cron = double('Cron')
      allow(fake_cron).to receive(:next_time) do |now|
        now - 5.0
      end

      entry = build_entry(cron: fake_cron, next_run_at: 0.0)

      monotonic_now = 1000.0
      entry.reschedule(monotonic_now)

      # wait would be -5.0; max(-5.0, 0.1) = 0.1; next_run_at ≈ 1000.1.
      # Use be_within rather than eq because Time#to_f → Float arithmetic
      # accumulates IEEE 754 rounding noise (we get 0.10000000000002274,
      # not exactly 0.1). What matters here is that MIN_SLEEP_TIME kicked
      # in — i.e. the delta is the floor value, not the negative wait.
      delta = entry.next_run_at - monotonic_now
      expect(delta).to be_within(0.001).of(Async::Background::MIN_SLEEP_TIME)
    end
  end

  describe 'interval and cron are mutually exclusive in practice' do
    # The Runner's build_task_config enforces "every OR cron" via ConfigError,
    # but Entry itself doesn't. If both are passed, the interval branch
    # wins (the `if interval` check fires first).
    it 'uses interval branch when both interval and cron are provided' do
      cron = Fugit::Cron.new('* * * * *')
      entry = build_entry(interval: 30, cron: cron, next_run_at: 1000.0)

      entry.reschedule(990.0)

      expect(entry.next_run_at).to eq(1030.0)
    end
  end
end
