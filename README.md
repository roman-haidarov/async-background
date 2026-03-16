# Async::Background

A lightweight, production-grade cron/interval scheduler for Ruby's [Async](https://github.com/socketry/async) ecosystem. Designed for [Falcon](https://github.com/socketry/falcon) but works with any Async-based application.

## Requirements

- **Ruby >= 3.3** — Fiber Scheduler is production-ready starting from 3.2, but `io-event >= 1.14` requires 3.3+ ([details](#why-ruby-33))
- **Async ~> 2.0** — Fiber Scheduler-based concurrency
- **Fugit ~> 1.0** — cron expression parsing

## Installation

```ruby
# Gemfile
gem "async-background"
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

### Key Features

- **Single event loop** — one Async task + min-heap instead of N loops. Scales to hundreds of jobs.
- **Skip overlapping** — if a job is still running when its next tick arrives, the tick is skipped (with a warning log).
- **Jitter** — random delay on startup to prevent thundering herd after restart.
- **Monotonic clock** — interval jobs use `CLOCK_MONOTONIC` to avoid NTP drift.
- **Wall clock for cron** — cron jobs use `Time.now` because "every day at 3am" must respect real time.
- **Deterministic sharding** — jobs are distributed across workers via `Zlib.crc32(name)`, stable across restarts.
- **Semaphore concurrency** — `job_count` limits how many jobs run in parallel per worker.
- **Timeout protection** — each job has a configurable timeout via `Async::Task#with_timeout`.

## Schedule Config

| Key | Required | Description |
|---|---|---|
| `class` | yes | Job class name. Must respond to `.perform_now` class method. |
| `every` | one of | Interval in seconds between runs. |
| `cron` | one of | Cron expression (parsed by Fugit). |
| `timeout` | no | Max execution time in seconds (default: 30). |
| `worker` | no | Pin job to specific worker index. If omitted, assigned via `crc32(name) % total_workers`. |

## Why Ruby 3.3?

- Ruby 3.0 introduced Fiber Scheduler hooks but had critical bugs.
- Ruby 3.1 is the minimum for Async 2.x (`io-event` dependency), but has autoload bugs.
- Ruby 3.2 fixes these issues. Samuel Williams (Async author): *"3.2 is the first production-ready release."*
- Falcon itself requires `>= 3.2`.
- `io-event >= 1.14` (pulled by latest `async`) requires Ruby `>= 3.3`.

## License

MIT
