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

Each job class must include `Async::Background::Job` and implement `#perform`:

```ruby
class SyncProductsJob
  include Async::Background::Job

  def perform
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
          require "async/background/queue/store"
          require "async/background/queue/client"
          require "async/background/queue/socket_notifier"

          total       = ENV.fetch("BACKGROUND_FORKS", 2).to_i
          db_path     = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
          socket_dir  = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")

          # Pre-fork: create schema only, then close.
          # SQLite connections must NOT survive across fork().
          store = Async::Background::Queue::Store.new(path: db_path)
          store.ensure_database!
          store.close

          total.times do |i|
            container.run(count: 1, restart: true) do |instance|
              require_relative "config/environment"
              require "async/background"

              instance.ready!

              runner = Async::Background::Runner.new(
                config_path:      Rails.root.join("config/schedule.yml"),
                job_count:        ENV.fetch("LIMIT_JOB_COUNT", 2).to_i,
                worker_index:     i + 1,
                total_workers:    total,
                queue_socket_dir: socket_dir,
                queue_db_path:    db_path
              )

              # Client uses SocketNotifier to wake up all workers via Unix sockets
              Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
                store: runner.queue_store,
                notifier: Async::Background::Queue::SocketNotifier.new(
                  socket_dir: socket_dir,
                  total_workers: total
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

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `FORKS` | 1 | Number of web worker processes |
| `BACKGROUND_FORKS` | 0 | Number of background scheduler processes (0 = disabled) |
| `LIMIT_JOB_COUNT` | 2 | Max concurrent jobs per worker |
| `QUEUE_DB_PATH` | `/app/tmp/queue/background.db` | Path to SQLite database |
| `QUEUE_SOCKET_DIR` | `/app/tmp/queue/sockets` | Directory for Unix domain sockets (cross-process notifications) |
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

## Step 4: Dynamic Queue

Enqueue jobs at runtime from any part of your application.

### Using the Job module (recommended)

Include `Async::Background::Job` for a familiar Sidekiq-like API:

```ruby
class SendEmailJob
  include Async::Background::Job

  def perform(user_id, template)
    user = User.find(user_id)
    Mailer.send(user, template)
  end
end
```

Now you have three ways to enqueue:

```ruby
# Immediate — executes as soon as a worker picks it up
SendEmailJob.perform_async(user_id, "welcome")

# Delayed — executes after N seconds
SendEmailJob.perform_in(300, user_id, "reminder")       # in 5 minutes
SendEmailJob.perform_in(3600, user_id, "follow_up")     # in 1 hour

# Scheduled — executes at a specific time
SendEmailJob.perform_at(Time.new(2026, 4, 1, 9, 0, 0), user_id, "promo")
```

> **Note:** `perform` is an instance method. When you include `Async::Background::Job`, the module creates a class-level `perform_now` wrapper that instantiates the class and calls `#perform`. This means your job classes are stateless by default.

### Using the Queue API directly

If you prefer not to use the Job module, use the lower-level API:

```ruby
Async::Background::Queue.enqueue(SendEmailJob, user_id, "welcome")

# Delayed (seconds)
Async::Background::Queue.enqueue_in(300, SendEmailJob, user_id, "reminder")

# Scheduled (Time object or float timestamp)
Async::Background::Queue.enqueue_at(Time.new(2026, 4, 1, 9, 0, 0), SendEmailJob, user_id, "promo")

# Also accepts class name as a string
Async::Background::Queue.enqueue("SendEmailJob", user_id, "welcome")
Async::Background::Queue.enqueue_in(60, "SendEmailJob", user_id, "reminder")
```

### How delayed jobs work

When you use `perform_in` or `perform_at`, the job is stored in SQLite with a `run_at` timestamp. The worker's `fetch` query filters by `WHERE status = 'pending' AND run_at <= now`, so the job won't be picked up until its scheduled time arrives.

```
perform_async  →  run_at = now        →  picked up immediately
perform_in(60) →  run_at = now + 60s  →  picked up after 60 seconds
perform_at(t)  →  run_at = t          →  picked up after time t
```

The queue is polled every 5 seconds (`QUEUE_POLL_INTERVAL`), so the actual execution may be delayed by up to 5 seconds after `run_at`.

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

### Enqueuing from Web Workers

Web workers (HTTP servers) can also enqueue jobs to background workers. Simply configure the `default_client` in your web service:

```ruby
service "web" do
  include Falcon::Environment::Rack
  
  count ENV.fetch("FORKS", 2).to_i
  
  service_class do
    Class.new(Async::Service::Generic) do
      def setup(container)
        require "async/background/queue/store"
        require "async/background/queue/client"
        require "async/background/queue/socket_notifier"
        
        total       = ENV.fetch("BACKGROUND_FORKS", 2).to_i
        db_path     = ENV.fetch("QUEUE_DB_PATH", "/app/tmp/queue/background.db")
        socket_dir  = ENV.fetch("QUEUE_SOCKET_DIR", "/app/tmp/queue/sockets")
        
        container.run(count: ENV.fetch("FORKS", 2).to_i) do |instance|
          require_relative "config/environment"
          
          # Web workers can enqueue and wake up background workers
          store = Async::Background::Queue::Store.new(path: db_path)
          Async::Background::Queue.default_client = Async::Background::Queue::Client.new(
            store: store,
            notifier: Async::Background::Queue::SocketNotifier.new(
              socket_dir: socket_dir,
              total_workers: total
            )
          )
          
          instance.ready!
          # ... start Falcon HTTP server ...
        end
      end
    end
  end
end
```

Now your Rails controllers can enqueue jobs:

```ruby
class UsersController < ApplicationController
  def create
    @user = User.create!(user_params)
    
    # Enqueue welcome email - background workers will pick it up instantly
    SendEmailJob.perform_async(@user.id, "welcome")
    
    redirect_to @user
  end
end
```

**Cross-process wake-up:** When a web worker enqueues a job, `SocketNotifier` sends a wake-up signal to all background workers via Unix domain sockets. Workers receive the notification in ~30-80µs (instead of waiting up to 5 seconds for the next poll).

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

---

## Minimal Example: Queue Only (without scheduler)

```ruby
require "async/background"

# Define a job
class MyJob
  include Async::Background::Job

  def perform(message)
    puts "Processing: #{message}"
  end
end

# Setup store and client
store = Async::Background::Queue::Store.new(path: "tmp/queue/jobs.db")
store.ensure_database!

notifier = Async::Background::Queue::Notifier.new
client   = Async::Background::Queue::Client.new(store: store, notifier: notifier)

Async::Background::Queue.default_client = client

# Enqueue jobs
MyJob.perform_async("hello")
MyJob.perform_in(10, "delayed hello")
MyJob.perform_at(Time.now + 60, "scheduled hello")
```
