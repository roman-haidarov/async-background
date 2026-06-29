# frozen_string_literal: true

require 'spec_helper'
require 'async/background/web'
require 'json'

RSpec.describe Async::Background::Web::App do
  let(:db_path) { temp_db_path }

  before do
    Async::Background::Queue::Store.prepare_dashboard!(path: db_path)
  end

  def build_app(overrides = {})
    config = Async::Background::Web::Configuration.new
    config.queue_path = db_path
    config.auth = ->(env) { env['HTTP_X_TOKEN'] == 'allow' }
    overrides.each { |k, v| config.public_send("#{k}=", v) }
    described_class.new(config)
  end

  def env_for(method:, path:, headers: {}, query: '')
    base = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'QUERY_STRING' => query
    }
    headers.each { |k, v| base["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    base
  end

  describe 'auth gate' do
    it 'returns 401 JSON when auth callable returns falsy' do
      app = build_app
      status, headers, body = app.call(env_for(method: 'GET', path: '/api/overview'))
      expect(status).to eq(401)
      expect(headers['content-type']).to start_with('application/json')
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(error: 'unauthorized')
    end

    it 'returns 401 when auth callable raises' do
      app = build_app
      app.instance_variable_set(
        :@auth,
        Async::Background::Web::Auth.new(->(_env) { raise 'boom' })
      )
      status, = app.call(env_for(method: 'GET', path: '/api/overview'))
      expect(status).to eq(401)
    end

    it 'forwards raising auth callables to the configured logger' do
      logger = instance_double('Logger', warn: nil, error: nil)
      app = build_app(logger: logger)
      app.instance_variable_set(
        :@auth,
        Async::Background::Web::Auth.new(->(_env) { raise 'boom from auth' }, logger: logger)
      )

      app.call(env_for(method: 'GET', path: '/api/overview'))

      expect(logger).to have_received(:warn).with(/boom from auth/)
    end

    it 'lets the request through when auth returns truthy' do
      app = build_app
      status, headers, = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('application/json')
    end
  end

  describe '/api/overview' do
    let(:app) { build_app }

    it 'returns json with counts and data_version' do
      _, _, body = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload).to include(:counts, :data_version, :generated_at)
      expect(payload[:counts]).to include(:executing, :claimed, :pending, :done, :failed)
    end
  end

  describe '/api/config' do
    let(:app) { build_app(title: 'My Background', poll_interval_ms: 1500) }

    it 'exposes UI knobs' do
      _, _, body = app.call(env_for(method: 'GET', path: '/api/config', headers: { 'x-token' => 'allow' }))
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload[:title]).to eq('My Background')
      expect(payload[:poll_interval_ms]).to eq(1500)
      expect(payload[:expose_args]).to eq(false)
      expect(payload[:transport]).to eq('sse')
    end

    it 'reports sse when transport is sse' do
      app = build_app(transport: :sse)
      _, _, body = app.call(env_for(method: 'GET', path: '/api/config', headers: { 'x-token' => 'allow' }))
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload[:transport]).to eq('sse')
    end
  end

  describe '/api/stream' do
    it 'returns 404 when transport is explicitly polling' do
      app = build_app(transport: :polling)
      status, = app.call(env_for(method: 'GET', path: '/api/stream', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(404)
    end

    it 'returns 200 text/event-stream when transport is sse' do
      app = build_app(transport: :sse)
      status, headers, body = app.call(env_for(method: 'GET', path: '/api/stream', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/event-stream')
      expect(headers['cache-control']).to include('no-cache')
      expect(headers['x-accel-buffering']).to eq('no')
      expect(headers['x-content-type-options']).to eq('nosniff')
      expect(body).to respond_to(:each)
    end

    it 'requires auth like every other endpoint' do
      app = build_app(transport: :sse)
      status, = app.call(env_for(method: 'GET', path: '/api/stream'))
      expect(status).to eq(401)
    end
  end

  describe 'HEAD requests' do
    let(:app) { build_app }

    it 'returns the same headers as GET with an empty body for JSON endpoints' do
      get_status, get_headers, get_body = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      head_status, head_headers, head_body = app.call(env_for(method: 'HEAD', path: '/api/overview', headers: { 'x-token' => 'allow' }))

      expect(head_status).to eq(get_status)
      expect(head_headers).to eq(get_headers)
      expect(head_body).to eq([])
      expect(get_body.first).not_to be_empty
    end

    it 'returns sse headers without opening a stream for HEAD on /api/stream' do
      status, headers, body = app.call(env_for(method: 'HEAD', path: '/api/stream', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/event-stream')
      expect(body).to eq([])
    end

    it 'enforces auth on HEAD requests too' do
      status, = app.call(env_for(method: 'HEAD', path: '/api/overview'))
      expect(status).to eq(401)
    end
  end

  describe 'method gate' do
    let(:app) { build_app }

    it 'returns 404 for non-GET/HEAD methods' do
      %w[POST PUT DELETE PATCH OPTIONS].each do |method|
        status, = app.call(env_for(method: method, path: '/api/overview', headers: { 'x-token' => 'allow' }))
        expect(status).to eq(404), "expected #{method} to be rejected"
      end
    end
  end

  describe 'security headers' do
    let(:app) { build_app(mount_path: '/admin/background') }

    it 'sets strict CSP and frame protection on the HTML shell' do
      _, headers, = app.call(env_for(method: 'GET', path: '/', headers: { 'x-token' => 'allow' }))

      expect(headers['x-content-type-options']).to eq('nosniff')
      expect(headers['x-frame-options']).to eq('DENY')
      expect(headers['referrer-policy']).to eq('no-referrer')
      expect(headers['content-security-policy']).to include("frame-ancestors 'none'")
      expect(headers['content-security-policy']).to include("default-src 'none'")
      expect(headers['content-security-policy']).to include("script-src 'self'")
      expect(headers['content-security-policy']).to include("base-uri 'none'")
      expect(headers['content-security-policy']).to include("form-action 'none'")
    end

    it 'sets nosniff and referrer-policy on JSON API responses' do
      _, headers, = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      expect(headers['x-content-type-options']).to eq('nosniff')
      expect(headers['referrer-policy']).to eq('no-referrer')
      expect(headers['cross-origin-resource-policy']).to eq('same-origin')
    end

    it 'sets nosniff on cacheable assets' do
      _, headers, = app.call(env_for(method: 'GET', path: '/assets/app.js', headers: { 'x-token' => 'allow' }))
      expect(headers['x-content-type-options']).to eq('nosniff')
    end

    it 'sets nosniff on 401 and 404 responses too' do
      _, h401, = app.call(env_for(method: 'GET', path: '/api/overview'))
      _, h404, = app.call(env_for(method: 'GET', path: '/nope', headers: { 'x-token' => 'allow' }))

      expect(h401['x-content-type-options']).to eq('nosniff')
      expect(h404['x-content-type-options']).to eq('nosniff')
    end
  end

  describe 'in-flight routes' do
    let(:app) { build_app }

    it 'returns an item envelope for executing jobs' do
      status, _, body = app.call(env_for(method: 'GET', path: '/api/executing', headers: { 'x-token' => 'allow' }))

      expect(status).to eq(200)
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(items: [])
    end

    it 'returns an item envelope for claimed jobs' do
      status, _, body = app.call(env_for(method: 'GET', path: '/api/claimed', headers: { 'x-token' => 'allow' }))

      expect(status).to eq(200)
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(items: [])
    end
  end

  describe '/api/done with cursor' do
    let(:app) { build_app }

    before do
      store = Async::Background::Queue::Store.new(path: db_path)
      5.times do |i|
        store.enqueue('CursorJob', [i], 1_700_000_000.0 - 100)
        job = store.fetch(1)
        store.complete(job[:id], claim_token: job[:claim_token], finished_at: 1_700_000_000.0 + i, duration_ms: 1)
      end
      store.close
    end

    it 'returns items and next_cursor' do
      _, _, body = app.call(env_for(method: 'GET', path: '/api/done', query: 'limit=2', headers: { 'x-token' => 'allow' }))
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload[:items].length).to eq(2)
      expect(payload[:next_cursor]).not_to be_nil
    end
  end

  describe '/api/metrics' do
    it 'reports unavailable when metrics_path is not configured' do
      app = build_app
      _, _, body = app.call(env_for(method: 'GET', path: '/api/metrics', headers: { 'x-token' => 'allow' }))
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload[:available]).to eq(false)
    end
  end

  describe '/' do
    let(:app) { build_app }

    it 'serves the HTML shell' do
      status, headers, body = app.call(env_for(method: 'GET', path: '/', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/html')
      expect(body.first).to include('<title>')
      expect(body.first).to include('Async::Background')
    end

    it 'serves the JS asset' do
      status, headers, body = app.call(env_for(method: 'GET', path: '/assets/app.js', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('application/javascript')
      expect(body.first).to include('DOMContentLoaded')
    end

    it 'embeds the configured mount path into the HTML shell' do
      app = build_app(mount_path: '/admin/background')
      status, _, body = app.call(env_for(method: 'GET', path: '/', headers: { 'x-token' => 'allow' }))

      expect(status).to eq(200)
      expect(body.first).to include('data-mount-path="/admin/background"')
      expect(body.first).to include('src="/admin/background/assets/app.js?v=')
      expect(body.first).to include('app.css?v=')
    end

    it 'serves the CSS asset' do
      status, headers = app.call(env_for(method: 'GET', path: '/assets/app.css', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(200)
      expect(headers['content-type']).to start_with('text/css')
    end
  end

  describe 'unknown routes' do
    let(:app) { build_app }

    it 'returns 404 JSON' do
      status, headers, body = app.call(env_for(method: 'GET', path: '/nope', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(404)
      expect(headers['content-type']).to start_with('application/json')
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(error: 'not_found')
    end
  end

  describe 'request errors' do
    let(:app) { build_app }

    it 'returns 400 for a malformed cursor instead of silently restarting pagination' do
      status, _, body = app.call(
        env_for(method: 'GET', path: '/api/done', query: 'cursor=not-a-cursor', headers: { 'x-token' => 'allow' })
      )

      expect(status).to eq(400)
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(error: 'invalid_request', message: 'invalid cursor')
    end

    it 'returns 400 for a non-positive limit' do
      status, _, body = app.call(
        env_for(method: 'GET', path: '/api/pending', query: 'limit=0', headers: { 'x-token' => 'allow' })
      )

      expect(status).to eq(400)
      expect(JSON.parse(body.first, symbolize_names: true)).to include(error: 'invalid_request')
    end
  end

  describe 'lifecycle' do
    it 'returns 503 after the read model is closed' do
      app = build_app
      app.close

      status, _, body = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(503)
      expect(JSON.parse(body.first, symbolize_names: true)).to eq(error: 'service_unavailable')
    end
  end

  describe 'internal errors' do
    let(:app) { build_app }

    it 'wraps internal exceptions in 500 JSON' do
      allow_any_instance_of(Async::Background::Web::Snapshot).to receive(:overview).and_raise(RuntimeError, 'kaboom')
      status, headers, body = app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))
      expect(status).to eq(500)
      expect(headers['content-type']).to start_with('application/json')
      payload = JSON.parse(body.first, symbolize_names: true)
      expect(payload).to eq(error: 'internal_error')
    end

    it 'forwards internal exceptions to the configured logger' do
      logger = instance_double('Logger', warn: nil, error: nil)
      app = build_app(logger: logger)
      allow_any_instance_of(Async::Background::Web::Snapshot).to receive(:overview).and_raise(RuntimeError, 'kaboom')

      app.call(env_for(method: 'GET', path: '/api/overview', headers: { 'x-token' => 'allow' }))

      expect(logger).to have_received(:error).with(/kaboom/)
    end
  end
end
