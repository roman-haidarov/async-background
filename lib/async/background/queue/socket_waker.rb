# frozen_string_literal: true

require 'socket'
require 'fileutils'
require_relative '../runtime'

module Async
  module Background
    module Queue
      class SocketWaker
        CLOSE_GRACE = 2

        attr_reader :path

        def initialize(path)
          @path = path
          @server = nil
          @notification = Runtime::Notification.new
          @running = false
          @accept_task = nil
          @clients = Runtime::TaskGroup.new
          @sockets = {}
        end

        def open!
          ensure_directory
          cleanup_stale_socket
          @server = UNIXServer.new(@path)
          @running = true
          self
        rescue Errno::EADDRINUSE
          raise "Socket #{@path} is already in use by another process"
        end

        def start_accept_loop(_parent_task = nil)
          @accept_task = Runtime.spawn(name: 'socket-waker-accept') { accept_loop }
        end

        def wait(timeout: nil)
          @notification.wait(timeout)
        end

        def signal
          @notification.signal_all
          true
        end

        def close
          return unless @running || @server

          @running = false
          stop_accept_loop
          @notification.signal_all
          hang_up_clients
          stop_clients

          @server&.close rescue nil
          @server = nil
          @accept_task = nil
          File.unlink(@path) rescue nil
        end

        private

        def accept_loop
          while @running
            begin
              client = @server.accept_nonblock
            rescue IO::WaitReadable
              @server.wait_readable
              next
            rescue Errno::EBADF, IOError
              break
            rescue StandardError => e
              Console.logger.error(self) { "SocketWaker accept error: #{e.class} #{e.message}" }
              next
            end

            break unless @running

            handle_client(client)
          end
        rescue StandardError => e
          Console.logger.error(self) { "SocketWaker loop crashed: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}" }
        end

        def handle_client(client)
          @sockets[client] = true

          @clients.spawn(name: 'socket-waker-client') do
            loop do
              client.read_nonblock(256)
              @notification.signal_all
            rescue IO::WaitReadable
              client.wait_readable
              retry
            rescue EOFError, Errno::ECONNRESET, Errno::EBADF, IOError
              break
            end
          rescue StandardError => e
            Console.logger.warn(self) { "SocketWaker client handler error: #{e.class} #{e.message}" }
          ensure
            @sockets.delete(client)
            client.close rescue nil
            @notification.signal_all
          end
        end

        def stop_accept_loop
          task = @accept_task or return

          wake_accept_loop
          return if await(task, CLOSE_GRACE)

          task.stop
          await(task, CLOSE_GRACE)
        end

        def wake_accept_loop
          return unless @server

          UNIXSocket.open(@path) { |s| s.write_nonblock("\x00") rescue nil }
        rescue StandardError
          nil
        end

        def hang_up_clients
          @sockets.keys.each do |socket|
            socket.close
          rescue StandardError
            nil
          end
        end

        def stop_clients
          return if @clients.empty?

          return if await_group(@clients, CLOSE_GRACE)

          @clients.stop_all(CLOSE_GRACE)
        end

        def await(task, grace)
          return true unless Runtime.scheduler

          task.wait(grace)
          true
        rescue Runtime::TimeoutError
          false
        rescue Exception # rubocop:disable Lint/RescueException
          true
        end

        def await_group(group, grace)
          return true unless Runtime.scheduler

          group.wait(grace)
          true
        rescue Runtime::TimeoutError
          false
        rescue StandardError
          true
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
