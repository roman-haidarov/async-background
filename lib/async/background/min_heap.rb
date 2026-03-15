# frozen_string_literal: true

module Async
  module Background
    class MinHeap
      def initialize
        @data = []
      end

      def push(entry)
        @data << entry
        sift_up(@data.size - 1)
      end

      def pop
        return if @data.empty?

        swap(0, @data.size - 1)
        entry = @data.pop
        sift_down(0) unless @data.empty?
        entry
      end

      def peek
        @data.first
      end

      def empty?
        @data.empty?
      end

      def size
        @data.size
      end

      private

      def sift_up(i)
        while i > 0
          parent = (i - 1) >> 1
          break if @data[parent].next_run_at <= @data[i].next_run_at

          swap(i, parent)
          i = parent
        end
      end

      def sift_down(i)
        while true
          smallest = i
          left  = (i << 1) + 1
          right = left + 1

          smallest = left  if left < @data.size && @data[left].next_run_at < @data[smallest].next_run_at
          smallest = right if right < @data.size && @data[right].next_run_at < @data[smallest].next_run_at

          break if smallest == i

          swap(i, smallest)
          i = smallest
        end
      end

      def swap(a, b)
        @data[a], @data[b] = @data[b], @data[a]
      end
    end
  end
end
