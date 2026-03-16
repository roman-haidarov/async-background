# Changelog

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
