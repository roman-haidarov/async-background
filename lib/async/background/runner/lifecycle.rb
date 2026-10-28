# frozen_string_literal: true

module Async
  module Background
    class Runner
      module Lifecycle
        private

        def setup_signal_handlers
          @signal_r, @signal_w = IO.pipe

          %w[INT TERM].each do |signal|
            Signal.trap(signal) { stop_from_signal }
          end
        end

        def stop_from_signal
          @running = false
          @signal_w.write_nonblock('.')
        rescue StandardError
          nil
        end

        def start_signal_watcher
          @services.spawn(name: 'signal-watcher') { watch_signals }
        end

        def watch_signals
          while running?
            result = read_signal
            next if result == :wait
            break unless result

            logger.info { 'Async::Background: stopping gracefully' } unless running?
            shutdown.signal_all
            @queue_waker&.signal
          end
        end

        def read_signal
          @signal_r.wait_readable
          @signal_r.read_nonblock(256)
        rescue IO::WaitReadable
          :wait
        rescue IOError, Errno::EBADF
          false
        end

        def error_handler
          @error_handler ||= build_error_handler
        end

        def build_error_handler
          log = logger
          lambda do |task, error|
            log.error('Async::Background') do
              "task #{task&.name || 'unnamed'} died: #{error.class} #{error.message}\n" \
                "#{Array(error.backtrace).join("\n")}"
            end
          end
        end

        def warn_unsafe_timeouts
          return if Runtime.native_timeouts?

          logger.warn('Async::Background') do
            "#{Fiber.scheduler.class} does not implement #timeout_after; job timeouts " \
              'fall back to stdlib Timeout and may interrupt an unrelated fiber'
          end
        end

        def wake_signal_watcher
          @signal_w&.write_nonblock('.')
        rescue StandardError
          nil
        end

        def shutdown_gracefully
          wake_services
          drain_jobs
          stop_services
          close_queue
          close_signal_pipe
        end

        def wake_services
          shutdown.signal_all
          wake_signal_watcher
          @queue_waker&.signal
        end

        def drain_jobs
          return if @jobs.empty?

          logger.info { "Async::Background: draining #{@jobs.size} in-flight job(s)" }
          @jobs.wait(@drain_timeout)
        rescue Runtime::TimeoutError
          cancel_draining_jobs
        end

        def cancel_draining_jobs
          logger.warn('Async::Background') do
            "#{@jobs.size} job(s) still running after #{@drain_timeout}s, cancelling"
          end
          @jobs.stop_all(JOB_CANCEL_GRACE)
        end

        def stop_services
          return if @services.empty?

          @services.wait(SERVICE_SHUTDOWN_GRACE)
        rescue Runtime::TimeoutError
          logger.warn('Async::Background') { 'service tasks did not exit in time, cancelling' }
          @services.stop_all(SERVICE_CANCEL_GRACE)
        end

        def close_queue
          @queue_waker&.close
          @queue_store&.close
        end

        def close_signal_pipe
          @signal_r&.close
          @signal_w&.close
        rescue IOError
          nil
        end
      end
    end
  end
end
