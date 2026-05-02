# Get Started

A four-step walkthrough: define jobs, configure Falcon, deploy on Docker, and use the dynamic queue.

---

## Step 1 — Define your jobs

Every job is a plain Ruby class that includes `Async::Background::Job` and implements `#perform`.

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

`SyncProductsJob`, `DailyReportJob`, and `HeavyImportJob` are defined the same way as `SendEmailJob` above — class with `include Async::Background::Job` and a `#perform` method.

> **Tip — class-level options.** Override the default 120 s timeout, enable retries, etc. with `.options`:
>
> ```ruby
> class HeavySyncJob
>   include Async::Background::Job
>   options timeout: 300, retry: 3, retry_delay: 10, backoff: :exponential
>
>   def perform(account_id) = Account.find(account_id).full_sync!
> end
> ```
>
> See [Retries](#retries-queue-jobs-only) below for the full retry option list.

---

&nbsp;

## Step 2 — Configure Falcon

A single `falcon.rb` defines three things: the web server, the background scheduler, and how web workers enqueue into the same SQLite queue.

```ruby
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/generic"

TOTAL_BG  = ENV.fetch("BACKGROUND_FORKS", 0).to_i
DB_PATH   = ENV.fetch("QUEUE_DB_PATH",     "/app/tmp/queue/background.db")
SOCK_DIR  = ENV.fetch("QUEUE_SOCKET_DIR",  "/app/tmp/queue/sockets")

# ── Web server (also enqueues into the queue) ──
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
          # ... start Falcon HTTP server ...
        end
      end
    end
  end
end

# ── Background scheduler (cron + interval + queue consumer) ──
if TOTAL_BG > 0
  service "scheduler" do
    service_class do
      Class.new(Async::Service::Generic) do
        def setup(container)
          require "async/background/queue/store"
          require "async/background/queue/client"
          require "async/background/queue/socket_notifier"

          # Pre-fork: create schema once, then close.
          # SQLite connections must NOT survive across fork().
          Async::Background::Queue::Store.new(path: DB_PATH).tap(&:ensure_database!).close

          TOTAL_BG.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              instance.ready!

              runner = Async::Background::Runner.new(
                config_path:      Rails.root.join("config/schedule.yml"),
                job_count:        ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
                worker_index:     i + 1,
                total_workers:    TOTAL_BG,
                queue_socket_dir: SOCK_DIR,
                queue_db_path:    DB_PATH
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

That's the full config — both web and scheduler share the same SQLite file and notify each other through Unix domain sockets. Web controllers can now enqueue:

```ruby
class UsersController < ApplicationController
  def create
    @user = User.create!(user_params)
    SendEmailJob.perform_async(@user.id, "welcome")
    redirect_to @user
  end
end
```

> **How wake-up works.** When any process (web or scheduler) enqueues a job, `SocketNotifier` sends one byte to a Unix domain socket. The chosen background worker wakes in ~30–80 µs and reads from SQLite — no polling delay.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `FORKS` | `1` | Web worker processes |
| `BACKGROUND_FORKS` | `0` | Background worker processes (`0` disables them) |
| `LIMIT_JOB_COUNT` | `2` | Max concurrent jobs per background worker |
| `QUEUE_DB_PATH` | `/app/tmp/queue/background.db` | SQLite database path |
| `QUEUE_SOCKET_DIR` | `/app/tmp/queue/sockets` | Directory for cross-process wake-up sockets |
| `ISOLATION_FORKS` | _(empty)_ | Comma-separated worker indices excluded from queue (e.g. `1,3`) |

---

&nbsp;

## Step 3 — Docker setup

> **⚠ Critical.** Skipping this causes WAL corruption in multi-process mode.

Docker's default `overlay2` filesystem does not guarantee coherence between `write()` and `mmap()` on the same file. SQLite WAL relies on it; without it, workers reading the WAL via `mmap` see stale bytes and corrupt the database.

**Fix:** mount a **named volume** for the SQLite directory. Named volumes use the host's native filesystem (ext4/xfs/zfs) where `write()`/`mmap()` coherence is guaranteed.

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

| Setup | mmap | Result |
|---|---|---|
| Named volume / bind mount | enabled | ✅ Best performance |
| `overlay2` + `mmap: false` | disabled | ✅ Safe, ~10–30% slower reads |
| `overlay2` + mmap enabled | enabled | ❌ **WAL corruption** |
| Bare metal / VM | enabled | ✅ Best performance |

> **No named volume?** Pass `mmap: false` to `Store.new` — see [Store tuning](#store-tuning-advanced) below. This forces SQLite to use `read()`/`write()` syscalls instead of mmap.

---

&nbsp;

## Step 4 — Use the queue

Once your jobs are defined (Step 1) and Falcon is configured (Step 2), enqueue from anywhere:

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

> **Timeout precedence.** Call-site `options: { timeout: ... }` > class-level `.options timeout: ...` > default 120 s.

If you'd rather skip the `Job` module, the lower-level API is symmetric:

```ruby
Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")
Async::Background::Queue.enqueue_in(300, SendEmailJob, user_id, "reminder")
Async::Background::Queue.enqueue_at(Time.new(2026, 4, 1, 9), SendEmailJob, user_id, "promo")
```

### Retries (queue jobs only)

Queue jobs can opt into automatic retries on failure or timeout:

```ruby
class SendWebhookJob
  include Async::Background::Job
  options timeout: 30, retry: 5, retry_delay: 10, backoff: :exponential

  def perform(endpoint_id) = Endpoint.find(endpoint_id).deliver!
end
```

| Option | Meaning | Default |
|---|---|---|
| `retry` | max retry attempts after the initial run (`0` disables) | `0` |
| `retry_delay` | base delay in seconds; required when `retry > 0` | — |
| `backoff` | `:fixed`, `:linear`, or `:exponential` | `:fixed` |
| `jitter` | random factor in `[0, 1]`; delay × `(1 + rand * jitter)` | `0.5` for `:exponential`, `0` otherwise |

Delay formulas (for `retry_delay: 10`, attempt `n`, before jitter):

- `:fixed` → `10`
- `:linear` → `10 * n`
- `:exponential` → `10 * 2^(n-1)`

Call-site overrides work the same way:

```ruby
SendWebhookJob.perform_async(id, options: { retry: 10, backoff: :linear })

# `nil` keeps the class-level value:
SendWebhookJob.perform_async(id, options: { retry: nil })  # still retries 5 times
```

> **Note.** Retries apply to queue jobs only (`perform_async` / `perform_in` / `perform_at`). Cron and interval jobs from `schedule.yml` are not retried — they simply run again at their next tick.

### Job lifecycle

```
pending → running → done
                  → failed
```

- **Recovery.** On worker restart, stale `running` jobs are automatically requeued as `pending`.
- **Cleanup.** Completed jobs older than 1 hour are deleted every 5 minutes (piggybacked on `fetch`).
- **Polling fallback.** Wake-up via Unix socket is the fast path; if a notification is missed, workers poll every 5 seconds (`QUEUE_POLL_INTERVAL`).
- **Worker isolation.** `ISOLATION_FORKS=1,3` excludes specific workers from queue processing — they only run scheduled cron/interval jobs.

---

## Store tuning (advanced)

`Store.new` accepts an `options:` hash that controls SQLite tuning. **Defaults are calibrated for typical job-queue workloads — most users never need to touch these.** The knobs exist for cases where you've measured a real bottleneck.

```ruby
Async::Background::Queue::Store.new(
  path: db_path,
  options: {
    mmap:               true,     # default: true
    synchronous:        :normal,  # default: :normal
    wal_autocheckpoint: :auto     # default: :auto (use SQLite's built-in 1000)
  }
)
```

All three values are validated at construction time — bad inputs raise `ArgumentError` immediately, not silently at runtime.

### `mmap` — memory-mapped I/O

| Value | Effect |
|---|---|
| `true` (default) | Maps up to 256 MB of the DB file into process memory; lower fetch latency on hot data |
| `false` | Falls back to `read()`/`write()` syscalls |

> **When to disable.**
> – Docker `overlay2` without a named volume (mmap incoherence corrupts WAL)
> – NFS or other network filesystems (locking semantics are unreliable; SQLite shouldn't really live there at all)
> – 32-bit processes (256 MB eats a meaningful slice of address space)

> **Cost of disabling.** ~10–30 % on fetch throughput against hot data. Worth it for safety on incompatible storage.

### `synchronous` — durability vs throughput

Controls how aggressively SQLite calls `fsync()` on commits. WAL mode means this only affects when WAL pages are forced to disk, not the WAL append itself.

| Value | PRAGMA | What you risk on power loss |
|---|---|---|
| `:normal` (default) | `NORMAL` | Last few committed transactions if the OS crashes between checkpoints. SIGKILL is safe. Recommended for queues — retries handle this edge case |
| `:full` | `FULL` | Nothing — every commit is fsync'd. Use for financial / audit workloads where individual job loss is unacceptable |
| `:extra` | `EXTRA` | Same as `:full` plus extra fsync on directory metadata. Marginal gain on most filesystems |

> **Cost of upgrading.** `:normal` → `:full` typically means **2–5×** lower enqueue throughput because every commit waits for disk fsync. Don't pay this unless you actually need it.

> `:off` is intentionally not exposed. For a job queue it sacrifices durability with no real win, and the failure mode (corrupted WAL) is much worse than just lost data.

### `wal_autocheckpoint` — checkpoint frequency

Number of pages SQLite accumulates in WAL before automatically running a checkpoint (folding WAL back into the main DB file).

| Value | Effect |
|---|---|
| `:auto` (default) | SQLite's built-in default of 1000 pages. Don't emit a `PRAGMA` — let the engine decide. Safe and balanced for almost everyone |
| `100..1000` | Frequent checkpoints. Smaller WAL, faster recovery, smoother latency, but more total fsync overhead |
| `1000..10_000` | Rarer checkpoints. Higher peak throughput on write-heavy bursts, bigger WAL (up to ~40 MB at 10000), occasional latency spikes when checkpoints do run |

> **When to tune.** You've **measured** enqueue throughput and it's the bottleneck, your sustained write rate fits in a bigger WAL window, and you can tolerate occasional checkpoint latency spikes. If any of those is "I'm not sure" — stay on `:auto`.

> **Why bounded.** Below 100 SQLite thrashes on checkpoints; above 10 000 the WAL approaches `journal_size_limit` (64 MB) and crash recovery starts taking visible time. Both bounds are enforced.

### What's not exposed (and why)

The library deliberately doesn't surface `cache_size`, `journal_size_limit`, `busy_timeout`, `temp_store`, etc. as user options. They're set to sensible internal values (16 MB cache, 64 MB WAL limit, 5 s busy timeout, in-memory temp store) and changing them without measuring rarely helps. If you've genuinely hit a wall where one of these matters, open an issue — that's a real signal that the knob deserves to exist.

---

## Minimal example (no Docker, no Rails)

For a one-process setup or quick experiments. Define your job (Step 1), then:

```ruby
require "async/background"

# Queue + scheduler in one process
store    = Async::Background::Queue::Store.new(path: "tmp/jobs.db")
store.ensure_database!
notifier = Async::Background::Queue::Notifier.new
client   = Async::Background::Queue::Client.new(store: store, notifier: notifier)

Async::Background::Queue.default_client = client

# Enqueue
SendEmailJob.perform_async(123, "welcome")
SendEmailJob.perform_in(60, 123, "reminder")

# Run the worker (cron / interval jobs from config/schedule.yml + queue consumer)
Async::Background::Runner.new(
  config_path:   "config/schedule.yml",
  job_count:     2,
  worker_index:  1,
  total_workers: 1
).run
```
