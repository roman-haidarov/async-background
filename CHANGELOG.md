# Changelog

## Unreleased

### Dashboard SSE hardening

- Make SSE the default dashboard transport. `:polling` remains an explicit compatibility fallback.
- Replace one `PRAGMA data_version` loop **per browser connection** with one shared `EventHub` watcher per Rack app process while at least one dashboard tab is connected. It fans complete overview snapshots to every SSE body through latest-value mailboxes, so slow tabs do not accumulate unbounded event queues.
- Use complete snapshots on connect and after a change rather than a replay log: reconnecting EventSource clients cannot miss the current queue state.
- Coalesce client-side list refreshes after a burst of changes, cancel stale list fetches on tab switches, and retain previous pages when `Load more` is used.
- Add SSE retry control, 25-second heartbeat frames, `no-cache, no-transform`, and `X-Accel-Buffering: no`. Remove the hop-by-hop `Connection` response header.
- Fingerprint asset URLs and cache immutable assets by digest, so a dashboard deploy cannot leave a browser on incompatible HTML/JS/CSS.
- Add coverage for event fan-out, latest-value coalescing, clean stream shutdown, forced overview reads, and the SSE configuration constraints.

## 1.1.0

Server-Sent Events transport for the dashboard. Replaces HTTP polling as the recommended transport.

### Added

- **SSE transport for the dashboard.** Set `c.transport = :sse` in `Async::Background::Web.configure` and the dashboard now uses a single long-lived `text/event-stream` connection per browser tab instead of polling `/api/overview` every 2 seconds. The browser opens `EventSource(mount_path + '/api/stream')` once; the server pushes an `overview` event whenever `PRAGMA data_version` changes, and a `:keepalive` comment frame every 30 seconds. Result: 1 HTTP connection per dashboard tab regardless of how long it stays open, instead of 30 req/min per tab.

  - New module `Async::Background::Web::Stream` implements the event loop as a Rack streaming body (responds to `#each`, yields SSE frames). Holds no state across requests.
  - New route `GET /api/stream` returns `200 text/event-stream` when `transport == :sse`, `404` otherwise. Subject to the same auth gate as every other endpoint.
  - New `Response.sse(body)` helper sets the correct headers including `x-accel-buffering: no` (disables nginx buffering for the streaming response).
  - JS client (`assets.rb`) detects `state.config.transport === 'sse'` at boot and chooses `EventSource` over `setInterval(tick, ...)`. Both transports share the same `applyOverview()` and `refreshActiveList()` handlers, so the UI behaves identically.

- **`Configuration#transport`** with default `:polling` (backward compatible) and accepted values `:polling | :sse`. Validation rejects anything else with `ConfigurationError`. The chosen transport is exposed at `/api/config` so the client knows which path to take.

### Migration

Existing deployments keep working unchanged. To opt into SSE:

```ruby
Async::Background::Web.configure do |c|
  c.queue_path = ...
  c.auth = ->(env) { ... }
  c.transport = :sse
end
```

### Server compatibility note

SSE holds the request thread/fiber open for the lifetime of the dashboard tab. **Recommended for Falcon**, which handles long-lived connections natively via fibers. **Puma works** but each open dashboard tab holds one worker thread for its lifetime — fine for an admin dashboard with a handful of operators, problematic if many concurrent operators would starve the worker pool. **Unicorn does not work** for SSE since its blocking worker model can't hold long-lived connections without timeouts; stay on `:polling` there.

### Backend-side polling

The server still polls `PRAGMA data_version` every 500ms inside the snapshot connection to detect changes. This is a connection-local PRAGMA call, microseconds, never hits a rate limiter. Client-facing transport is push.

### Tests

- New `spec/async/background/web/stream_spec.rb` — covers overview event on data_version change, heartbeat after idle, graceful exit on `EPIPE`/`IOError`, error frame on `ClosedError`/`UnavailableError`.
- Extended `spec/async/background/web/app_spec.rb` — `/api/stream` returns 404 on polling default, 200 text/event-stream on `:sse`, 401 without auth.
- Extended `spec/async/background/web/configuration_spec.rb` — accepts `:sse`, rejects unknown transports.

## 1.0.0

First stable release. The queue execution contract from 0.7.2 (claim-token CAS, lifecycle columns, barrier-based shutdown drain, per-status partial indexes, versioned migrations) is now considered the public API.

