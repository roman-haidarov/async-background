# Async::Background

A lightweight cron, interval, and job-queue scheduler for Ruby's [Async](https://github.com/socketry/async) ecosystem. Built for [Falcon](https://github.com/socketry/falcon), works with any Async app.

- **Cron & interval scheduling** on a single event loop with a min-heap
- **Dynamic job queue** backed by SQLite, with delayed jobs (`perform_in` / `perform_at`)
- **Cross-process wake-ups** over Unix domain sockets — web workers can enqueue and instantly wake background workers
- **Multi-process safe** — deterministic worker sharding, no duplicate execution
- **Per-job timeouts**, skip-on-overlap, startup jitter, optional metrics

## Requirements

- Ruby >= 3.3
- `async ~> 2.0`, `fugit ~> 1.0`
- `sqlite3 ~> 2.0` (optional, for the job queue)
- `async-utilization >= 0.3, < 0.5` (optional, for metrics)

## Install

```ruby
# Gemfile
gem "async-background"
gem "sqlite3", "~> 2.0"            # optional
gem "async-utilization", ">= 0.3", "< 0.5"  # optional
```

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
Async::Background::Queue.migrate!(path: db_path) # ← once, before fork
# Every process opens its own Store lazily after fork.
```

**Two clocks, on purpose.** Interval jobs use `CLOCK_MONOTONIC` (immune to NTP drift). Cron jobs use wall-clock time, because "every day at 3am" needs to mean 3am.

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

### Schema migration during deploy

Run queue migrations once in the release/pre-deploy step, before starting new web or worker
processes. This serializes the schema upgrade with `BEGIN IMMEDIATE`, records the version in
SQLite, and avoids a first producer doing DDL under live queue traffic:

```ruby
Async::Background::Queue.migrate!(path: ENV.fetch("QUEUE_DB_PATH"))
```

A fresh database still self-initializes on first use for local development, but explicit
migration is the production path. For an existing queue, finish or stop 0.7.1 producers/workers,
run the migration once, then start 0.7.2 processes.

### Future dashboard indexes

The queue does **not** install dashboard indexes by default. They slow every enqueue even though
pending rows never enter terminal or in-flight read-model indexes. When the 1.0 dashboard module
is enabled, its installer will run this once in the same release step:

```ruby
Async::Background::Queue.prepare_dashboard!(path: ENV.fetch("QUEUE_DB_PATH"))
```

It adds three compact indexes: one each for cursor-sorted done and failed jobs, plus one for
the bounded in-flight list. It does not change queue behavior or rerun the core migration.

## Metrics

Metrics are an optional integration with `async-utilization` (`>= 0.3`, `< 0.5`). The
background worker remains fully functional when that gem is absent. With it installed, each
worker publishes counters to a shared-memory segment.

```ruby
runner.metrics.enabled?
runner.metrics.values
# => { total_runs: 142, total_successes: 140, total_failures: 2,
#      total_timeouts: 0, total_skips: 5, active_jobs: 1, ... }

Async::Background::Metrics.read_all(total_workers: 2)
# => [{ worker: 1, ... }, { worker: 2, ... }]
```

`Metrics.read_all` returns `[]` until the optional gem is installed and a worker has created
the file, so an observer can render an unavailable state without rescuing `LoadError`. Its
snapshot is lock-free best effort: cumulative fields (`total_runs`, `total_successes`,
`total_failures`, `total_timeouts`, `total_skips`) are counters; `active_jobs`,
`last_run_at`, and `last_duration_ms` are gauges. Fields can describe adjacent moments in time
rather than one globally atomic instant.

By default the file is `/tmp/async-background.shm`. Set `ASYNC_BACKGROUND_METRICS_PATH`
or pass `metrics_shm_path:` to `Runner.new` when another observer runs in a separate process
or container; both sides must see the same mounted file.



## License

MIT
