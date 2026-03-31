# Async::Background

A lightweight, production-grade cron/interval scheduler for Ruby's [Async](https://github.com/socketry/async) ecosystem. Designed for [Falcon](https://github.com/socketry/falcon) but works with any Async-based application.

## What It Does

- **Cron & interval scheduling** — single event loop + min-heap, scales to hundreds of jobs
- **Dynamic job queue** — enqueue jobs at runtime via SQLite, pick up by background workers
- **Delayed jobs** — schedule jobs for future execution with `perform_in` / `perform_at` (Sidekiq-like API)
- **Multi-process safe** — deterministic worker sharding via `Zlib.crc32`, no duplicate execution
- **Skip overlapping** — if a job is still running when its next tick arrives, the tick is skipped
- **Timeout protection** — per-job configurable timeout via `Async::Task#with_timeout`
- **Startup jitter** — random delay to prevent thundering herd after restart
- **Optional metrics** — shared memory performance tracking with `async-utilization`

## Requirements

- **Ruby >= 3.3** — Fiber Scheduler production-ready ([why?](#why-ruby-33))
- **Async ~> 2.0** — Fiber Scheduler-based concurrency
- **Fugit ~> 1.0** — cron expression parsing

## Installation

```ruby
# Gemfile
gem "async-background"

# Optional
gem "sqlite3", "~> 2.0"           # for dynamic job queue
gem "async-utilization", "~> 0.3"  # for metrics
```

## ➡️ [Get Started](docs/GET_STARTED.md)

Step-by-step setup guide: schedule config, Falcon integration, Docker, dynamic queue, delayed jobs.

---

## Quick Example: Job Module

Include `Async::Background::Job` for a Sidekiq-like interface:

```ruby
class SendEmailJob
  include Async::Background::Job

  def perform(user_id, template)
    user = User.find(user_id)
    Mailer.send(user, template)
  end
end

# Immediate execution in the queue
SendEmailJob.perform_async(user_id, "welcome")

# Execute after 5 minutes
SendEmailJob.perform_in(300, user_id, "reminder")

# Execute at a specific time
SendEmailJob.perform_at(Time.new(2026, 4, 1, 9, 0, 0), user_id, "scheduled")
```

Or use the lower-level API directly:

```ruby
Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")
Async::Background::Queue.enqueue_in(300, SendEmailJob, user_id, "reminder")
Async::Background::Queue.enqueue_at(Time.new(2026, 4, 1, 9, 0, 0), SendEmailJob, user_id, "scheduled")
```

---

## ⚠️ Important Notes

### Docker: SQLite requires a named volume

The SQLite database **must not** live on Docker's `overlay2` filesystem. The `overlay2` driver breaks coherence between `write()` and `mmap()`, which corrupts SQLite WAL under concurrent access.

```yaml
# docker-compose.yml
volumes:
  - queue-data:/app/tmp/queue   # ← named volume, NOT overlay2

volumes:
  queue-data:
```

Without this, you will get database crashes in multi-process mode. See [Get Started → Step 3](docs/GET_STARTED.md#step-3-docker) for details.

### Fork safety

SQLite connections **must not** cross `fork()` boundaries. Always open connections **after** fork (inside `container.run` block), never before. The gem handles this internally via lazy `ensure_connection`, but if you create a `Queue::Store` manually for schema setup, close it before fork:

```ruby
store = Async::Background::Queue::Store.new(path: db_path)
store.ensure_database!
store.close  # ← before fork
```

### Clock handling

The `Clock` module provides shared time helpers used across the codebase:

- **`monotonic_now`** (`CLOCK_MONOTONIC`) — for in-process intervals and durations, immune to NTP drift / wall-clock jumps
- **`realtime_now`** (`CLOCK_REALTIME`) — for persisted timestamps (SQLite `run_at`, `created_at`, `locked_at`)

Interval jobs use monotonic clock. Cron jobs use `Time.now` because "every day at 3am" must respect real time. These are different clocks by design.

---

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

### Queue Architecture

```
Producer (web/console)          Consumer (background worker)
     │                                │
     ▼                                ▼
 Queue::Client                   Queue::Store.fetch
     │                           (WHERE run_at <= now)
     ├─ push(class, args, run_at)     │
     ├─ push_in(delay, class, args)   ▼
     └─ push_at(time, class, args)  run_queue_job
     │                                │
     ▼                                ▼
 Queue::Store ──── SQLite ──── Queue::Notifier
 (INSERT job)    (jobs table)    (IO.pipe wakeup)
```

## Schedule Config

| Key | Required | Description |
|---|---|---|
| `class` | yes | Must include `Async::Background::Job` |
| `every` | one of | Interval in seconds between runs |
| `cron` | one of | Cron expression (parsed by Fugit) |
| `timeout` | no | Max execution time in seconds (default: 30) |
| `worker` | no | Pin to specific worker index. If omitted — `crc32(name) % total_workers` |

## SQLite Pragmas

| Pragma | Value | Why |
|---|---|---|
| `journal_mode` | WAL | Concurrent reads during writes |
| `synchronous` | NORMAL | Safe with WAL, lower fsync overhead |
| `mmap_size` | 256 MB | Fast reads ([requires proper filesystem](#docker-sqlite-requires-a-named-volume)) |
| `cache_size` | 16000 pages | ~64 MB page cache |
| `busy_timeout` | 5000 ms | Wait instead of failing on lock contention |

## Metrics

When `async-utilization` gem is available, metrics are collected in shared memory (`/tmp/async-background.shm`) with lock-free updates per worker.

```ruby
runner.metrics.values
# => { total_runs: 142, total_successes: 140, total_failures: 2,
#      total_timeouts: 0, total_skips: 5, active_jobs: 1,
#      last_run_at: 1774445243, last_duration_ms: 1250 }

# Read all workers at once (no server needed)
Async::Background::Metrics.read_all(total_workers: 2)
```

Without the gem — metrics are silently disabled, zero overhead.

## Why Ruby 3.3?

- Ruby 3.0 introduced Fiber Scheduler but had critical bugs
- Ruby 3.2 is the first production-ready release (per Samuel Williams)
- `io-event >= 1.14` (pulled by latest `async`) requires Ruby `>= 3.3`

## License

MIT