### Features

- **Web dashboard.** Rack-mountable read-only UI under `require 'async/background/web'`. Vanilla HTML/CSS/JS, no JS framework, no npm.
  - Endpoints: `GET /`, `GET /assets/app.css`, `GET /assets/app.js`, `GET /api/overview`, `GET /api/executing`, `GET /api/claimed`, `GET /api/pending`, `GET /api/done`, `GET /api/failed`, `GET /api/metrics`, `GET /api/config`.
  - Default transport is JSON polling (`poll_interval_ms`, default 2000). SSE adapter for Falcon is intentionally deferred to a later release; the dashboard already coalesces work via a shared overview cache, so adding SSE later is a backward-compatible change.
  - Read path runs through `Async::Background::Web::Snapshot`, which opens SQLite with `file:?mode=ro`, wraps a `Mutex` around a single shared connection, and uses one read transaction per endpoint and caches each overview as one consistent snapshot.
  - Distinguishes `Executing` (`status='running' AND started_at IS NOT NULL`) from `Claimed` (`status='running' AND started_at IS NULL`).
  - Overview snapshot cache for `counts_cache_ttl` seconds (default 3.0) so a busy queue does not turn the dashboard into a hot reader.
  - Cursor pagination for `done`/`failed`/`pending` using `(finished_at, id)` / `(run_at, id)` tuples. Stable on ties.
  - Args hidden by default (`expose_args: false`); when enabled, content runs through `redact_args`. All user content rendered through `textContent`, never `innerHTML`.
  - Auth hook is **mandatory**. `Configuration#validate!` rejects an unconfigured `auth`. There is no permissive default.

  - Add the optional Rack dashboard for the SQLite queue.
  - Make sqlite3 an explicit runtime dependency for queue/dashboard installs.

### Configuration

```ruby
require 'async/background/web'

Async::Background::Queue::Store.prepare_dashboard!(path: '/var/lib/app/queue.db')

Async::Background::Web.configure do |c|
  c.queue_path        = '/var/lib/app/queue.db'
  c.auth              = ->(env) { env['warden'].user&.admin? }
  c.expose_args       = false
  c.metrics_path      = '/run/app/async-background.shm'
  c.total_workers     = 4
  c.counts_cache_ttl  = 3.0
  c.poll_interval_ms  = 2000
  c.list_limit        = 50
  c.mount_path        = '/admin/background'
  c.title             = 'My App background jobs'
end

run Async::Background::Web.app
```

### Dependencies

- `rack` is an optional dependency. Required only when `require 'async/background/web'` is loaded. Core gem and worker processes do not require it.

### Breaking changes from 0.7.x

None beyond what 0.7.2 already shipped. The 1.0 line locks the existing contract:

- `Queue::Store#fetch` returns `claim_token` in the result hash.
- All terminal `Queue::Store` methods (`complete`, `fail`, `retry_or_fail`) require the `claim_token:` kwarg and return CAS success boolean / `:retried` / `:failed` / `nil`.
- Schema is versioned via `PRAGMA user_version`. Use `Queue::Store.migrate!(path:)` to upgrade. Use `Queue::Store.prepare_dashboard!(path:)` from the dashboard process to lazily create dashboard-only indexes (per-status partial indexes for `done` / `failed`, plus separate `executing` and `claimed` indexes).

## 0.7.2

- Harden queue execution, retries, shutdown, and metrics.
- Add schema v1, optional dashboard indexes, and a faster enqueue path.

## 0.7.1

### Features
- **Tunable `Store` options via `StoreOptions`** — three knobs exposed for SQLite tuning, validated at construction time so misconfigurations fail fast at boot:
  - `mmap` (`true`/`false`, default `true`) — toggle memory-mapped I/O
  - `synchronous` (`:normal`/`:full`/`:extra`, default `:normal`) — durability vs throughput
  - `wal_autocheckpoint` (`Integer` in `100..10_000`, default `1_000`) — WAL checkpoint frequency in pages

  Range and enum validation prevent foot-guns (e.g. `wal_autocheckpoint: 100_000` would bloat WAL beyond `journal_size_limit`). See [Get Started → Store tuning](docs/GET_STARTED.md) for trade-offs of each knob

