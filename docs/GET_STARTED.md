# Get started

A walkthrough from zero to a running Falcon app with cron jobs, a dynamic
queue, and an optional read-only dashboard.

1. [Define your jobs](#step-1--define-your-jobs)
2. [Configure Falcon](#step-2--configure-falcon)
3. [Mount the optional dashboard](#step-25--mount-the-optional-dashboard)
4. [Docker setup](#step-3--docker-setup)
5. [Use the queue](#step-4--use-the-queue)

Plus appendices:

- [Store tuning](#appendix-store-tuning)
- [Optional metrics](#appendix-optional-metrics)
- [Minimal example, no Docker, no Rails](#appendix-minimal-example)



&nbsp;

## Step 1 — Define your jobs

Every job is a plain Ruby class that includes `Async::Background::Job` and
implements `#perform`.

```ruby
class SendEmailJob
  include Async::Background::Job

  def perform(user_id, template)
    Mailer.send(User.find(user_id), template)
  end
end
```

For scheduled jobs (cron / interval), declare them in `config/schedule.yml`:

```yaml
sync_products:
  class: SyncProductsJob
  every: 60
  timeout: 120

daily_report:
  class: DailyReportJob
  cron: "0 3 * * *"
  timeout: 120

# Pin to a specific worker (optional)
heavy_import:
  class: HeavyImportJob
  cron: "0 */6 * * *"
  timeout: 600
  worker: 1
```

`SyncProductsJob`, `DailyReportJob` and `HeavyImportJob` are defined the
same way as `SendEmailJob` above.

### Class-level options

Override the default 120 s timeout, enable retries, etc. with `.options`:

```ruby
class HeavySyncJob
  include Async::Background::Job
  options timeout: 300, retry: 3, retry_delay: 10, backoff: :exponential

  def perform(account_id) = Account.find(account_id).full_sync!
end
```

The full list of retry knobs is in [Step 4 → Retries](#retries-queue-jobs-only).



&nbsp;

## Step 2 — Configure Falcon

A single `falcon.rb` defines three things: the web server, the background
scheduler, and how web workers enqueue into the same SQLite queue.

### Shared paths

```ruby
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/generic"

TOTAL_BG     = ENV.fetch("BACKGROUND_FORKS", 0).to_i
DB_PATH      = ENV.fetch("QUEUE_DB_PATH",                "/app/tmp/queue/background.db")
SOCK_DIR     = ENV.fetch("QUEUE_SOCKET_DIR",             "/app/tmp/queue/sockets")
METRICS_PATH = ENV.fetch("ASYNC_BACKGROUND_METRICS_PATH","/app/tmp/queue/async-background.shm")
```

> Schema migration belongs in the deploy release step (`bin/migrate_async_background`
> below), **before** this supervisor starts any web or scheduler process.
> Don't call it from inside a service.

### Web service — Falcon + producer

```ruby
service "web" do
  include Falcon::Environment::Rack

  count ENV.fetch("FORKS", 1).to_i

  endpoint do
    Async::HTTP::Endpoint.parse(
      "http://#{ENV.fetch('APP_HOST', '0.0.0.0')}:#{ENV.fetch('APP_PORT', 3000)}"
    )
  end

  service_class do
    Class.new(Async::Service::Generic) do
      def setup(container)
        require "async/background/queue/store"
        require "async/background/queue/client"
        require "async/background/queue/socket_notifier"

        container.run(count: ENV.fetch("FORKS", 1).to_i) do |instance|
          require_relative "config/environment"

          store = Async::Background::Queue::Store.new(path: DB_PATH)
          Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
            store:    store,
            notifier: Async::Background::Queue::SocketNotifier.new(
              socket_dir:    SOCK_DIR,
              total_workers: TOTAL_BG
            )
          )

          instance.ready!
          # … start Falcon HTTP server …
        end
      end
    end
  end
end
```

### Background service — scheduler + consumer

```ruby
if TOTAL_BG > 0
  service "scheduler" do
    service_class do
      Class.new(Async::Service::Generic) do
        def setup(container)
          require "async/background/queue/store"
          require "async/background/queue/client"
          require "async/background/queue/socket_notifier"

          TOTAL_BG.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              instance.ready!

              runner = Async::Background::Runner.new(
                config_path:     Rails.root.join("config/schedule.yml"),
                job_count:       ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
                worker_index:    i + 1,
                total_workers:   TOTAL_BG,
                queue_socket_dir: SOCK_DIR,
                queue_db_path:    DB_PATH,
                metrics_shm_path: METRICS_PATH
              )

              Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
                store:    runner.queue_store,
                notifier: Async::Background::Queue::SocketNotifier.new(
                  socket_dir:    SOCK_DIR,
                  total_workers: TOTAL_BG
                )
              )

              runner.run
            end
          end
        end
      end
    end
  end
end
```

### Schema migration — one-time release step

```ruby
# bin/migrate_async_background
require "async/background/queue/client"

Async::Background::Queue.migrate!(path: ENV.fetch("QUEUE_DB_PATH"))
```

Run this once before starting new web or worker processes. It serializes
the upgrade with `BEGIN IMMEDIATE`, records the version in SQLite, and
avoids a producer doing DDL under live queue traffic. A fresh database
still self-initializes on first use for local development, but explicit
migration is the production path.

### How wake-up works

When any process enqueues a job, `SocketNotifier` sends one byte to a Unix
domain socket. The chosen worker wakes in 30–80 µs and reads from SQLite —
no polling delay. If the wake-up is lost (socket cleanup, restart) the
worker still polls every 5 seconds as a safety net.



### Queue-only worker

A recurring schedule is optional. For applications that only use
`perform_async` / `perform_in` / `perform_at`, pass `config_path: nil`:

```ruby
Async::Background::Runner.new(
  config_path:       nil,
  worker_index:      1,
  total_workers:     1,
  queue_db_path:     Rails.root.join("storage/async-background.sqlite3").to_s,
  queue_socket_dir:  "/tmp"
).run
```

A non-`nil` `config_path` stays strict: a missing or empty schedule file
raises `Async::Background::ConfigError` rather than silently disabling
recurring jobs.



### Environment variables

| Variable                        | Default                            | Description                                                              |
| ------------------------------- | ---------------------------------- | ------------------------------------------------------------------------ |
| `FORKS`                         | `1`                                | Web worker processes.                                                    |
| `BACKGROUND_FORKS`              | `0`                                | Background worker processes (`0` disables them).                         |
| `LIMIT_JOB_COUNT`               | `2`                                | Max concurrent jobs per background worker.                               |
| `QUEUE_DB_PATH`                 | `/app/tmp/queue/background.db`     | SQLite database path.                                                    |
| `QUEUE_SOCKET_DIR`              | `/app/tmp/queue/sockets`           | Directory for cross-process wake-up sockets.                             |
| `ISOLATION_FORKS`               | _empty_                            | Comma-separated worker indices excluded from queue, e.g. `1,3`.          |
| `ASYNC_BACKGROUND_METRICS_PATH` | `/tmp/async-background.shm`        | Optional shared-memory file. Mount a common path across containers.      |



&nbsp;

## Step 2.5 — Mount the optional dashboard

The dashboard is a separate, read-only Rack app over the same SQLite file.
It never enqueues, retries, deletes or otherwise mutates jobs.

Before mounting it, add its read-model indexes once in the same release
step as the queue migration:

```ruby
# bin/migrate_async_background
require "async/background/queue/client"

queue_path = ENV.fetch("QUEUE_DB_PATH")
Async::Background::Queue.migrate!(path: queue_path)
Async::Background::Queue.prepare_dashboard!(path: queue_path)
```

`prepare_dashboard!` is idempotent. It installs four dashboard-only indexes
for `done`, `failed`, `claimed` and `executing` lists. Normal queue-only
deployments do not pay this write cost.

### Rack / Falcon

```ruby
# config.ru
require "async/background/web"

Async::Background::Web.configure do |config|
  config.queue_path = ENV.fetch("QUEUE_DB_PATH", "/var/lib/app/queue.db")
  config.auth       = ->(env) { env["warden"]&.user&.admin? }

  # Optional metrics (requires async-utilization and a shared file path).
  config.metrics_path  = ENV["ASYNC_BACKGROUND_METRICS_PATH"]
  config.total_workers = ENV.fetch("BACKGROUND_FORKS", 1).to_i

  config.mount_path = "/admin/background"
  config.transport  = :sse
end

run Async::Background::Web.app
```

Add `rack` to the application bundle when it isn't already present:

```ruby
gem "rack", "~> 3.0"
```

### Rails

```ruby
# config/initializers/async_background_dashboard.rb
require "async/background/web"

Async::Background::Web.configure do |config|
  config.queue_path = ENV.fetch(
    "QUEUE_DB_PATH",
    Rails.root.join("tmp/queue/background.db").to_s
  )
  config.auth          = ->(env) { env["warden"]&.user&.admin? }
  config.metrics_path  = ENV["ASYNC_BACKGROUND_METRICS_PATH"]
  config.total_workers = ENV.fetch("BACKGROUND_FORKS", 1).to_i
  config.mount_path    = "/admin/background"
  config.transport     = :sse
end
```

```ruby
# config/routes.rb
mount Async::Background::Web.app => "/admin/background"
```

> Use an application-specific authorization predicate. The gem intentionally
> has no permissive default: a missing or falsey `auth` result returns `401`.
> Don't expose the dashboard publicly without an authentication layer.

### Live updates over SSE

SSE is the default transport. A dashboard tab opens one authenticated
`GET /api/stream` request; the server pushes a complete overview snapshot
after connect and after the queue changes. The browser does not poll on a
timer.

Each Rack process reads `PRAGMA data_version` every `stream_poll_seconds`
(default `0.5`) on its read connection. A heartbeat goes out every
`stream_heartbeat_seconds` (default `25`); reconnects use a server-supplied
delay of `stream_retry_ms` (default `5000`). No event log, no Redis.

> If the host app applies a Rack::Attack throttle to `/admin`, exempt
> authenticated dashboard reads so a long-lived stream and its initial list
> request don't count as abuse:
>
> ```ruby
> Rack::Attack.safelist("authenticated async-background dashboard") do |request|
>   request.path.start_with?("/admin/background") &&
>     request.env["warden"]&.user(:admin_user).present?
> end
> ```
>
> `config.auth` still runs for every request. If a reverse proxy buffers
> streaming responses, disable buffering for `/admin/background/api/stream`;
> the response already includes `X-Accel-Buffering: no` for nginx.

Use `config.transport = :polling` only for a server that cannot keep an SSE
response open. It's a compatibility fallback, not the recommended production mode.



&nbsp;

## Step 3 — Docker setup

> **⚠ Critical.** Skipping this causes WAL corruption in multi-process mode.

Docker's default `overlay2` filesystem does not guarantee coherence between
`write()` and `mmap()` on the same file. SQLite WAL relies on it; without
it, workers reading the WAL via `mmap` see stale bytes and corrupt the
database.

**Fix:** mount a **named volume** for the SQLite directory. Named volumes
use the host's native filesystem (ext4 / xfs / zfs) where `write()` and
`mmap()` coherence is guaranteed.

```yaml
# docker-compose.yml
services:
  web:
    build: .
    command: bundle exec falcon-host falcon.rb
    environment:
      - BACKGROUND_FORKS=2
    volumes:
      - ./my_app:/app                  # code (overlay2 — fine)
      - queue-data:/app/tmp/queue      # SQLite (ext4 — required)

volumes:
  queue-data:
```

| Setup                       | mmap     | Result                                         |
| --------------------------- | -------- | ---------------------------------------------- |
| Named volume / bind mount   | enabled  | ✅ Best performance                            |
| `overlay2` + `mmap: false`  | disabled | ✅ Safe, ~10–30 % slower reads                  |
| `overlay2` + mmap enabled   | enabled  | ❌ **WAL corruption**                          |
| Bare metal / VM             | enabled  | ✅ Best performance                            |

If you can't use a named volume, pass `mmap: false` to `Store.new` — see
[Store tuning](#appendix-store-tuning).



&nbsp;

## Step 4 — Use the queue

Once jobs are defined (Step 1) and Falcon is configured (Step 2), enqueue
from anywhere:

```ruby
# Immediate
SendEmailJob.perform_async(user_id, "welcome")

# Override timeout for this single call
SendEmailJob.perform_async(user_id, "welcome", options: { timeout: 10 })

# Delayed by N seconds
SendEmailJob.perform_in(300, user_id, "reminder")

# At a specific time
SendEmailJob.perform_at(Time.new(2026, 4, 1, 9, 0, 0), user_id, "promo")
```

**Timeout precedence:** call-site `options: { timeout: ... }` > class-level
`.options timeout: ...` > default 120 s.

If you'd rather skip the `Job` module, the lower-level API is symmetric:

```ruby
Async::Background::Queue.enqueue   (SendEmailJob, user_id, "welcome")
Async::Background::Queue.enqueue_in(300,                SendEmailJob, user_id, "reminder")
Async::Background::Queue.enqueue_at(Time.new(2026,4,1,9), SendEmailJob, user_id, "promo")
```

### Retries (queue jobs only)

```ruby
class SendWebhookJob
  include Async::Background::Job
  options timeout: 30, retry: 5, retry_delay: 10, backoff: :exponential

  def perform(endpoint_id) = Endpoint.find(endpoint_id).deliver!
end
```

| Option        | Meaning                                                       | Default                              |
| ------------- | ------------------------------------------------------------- | ------------------------------------ |
| `retry`       | Max retry attempts after the initial run. `0` disables.       | `0`                                  |
| `retry_delay` | Base delay in seconds. Required when `retry > 0`.             | —                                    |
| `backoff`     | `:fixed`, `:linear`, or `:exponential`.                       | `:fixed`                             |
| `jitter`      | Random factor in `[0, 1]`. `delay × (1 + rand × jitter)`.     | `0.5` for `:exponential`, `0` else.  |

Delay formulas (for `retry_delay: 10`, attempt `n`, before jitter):

| Strategy        | Formula     |
| --------------- | ----------- |
| `:fixed`        | `10`        |
| `:linear`       | `10 × n`    |
| `:exponential`  | `10 × 2^(n-1)` |

Call-site overrides work the same way:

```ruby
SendWebhookJob.perform_async(id, options: { retry: 10, backoff: :linear })

# nil keeps the class-level value:
SendWebhookJob.perform_async(id, options: { retry: nil })  # still retries 5 times
```

> Retries apply to **queue jobs only** — `perform_async` / `perform_in` /
> `perform_at`. Cron and interval jobs from `schedule.yml` are not retried;
> they simply run again at the next tick.

### Job lifecycle

```
pending → running → done
                  → failed
```

- **Recovery.** Stale `running` jobs are requeued as `pending` on worker restart.
- **Cleanup.** Completed jobs older than 1 hour are deleted every 5 minutes
  (piggybacked on `fetch`).
- **Polling fallback.** Wake-up over a Unix socket is the fast path. If a
  notification is missed, workers poll every 5 seconds (`QUEUE_POLL_INTERVAL`).
- **Worker isolation.** `ISOLATION_FORKS=1,3` excludes specific workers from
  queue processing — they only run scheduled cron / interval jobs.



&nbsp;

---

## Appendix: store tuning

`Store.new` accepts an `options:` hash that controls SQLite tuning.
**Defaults are calibrated for typical job-queue workloads — most users
never need to touch these.** The knobs exist for cases where you've
measured a real bottleneck.

```ruby
Async::Background::Queue::Store.new(
  path: db_path,
  options: {
    mmap:               true,     # default: true
    synchronous:        :normal,  # default: :normal
    wal_autocheckpoint: :auto     # default: :auto
  }
)
```

All three values are validated at construction time — bad inputs raise
`ArgumentError` immediately, not silently at runtime.

### `mmap` — memory-mapped I/O

| Value            | Effect                                                                |
| ---------------- | --------------------------------------------------------------------- |
| `true` (default) | Maps up to 256 MB of the DB file into process memory; lower fetch latency. |
| `false`          | Falls back to `read()` / `write()` syscalls.                          |

Disable when:

- You're on Docker `overlay2` without a named volume (mmap incoherence corrupts WAL).
- You're on NFS or another network filesystem (locking semantics are unreliable; SQLite shouldn't really live there at all).
- You're running a 32-bit process (256 MB eats a meaningful slice of address space).

Cost of disabling: ~10–30 % on fetch throughput against hot data. Worth it
for safety on incompatible storage.

### `synchronous` — durability vs throughput

Controls how aggressively SQLite calls `fsync()` on commits.

| Value               | PRAGMA   | What you risk on power loss                                              |
| ------------------- | -------- | ------------------------------------------------------------------------ |
| `:normal` (default) | `NORMAL` | The last few committed transactions if the OS crashes between checkpoints. SIGKILL is safe. Recommended for queues. |
| `:full`             | `FULL`   | Nothing — every commit is fsync'd. For financial / audit workloads.      |
| `:extra`            | `EXTRA`  | Same as `:full` plus extra fsync on directory metadata. Marginal gain.   |

`:normal` → `:full` typically means **2–5×** lower enqueue throughput
because every commit waits for disk fsync. Don't pay this unless you
actually need it.

> `:off` is intentionally not exposed. For a job queue it sacrifices
> durability with no real win, and the failure mode (corrupted WAL) is
> worse than just lost data.

### `wal_autocheckpoint` — checkpoint frequency

| Value                | Effect                                                                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `:auto` (default)    | SQLite's built-in default of 1000 pages. Safe and balanced for almost everyone.                                                       |
| `100..1000`          | Frequent checkpoints. Smaller WAL, faster recovery, smoother latency, more total fsync overhead.                                      |
| `1000..10_000`       | Rarer checkpoints. Higher peak throughput on write-heavy bursts, bigger WAL (up to ~40 MB at 10 000), occasional latency spikes.       |

Tune only when you've **measured** that enqueue throughput is the
bottleneck. Below 100 SQLite thrashes on checkpoints; above 10 000 the WAL
approaches `journal_size_limit` (64 MB) and crash recovery starts taking
visible time. Both bounds are enforced.

### What's not exposed (and why)

`cache_size`, `journal_size_limit`, `busy_timeout`, `temp_store` and friends
are set to sensible internal values (16 MB cache, 64 MB WAL limit, 5 s busy
timeout, in-memory temp store) and changing them without measuring rarely
helps. If you've genuinely hit a wall where one of these matters, open an
issue — that's a real signal the knob deserves to exist.



&nbsp;

---

## Appendix: optional metrics

Install `async-utilization` only in applications that need worker metrics:

```ruby
gem "async-utilization", ">= 0.3", "< 0.5"
```

The queue and scheduler don't depend on it. With the gem absent,
`runner.metrics.enabled?` is `false` and
`Async::Background::Metrics.read_all(...)` returns `[]`. When web and
background run in separate containers, point
`ASYNC_BACKGROUND_METRICS_PATH` at a file under a shared volume (for
example `/app/tmp/queue/async-background.shm`).



&nbsp;

---

## Appendix: minimal example

One process, no Docker, no Rails. Define your job (Step 1), then:

```ruby
require "async/background"

store    = Async::Background::Queue::Store.new(path: "tmp/jobs.db")
store.ensure_database!

notifier = Async::Background::Queue::Notifier.new
client   = Async::Background::Queue::Client.new(store: store, notifier: notifier)

Async::Background::Queue.default_client = client

# Enqueue
SendEmailJob.perform_async(123, "welcome")
SendEmailJob.perform_in(60, 123, "reminder")

# Run the worker (cron + interval jobs + queue consumer)
Async::Background::Runner.new(
  config_path:   "config/schedule.yml",
  job_count:     2,
  worker_index:  1,
  total_workers: 1
).run
```
