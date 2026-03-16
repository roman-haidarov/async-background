# Changelog

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
