# Async::Background

A lightweight, production-grade cron/interval scheduler for Ruby's [Async](https://github.com/socketry/async) ecosystem. Designed for [Falcon](https://github.com/socketry/falcon) but works with any Async-based application.

## Features

- **Single event loop** — one Async task + min-heap instead of N loops. Scales to hundreds of jobs
- **Skip overlapping execution** — prevents job pile-up with configurable timeout protection
- **Deterministic worker sharding** — jobs distributed via `Zlib.crc32(name)`, stable across restarts
- **Startup jitter** — random delay to prevent thundering herd after restart
- **Monotonic clock** — interval jobs use `CLOCK_MONOTONIC` to avoid NTP drift
- **Wall clock for cron** — cron jobs use `Time.now` for real-time scheduling
- **Semaphore concurrency** — configurable parallel job execution per worker
- **Optional metrics** — shared memory performance tracking with `async-utilization`

## Requirements

- **Ruby >= 3.3** — Fiber Scheduler production-ready ([why?](#why-ruby-33))
- **Async ~> 2.0** — Fiber Scheduler-based concurrency
- **Fugit ~> 1.0** — cron expression parsing

## Installation

```ruby
# Gemfile
gem "async-background"

# Optional: for metrics collection
gem "async-utilization", "~> 0.3"
```

## Quick Start

```yaml
# config/schedule.yml
sync_products:
  class: SyncProductsJob
  every: 60
  timeout: 30

daily_report:
  class: DailyReportJob
  cron: "0 3 * * *"
  timeout: 120

# Pin to specific worker (optional)
heavy_import:
  class: HeavyImportJob
  cron: "0 */6 * * *"
  timeout: 600
  worker: 1
```

```ruby
# In your Falcon config or any Async context
require "async/background"

Async::Background::Runner.new(
  config_path:  "config/schedule.yml",
  job_count:    2,          # max concurrent jobs
  worker_index: 1,          # this worker's index (1-based)
  total_workers: 2          # total background workers
).run
```

### With Falcon

```ruby
# falcon.rb
service "scheduler" do
  service_class do
    Class.new(Async::Service::Generic) do
      def setup(container)
        total = ENV.fetch("BACKGROUND_FORKS", 1).to_i

        total.times do |i|
          container.run(count: 1, restart: true) do |instance|
            require_relative "config/environment"
            require "async/background"

            instance.ready!

            Async::Background::Runner.new(
              config_path:   Rails.root.join("config/schedule.yml"),
              job_count:     ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
              worker_index:  i + 1,
              total_workers: total
            ).run
          end
        end
      end
    end
  end
end
```

## Schedule Config

| Key | Required | Description |
|---|---|---|
| `class` | yes | Job class name. Must respond to `.perform_now` class method. |
| `every` | one of | Interval in seconds between runs. |
| `cron` | one of | Cron expression (parsed by Fugit). |
| `timeout` | no | Max execution time in seconds (default: 30). |
| `worker` | no | Pin job to specific worker index. If omitted, assigned via `crc32(name) % total_workers`. |

## Metrics (Optional)

Async::Background includes optional metrics collection using shared memory when the `async-utilization` gem is available.

### Setup

Add to your Gemfile:
```ruby
gem "async-utilization", "~> 0.3"
```

### Usage

```ruby
runner = Async::Background::Runner.new(
  config_path:   "config/schedule.yml",
  job_count:     2,
  worker_index:  1,
  total_workers: 2
)

# Check if metrics are enabled
runner.metrics.enabled?  # => true/false

# Get current metrics for this worker
runner.metrics.values
# => {
#   total_runs: 142,
#   total_successes: 140,
#   total_failures: 2,
#   total_timeouts: 0,
#   total_skips: 5,
#   active_jobs: 1,
#   last_run_at: 1774445243,
#   last_duration_ms: 1250
# }

# Read metrics for all workers (no server needed)
Async::Background::Metrics.read_all(total_workers: 2)
# => [
#   { worker: 1, total_runs: 142, active_jobs: 1, ... },
#   { worker: 2, total_runs: 98,  active_jobs: 0, ... }
# ]
```

### Available Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `total_runs` | u64 | Total number of job executions started |
| `total_successes` | u64 | Number of successful job completions |
| `total_failures` | u64 | Number of jobs that failed with exceptions |
| `total_timeouts` | u64 | Number of jobs that exceeded timeout |
| `total_skips` | u64 | Number of jobs skipped (previous run still active) |
| `active_jobs` | u32 | Current number of running jobs |
| `last_run_at` | u64 | Unix timestamp of last job execution |
| `last_duration_ms` | u32 | Duration of last completed job in milliseconds |

Metrics are stored in shared memory (`/tmp/async-background.shm`) and persist across worker restarts. Each worker maintains its own segment for lock-free updates.

**Without `async-utilization`**: All metrics methods return empty results and logging continues as normal. No performance impact.

## Architecture

```
schedule.yml
     │
     ▼
 build_heap          ← parse config, validate, assign workers
     │
     ▼
 MinHeap<Entry>      ← O(log N) push/pop, sorted by next_run_at
     │
     ▼
 1 scheduler loop    ← single Async task, sleeps until next entry
     │
     ▼
 Semaphore           ← limits concurrent job execution
     │
     ▼
 run_job             ← timeout, logging, error handling
```

## Why Ruby 3.3?

- Ruby 3.0 introduced Fiber Scheduler hooks but had critical bugs
- Ruby 3.1 is the minimum for Async 2.x (`io-event` dependency), but has autoload bugs
- Ruby 3.2 fixes these issues. Samuel Williams (Async author): *"3.2 is the first production-ready release."*
- Falcon itself requires `>= 3.2`
- `io-event >= 1.14` (pulled by latest `async`) requires Ruby `>= 3.3`

## License

MIT
