# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'

RSpec.describe Async::Background::Web::Request do
  let(:config) do
    Async::Background::Web::Configuration.new.tap do |value|
      value.queue_path = '/tmp/queue.db'
      value.auth = ->(_) { true }
    end
  end

  def request(query = '')
    described_class.new({'QUERY_STRING' => query}, config)
  end

  it 'parses a bounded limit and terminal cursor once' do
    cursor = Async::Background::Web::Cursor.encode_finished(10.5, 3)
    value = request("limit=75&cursor=#{cursor}")

    expect(value.limit).to eq(75)
    expect(value.finished_cursor).to eq(finished_at: 10.5, id: 3)
  end

  it 'rejects an invalid limit instead of silently changing the requested page' do
    expect { request('limit=zero').limit }
      .to raise_error(Async::Background::Web::RequestError, /positive integer/)
  end

  it 'rejects an invalid cursor instead of treating it as the first page' do
    expect { request('cursor=nope').finished_cursor }
      .to raise_error(Async::Background::Web::RequestError, 'invalid cursor')
  end
end
