# frozen_string_literal: true

require 'socket'

module Async
  module Background
    module Queue
      class SocketNotifier
        # Errors that indicate a worker is unavailable - silently skip
        UNAVAILABLE = [
          Errno::ENOENT,        # Socket file doesn't exist (worker hasn't started yet)
          Errno::ECONNREFUSED,  # File exists but no one listening (worker died)
          Errno::EPIPE,         # Connection broken during write
          Errno::EAGAIN,        # Socket buffer full - wake-up already queued
          IO::WaitWritable,     # Same as EAGAIN on some platforms
          Errno::ECONNRESET     # Connection reset by peer
        ].freeze

        def initialize(socket_dir:, total_workers:)
          @socket_dir = socket_dir
          @total_workers = total_workers
        end

        def notify_all
          (1..@total_workers).each do |worker_index|
            notify_one(worker_index)
          end
        end

        private

        def notify_one(worker_index)
          path = socket_path(worker_index)
          sock = UNIXSocket.new(path)
          begin
            sock.write_nonblock("\x01")
          ensure
            sock.close rescue nil
          end
        rescue *UNAVAILABLE
          # Worker is unavailable - not a problem.
          # The job is already in the database. The worker will:
          # - Pick it up on next poll (within QUEUE_POLL_INTERVAL seconds), or
          # - Pick it up when it starts/restarts via normal fetch loop
        rescue => e
          # Unexpected error - log but don't crash the enqueue operation
          Console.logger.warn(self) { "SocketNotifier#notify_one(#{worker_index}) failed: #{e.class} #{e.message}" } rescue nil
        end

        def socket_path(worker_index)
          File.join(@socket_dir, "async_bg_worker_#{worker_index}.sock")
        end
      end
    end
  end
end
