#!/usr/bin/env ruby
# frozen_string_literal: true
# docker run --rm -v $(pwd):/app -w /app ruby:3.3 sh -c "bundle install && timeout 15s ruby test_example.rb || echo 'Test completed'"

require_relative "lib/async/background"

# $stdout.sync = true

class TestJob
  def self.perform_now
    puts "[#{Time.now}] TestJob executed!"
  end
end

config = {
  'test_job' => {
    'class' => 'TestJob',
    'every' => 3,
    'timeout' => 10
  }
}

File.write('test_schedule.yml', config.to_yaml)

# Thread.new do
#   sleep 10
#   puts "\n--- Sending SIGTERM to self (pid=#{Process.pid}) ---"
#   Process.kill('TERM', Process.pid)
# end

puts "Starting Async::Background (pid=#{Process.pid})..."
puts "Will self-terminate in 10 seconds\n\n"

runner = Async::Background::Runner.new(
  config_path: 'test_schedule.yml',
  job_count: 1,
  worker_index: 1,
  total_workers: 1
)

runner.run

puts "\nProcess exited cleanly!"
puts "\n--- Metrics ---"
pp runner.metrics.values
