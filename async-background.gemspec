# frozen_string_literal: true

require_relative 'lib/async/background/version'

Gem::Specification.new do |spec|
  spec.name    = 'async-background'
  spec.version = Async::Background::VERSION
  spec.authors = ['Roman Hajdarov']
  spec.email   = ['romnhajdarov@gmail.com']

  spec.summary     = 'Lightweight heap-based cron/interval scheduler for Async.'
  spec.description = 'A production-grade lightweight scheduler built on top of Async. ' \
                     'Single event loop with min-heap timer, skip-overlapping execution, ' \
                     'jitter, monotonic clock intervals, semaphore concurrency control, ' \
                     'and deterministic worker sharding. Designed for Falcon but works ' \
                     'with any Async-based application.'

  spec.homepage = 'https://github.com/roman-haidarov/async-background'
  spec.license  = 'MIT'

  spec.metadata = {
    'source_code_uri' => 'https://github.com/roman-haidarov/async-background',
    'changelog_uri'   => 'https://github.com/roman-haidarov/async-background/blob/main/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/roman-haidarov/async-background/issues'
  }

  spec.files         = Dir.glob('lib/**/*', base: __dir__) +
                       %w[README.md CHANGELOG.md LICENSE async-background.gemspec]
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.3'

  spec.add_dependency 'async',   '~> 2.0'
  spec.add_dependency 'console', '~> 1.0'
  spec.add_dependency 'fugit',   '~> 1.0'

  # Optional: add to your own Gemfile if you need these features
  #   gem 'extralite-bundle',  '~> 2.12' # dynamic job queue (fiber-native SQLite)
  #   gem 'async-utilization', '~> 0.3'  # shared-memory worker metrics

  spec.add_development_dependency 'rake',  '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
end
