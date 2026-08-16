# frozen_string_literal: true

require_relative 'runtime'

module Async
  module Background
    module Scheduler
      ENV_KEY = 'ASYNC_BACKGROUND_SCHEDULER'
      THREAD_ENV_KEY = 'ASYNC_BACKGROUND_SCHEDULER_THREAD'
      KNOWN = %i[async itsi].freeze

      class UnknownScheduler < ArgumentError; end
      class Unavailable < Background::Error; end

      module_function

      def installed? = !Fiber.scheduler.nil?

      def current
        return nil unless installed?

        Fiber.scheduler.class.name
      end

      def preload!(kind = nil)
        case resolve(kind)
        when :async then require 'async'
        when :itsi then require 'itsi/scheduler'
        end
        true
      end

      def run(kind = nil, &block)
        raise ArgumentError, 'block required' unless block
        return block.call if installed?

        case resolve(kind)
        when :async then run_async(&block)
        when :itsi then run_itsi(&block)
        end
      end

      def resolve(kind = nil)
        name = (kind || ENV.fetch(ENV_KEY, 'auto')).to_s.downcase
        return name.to_sym if KNOWN.include?(name.to_sym)
        return detect if name == 'auto'

        raise UnknownScheduler, "unknown scheduler #{name.inspect}, expected one of: #{KNOWN.join(', ')}, auto"
      end

      def detect
        return :async if defined?(::Async::Scheduler)
        return :itsi if defined?(::Itsi::Scheduler)

        return :async if available?('async')
        return :itsi if available?('itsi/scheduler')

        raise Unavailable, 'no fiber scheduler available: add `async` or `itsi-scheduler` to your bundle'
      end

      def available?(feature)
        !Gem.find_files(feature).empty? || !Gem.find_files("#{feature}.rb").empty?
      rescue StandardError
        try_require(feature)
      end

      def try_require(feature)
        require feature
        true
      rescue LoadError
        false
      end

      def run_async(&block)
        require 'async'

        result = nil
        send(:Async) { result = block.call }
        result
      end

      def run_itsi(&block)
        require 'itsi/scheduler'

        return run_on_thread(::Itsi::Scheduler, &block) if threaded?

        run_on_current_thread(::Itsi::Scheduler.new, &block)
      end

      def threaded?
        %w[1 true yes].include?(ENV.fetch(THREAD_ENV_KEY, '').to_s.downcase)
      end

      def run_on_current_thread(scheduler, &block)
        result = nil
        failure = nil
        finished = false

        previous = Fiber.scheduler
        Fiber.set_scheduler(scheduler)

        begin
          Fiber.schedule do
            result = block.call
          rescue Exception => e # rubocop:disable Lint/RescueException
            failure = e
          ensure
            finished = true
          end

          scheduler.run if scheduler.respond_to?(:run)
        ensure
          Fiber.set_scheduler(previous)
        end

        raise failure if failure
        unless finished
          raise Unavailable,
                "#{scheduler.class} did not run the scheduled fiber to completion on close; " \
                "set #{THREAD_ENV_KEY}=1 to fall back to a dedicated scheduler thread"
        end

        result
      end

      def run_on_thread(scheduler_class, &block)
        result = nil
        failure = nil

        thread = Thread.new do
          Fiber.set_scheduler(scheduler_class.new)
          Fiber.schedule do
            result = block.call
          rescue Exception => e # rubocop:disable Lint/RescueException
            failure = e
          end
        end
        thread.join
        raise failure if failure

        result
      end
    end
  end
end
