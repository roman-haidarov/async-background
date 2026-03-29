# Get Started

## Step 1: Schedule Config

Create `config/schedule.yml`:

```yaml
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

Each job class must implement `.perform_now`:

```ruby
class SyncProductsJob
  def self.perform_now
    Product.sync_all
  end
end
```

---

## Step 2: Falcon Config

Create `falcon.rb` in your project root:

```ruby
#!/usr/bin/env -S falcon-host
# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/generic"

# ── Web server ──
service "web" do
  include Falcon::Environment::Rack

  count ENV.fetch("FORKS", 1).to_i

  endpoint do
    host = ENV.fetch("APP_HOST", "0.0.0.0")
    port = ENV.fetch("APP_PORT", 3000)
    Async::HTTP::Endpoint.parse("http://#{host}:#{port}")
  end
end

# ── Background scheduler ──
if ENV.fetch("BACKGROUND_FORKS", 0).to_i > 0
  service "scheduler" do
    service_class do
      Class.new(Async::Service::Generic) do
        def setup(container)
          require "async/background/queue/notifier"
          require "async/background/queue/store"
          require "async/background/queue/client"

          total   = ENV.fetch("BACKGROUND_FORKS", 2).to_i
          db_path = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")

          queue_notifier = Async::Background::Queue::Notifier.new

          # Pre-fork: create schema only, then close.
          # SQLite connections must NOT survive across fork().
          store = Async::Background::Queue::Store.new(path: db_path)
          store.ensure_database!
          store.close

          Async::Background::Queue.default_client = nil

          total.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              queue_notifier.for_consumer!
              instance.ready!

              runner = Async::Background::Runner.new(
                config_path:    Rails.root.join("config/schedule.yml"),
                job_count:      ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
                worker_index:   i + 1,
                total_workers:  total,
                queue_notifier: queue_notifier,
                queue_db_path:  db_path
              )

              Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
                store: runner.queue_store, notifier: queue_notifier
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

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `FORKS` | 1 | Number of web worker processes |
| `BACKGROUND_FORKS` | 0 | Number of background scheduler processes (0 = disabled) |
| `LIMIT_JOB_COUNT` | 2 | Max concurrent jobs per worker |
| `QUEUE_DB_PATH` | `/app/tmp/queue/background.db` | Path to SQLite database |
| `ISOLATION_FORKS` | (empty) | Comma-separated worker indices to exclude from queue (e.g. `1,3`) |

---

## Step 3: Docker

> **⚠️ This step is critical.** Skipping it will cause database crashes in multi-process mode.

### Why

Docker uses the `overlay2` filesystem for container storage by default. `overlay2` does not guarantee coherence between `write()` and `mmap()` on the same file. SQLite WAL relies on this coherence — without it, workers reading the WAL via `mmap` may see stale data from another worker's `write()`, leading to corruption.

### Fix

Mount a **named volume** for the SQLite database directory. Named volumes use the host's native filesystem (ext4/xfs) where POSIX `write()`/`mmap()` coherence is guaranteed.

```yaml
# docker-compose.yml
services:
  web:
    build: .
    command: bundle exec falcon-host falcon.rb
    environment:
      - BACKGROUND_FORKS=2
      - QUEUE_DB_PATH=/app/tmp/queue/background.db
    volumes:
      - ./my_app:/app                  # code (overlay2 — fine)
      - queue-data:/app/tmp/queue      # SQLite (ext4 — required)

volumes:
  queue-data:
```

### If you can't use a named volume

Set `mmap_size = 0` in the `PRAGMAS` constant of `Queue::Store`. This forces SQLite to use `read()` instead of `mmap`, which is safe on `overlay2` but slower for read-heavy workloads.

### Quick reference

| Setup | `mmap_size` | Works? |
|---|---|---|
| Named volume / bind mount | 256 MB | ✅ Best performance |
| `overlay2` + `mmap_size = 0` | 0 | ✅ Safe, slower reads |
| `overlay2` + `mmap_size > 0` | any | ❌ **WAL corruption** |
| Bare metal / VM | 256 MB | ✅ Best performance |

---

## Step 4: Dynamic Queue (Optional)

Enqueue jobs at runtime from any part of your application:

```ruby
# Job class — same interface as scheduled jobs
class SendEmailJob
  def self.perform_now(user_id, template)
    user = User.find(user_id)
    Mailer.send(user, template)
  end
end

# Enqueue from a web request, console, rake task, etc.
Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")

# Also accepts class name as a string
Async::Background::Queue.enqueue("SendEmailJob", user_id, "welcome")
```

### Job lifecycle

```
pending → running → done
                  → failed
```

- **Recovery:** On worker restart, stale `running` jobs are automatically requeued as `pending`.
- **Cleanup:** Completed jobs older than 1 hour are deleted every 5 minutes (piggyback on fetch).
- **Timeout:** Queue jobs use the default timeout of 30 seconds.

### Worker isolation

Exclude specific workers from queue processing:

```bash
# Workers 1 and 3 only run scheduled cron/interval jobs
ISOLATION_FORKS=1,3
```

---

## Minimal Example (without Docker/Rails)

```ruby
require "async/background"

Async::Background::Runner.new(
  config_path:   "config/schedule.yml",
  job_count:     2,
  worker_index:  1,
  total_workers: 1
).run
```

This is all you need for a single-process setup with no dynamic queue.
