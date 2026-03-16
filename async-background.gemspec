# frozen_string_literal: true

require_relative 'lib/async/background/version'

Gem::Specification.new do |spec|
  spec.name    = 'async-background'
  spec.version = Async::Background::VERSION
  spec.authors = ['Roman Hajdarov']
  spec.email = ['romnhajdarov@gmail.com']

  spec.summary     = 'Lightweight heap-based cron/interval scheduler for Async.'
  spec.description = 'A production-grade lightweight scheduler built on top of Async. Single event loop with min-heap timer, skip-overlapping execution, jitter, monotonic clock intervals, semaphore concurrency control, and deterministic worker sharding. Designed for Falcon but works with any Async-based application.'

  spec.homepage = 'https://github.com/roman-haidarov/async-background'
  spec.license  = 'MIT'

  spec.metadata = {
    'source_code_uri' => 'https://github.com/roman-haidarov/async-background',
    'changelog_uri' => 'https://github.com/roman-haidarov/async-background/blob/main/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/roman-haidarov/async-background/issues'
  }

  spec.files = Dir.glob('{lib}/**/*', File::FNM_DOTMATCH, base: __dir__)

  # Ruby 3.3+ required:
  # - Fiber Scheduler landed in 3.0 but had critical bugs
  # - Async 2.x requires 3.1+ (io-event dependency)
  # - autoload bugs in 3.1 fixed in 3.2
  # - io-event >= 1.14 requires Ruby 3.3+
  # - Falcon itself requires >= 3.2
  # - Samuel Williams (Async author): "3.2 is the first production-ready release"
  spec.required_ruby_version = '>= 3.3'

  # Runtime dependencies — pinned to known-good major versions
  spec.add_dependency 'async',    '~> 2.0'   # Fiber Scheduler-based, requires Ruby 3.1+
  spec.add_dependency 'console',  '~> 1.0'   # Structured logging (ships with Async ecosystem)
  spec.add_dependency 'fugit',    '~> 1.0'   # Cron expression parsing (based on et-orbi + raabro)

  # Development dependencies
  spec.add_development_dependency 'rake',    '~> 13.0'
  spec.add_development_dependency 'rspec',   '~> 3.12'
end
