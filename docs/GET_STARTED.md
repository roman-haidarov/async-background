# Get started

A walkthrough from zero to a running app with cron jobs, a dynamic queue,
and an optional read-only dashboard. Web can sit on Falcon or Itsi;
background workers are separate processes either way.

1. [Define your jobs](#step-1--define-your-jobs)
2. [Run web and workers](#step-2--run-web-and-workers)
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

## Step 2 — Run web and workers

Web processes only enqueue. Background workers run `Runner#run` under a
`Fiber.scheduler`. Falcon can supervise workers as extra services next to
its rack process. Itsi is a preforking HTTP server — it does not supervise
background processes — so workers are their own OS processes with
`Itsi::Scheduler`.

Do not start `Runner#run` inside an Itsi HTTP worker (`after_fork` or a
request thread). That process already owns the scheduler.

> Schema migration belongs in the deploy release step
> (`bin/migrate_async_background` below), **before** any web or worker
> process starts. Don't call it from a service boot hook.

### Shared paths

Read these from ENV in `falcon.rb`, `Itsi.rb`, and `bin/async_background`.
The values must match across web and workers.

```ruby
TOTAL_BG     = ENV.fetch("BACKGROUND_FORKS", "0").to_i
DB_PATH      = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
SOCK_DIR     = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")
METRICS_PATH = ENV.fetch("ASYNC_BACKGROUND_METRICS_PATH", "/app/tmp/queue/async-background.shm")
```

### Producer — install the queue client

`perform_async` needs `Queue.default_client`. Install it once per process
that enqueues, after the app boots and **after fork**.

Rails: `config/initializers/async_background.rb` is enough when each
process loads `config/environment` after fork (Falcon `container.run`,
Itsi `after_fork`). A long-lived SQLite handle must not be inherited
across `fork`.

```ruby
require "async/background/queue/store"
require "async/background/queue/client"
require "async/background/queue/socket_notifier"

store = Async::Background::Queue::Store.new(path: DB_PATH)
Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
  store:    store,
  notifier: Async::Background::Queue::SocketNotifier.new(
    socket_dir:    SOCK_DIR,
    total_workers: TOTAL_BG
  )
)
```

Without a client, `perform_async` raises `Async::Background::Queue not configured`.

### Web — Falcon (HTTP only)

Use Falcon's own rack service for HTTP. Do **not** replace
`Falcon::Environment::Rack` with `Async::Service::Generic` — Generic does
not start an HTTP server.

```ruby
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/generic"

TOTAL_BG     = ENV.fetch("BACKGROUND_FORKS", "0").to_i
DB_PATH      = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
SOCK_DIR     = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")
METRICS_PATH = ENV.fetch("ASYNC_BACKGROUND_METRICS_PATH", "/app/tmp/queue/async-background.shm")

service "web" do
  include Falcon::Environment::Rack

  count ENV.fetch("FORKS", 1).to_i
  # rackup_path defaults to ./config.ru

  endpoint do
    Async::HTTP::Endpoint.parse(
      "http://#{ENV.fetch('APP_HOST', '0.0.0.0')}:#{ENV.fetch('APP_PORT', 3000)}"
    )
  end
end
```

Wire the producer in the initializer (or at the top of `config.ru` after
the app is loaded). Falcon already has an Async reactor in that process.

### Background — Falcon (consumer)

```ruby
if TOTAL_BG > 0
  service "scheduler" do
    service_class do
      Class.new(Async::Service::Generic) do
        def setup(container)
          TOTAL_BG.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              instance.ready!

              runner = Async::Background::Runner.new(
                config_path:      Rails.root.join("config/schedule.yml"),
                job_count:        ENV.fetch("LIMIT_JOB_COUNT", "2").to_i,
                worker_index:     i + 1,
                total_workers:    TOTAL_BG,
                queue_socket_dir: SOCK_DIR,
                queue_db_path:    DB_PATH,
                metrics_shm_path: METRICS_PATH
              )

              # Optional: workers that also enqueue.
              Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
                store:    runner.queue_store,
                notifier: Async::Background::Queue::SocketNotifier.new(
                  socket_dir:    SOCK_DIR,
                  total_workers: TOTAL_BG
                )
              )

              Async { runner.run }
            end
          end
        end
      end
    end
  end
end
```

`queue_socket_dir` is what turns the queue listener on. Without it the
process only runs `schedule.yml`. `drain_timeout:` defaults to 30s; pass
`nil` for an unbounded shutdown wait.

### Itsi — HTTP server + separate worker processes

Itsi is a [preforking HTTP server](https://itsi.fyi/options/workers/).
`workers N` are request processes. [`fiber_scheduler true`](https://itsi.fyi/options/fiber_scheduler/)
puts `Itsi::Scheduler` on those request threads. There is no Falcon-style
`service "scheduler"`. [`after_fork`](https://itsi.fyi/options/after_fork/)
is the place to install the **producer**, not `Runner#run`.

Workers need `itsi-scheduler`. The full `itsi` gem is only for the HTTP
server.

```ruby
# Gemfile
gem "itsi"             # web process
gem "itsi-scheduler"   # worker processes (can be the same bundle)
gem "sqlite3", "~> 2.0"
```

#### Web — Itsi.rb (producer only)

```ruby
# Itsi.rb
fiber_scheduler true
workers ENV.fetch("FORKS", "1").to_i
bind "http://0.0.0.0:#{ENV.fetch('APP_PORT', 3000)}"
rackup_file "config.ru"

after_fork do
  require_relative "config/environment"
  require "async/background/queue/store"
  require "async/background/queue/client"
  require "async/background/queue/socket_notifier"

  total    = ENV.fetch("BACKGROUND_FORKS", "0").to_i
  db_path  = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
  sock_dir = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")

  store = Async::Background::Queue::Store.new(path: db_path)
  Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
    store:    store,
    notifier: Async::Background::Queue::SocketNotifier.new(
      socket_dir:    sock_dir,
      total_workers: total
    )
  )
end
```

Itsi picks up `config.ru` if `Itsi.rb` is omitted; you need this file once
`after_fork` has to wire the queue client.

#### Workers — dedicated processes

Each consumer is its own process with a unique `WORKER_INDEX` in
`1..BACKGROUND_FORKS`. `Scheduler.run` installs `Itsi::Scheduler` on the
current thread. Set `ASYNC_BACKGROUND_SCHEDULER_THREAD=1` to run it on a
dedicated thread instead. If both `async` and `itsi-scheduler` are in the
bundle, `auto` picks `async` — Itsi workers must set the ENV:

```ruby
# bin/async_background
require_relative "../config/environment"
require "async/background"
require "async/background/scheduler"

index = Integer(ENV.fetch("WORKER_INDEX"))
total = Integer(ENV.fetch("BACKGROUND_FORKS"))
db_path      = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
sock_dir     = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")
metrics_path = ENV.fetch("ASYNC_BACKGROUND_METRICS_PATH", "/app/tmp/queue/async-background.shm")

runner = Async::Background::Runner.new(
  config_path:      Rails.root.join("config/schedule.yml"),
  job_count:        ENV.fetch("LIMIT_JOB_COUNT", "2").to_i,
  worker_index:     index,
  total_workers:    total,
  queue_socket_dir: sock_dir,
  queue_db_path:    db_path,
  metrics_shm_path: metrics_path
)

# ASYNC_BACKGROUND_SCHEDULER=itsi
Async::Background::Scheduler.run { runner.run }
```

`Runner#run` already traps `INT`/`TERM`. Extra `Signal.trap` in the bin
is optional.

```bash
export QUEUE_DB_PATH=/app/tmp/queue/background.db
export QUEUE_SOCKET_DIR=/app/tmp/queue/sockets
export BACKGROUND_FORKS=2
export ASYNC_BACKGROUND_SCHEDULER=itsi

WORKER_INDEX=1 bundle exec ruby bin/async_background
WORKER_INDEX=2 bundle exec ruby bin/async_background
```

Supervise those processes yourself (systemd, Docker, Kamal). Compose
`scale` does not assign unique `WORKER_INDEX` values — declare one
service per index, or a tiny wrapper that reads the replica slot.

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
require "async/background/scheduler"

runner = Async::Background::Runner.new(
  config_path:       nil,
  worker_index:      1,
  total_workers:     1,
  queue_db_path:     Rails.root.join("storage/async-background.sqlite3").to_s,
  queue_socket_dir:  "/tmp"
)
Async::Background::Scheduler.run { runner.run }
```

A non-`nil` `config_path` stays strict: a missing or empty schedule file
raises `Async::Background::ConfigError` rather than silently disabling
recurring jobs.



### Environment variables

| Variable                        | Default                            | Description                                                              |
| ------------------------------- | ---------------------------------- | ------------------------------------------------------------------------ |
| `FORKS`                         | `1`                                | Web worker processes.                                                    |
| `BACKGROUND_FORKS`              | `0`                                | Background worker processes (`0` disables them).                         |
| `WORKER_INDEX`                  | —                                  | This process's worker index (`1..BACKGROUND_FORKS`). Itsi workers only.  |
| `LIMIT_JOB_COUNT`               | `2`                                | Max concurrent jobs per background worker.                               |
| `QUEUE_DB_PATH`                 | `/app/tmp/queue/background.db`     | SQLite database path.                                                    |
| `QUEUE_SOCKET_DIR`              | `/app/tmp/queue/sockets`           | Directory for cross-process wake-up sockets.                             |
| `ISOLATION_FORKS`               | _empty_                            | Comma-separated worker indices excluded from queue, e.g. `1,3`.          |
| `ASYNC_BACKGROUND_METRICS_PATH` | `/tmp/async-background.shm`        | Optional shared-memory file. Mount a common path across containers.      |
| `ASYNC_BACKGROUND_SCHEDULER`    | `auto`                             | Used only by `Scheduler.run`: `async`, `itsi`, or `auto`. `auto` prefers `async` if both gems are present. |
| `ASYNC_BACKGROUND_SCHEDULER_THREAD` | _empty_                        | `1` runs the itsi scheduler on a dedicated thread instead of the current one. |



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
# docker-compose.yml — Falcon supervises web + workers in one process tree
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

Itsi needs a web service plus one container per worker index:

```yaml
services:
  web:
    command: bundle exec itsi
    environment:
      BACKGROUND_FORKS: "2"
      QUEUE_DB_PATH: /app/tmp/queue/background.db
      QUEUE_SOCKET_DIR: /app/tmp/queue/sockets
    volumes:
      - ./my_app:/app
      - queue-data:/app/tmp/queue

  worker-1: &worker
    command: bundle exec ruby bin/async_background
    environment:
      ASYNC_BACKGROUND_SCHEDULER: itsi
      BACKGROUND_FORKS: "2"
      WORKER_INDEX: "1"
      QUEUE_DB_PATH: /app/tmp/queue/background.db
      QUEUE_SOCKET_DIR: /app/tmp/queue/sockets
    volumes:
      - ./my_app:/app
      - queue-data:/app/tmp/queue

  worker-2:
    <<: *worker
    environment:
      ASYNC_BACKGROUND_SCHEDULER: itsi
      BACKGROUND_FORKS: "2"
      WORKER_INDEX: "2"
      QUEUE_DB_PATH: /app/tmp/queue/background.db
      QUEUE_SOCKET_DIR: /app/tmp/queue/sockets

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

Once jobs are defined (Step 1) and workers are running (Step 2), enqueue
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
- **Cleanup.** `done` jobs older than 1 hour are deleted every 5 minutes
  (piggybacked on `fetch`). `failed` jobs are kept for 7 days.
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
    wal_autocheckpoint: 1_000     # default: 1_000 (pages)
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
| `1_000` (default)    | SQLite's usual 1000-page checkpoint. Safe and balanced for almost everyone. `:auto` is not accepted.                                  |
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
require "async/background/queue/socket_notifier"
require "async/background/scheduler"
require "fileutils"

FileUtils.mkdir_p("tmp/sockets")

store = Async::Background::Queue::Store.new(path: "tmp/jobs.db")
store.ensure_database!

Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
  store:    store,
  notifier: Async::Background::Queue::SocketNotifier.new(
    socket_dir:    "tmp/sockets",
    total_workers: 1
  )
)

SendEmailJob.perform_async(123, "welcome")
SendEmailJob.perform_in(60, 123, "reminder")

# queue_socket_dir turns the SQLite listener on. Without it the runner
# only executes schedule.yml and never claims perform_async jobs.
runner = Async::Background::Runner.new(
  config_path:      "config/schedule.yml",
  job_count:        2,
  worker_index:     1,
  total_workers:    1,
  queue_db_path:    "tmp/jobs.db",
  queue_socket_dir: "tmp/sockets"
)
Async::Background::Scheduler.run { runner.run }
```