### Breaking changes
- `Store.new(path:, mmap:)` → `Store.new(path:, options: { mmap: ... })`. Direct `mmap:` keyword argument removed in favor of the unified `options:` hash. Users who construct `Store` manually (e.g. for web-worker enqueue) need to update the call site

## 0.6.2

### Features
- **Configurable timeout for queue jobs** — queue jobs previously used a hardcoded 30-second timeout (`DEFAULT_TIMEOUT`). Now configurable via `options` hash at two levels:
  ```ruby
  # Class-level default
  class HeavyImportJob
    include Async::Background::Job
    options timeout: 600

    def perform(user_id) = # ...
  end

  # Call-site override (wins over class-level)
  HeavyImportJob.perform_async(user_id, options: { timeout: 120 })
  ```
  Priority: call-site `options:` → class-level `options` → `DEFAULT_TIMEOUT` (30s). Options are merged at enqueue time so the runner simply reads the final value from the payload
- **`options:` hash across the entire enqueue chain** — single extensible contract from `perform_async` through `Client` down to `Store`. Currently supports `:timeout`, designed to accommodate future keys (e.g. `:retry`) without API changes
- **`Job::Options` schema via `Data.define`** — declares known option keys with types and defaults. Unknown keys raise `ArgumentError`, invalid types raise `TypeError`. No manual validation code
- **`options TEXT` column in SQLite** — stores the merged options hash as JSON. Extensible without schema changes when new options are added

### Improvements
- **Queue timeout logged on failure** — `run_queue_job` error log now includes actual timeout value: `"timed out after 120s"` instead of generic `"timed out"`
- **Idempotent schema migration** — existing databases get `ALTER TABLE jobs ADD COLUMN options TEXT` on first connection, wrapped in `rescue nil` for safe re-runs. New databases include the column in `CREATE TABLE`

## 0.6.1

### Bug Fixes
- **Runner: cron jobs busy-loop on overlap skip** — when a scheduled run was skipped because the previous one was still active, the entry was re-pushed to the heap without calling `reschedule`. For cron jobs (where `interval` is `nil`), this meant `next_run_at` was never advanced to the next cron tick, causing the entry to be picked up again immediately on the next loop iteration. Skip branch now calls `entry.reschedule(monotonic_now)` like the normal path
- **Store: prepared statement not reset on fetch error** — `@fetch_stmt.reset!` was called after `execute` returned, so an exception inside `execute` left the statement in a dirty state and the next `fetch` could fail. Wrapped in `begin/ensure` to guarantee reset

### Improvements
- **SocketNotifier: non-blocking enqueue with ring fallback** — `notify_all` no longer connects to all N worker sockets on every enqueue. `UNIXSocket.new` is a blocking, non-fiber-aware syscall, and notifying every worker blocked the Falcon reactor for N `connect()` calls on the hot HTTP enqueue path. Now wakes a single worker chosen by random offset, falling back through the ring only if the chosen worker is dead (`ECONNREFUSED` etc.). Happy path: 1 connect. Worst case (all workers down): N connects — same as before, but only when actually needed. Safe because the queue is shared in SQLite, not sharded per worker
- **SocketNotifier: cleaned up `UNAVAILABLE` error list** — removed `IO::WaitWritable` and `Errno::EAGAIN`. They implied "socket buffer full", but `write_nonblock` of a single byte to a freshly-opened connection cannot fill the kernel buffer. Listing them only misled readers
- **Store: partial index for pending lookup** — replaced `idx_jobs_status_run_at_id(status, run_at, id)` with partial index `idx_jobs_pending(run_at, id) WHERE status = 'pending'`. Smaller on disk, cheaper to update, and matches the only query that uses it (`fetch`). `done`/`failed`/`running` rows no longer occupy index pages

## 0.6.0

### Breaking Changes
- **Queue notification system completely rewritten** — replaced pipe-based `Notifier` with Unix domain socket-based architecture
  - `Runner` now takes `queue_socket_dir:` parameter instead of `queue_notifier:`
  - Removed `Notifier#for_producer!` and `Notifier#for_consumer!` — no longer needed
  - `Client#push` now calls `notifier.notify_all` instead of `notifier.notify`

