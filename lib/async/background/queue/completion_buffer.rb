# frozen_string_literal: true

require_relative '../clock'

module Async
  module Background
    module Queue
      class CompletionBuffer
        include Clock

        DEFAULT_MAX_SIZE   = 250
        DEFAULT_LINGER_MS  = 5

        attr_reader :max_size, :max_linger_ms

        def initialize(max_size: DEFAULT_MAX_SIZE, max_linger_ms: DEFAULT_LINGER_MS)
          @max_size      = max_size
          @max_linger_ms = max_linger_ms
          @completed     = []
          @failed        = []
          @retries       = []   # array of { id:, fallback_options: }
          @first_added_at = nil
        end

        def any?
          !empty?
        end

        def empty?
          @completed.empty? && @failed.empty? && @retries.empty?
        end

        def size
          @completed.size + @failed.size + @retries.size
        end

        def full?
          size >= @max_size
        end

        def linger_expired?
          return false unless @first_added_at
          (monotonic_now - @first_added_at) * 1000.0 >= @max_linger_ms
        end

        def linger_deadline_at
          return nil unless @first_added_at
          @first_added_at + (@max_linger_ms / 1000.0)
        end

        def add_complete(id)
          @completed << id
          @first_added_at ||= monotonic_now
        end

        def add_failure(id)
          @failed << id
          @first_added_at ||= monotonic_now
        end

        def add_retry(id, fallback_options)
          @retries << { id: id, fallback_options: fallback_options }
          @first_added_at ||= monotonic_now
        end

        def flush(store)
          return empty_summary if empty?

          completed = @completed
          failed    = @failed
          retries   = @retries
          @completed = []
          @failed    = []
          @retries   = []
          @first_added_at = nil

          completed_count = store.complete_batch(completed)
          failed_count    = store.fail_batch(failed)
          retry_result    = retries.empty? ? { retried: [], failed: [] } : store.retry_or_fail_batch(retries)

          {
            completed:    completed_count,
            failed:       failed_count,
            retried:      retry_result[:retried],
            retry_failed: retry_result[:failed]
          }
        end

        private

        def empty_summary
          { completed: 0, failed: 0, retried: [], retry_failed: [] }
        end
      end
    end
  end
end
