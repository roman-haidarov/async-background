# frozen_string_literal: true

module Async
  module Background
    module Queue
      class Notifier
        attr_reader :reader, :writer

        def initialize
          @reader, @writer = IO.pipe
          @reader.binmode
          @writer.binmode
        end

        def notify
          @writer.write_nonblock("\x01")
        rescue IO::WaitWritable, Errno::EAGAIN
          # pipe buffer full — consumer is already behind, skip
        rescue IOError
          # pipe closed
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
          rescue IO::WaitReadable, EOFError
            break
          end
          nil
        end
      end
    end
  end
end
