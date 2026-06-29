# Changelog

## 1.0.1

Dashboard security headers and a fiber-native rewrite of the SSE stream.

### Security

- HTML shell now ships a strict CSP and `X-Frame-Options: DENY`. The CSP is
  `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'
  data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none';
  form-action 'none'`.
- Every response carries `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: no-referrer`, and `Cross-Origin-Resource-Policy:
  same-origin`.
- `401` and `404` responses are now JSON like every other error — minor
  breaking change for clients that parsed the previous `text/plain` body.
- `HEAD` is accepted on every route that accepts `GET` (RFC 9110 §9.3.2).
  `HEAD /api/stream` returns the SSE headers without opening a stream.
- `mount_path` validation is stricter: must start with `/`, no trailing
  slash, no control characters, no whitespace.
- New `Configuration#logger` (any object responding to `#warn` / `#error`).
  When set, auth-callable exceptions, internal `rescue StandardError`, and
  SSE stream errors are surfaced instead of being silently swallowed.

### Architecture: fiber-native SSE

- Removed the per-process monitor `Thread.new` and per-subscription
  `Mutex` + `ConditionVariable`. The dashboard web subsystem spawns **zero**
  native threads of its own.
- `EventHub` is now a tiny mutex-guarded frame cache keyed by `data_version`.
  No subscriptions, no monitor.
- `Stream#each` runs the entire poll-and-yield loop inside the per-request
  Falcon fiber: `sleep` (fiber-aware), read `PRAGMA data_version`, yield the
  `overview` frame when the version moves, yield a heartbeat otherwise.
- Each tab now polls `data_version` independently. At default 0.5 s and
  realistic operator fan-out that's well under 50 SQLite header reads /
  second per process. JSON rendering still happens at most once per version
  thanks to the hub cache.
- Shutdown is clean: `App#close` marks the hub closed, the next poll raises
  `ClosedError`, the loop exits. No thread to join, no `Subscription` to
  unsubscribe.



&nbsp;

## 1.0.0

First stable release. The queue execution contract from 0.7.2 (claim-token
CAS, lifecycle columns, barrier-based shutdown drain, per-status partial
indexes, versioned migrations) is now considered the public API.

### Dashboard

A read-only Rack-mountable UI under `require 'async/background/web'`:
vanilla HTML / CSS / JS, no framework, no npm.

- Endpoints: `GET /`, `GET /assets/{app.css,app.js}`,
  `GET /api/{overview,executing,claimed,pending,done,failed,metrics,config,stream}`.
- The read path runs through `Async::Background::Web::Snapshot`, which
  opens SQLite with `file:?mode=ro`, wraps a `Mutex` around a single shared
  connection, and uses one read transaction per endpoint plus a TTL'd
  overview cache (`counts_cache_ttl`, default 3 s).
- Distinguishes **executing** (`status='running' AND started_at IS NOT
  NULL`) from **claimed** (`status='running' AND started_at IS NULL`).
- Cursor pagination for `done` / `failed` / `pending` using
  `(finished_at, id)` / `(run_at, id)` tuples. Stable on ties.
- Args hidden by default (`expose_args: false`); when enabled, content
  runs through `redact_args`. All user content rendered through
  `textContent`, never `innerHTML`.
- `auth` is **mandatory**. `Configuration#validate!` rejects an
  unconfigured `auth`. There is no permissive default — a falsey result
  returns `401`.

### SSE transport

The dashboard uses a single long-lived `text/event-stream` connection per
browser tab instead of polling `/api/overview` every 2 seconds. One HTTP
connection per tab regardless of how long it stays open.

- `Configuration#transport` accepts `:sse` (default) or `:polling`. Anything
  else raises `ConfigurationError`. The chosen transport is exposed at
  `/api/config` so the client knows which path to take.
- Client opens `EventSource(mount_path + '/api/stream')` once; the server
  pushes an `overview` event when `PRAGMA data_version` changes and a
  `:keepalive` comment frame every 25 s.
