# frozen_string_literal: true

require 'async/background/scheduler'

module SchedulerHelpers
  def with_scheduler(&block)
    Async::Background::Scheduler.run(&block)
  end

  def scheduler_kind
    Async::Background::Scheduler.resolve
  end
end

RSpec.configure do |config|
  config.include SchedulerHelpers

  config.before(:suite) do
    kind = Async::Background::Scheduler.resolve
    RSpec.configuration.reporter.message("Fiber scheduler under test: #{kind}")
  end
end