### Features
- **Unix domain socket-based notifications** — solves all cross-process notification problems
  - New `SocketWaker` class (consumer-side) — each worker listens on its own Unix socket (`/tmp/queue/sockets/async_bg_worker_N.sock`)
  - New `SocketNotifier` class (producer-side) — connects to all worker sockets to broadcast wake-ups
  - **Cross-process wake-up now works correctly** — web workers → background workers, background workers → background workers
  - **Fork-safe by design** — no shared file descriptors, each process creates its own socket after fork
  - **Resilient to restarts** — stale socket cleanup on worker startup, graceful degradation if worker unavailable
  - **Sub-100µs latency** — typical wake-up time 30-80µs vs previous 5-second polling fallback

### Bug Fixes
- **CRITICAL: Notifier bug in recommended setup** — the old pipe-based `Notifier` was fundamentally broken in multi-fork scenarios:
  - `for_consumer!` closed the writer end in each child process, making `Client#push → notify` fail silently with `IOError`
  - All writes were caught by `WRITE_DROPPED` rescue block, causing jobs to use 5-second polling instead of instant wake-up
  - Web workers had no way to notify background workers (no shared pipe after fork)
  - The bug was masked by `WRITE_DROPPED` silently catching `IOError` — appeared to work but degraded to polling
- **Socket cleanup race conditions** — `SocketWaker#cleanup_stale_socket` now validates if socket is truly stale by attempting connection

### Improvements
- Updated `docs/GET_STARTED.md` with new socket-based setup for Falcon
- Added section on web worker → background worker job enqueuing with full example
- Changed environment variable from `QUEUE_SOCKET_PATH` to `QUEUE_SOCKET_DIR` (directory instead of single socket path)
- Better error handling in `SocketWaker` and `SocketNotifier` with comprehensive `UNAVAILABLE` error list
- Integrated with `Async::Notification` for local wake-ups (shutdown signals)

### Technical Details
- **Why sockets over pipes?** Pipes require shared FDs across fork boundaries. The recommended Falcon setup calls `for_consumer!` in each child, which closes the writer, breaking the notification chain. Sockets use filesystem paths — any process can connect without inherited FDs.
- **Performance impact:** Adding ~80µs per enqueue for 8 workers (8 socket connections) vs ~100µs for SQLite transaction = negligible overhead
- **Graceful degradation:** If worker socket unavailable (`ENOENT`, `ECONNREFUSED`), producer silently skips — job still in database, will be picked up on next poll (5s max delay)

## 0.5.1

### Testing Infrastructure
- **Comprehensive CI setup** — full Docker-based integration testing environment with `Dockerfile.ci`, `docker-compose.ci.yml`, and `Gemfile.ci`
- **End-to-end scenario testing** — new `ci/scenario_test.rb` validates real-world scenarios with forked workers:
  - Normal execution of fast/slow/failing jobs across multiple workers
  - Crash recovery after SIGKILL with automatic job pickup by remaining workers
  - No duplicate execution guarantees under worker crashes
  - Proper job distribution validation across worker pool
- **Test fixtures** — dedicated `ci/fixtures/jobs.rb` and `ci/fixtures/schedule.yml` for scenario testing

### Bug Fixes
- **SQLite busy timeout** — added `PRAGMA busy_timeout = 5000` to `Queue::Store` to prevent `SQLITE_BUSY` errors under concurrent multi-process database access
- **Enhanced Queue::Notifier error handling** — restructured IO error handling with clearer categorization:
  - `WRITE_DROPPED` for write failures (`IO::WaitWritable`, `Errno::EAGAIN`, `IOError`, `Errno::EPIPE`) — all non-fatal as job is already in store
  - `READ_EXHAUSTED` for read exhaustion (`IO::WaitReadable`, `EOFError`, `IOError`) — normal drain completion
  - Added explanatory comments for each error type and handling strategy

## 0.5.0

### Features
- **Delayed jobs** — full support for scheduling jobs in the future
  - `Queue::Client#push_in(delay, class_name, args)` — enqueue with delay in seconds
  - `Queue::Client#push_at(time, class_name, args)` — enqueue at a specific time
  - `Queue.enqueue_in(delay, job_class, *args)` — class-level delayed enqueue
  - `Queue.enqueue_at(time, job_class, *args)` — class-level scheduled enqueue
  - New `run_at` column in SQLite `jobs` table — jobs are only fetched when `run_at <= now`
- **Job module** — Sidekiq-like `include Async::Background::Job` interface
  - `perform_async(*args)` — immediate queue execution
  - `perform_in(delay, *args)` — delayed execution after N seconds
  - `perform_at(time, *args)` — scheduled execution at a specific time
  - Instance-level `#perform` with class-level `perform_now` delegation