- Server-supplied 5 s reconnect delay; each reconnect begins from a full
  current snapshot (no event log).
- Asset URLs are fingerprinted and cached immutably by digest, so a
  dashboard deploy can't leave a browser on incompatible HTML / JS / CSS.

### Server compatibility for SSE

SSE holds the response open for the lifetime of the dashboard tab.

- **Falcon** — recommended. Handles long-lived connections via fibers.
- **Puma** — works. Each open tab holds one worker thread for its lifetime;
  fine for a handful of operators, problematic if many concurrent operators
  would starve the worker pool.
- **Unicorn** — doesn't work. Blocking worker model can't hold long-lived
  connections without timeouts. Stay on `:polling`.

See the picture in the README for what each server is actually holding.

### Configuration

```ruby
require 'async/background/web'

Async::Background::Queue::Store.prepare_dashboard!(path: '/var/lib/app/queue.db')

Async::Background::Web.configure do |c|
  c.queue_path       = '/var/lib/app/queue.db'
  c.auth             = ->(env) { env['warden'].user&.admin? }
  c.expose_args      = false
  c.metrics_path     = '/run/app/async-background.shm'
  c.total_workers    = 4
  c.counts_cache_ttl = 3.0
  c.poll_interval_ms = 2000
  c.list_limit       = 50
  c.mount_path       = '/admin/background'
  c.title            = 'My App background jobs'
end

run Async::Background::Web.app
```

### Dependencies

`rack` is optional. Required only when `require 'async/background/web'` is
loaded. Core gem and worker processes don't require it.

### Breaking changes from 0.7.x

None beyond what 0.7.2 already shipped. The 1.0 line locks the existing
contract:

- `Queue::Store#fetch` returns `claim_token` in the result hash.
- All terminal `Queue::Store` methods (`complete`, `fail`, `retry_or_fail`)
  require the `claim_token:` kwarg and return CAS success boolean /
  `:retried` / `:failed` / `nil`.
- Schema is versioned via `PRAGMA user_version`. Use
  `Queue::Store.migrate!(path:)` to upgrade. Use
  `Queue::Store.prepare_dashboard!(path:)` from the dashboard process to
  add dashboard-only indexes.



&nbsp;

## 0.7.2

Harden queue execution, retries, shutdown, and metrics. Adds schema v1,
optional dashboard indexes, and a faster enqueue path.



&nbsp;

## 0.7.1

`Store` exposes three SQLite tuning knobs via `StoreOptions`, validated at
construction time so misconfigurations fail fast:

- `mmap` (`true` / `false`, default `true`) — memory-mapped I/O.
- `synchronous` (`:normal` / `:full` / `:extra`, default `:normal`) —
  durability vs throughput.
- `wal_autocheckpoint` (`Integer` in `100..10_000`, default `1_000`) — WAL
  checkpoint frequency in pages.

**Breaking change.** `Store.new(path:, mmap:)` → `Store.new(path:, options:
{ mmap: ... })`. The direct `mmap:` kwarg is removed in favor of the
unified `options:` hash. Update any call site that constructs `Store`
manually.

