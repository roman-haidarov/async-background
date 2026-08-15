# frozen_string_literal: true

require 'socket'

require_relative '../clock'

module Async
  module Background
    module Queue
      class SocketNotifier
        include Clock

        # Errors that indicate a worker is unavailable - silently skip and try the next.
        UNAVAILABLE = [
          Errno::ENOENT,        # Socket file doesn't exist (worker hasn't started yet)
          Errno::ECONNREFUSED,  # File exists but no one listening (worker died)
          Errno::EPIPE,         # Connection broken during write
          Errno::ECONNRESET     # Connection reset by peer
        ].freeze

        DEAD_WORKER_TTL = 5.0
        WAKE_BYTE = "\x01".freeze

        def initialize(socket_dir:, total_workers:)
          @socket_dir = socket_dir
          @total_workers = total_workers
          @paths = build_paths
          @dead_until = Array.new([@total_workers, 0].max, 0.0)
          @cursor = 0
        end

        def notify_all
          return false if @total_workers <= 0

          now = monotonic_now
          start = advance_cursor

          @total_workers.times do |offset|
            index = (start + offset) % @total_workers
            return true if notify_one(index, now)
          end

          false
        end

        private

        def build_paths
          return [].freeze if @total_workers <= 0

          Array.new(@total_workers) do |index|
            File.join(@socket_dir, "async_bg_worker_#{index + 1}.sock").freeze
          end.freeze
        end

        def advance_cursor
          @cursor = (@cursor + 1) % @total_workers
        end

        def notify_one(index, now)
          return false if @dead_until[index] > now

          socket = UNIXSocket.new(@paths[index])
          begin
            socket.write_nonblock(WAKE_BYTE)
          ensure
            socket.close rescue nil
          end
          true
        rescue IO::WaitWritable
          true
        rescue *UNAVAILABLE
          mark_dead(index, now)
          false
        rescue => e
          mark_dead(index, now)
          Console.logger.warn(self) { "SocketNotifier#notify_one(#{index + 1}) failed: #{e.class} #{e.message}" } rescue nil
          false
        end

        def mark_dead(index, now)
          @dead_until[index] = now + DEAD_WORKER_TTL
        end
      end
    end
  end
end
