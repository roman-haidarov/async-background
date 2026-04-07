# frozen_string_literal: true

module Async
  module Background
    module Queue
      class Notifier
        #  Error groups
        WRITE_DROPPED = [
          IO::WaitWritable,  # buffer full — consumer is behind, skip
          Errno::EAGAIN,     # same as above on some platforms
          IOError,           # our own writer end has been closed
          Errno::EPIPE       # the reader end is gone (consumer crashed) — skip
        ].freeze

        READ_EXHAUSTED = [
          IO::WaitReadable,  # nothing left in the buffer — normal exit
          EOFError,          # writer end closed — no more data ever
          IOError            # our own reader end has been closed
        ].freeze

        attr_reader :reader, :writer

        def initialize
          @reader, @writer = IO.pipe
          @reader.binmode
          @writer.binmode
        end

        def notify
          @writer.write_nonblock("\x01")
        rescue *WRITE_DROPPED
          # All write failures are non-fatal: the job is already in the
          # store, and missing one wake-up only delays pickup by at most
          # one poll interval.
        end

        def wait(timeout: nil)
          @reader.wait_readable(timeout)
          drain
        end

        def close_writer
          @writer.close unless @writer.closed?
        end

        def close_reader
          @reader.close unless @reader.closed?
        end

        def close
          close_reader
          close_writer
        end

        def for_producer!
          close_reader
        end

        def for_consumer!
          close_writer
        end

        private

        def drain
          loop do
            @reader.read_nonblock(256)
          rescue *READ_EXHAUSTED
            break
          end
          nil
        end
      end
    end
  end
end