See [Get Started → Store tuning](docs/GET_STARTED.md#appendix-store-tuning)
for trade-offs.



&nbsp;

## 0.6.2

Queue jobs gain a **configurable timeout** at three levels — call-site
`options:`, class-level `.options`, default 120 s — merged at enqueue time
so the runner just reads the final value from the payload:

```ruby
class HeavyImportJob
  include Async::Background::Job
  options timeout: 600
end

HeavyImportJob.perform_async(user_id, options: { timeout: 120 })  # wins
```

Side effects: an `options TEXT` column in SQLite (added idempotently via
`ALTER TABLE … rescue nil` on existing databases), an extensible `options:`
hash across the entire enqueue chain, a `Job::Options` schema via
`Data.define` (unknown keys raise `ArgumentError`), and queue-timeout
failure logs now include the actual value (`"timed out after 120s"`).



&nbsp;

## 0.6.1

Two scheduler fixes and one notification fast path:

- **Cron busy-loop on overlap skip.** When a scheduled run was skipped
  because the previous one was still active, the entry was re-pushed to the
  heap without `reschedule`. `next_run_at` never advanced, so the next
  iteration picked it up immediately. Skip branch now calls
  `entry.reschedule(monotonic_now)` like the normal path.
- **Prepared statement reset on fetch error.** `@fetch_stmt.reset!` ran
  after `execute` returned, so an exception inside `execute` left the
  statement dirty and the next `fetch` could fail. Wrapped in
  `begin / ensure`.
- **SocketNotifier: 1 connect per enqueue.** `notify_all` no longer
  connects to all N worker sockets on every enqueue. Wakes a single worker
  chosen by random offset, falls back through the ring only if the chosen
  worker is dead. Happy path: 1 connect; worst case (all workers down): N.
- Pending lookup now uses a partial index
  `idx_jobs_pending(run_at, id) WHERE status = 'pending'`. Smaller on disk,
  cheaper to update, and matches the only query that uses it.



&nbsp;

## 0.6.0

**Queue notification system rewritten.** The pipe-based `Notifier` is
replaced with a Unix-domain-socket architecture: each worker listens on its
own socket (`<dir>/async_bg_worker_N.sock`), producers broadcast wake-ups
via `SocketNotifier`. Fork-safe by design (no shared FDs), resilient to
restarts (stale-socket cleanup), and sub-100 µs wake-up latency
(30–80 µs typical).

**Why.** The pipe-based notifier was fundamentally broken in the
recommended multi-fork setup: `for_consumer!` closed the writer end in each
child, making `Client#push → notify` fail silently with `IOError`. All
writes hit `WRITE_DROPPED`, so the queue silently degraded to 5-second
polling.

**Breaking changes.** `Runner` now takes `queue_socket_dir:` instead of
`queue_notifier:`. `Notifier#for_producer!` / `Notifier#for_consumer!` are
removed. `Client#push` calls `notifier.notify_all`. Environment variable
`QUEUE_SOCKET_PATH` is replaced by `QUEUE_SOCKET_DIR` (a directory now).



&nbsp;

## 0.5.1

CI infrastructure: full Docker-based integration testing (`Dockerfile.ci`,
`docker-compose.ci.yml`, `Gemfile.ci`) plus an end-to-end scenario test that
validates forked-worker behavior — normal execution, crash recovery after
SIGKILL, no duplicate execution under crashes, proper distribution across
the pool.

Also: `PRAGMA busy_timeout = 5000` on `Queue::Store` to prevent
`SQLITE_BUSY` under concurrent multi-process access; cleaner IO error
categorization in `Queue::Notifier` (`WRITE_DROPPED` vs `READ_EXHAUSTED`)
with explanatory comments.



&nbsp;

## 0.5.0

**Delayed jobs.** Full support for scheduling jobs in the future:

```ruby
SomeJob.perform_in(60, *args)
SomeJob.perform_at(time, *args)
```

Backed by a new `run_at` column in the SQLite `jobs` table — jobs are only
fetched when `run_at <= now`.

**Job module.** Sidekiq-like `include Async::Background::Job` adds
`perform_async`, `perform_in`, `perform_at`, instance-level `#perform`, and
class-level `perform_now` delegation.

**Clock module.** Shared `monotonic_now` / `realtime_now` helpers extracted
to `Async::Background::Clock` and included by `Runner`, `Queue::Store`, and
`Queue::Client`.



&nbsp;

## 0.4.5

**Fetch race condition fixed.** Wrapped `UPDATE ... RETURNING` in
`BEGIN IMMEDIATE` to prevent two workers from picking up the same job
simultaneously.

**mmap on Docker overlay2.** `overlay2` does not guarantee `write()` /
`mmap()` coherence, which corrupts the WAL under concurrent multi-process
access. mmap is now configurable via `queue_mmap: false` instead of being
hardcoded. Proper Docker setup with named volumes is documented in
[Get Started → Docker](docs/GET_STARTED.md#step-3--docker-setup).

Also: `PRAGMA optimize` on shutdown wrapped in `rescue nil`,
`PRAGMA incremental_vacuum` actually works now (`PRAGMA auto_vacuum =
INCREMENTAL` added to schema; only takes effect on new databases),
composite index `idx_jobs_status_id(status, id)` to eliminate a sort in
`fetch`. New `queue_mmap:` / `mmap:` parameters and a public
`attr_reader :queue_store` on `Runner`.

**Breaking-ish.** `PRAGMAS` is now a frozen lambda `PRAGMAS.call(mmap_size)`
instead of a static string; update any direct reference.



&nbsp;

## 0.4.0

**Dynamic job queue.** Enqueue jobs at runtime from any process (web,
console, rake) with automatic execution by background workers.

- `Queue::Store` — SQLite-backed persistent storage with WAL mode,
  prepared statements, and optimized pragmas.
- `Queue::Notifier` — `IO.pipe`-based zero-cost wake-up between producer
  and consumer processes.
- `Queue::Client` — public API: `Async::Background::Queue.enqueue
  (JobClass, *args)`.
- Automatic recovery of stale `running` jobs on worker restart.
- Periodic cleanup of completed jobs (piggybacked on fetch, every 5 min);
  `PRAGMA incremental_vacuum` when cleanup removes 100+ rows.
- `ISOLATION_FORKS` env var excludes specific workers from queue processing.
- Custom database path via `queue_db_path:` on `Runner`.

Requires the optional `sqlite3` gem (`~> 2.0`).

(The 0.6.0 socket-based architecture supersedes the pipe-based notifier
introduced here.)



&nbsp;

## 0.3.0

Optional metrics collection via shared memory. `Metrics` tracks per-worker
counters: `total_runs`, `total_successes`, `total_failures`,
`total_timeouts`, `total_skips`, `active_jobs`, plus last-run timestamp and
duration. Public API: `runner.metrics.enabled?`, `runner.metrics.values`,
`Metrics.read_all(total_workers:)`. Requires the optional
`async-utilization` gem; absent that, `enabled?` is `false` and `read_all`
returns `[]`. Default file: `/tmp/async-background.shm`.



&nbsp;

## 0.2.x

- **0.2.6** — `wait_with_shutdown` uses the passed `task` parameter
  instead of `Async::Task.current`.
- **0.2.5** — Graceful shutdown via `SIGINT` / `SIGTERM` signal handlers
  using `Signal.trap` and `IO.pipe`. Compatible with Async 2.x API
  (removed deprecated `:parent`).
- **0.2.4** — Removed hardcoded version warning. Use semver pre-release
  suffixes for unstable versions (e.g. `0.3.0.alpha1`).
- **0.2.2** — Removed unused `logger` parameter from `Runner#initialize`;
  use `Console.logger` directly, which now initializes correctly in
  forked processes.
- **0.2.1** — Added missing `require 'console'` in main module. Logger
  was `nil`, causing `undefined method 'info' for nil` on worker
  initialization.
- **0.2.0** — Removed hidden ActiveSupport dependency
  (`safe_constantize` → `Object.const_get` + `NameError`). Job validation
  now checks for `.perform_now` (class method) instead of `.perform`
  (instance method). Fixed a race where an entry could disappear from the
  heap during execution. Added `stop()` and `running?()` to `Runner`.



&nbsp;

## 0.1.0

Initial release.

- Single event loop with min-heap timer (`O(log N)` scheduling).
- Skip overlapping execution.
- Startup jitter to prevent thundering herd.
- Monotonic clock for interval jobs, wall clock for cron jobs.
- Deterministic worker sharding via `Zlib.crc32`.
- Semaphore-based concurrency control.
- Per-job timeout protection.
- Structured logging via Console.
