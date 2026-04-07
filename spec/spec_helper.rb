# frozen_string_literal: true

require 'rspec'
require 'sqlite3'
require 'tempfile'
require 'fileutils'

require_relative '../lib/async/background'

# Notifier is lazy-loaded by Runner only when queue is enabled, so we eagerly
# require it here. Without this, RSpec's `verify_partial_doubles` cannot
# validate `instance_double('Async::Background::Queue::Notifier')` and would
# silently allow stale method names in mocks.
require_relative '../lib/async/background/queue/notifier'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true

  config.around(:each) do |example|
    @temp_files = []
    example.run
  ensure
    @temp_files&.each { |path| FileUtils.rm_f(path) }
  end

  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true if meta[:type] == :unit
  end
end

module SpecHelpers
  def temp_db_path
    tempfile = Tempfile.new(['test_db', '.sqlite3'])
    path = tempfile.path
    tempfile.close!
    @temp_files ||= []
    # SQLite WAL mode creates -wal and -shm sidecar files; clean them too.
    @temp_files << path
    @temp_files << "#{path}-wal"
    @temp_files << "#{path}-shm"
    path
  end

  def temp_file_path(extension = '.tmp')
    tempfile = Tempfile.new(['test_file', extension])
    path = tempfile.path
    tempfile.close!
    @temp_files ||= []
    @temp_files << path
    path
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
end
