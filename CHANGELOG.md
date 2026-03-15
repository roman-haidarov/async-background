# Changelog

## 0.1.0 (unreleased)

- Initial release
- Single event loop with min-heap timer (O(log N) scheduling)
- Skip overlapping execution
- Startup jitter to prevent thundering herd
- Monotonic clock for interval jobs, wall clock for cron jobs
- Deterministic worker sharding via Zlib.crc32
- Semaphore-based concurrency control
- Per-job timeout protection
- Structured logging via Console
