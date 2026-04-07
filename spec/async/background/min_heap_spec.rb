# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Async::Background::MinHeap, type: :unit do
  let(:heap) { described_class.new }
  let(:item_class) do
    Struct.new(:next_run_at) do
      include Comparable
      def <=>(other) = next_run_at <=> other.next_run_at
    end
  end

  def item(value)
    item_class.new(value)
  end

  describe '#initialize' do
    it 'creates empty heap' do
      expect(heap.size).to eq(0)
      expect(heap.empty?).to be true
    end
  end

  describe '#push and #pop' do
    it 'maintains heap property with single element' do
      it5 = item(5)
      heap.push(it5)

      expect(heap.size).to eq(1)
      expect(heap.empty?).to be false
      expect(heap.pop).to eq(it5)
      expect(heap.empty?).to be true
    end

    it 'maintains min-heap property' do
      values = [10, 3, 8, 1, 15, 4]
      values.each { |v| heap.push(item(v)) }

      expect(heap.size).to eq(6)

      sorted_values = []
      until heap.empty?
        sorted_values << heap.pop.next_run_at
      end

      expect(sorted_values).to eq([1, 3, 4, 8, 10, 15])
    end

    it 'handles duplicate values' do
      [5, 3, 5, 1, 3, 1].each { |v| heap.push(item(v)) }

      result = []
      until heap.empty?
        result << heap.pop.next_run_at
      end

      expect(result).to eq([1, 1, 3, 3, 5, 5])
    end

    it 'handles negative numbers' do
      [-5, 10, -3, 0, -10, 2].each { |v| heap.push(item(v)) }

      result = []
      until heap.empty?
        result << heap.pop.next_run_at
      end

      expect(result).to eq([-10, -5, -3, 0, 2, 10])
    end
  end

  describe '#peek' do
    context 'with empty heap' do
      it 'returns nil' do
        expect(heap.peek).to be_nil
      end
    end

    context 'with elements' do
      before do
        [10, 3, 8, 1, 15].each { |v| heap.push(item(v)) }
      end

      it 'returns minimum element without removing it' do
        expect(heap.peek.next_run_at).to eq(1)
        expect(heap.size).to eq(5)
        expect(heap.peek.next_run_at).to eq(1)
      end

      it 'updates correctly after operations' do
        expect(heap.peek.next_run_at).to eq(1)

        heap.pop
        expect(heap.peek.next_run_at).to eq(3)

        heap.push(item(0))
        expect(heap.peek.next_run_at).to eq(0)
      end
    end
  end

  describe '#replace_top' do
    it 'replaces root and restores heap property' do
      [1, 3, 5, 7, 9].each { |v| heap.push(item(v)) }

      heap.replace_top(item(10))

      result = []
      until heap.empty?
        result << heap.pop.next_run_at
      end

      expect(result).to eq([3, 5, 7, 9, 10])
    end

    it 'works when new value is still smallest' do
      [5, 10, 15].each { |v| heap.push(item(v)) }

      heap.replace_top(item(2))

      expect(heap.peek.next_run_at).to eq(2)
      expect(heap.size).to eq(3)
    end
  end

  describe '#empty?' do
    it 'returns true for new heap' do
      expect(heap.empty?).to be true
    end

    it 'returns false when elements present' do
      heap.push(item(1))
      expect(heap.empty?).to be false
    end

    it 'returns true after all elements removed' do
      heap.push(item(1))
      heap.push(item(2))
      heap.pop
      heap.pop
      expect(heap.empty?).to be true
    end
  end

  describe '#size' do
    it 'tracks size correctly' do
      expect(heap.size).to eq(0)

      heap.push(item(1))
      expect(heap.size).to eq(1)

      heap.push(item(2))
      heap.push(item(3))
      expect(heap.size).to eq(3)

      heap.pop
      expect(heap.size).to eq(2)

      heap.pop
      heap.pop
      expect(heap.size).to eq(0)
    end
  end

  describe 'stress testing' do
    it 'handles large number of operations' do
      numbers = Array.new(1000) { rand(1000) }
      numbers.each { |n| heap.push(item(n)) }

      expect(heap.size).to eq(1000)

      result = []
      until heap.empty?
        result << heap.pop.next_run_at
      end

      expect(result).to eq(numbers.sort)
    end

    it 'maintains heap property during mixed operations' do
      operations = [:push, :pop, :push, :push, :pop, :push, :peek]
      test_values = [50, 30, 70, 20, 80, 10, 90]
      pushed = []

      operations.each_with_index do |op, i|
        case op
        when :push
          heap.push(item(test_values[i]))
          pushed << test_values[i]
        when :pop
          unless heap.empty?
            popped = heap.pop
            pushed.delete_at(pushed.index(popped.next_run_at))
          end
        when :peek
          if heap.size > 0
            expect(heap.peek.next_run_at).to eq(pushed.min)
          else
            expect(heap.peek).to be_nil
          end
        end
      end
    end
  end

  describe 'edge cases' do
    it 'handles popping from empty heap gracefully' do
      expect(heap.pop).to be_nil
      expect(heap.size).to eq(0)
    end

    it 'handles very large numbers' do
      large_numbers = [1_000_000, 999_999, 1_000_001]
      large_numbers.each { |n| heap.push(item(n)) }

      expect(heap.pop.next_run_at).to eq(999_999)
      expect(heap.pop.next_run_at).to eq(1_000_000)
      expect(heap.pop.next_run_at).to eq(1_000_001)
    end

    it 'handles floating point numbers' do
      floats = [3.14, 2.71, 1.41, 2.72]
      floats.each { |f| heap.push(item(f)) }

      result = []
      until heap.empty?
        result << heap.pop.next_run_at
      end

      expect(result).to eq(floats.sort)
    end
  end

  describe 'comparison with Ruby Array sort' do
    it 'produces same result as Array#sort for random data' do
      random_data = Array.new(100) { rand(-500..500) }

      random_data.each { |v| heap.push(item(v)) }
      heap_result = []
      until heap.empty?
        heap_result << heap.pop.next_run_at
      end

      array_result = random_data.sort

      expect(heap_result).to eq(array_result)
    end
  end
end