- **Clock module** — shared `monotonic_now` / `realtime_now` helpers extracted into `Async::Background::Clock`, included by `Runner`, `Queue::Store`, and `Queue::Client`

### Bug Fixes
- **Runner: incorrect task in `with_timeout`** — `semaphore.async { |job_task| ... }` now correctly receives the child task instead of capturing the parent `task` from the outer scope. Previously, `with_timeout` was applied to the parent task, which could cancel unrelated work

### Improvements
- **Job API: `#perform` instead of `#perform_now`** — job classes now define `#perform` instance method. The class-level `perform_now` creates instance and calls `#perform`, aligning with ActiveJob / Sidekiq conventions
- Updated error messages: validation failures now suggest `must include Async::Background::Job` instead of `must implement .perform_now`
- `Queue::Client` — extracted private `ensure_configured!` and `resolve_class_name` methods for cleaner validation and class name resolution logic
- `Queue::Notifier` — extracted `IO_ERRORS` constant (`IO::WaitReadable`, `EOFError`, `IOError`) for cleaner `rescue` in `drain`
- `Queue::Store` — replaced index `idx_jobs_status_id(status, id)` with `idx_jobs_status_run_at_id(status, run_at, id)` for efficient delayed job lookups
- `Queue::Store` — `fetch` SQL now uses `WHERE status = 'pending' AND run_at <= ?` with `ORDER BY run_at, id` to process jobs in scheduled order
- Removed duplicated `monotonic_now` / `realtime_now` from `Runner` and `Store` — now provided by `Clock` module
- Updated documentation: README (Job module examples, Queue architecture diagram, Clock section), GET_STARTED (delayed jobs guide, Job module usage, minimal queue-only example)

## 0.4.5

### Breaking Changes
- `PRAGMAS` is now a frozen lambda `PRAGMAS.call(mmap_size)` instead of a static string — if you referenced this constant directly, update your code

### Features
- New `queue_mmap:` parameter on `Runner` (default: `true`) — allows disabling SQLite mmap for environments where it's unsafe (Docker overlay2)
- New `mmap:` parameter on `Queue::Store` (default: `true`) — controls `PRAGMA mmap_size` (256 MB when enabled, 0 when disabled)
- Public `attr_reader :queue_store` on `Runner` — eliminates need for `instance_variable_get` when sharing Store with Client

### Bug Fixes
- **CRITICAL: fetch race condition** — wrapped `UPDATE ... RETURNING` in `BEGIN IMMEDIATE` transaction to prevent two workers from picking up the same job simultaneously
- **CRITICAL: mmap + Docker overlay2** — `overlay2` filesystem does not guarantee `write()`/`mmap()` coherence, causing SQLite WAL corruption under concurrent multi-process access. mmap is now configurable via `queue_mmap: false` instead of being hardcoded. Documented proper Docker setup with named volumes in `docs/GET_STARTED.md`
- **`PRAGMA optimize` on shutdown** — wrapped in `rescue nil` to prevent `SQLite3::BusyException` when another process holds the write lock during graceful shutdown
- **`PRAGMA incremental_vacuum` was a no-op** — added `PRAGMA auto_vacuum = INCREMENTAL` to schema. Without it, `incremental_vacuum` does nothing. Note: only takes effect on newly created databases; existing databases require a one-time `VACUUM`

### Improvements
- Replaced index `idx_jobs_status(status)` with composite `idx_jobs_status_id(status, id)` — eliminates sort step in `fetch` query (`ORDER BY id LIMIT 1` is now a direct B-tree lookup)
- Fixed `finalize_statements` — changed `%i[@enqueue_stmt ...]` to `%i[enqueue_stmt ...]` with `:"@#{name}"` interpolation for idiomatic `instance_variable_get`/`set` usage
- Added documentation: `README.md` (concise, with warning markers) and `docs/GET_STARTED.md` (step-by-step guide covering schedule config, Falcon integration, Docker setup, dynamic queue)

## 0.4.0

