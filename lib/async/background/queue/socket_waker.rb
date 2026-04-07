# frozen_string_literal: true

require 'socket'
require 'async/notification'
require 'fileutils'

module Async
  module Background
    module Queue
      class SocketWaker
        attr_reader :path

        def initialize(path)
          @path = path
          @server = nil
          @notification = ::Async::Notification.new
          @running = false
          @accept_task = nil
        end

        def open!
          cleanup_stale_socket
          ensure_directory
          @server = UNIXServer.new(@path)
          File.chmod(0600, @path)
          @running = true
        rescue Errno::EADDRINUSE
          raise "Socket #{@path} is already in use by another process"
        end

        def start_accept_loop(parent_task)
          @accept_task = parent_task.async do |task|
            while @running
              begin
                client = @server.accept_nonblock
                handle_client(task, client)
              rescue IO::WaitReadable
                @server.wait_readable
              rescue Errno::EBADF, IOError
                break
              rescue => e
                Console.logger.error(self) { "SocketWaker accept error: #{e.class} #{e.message}" }
              end
            end
          rescue => e
            Console.logger.error(self) { "SocketWaker loop crashed: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}" }
          ensure
            @accept_task = nil
          end
        end

        def wait(timeout: nil)
          if timeout
            ::Async::Task.current.with_timeout(timeout) { @notification.wait }
          else
            @notification.wait
          end
        rescue ::Async::TimeoutError
          # Timeout is normal - listener will fall back to polling
        end

        def signal
          @notification.signal
        end

        def close
          @running = false
          if @accept_task && !@accept_task.finished?
            @accept_task.stop rescue nil
          end

          @server&.close rescue nil
          @server = nil
          File.unlink(@path) rescue nil
        end

        private

        def handle_client(parent_task, client)
          parent_task.async do
            begin
              loop do
                client.read_nonblock(256)
              rescue IO::WaitReadable
                client.wait_readable
                retry
              rescue EOFError, Errno::ECONNRESET
                break
              end
            rescue => e
              Console.logger.warn(self) { "SocketWaker client handler error: #{e.class} #{e.message}" }
            ensure
              client.close rescue nil
              @notification.signal
            end
          end
        end

        def cleanup_stale_socket
          return unless File.exist?(@path)

          begin
            UNIXSocket.open(@path) { |s| s.close }

            raise "Socket #{@path} is already in use by another process (worker_index conflict?)"
          rescue Errno::ECONNREFUSED, Errno::ENOENT
            File.unlink(@path) rescue nil
          end
        end

        def ensure_directory
          dir = File.dirname(@path)
          FileUtils.mkdir_p(dir) unless File.exist?(dir)
        end
      end
    end
  end
end
