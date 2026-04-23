# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'Async::Background::Runner#run_job', type: :unit do
  before(:all) do
    unless defined?(::RunJobSpec_Cron)
      Object.const_set(:RunJobSpec_Cron, Class.new do
        include Async::Background::Job

        @runs = 0
        class << self
          attr_accessor :runs
        end

        def perform
          self.class.runs += 1
        end
      end)
    end
  end

  before do
    RunJobSpec_Cron.runs = 0
  end

  let(:schedule_path) do
    path = temp_file_path('.yml')
    File.write(path, {
      'cron_job' => {
        'class' => 'RunJobSpec_Cron',
        'cron' => '*/5 * * * *',
        'worker' => 1
      }
    }.to_yaml)
    path
  end

  let(:runner) do
    Async::Background::Runner.new(
      config_path: schedule_path,
      job_count: 1,
      worker_index: 1,
      total_workers: 1
    )
  end

  let(:entry) do
    Async::Background::Entry.new(
      name: 'cron_job',
      job_class: RunJobSpec_Cron,
      interval: nil,
      cron: Fugit::Cron.new('*/5 * * * *'),
      timeout: 30,
      next_run_at: 0.0
    )
  end

  let(:passthrough_task) do
    Class.new do
      def with_timeout(_seconds)
        yield
      end
    end.new
  end

  it 'executes cron/config jobs without touching queue retry state' do
    queue_store = instance_double('Async::Background::Queue::Store')
    runner.instance_variable_set(:@queue_store, queue_store)

    expect(queue_store).not_to receive(:retry_or_fail)
    expect(queue_store).not_to receive(:fail)
    expect(queue_store).not_to receive(:complete)

    runner.send(:run_job, passthrough_task, entry)

    expect(RunJobSpec_Cron.runs).to eq(1)
  end
end
