# Async::Background

A lightweight cron, interval, and job-queue scheduler for Ruby's [Async](https://github.com/socketry/async) ecosystem. Built for [Falcon](https://github.com/socketry/falcon), works with any Async app.

- **Cron & interval scheduling** on a single event loop with a min-heap
- **Dynamic job queue** backed by SQLite (via [Extralite](https://github.com/digital-fabric/extralite)), with delayed jobs (`perform_in` / `perform_at`)
- **Bundled SQLite** — `extralite-bundle` ships the SQLite amalgamation inline, so no system `libsqlite3-dev` is required to build
- **Cross-process wake-ups** over Unix domain sockets — web workers can enqueue and instantly wake background workers
- **Multi-process safe** — deterministic worker sharding, no duplicate execution
- **Per-job timeouts**, skip-on-overlap, startup jitter, optional metrics

## Requirements

- Ruby >= 3.3
- `async ~> 2.0`, `fugit ~> 1.0`
- `extralite-bundle ~> 2.12` (optional, for the job queue)
- `async-utilization ~> 0.3` (optional, for metrics)

## Install

```ruby
# Gemfile
gem "async-background"
gem "extralite-bundle",  "~> 2.12"  # optional, for the job queue
gem "async-utilization", "~> 0.3"   # optional, for metrics
```

> **Why extralite-bundle?** Extralite has a smaller, faster C extension than the `sqlite3` gem and releases the GVL more aggressively during queries, which plays nicer with multi-threaded setups. The `-bundle` variant ships SQLite source inline — no system `libsqlite3-dev` required at build time.

## ➡️ [Get Started](docs/GET_STARTED.md)

Full setup walkthrough: schedule config, Falcon integration, Docker, queue, delayed jobs.

---

## Quick Look

```ruby
class SendEmailJob
  include Async::Background::Job

  def perform(user_id, template)
    Mailer.send(User.find(user_id), template)
  end
end

SendEmailJob.perform_async(user_id, "welcome")
SendEmailJob.perform_in(300, user_id, "reminder")
SendEmailJob.perform_at(Time.new(2026, 4, 1, 9), user_id, "scheduled")
```

Schedule recurring jobs in `config/schedule.yml`:

```yaml
sync_products:
  class: SyncProductsJob
  every: 60

daily_report:
  class: DailyReportJob
  cron: "0 3 * * *"
  timeout: 120
```

| Key | Description |
|---|---|
| `class` | Job class — must include `Async::Background::Job` |
| `every` / `cron` | One of: interval in seconds, or cron expression |
| `timeout` | Max execution time in seconds (default: 30) |
| `worker` | Pin to a specific worker. Default: `crc32(name) % total_workers` |

---

## Gotchas

### Docker: SQLite requires a named volume

The SQLite database **must not** live on Docker's `overlay2` filesystem. The `overlay2` driver breaks coherence between `write()` and `mmap()`, which corrupts SQLite WAL under concurrent access.

```yaml
# docker-compose.yml
services:
  app:
    volumes:
      - queue-data:/app/tmp/queue   # ← named volume, NOT overlay2

volumes:
  queue-data:
```

Without this, you will get database crashes in multi-process mode. See [Get Started → Step 3](docs/GET_STARTED.md#step-3-docker) for details. If you can't use a named volume, pass `queue_mmap: false` to disable mmap entirely.

### Other gotchas

**Don't share SQLite connections across `fork()`.** The gem opens connections lazily after fork, but if you create a `Queue::Store` manually for schema setup, close it before forking:

```ruby
store = Async::Background::Queue::Store.new(path: db_path)
store.ensure_database!
store.close  # ← before fork
```

**Two clocks, on purpose.** Interval jobs use `CLOCK_MONOTONIC` (immune to NTP drift). Cron jobs use wall-clock time, because "every day at 3am" needs to mean 3am.

**Queue holds the GVL during each query.** SQLite queries run inside the C extension and hold the Ruby GVL for their duration. In practice queue operations are short (sub-millisecond), so this is fine for fiber-based servers like Falcon, but it means long-running queries will stall the Async reactor. Keep queue operations small and avoid heavy scans on the hot path.

---

## How it works

```
schedule.yml ─► build_heap ─► MinHeap<Entry> ─► scheduler loop ─► Semaphore ─► run_job
```

A single Async task sleeps until the next entry is due, then dispatches it under a semaphore that caps concurrency. Overlapping ticks are skipped and rescheduled.

The dynamic queue runs alongside it:

```
   Producer (web/console)              Consumer (background worker)
          │                                       │
          ▼                                       ▼
    Queue::Client                          Queue::Store#fetch
   push / push_in / push_at                (run_at <= now)
          │                                       ▲
          ▼                                       │
    Queue::Store ──── SQLite (jobs) ──── SocketWaker
          │                                       ▲
          └───────► SocketNotifier ───────────────┘
                    (UNIX socket wake-up, ~80µs)
```

Jobs are persisted in SQLite, so a missed wake-up is never a lost job — workers also poll every 5 seconds as a safety net.

## Metrics

With `async-utilization` installed, per-worker stats land in shared memory at `/tmp/async-background.shm` with lock-free updates.

```ruby
runner.metrics.values
# => { total_runs: 142, total_successes: 140, total_failures: 2,
#      total_timeouts: 0, total_skips: 5, active_jobs: 1, ... }

Async::Background::Metrics.read_all(total_workers: 2)
```

Without the gem, metrics are silently disabled — zero overhead.

## License

MIT
