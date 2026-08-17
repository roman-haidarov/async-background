# frozen_string_literal: true

require 'async/background/runtime'

class Latch
  def initialize
    @open = false
    @notification = Async::Background::Runtime::Notification.new
  end

  def open? = @open

  def wait
    @notification.wait until @open
    true
  end

  def open!
    @open = true
    @notification.signal_all
    true
  end
end
