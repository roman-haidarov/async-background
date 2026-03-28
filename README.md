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
- **Dynamic job queue** — enqueue jobs at runtime via SQLite-backed queue with IO.pipe notifications

## Requirements

- **Ruby >= 3.3** — Fiber Scheduler production-ready ([why?](#why-ruby-33))
- **Async ~> 2.0** — Fiber Scheduler-based concurrency
- **Fugit ~> 1.0** — cron expression parsing

## Installation

```ruby
# Gemfile
gem "async-background"  # Stable versions: 0.3.0, 0.4.4

# Optional: for dynamic job queue
gem "sqlite3", "~> 2.0"

# Optional: for metrics collection
gem "async-utilization", "~> 0.3"
```

> **⚠️ Version Note:** Currently stable versions are **0.3.0** and **0.4.4**. Other versions may have compatibility issues.

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
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/generic"

service "web" do
  include Falcon::Environment::Rack

  count ENV.fetch("FORKS", 1).to_i

  endpoint do
    host, port = ENV.fetch("APP_HOST", "0.0.0.0"), ENV.fetch("APP_PORT", 3000)

    Async::HTTP::Endpoint.parse("http://#{host}:#{port}")
  end
end

if ENV.fetch("BACKGROUND_FORKS", 0).to_i > 0
  service "scheduler" do
    service_class do
      Class.new(Async::Service::Generic) do
        def setup(container)
          require "async/background/queue/notifier"
          require "async/background/queue/store"
          require "async/background/queue/client"

          total = ENV.fetch("BACKGROUND_FORKS", 2).to_i
          queue_notifier = Async::Background::Queue::Notifier.new
          queue_store = Async::Background::Queue::Store.new
          queue_store.ensure_database!
          queue_store.close

          Async::Background::Queue.default_client = nil

          total.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              queue_store = Async::Background::Queue::Store.new
              queue_store.ensure_database!
              queue_notifier.for_consumer!

              Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
                store: queue_store, notifier: queue_notifier
              )

              instance.ready!

              begin
                Async::Background::Runner.new(
                  config_path:    Rails.root.join("config/schedule.yml"),
                  job_count:      ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
                  worker_index:   i + 1,
                  total_workers:  total,
                  queue_notifier: queue_notifier,
                  queue_db_path:  nil
                ).run
              ensure
                queue_store.close if queue_store
              end
            end
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

## Dynamic Job Queue (Optional)

In addition to scheduled cron/interval jobs, Async::Background supports a dynamic job queue — enqueue jobs at runtime from any process (web request, console, another worker), and they will be picked up and executed by background workers.

> **⚠️ Required dependency:** The queue module requires the `sqlite3` gem. It is **not** included automatically — you must add it to your Gemfile explicitly.

### Setup

Add to your Gemfile:

```ruby
gem "sqlite3", "~> 2.0"
```

### How It Works

The queue uses three components:

| Component | Role |
|-----------|------|
| `Queue::Store` | SQLite-backed persistent storage for jobs (WAL mode, prepared statements) |
| `Queue::Notifier` | `IO.pipe`-based notification — zero-cost wakeup, no polling |
| `Queue::Client` | Public API for enqueueing jobs |

The `Notifier` (IO.pipe) is created **before fork** and shared between producer (web process) and consumers (background workers). Each side closes the unused end of the pipe for safety.

> **Note:** Конфигурация с поддержкой динамической очереди показана в разделе [With Falcon](#with-falcon) выше.

### Enqueueing Jobs

From anywhere in your application (web request, console, rake task):

```ruby
# Job class must implement .perform_now
class SendEmailJob
  def self.perform_now(user_id, template)
    user = User.find(user_id)
    Mailer.send(user, template)
  end
end

# Enqueue — returns the job ID
Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")

# You can also pass the class name as a string
Async::Background::Queue.enqueue("SendEmailJob", user_id, "welcome")
```

### Worker Isolation

By default, all background workers listen to the queue. If you want to **exclude** specific workers from queue processing (e.g., dedicate them only to scheduled cron/interval jobs), use the `ISOLATION_FORKS` environment variable:

```bash
# Workers 1 and 3 will NOT listen to the queue
ISOLATION_FORKS=1,3
```

Isolated workers still run their scheduled jobs from `schedule.yml` as normal — they just ignore the dynamic queue.

### Job Lifecycle

| Status | Description |
|--------|-------------|
| `pending` | Job enqueued, waiting to be picked up |
| `running` | Claimed by a worker, currently executing |
| `done` | Completed successfully |
| `failed` | Failed with exception or timed out |

- **Recovery on restart:** When a worker starts, it automatically recovers any jobs that were `running` under its `worker_index` (stale after crash/restart) and requeues them as `pending`.
- **Automatic cleanup:** Completed jobs (`done`) older than 1 hour are deleted periodically (piggyback on `fetch`, every 5 minutes). If more than 100 rows are cleaned, `PRAGMA incremental_vacuum` reclaims disk space.
- **Timeout:** Queue jobs use the default timeout of 30 seconds.

### Custom Database Path

By default the SQLite database is created at `async_background_queue.db` in the working directory. You can customize it:

```ruby
Async::Background::Runner.new(
  # ...
  queue_db_path: "/var/data/my_queue.db"
)
```

### SQLite Configuration

The queue store applies the following SQLite pragmas for optimal performance:

| Pragma | Value | Why |
|--------|-------|-----|
| `journal_mode` | WAL | Concurrent reads during writes |
| `synchronous` | NORMAL | Safe with WAL, lower fsync overhead |
| `mmap_size` | 256 MB | Memory-mapped I/O for faster reads |
| `cache_size` | 16000 pages | ~64 MB page cache |
| `temp_store` | MEMORY | Temp tables in RAM |
| `busy_timeout` | 5000 ms | Wait instead of failing on lock contention |
| `journal_size_limit` | 64 MB | Prevent unbounded WAL growth |

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
