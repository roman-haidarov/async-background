# Changelog

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
