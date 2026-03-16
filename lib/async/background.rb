# frozen_string_literal: true

require 'async'
require 'async/semaphore'
require 'console'
require 'fugit'

require_relative 'background/version'

# Warn if using an unstable version
unless ['0.1.0', '0.2.2', '0.2.3'].include?(Async::Background::VERSION)
  warn "\n⚠️  WARNING: Async::Background v#{Async::Background::VERSION} is not a stable version!"
  warn "⚠️  Stable versions are: 0.1.0, 0.2.2, and 0.2.3"
  warn "⚠️  For production use, pin to one of these versions in your Gemfile\n\n"
end

require_relative 'background/min_heap'
require_relative 'background/entry'
require_relative 'background/runner'
