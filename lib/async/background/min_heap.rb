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

      def replace_top(entry)
        @data[0] = entry
        sift_down(0)
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
        while i.positive?
          parent = (i - 1) >> 1
          break if @data[parent].next_run_at <= @data[i].next_run_at

          swap(i, parent)
          i = parent
        end
      end

      def sift_down(index)
        loop do
          child = smallest_child(index)
          break if child == index

          swap(index, child)
          index = child
        end
      end

      def smallest_child(index)
        left = (index << 1) + 1
        right = left + 1
        smallest = index

        smallest = left if left < @data.size && @data[left].next_run_at < @data[smallest].next_run_at
        smallest = right if right < @data.size && @data[right].next_run_at < @data[smallest].next_run_at
        smallest
      end

      def swap(a, b)
        @data[a], @data[b] = @data[b], @data[a]
      end
    end
  end
end
