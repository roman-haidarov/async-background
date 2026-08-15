# frozen_string_literal: true

require 'fileutils'
require 'json'

module ScenarioStackprof
  WORKER_MODES = {1 => :cpu, 2 => :wall, 3 => :object}.freeze
  WORKER_SCENARIOS = %w[enqueue_perf].freeze

  class << self
    attr_accessor :scenario

    def enabled?
      ENV['STACKPROF'] == '1'
    end

    def dir
      ENV.fetch('STACKPROF_DIR', File.expand_path('../tmp/stackprof', __dir__))
    end

    def start!(label, mode: :cpu, interval: nil)
      return unless enabled?

      require 'stackprof'
      FileUtils.mkdir_p(dir)
      stop! if @running
      opts = {mode: mode.to_sym, raw: true}
      opts[:interval] = interval || default_interval(mode)
      StackProf.start(**opts)
      @running = {label: label, mode: mode.to_sym}
    end

    def stop!
      return unless @running

      meta = @running
      @running = nil
      StackProf.stop
      results = StackProf.results
      write_dump(meta[:label], meta[:mode], results) if results.is_a?(Hash)
      results
    end

    def profile(label, mode: :wall, interval: nil)
      return yield unless enabled?

      start!(label, mode: mode, interval: interval)
      yield
    ensure
      stop! if enabled?
    end

    def install_worker!(index)
      return unless enabled?
      return unless WORKER_SCENARIOS.include?(scenario.to_s)

      mode = WORKER_MODES.fetch(index, :cpu)
      start!("worker#{index}", mode: mode)
      at_exit { stop! }
    end

    def write_reports!
      return unless enabled?

      require 'stackprof'
      FileUtils.mkdir_p(dir)
      dumps = Dir.glob(File.join(dir, '*.dump')).sort
      summaries = {}

      dumps.each do |dump_path|
        results = Marshal.load(File.binread(dump_path))
        unless results.is_a?(Hash) && results[:frames]
          warn "skipping unreadable dump #{dump_path} (#{results.class})"
          next
        end

        base = dump_path.delete_suffix('.dump')
        write_text_report(base, results)
        summaries[File.basename(dump_path)] = summarize(results)
      end

      File.write(File.join(dir, 'summary.json'), JSON.pretty_generate(summaries))
      File.write(File.join(dir, 'README.txt'), readme(dumps))
      File.write(File.join(dir, 'ci-summary.md'), markdown_summary(summaries))
      summaries
    end

    private

    def default_interval(mode)
      mode.to_sym == :object ? 10 : 1000
    end

    def write_dump(label, mode, results)
      FileUtils.mkdir_p(dir)
      name = [scenario, label, mode, "pid#{Process.pid}"].compact.join('_')
      path = File.join(dir, "#{sanitize(name)}.dump")
      File.binwrite(path, Marshal.dump(results))
      path
    end

    def write_text_report(base, results)
      File.open("#{base}.txt", 'w') do |io|
        print_header(results, io)
        print_top_frames(results, io, 40)
        io.puts
        io.puts '--- frames matching async-background / sqlite3 / json ---'
        print_matching(results, io, %r{async/background|sqlite3|json}i)
      end
    end

    def print_header(results, io)
      samples = results[:samples].to_i
      missed = results[:missed_samples].to_i
      gc = results[:gc_samples].to_i
      denom = [samples, 1].max
      miss_pct = 100.0 * missed / [samples + missed, 1].max
      gc_pct = 100.0 * gc / denom
      io.puts '=================================='
      io.puts "  Mode: #{results[:mode]}(#{results[:interval]})"
      io.puts "  Samples: #{samples} (#{format('%.2f', miss_pct)}% miss rate)"
      io.puts "  GC: #{gc} (#{format('%.2f', gc_pct)}%)"
      io.puts '=================================='
      io.puts '     TOTAL    (pct)     SAMPLES    (pct)     FRAME'
    end

    def print_top_frames(results, io, limit)
      samples = [results[:samples].to_i, 1].max
      frames = results[:frames].values.sort_by { |frame| -(frame[:samples] || 0) }.first(limit)
      frames.each do |frame|
        own = frame[:samples].to_i
        total = frame[:total_samples].to_i
        io.printf(
          "  %8d  (%5.1f%%)  %8d  (%5.1f%%)  %s\n",
          total, 100.0 * total / samples,
          own, 100.0 * own / samples,
          frame[:name]
        )
      end
    end

    def print_matching(results, io, pattern)
      frames = results[:frames].values
        .select { |frame| matching_frame?(frame, pattern) }
        .sort_by { |frame| -(frame[:samples] || 0) }
        .first(25)

      if frames.empty?
        io.puts '(none)'
        return
      end

      samples = [results[:samples].to_i, 1].max
      frames.each do |frame|
        own = frame[:samples].to_i
        total = frame[:total_samples].to_i
        io.printf(
          "  %6d (%5.1f%%)  total %6d (%5.1f%%)  %s\n",
          own, 100.0 * own / samples,
          total, 100.0 * total / samples,
          frame[:name]
        )
      end
    end

    def matching_frame?(frame, pattern)
      [frame[:name], frame[:file]].compact.any? { |value| value.to_s.match?(pattern) }
    end

    def summarize(results)
      samples = [results[:samples].to_i, 1].max
      frames = results[:frames].values.sort_by { |frame| -(frame[:samples] || 0) }
      {
        mode: results[:mode],
        interval: results[:interval],
        samples: results[:samples],
        gc_samples: results[:gc_samples],
        missed_samples: results[:missed_samples],
        top: frames.first(20).map { |frame| frame_summary(frame, samples) }
      }
    end

    def frame_summary(frame, samples)
      {
        name: frame[:name],
        file: frame[:file],
        line: frame[:line],
        samples: frame[:samples],
        total_samples: frame[:total_samples],
        pct: (100.0 * frame[:samples].to_i / samples).round(2)
      }
    end

    def sanitize(name)
      name.to_s.gsub(/[^A-Za-z0-9._-]+/, '_')
    end

    def markdown_summary(summaries)
      lines = ["### Profiles", '']
      summaries.sort.each do |name, data|
        lines << "#### `#{name}`"
        lines << ''
        lines << "mode=`#{data[:mode]}` samples=#{data[:samples]} gc=#{data[:gc_samples]} missed=#{data[:missed_samples]}"
        lines << ''
        lines << '| % | samples | frame |'
        lines << '| ---: | ---: | --- |'
        Array(data[:top]).first(8).each do |frame|
          lines << format('| %.1f | %s | `%s` |', frame[:pct], frame[:samples], frame[:name])
        end
        lines << ''
      end
      lines.join("\n")
    end

    def readme(dumps)
      <<~TEXT
        StackProf dumps from the CI scenario (STACKPROF=1).

          bundle exec stackprof tmp/stackprof/<name>.dump --text
          bundle exec stackprof tmp/stackprof/<name>.dump --method 'Async::Background::Queue::Store#'

        Dumps:
        #{dumps.map { |path| "  - #{File.basename(path)}" }.join("\n")}
      TEXT
    end
  end
end
