# frozen_string_literal: true

require 'socket'

module Async
  module Background
    module Queue
      class SocketNotifier
        # Errors that indicate a worker is unavailable - silently skip and try the next.
        UNAVAILABLE = [
          Errno::ENOENT,        # Socket file doesn't exist (worker hasn't started yet)
          Errno::ECONNREFUSED,  # File exists but no one listening (worker died)
          Errno::EPIPE,         # Connection broken during write
          Errno::ECONNRESET     # Connection reset by peer
        ].freeze

        def initialize(socket_dir:, total_workers:)
          @socket_dir = socket_dir
          @total_workers = total_workers
        end

        def notify_all
          return if @total_workers <= 0

          start = rand(@total_workers)
          @total_workers.times do |i|
            worker_index = ((start + i) % @total_workers) + 1
            return if notify_one(worker_index)
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
          true
        rescue *UNAVAILABLE
          false
        rescue => e
          Console.logger.warn(self) { "SocketNotifier#notify_one(#{worker_index}) failed: #{e.class} #{e.message}" } rescue nil
          false
        end

        def socket_path(worker_index)
          File.join(@socket_dir, "async_bg_worker_#{worker_index}.sock")
        end
      end
    end
  end
end