### Features
- **Dynamic job queue** — enqueue jobs at runtime from any process (web, console, rake) with automatic execution by background workers
  - `Queue::Store` — SQLite-backed persistent storage with WAL mode, prepared statements, and optimized pragmas
  - `Queue::Notifier` — `IO.pipe`-based zero-cost wakeup between producer and consumer processes (no polling)
  - `Queue::Client` — public API: `Async::Background::Queue.enqueue(JobClass, *args)`
  - Automatic recovery of stale `running` jobs on worker restart
  - Periodic cleanup of completed jobs (piggyback on fetch, every 5 minutes)
  - `PRAGMA incremental_vacuum` when cleanup removes 100+ rows
  - Worker isolation via `ISOLATION_FORKS` env variable — exclude specific workers from queue processing
  - Custom database path via `queue_db_path` parameter
  - Requires optional `sqlite3` gem (`~> 2.0`) — not included by default, must be added to Gemfile explicitly
- New Runner parameters: `queue_notifier:` and `queue_db_path:`

### Improvements
- Unified `monotonic_now` usage across `run_job` and `run_queue_job` (was using direct `Process.clock_gettime` call in `run_job`)
- `Queue::Notifier#drain` — moved `rescue` inside the loop to avoid stack unwinding on each drain cycle

## 0.3.0

### Features
- Added optional metrics collection system using shared memory
- New `Metrics` class with worker-specific performance tracking
- Public API: `runner.metrics.enabled?`, `runner.metrics.values`, `Metrics.read_all()`
- Tracks total runs, successes, failures, timeouts, skips, active jobs, and execution times
- Requires optional `async-utilization` gem dependency
- Metrics stored in `/tmp/async-background.shm` with lock-free updates per worker

## 0.2.6

### Improvements
- Micro-optimization in `wait_with_shutdown` method: use passed `task` parameter instead of `Async::Task.current` for better consistency and slight performance improvement

## 0.2.5

### Features
- Added graceful shutdown via signal handlers for SIGINT and SIGTERM
- Enhanced process lifecycle management with proper signal handling using `Signal.trap` and IO.pipe for async communication
- Improved robustness for production deployments and container orchestration
- Updated dependencies to work with latest Async 2.x API (removed deprecated `:parent` parameter usage)

## 0.2.4

### Improvements
- Removed hardcoded version warning from main module (was checking against fixed list: 0.1.0, 0.2.2, 0.2.3). Use semantic versioning with pre-release suffixes for unstable versions (e.g., 0.3.0.alpha1) instead
- Removed hardcoded stable versions list from gemspec description — metadata should describe functionality, not versioning
- Changed `while true` to idiomatic `loop do` in run method
- Added `Gemfile.lock` to .gitignore (gems should not commit lockfile)
- Updated README: clarified that job class must respond to `.perform_now` class method (removed confusing mention of instance `#perform`)

## 0.2.2

### Bug Fixes
- **CRITICAL**: Removed logger parameter from Runner initialize (was unused). Fixed initialization to use Console.logger directly which now properly initializes in forked processes with correct context

## 0.2.1

### Bug Fixes
- **CRITICAL**: Added missing `require 'console'` in main module. Logger was nil because Console gem was not imported, causing `undefined method 'info' for nil` errors on worker initialization

## 0.2.0

### Bug Fixes
- **CRITICAL**: Removed hidden ActiveSupport dependency. Replaced `safe_constantize` with `Object.const_get` + `NameError` handling
- **CRITICAL**: Fixed validator mismatch: now validates `.perform_now` (class method) instead of `.perform` (instance method)
- **CRITICAL**: Fixed race condition where entry could disappear from heap during execution. `reschedule` and `heap.push` now always execute after job processing
- Added full exception backtrace to error logs for production debugging
- Improved YAML security by removing `Symbol` from `permitted_classes`
- Removed Mutex from graceful shutdown (anti-pattern in Async). Boolean assignment is atomic in MRI

### Features
- Added optional `logger` parameter to Runner constructor for custom loggers (Rails.logger, etc.)
- Added `stop()` method for graceful shutdown
- Added `running?()` method to check scheduler status

### Breaking Changes
- Job class validation now checks for `.perform_now` class method (was checking for `.perform` instance method)

## 0.1.0

- Initial release
- Single event loop with min-heap timer (O(log N) scheduling)
- Skip overlapping execution
- Startup jitter to prevent thundering herd
- Monotonic clock for interval jobs, wall clock for cron jobs
- Deterministic worker sharding via Zlib.crc32
- Semaphore-based concurrency control
- Per-job timeout protection
- Structured logging via Console
