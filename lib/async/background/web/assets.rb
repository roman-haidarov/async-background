# frozen_string_literal: true

require 'cgi'
require 'digest'

module Async
  module Background
    module Web
      module Assets
        CSS = <<~CSS
          :root {
            --bg: #0f1115;
            --panel: #161a20;
            --panel-soft: #1c2128;
            --border: #2a313b;
            --text: #e6e8ec;
            --text-dim: #98a2b3;
            --accent: #4f8ef7;
            --green: #4ade80;
            --amber: #fbbf24;
            --red: #f87171;
            --blue: #60a5fa;
            --gray: #94a3b8;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
          }
          header {
            display: flex;
            align-items: center;
            gap: 16px;
            padding: 14px 24px;
            border-bottom: 1px solid var(--border);
            background: var(--panel);
          }
          header h1 { font-size: 16px; margin: 0; font-weight: 600; }
          header .meta { color: var(--text-dim); font-size: 12px; }
          header .status-dot {
            width: 8px; height: 8px; border-radius: 50%;
            background: var(--gray);
            display: inline-block; margin-right: 6px;
          }
          header .status-dot.ok { background: var(--green); }
          header .status-dot.stale { background: var(--amber); }
          header .status-dot.error { background: var(--red); }
          main { padding: 16px 24px; }
          .counts {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 12px;
            margin-bottom: 20px;
          }
          .count-card {
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 12px 14px;
          }
          .count-card .label { color: var(--text-dim); font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
          .count-card .value { font-size: 24px; font-weight: 600; margin-top: 4px; font-variant-numeric: tabular-nums; }
          .count-card.executing .value { color: var(--blue); }
          .count-card.claimed .value { color: var(--amber); }
          .count-card.pending .value { color: var(--text); }
          .count-card.done .value { color: var(--green); }
          .count-card.failed .value { color: var(--red); }
          .totals {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
            gap: 12px;
            margin-bottom: 20px;
          }
          .total-card {
            background: var(--panel-soft);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 10px 12px;
          }
          .total-card .label { color: var(--text-dim); font-size: 11px; }
          .total-card .value { font-variant-numeric: tabular-nums; font-size: 18px; margin-top: 2px; }
          nav.tabs {
            display: flex;
            gap: 2px;
            border-bottom: 1px solid var(--border);
            margin-bottom: 12px;
            flex-wrap: wrap;
          }
          nav.tabs button {
            background: transparent;
            color: var(--text-dim);
            border: none;
            border-bottom: 2px solid transparent;
            padding: 10px 14px;
            font: inherit;
            cursor: pointer;
            border-radius: 0;
          }
          nav.tabs button:hover { color: var(--text); }
          nav.tabs button.active {
            color: var(--text);
            border-bottom-color: var(--accent);
          }
          nav.tabs button .badge {
            display: inline-block;
            background: var(--panel-soft);
            color: var(--text-dim);
            border-radius: 10px;
            padding: 1px 8px;
            font-size: 11px;
            margin-left: 6px;
            font-variant-numeric: tabular-nums;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 8px;
            overflow: hidden;
          }
          th, td {
            text-align: left;
            padding: 9px 12px;
            border-bottom: 1px solid var(--border);
            vertical-align: top;
            font-variant-numeric: tabular-nums;
          }
          tbody tr:last-child td { border-bottom: none; }
          th {
            background: var(--panel-soft);
            color: var(--text-dim);
            font-weight: 500;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: .04em;
          }
          td.dim { color: var(--text-dim); }
          td.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
          .empty {
            padding: 32px;
            text-align: center;
            color: var(--text-dim);
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: 8px;
          }
          .pagination {
            display: flex;
            gap: 8px;
            margin-top: 12px;
          }
          button.btn {
            background: var(--panel-soft);
            color: var(--text);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 6px 12px;
            font: inherit;
            cursor: pointer;
          }
          button.btn:hover { border-color: var(--accent); }
          button.btn:disabled { opacity: .4; cursor: not-allowed; }
          .err-msg {
            color: var(--red);
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 12px;
            max-width: 480px;
            white-space: pre-wrap;
            word-break: break-word;
          }
          .err-class { color: var(--amber); font-weight: 600; }
          .args-cell pre {
            margin: 0;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 12px;
            color: var(--text-dim);
            white-space: pre-wrap;
            word-break: break-all;
            max-width: 380px;
          }
          .args-redacted { color: var(--text-dim); font-style: italic; }
        CSS

        JS = <<~'JS'
          (function () {
            const state = {
              config: null,
              activeTab: 'executing',
              data: { executing: [], claimed: [], pending: [], done: [], failed: [] },
              cursors: { pending: null, done: null, failed: null },
              counts: { executing: 0, claimed: 0, pending: 0, done: 0, failed: 0 },
              totals: null,
              overview: null,
              dataVersion: null,
              lastUpdate: null,
              connection: 'connecting',
              stream: null,
              pollingTimer: null,
              pollingInFlight: false,
              listAbort: null,
              listRequestId: 0,
              listRefreshTimer: null,
              listRefreshQueued: false,
              listError: null
            };

            function initialBasePath() {
              if (document.body && document.body.dataset.mountPath !== undefined) {
                return document.body.dataset.mountPath;
              }

              if (document.currentScript && document.currentScript.src) {
                const scriptUrl = new URL(document.currentScript.src, location.origin);
                return scriptUrl.pathname.replace(/\/assets\/app\.js$/, '');
              }

              return location.pathname.replace(/\/$/, '');
            }

            const bootBasePath = initialBasePath();

            function basePath() {
              return state.config && state.config.mount_path !== undefined ?
                state.config.mount_path : bootBasePath;
            }

            class HttpError extends Error {
              constructor(response) {
                super('http ' + response.status);
                this.name = 'HttpError';
                this.status = response.status;
              }
            }

            async function api(path, params, signal) {
              const url = new URL(basePath() + path, location.origin);
              if (params) {
                Object.keys(params).forEach((key) => {
                  if (params[key] !== null && params[key] !== undefined) {
                    url.searchParams.set(key, params[key]);
                  }
                });
              }

              const response = await fetch(url.toString(), {
                credentials: 'same-origin',
                headers: { accept: 'application/json' },
                signal: signal
              });

              if (!response.ok) throw new HttpError(response);
              return response.json();
            }

            async function loadConfig() {
              state.config = await api('/api/config');
              const title = document.getElementById('title');
              if (title) title.textContent = state.config.title;
              document.title = state.config.title + ' dashboard';
            }

            async function refreshOverview() {
              try {
                applyOverview(await api('/api/overview'));
              } catch (error) {
                setConnection('error');
                return null;
              }
            }

            async function refreshActiveList(reset) {
              if (!state.config) return;

              const tab = state.activeTab;
              const requestId = ++state.listRequestId;
              const cursor = !reset ? state.cursors[tab] : null;
              const controller = new AbortController();

              if (state.listAbort) state.listAbort.abort();
              state.listAbort = controller;

              try {
                const params = { limit: state.config.list_limit };
                if (cursor) params.cursor = cursor;
                const payload = await api('/api/' + tab, params, controller.signal);

                if (requestId !== state.listRequestId || tab !== state.activeTab) return;

                const items = Array.isArray(payload.items) ? payload.items : Array.isArray(payload) ? payload : [];
                const nextCursor = Array.isArray(payload.items) ? payload.next_cursor || null : null;
                state.data[tab] = cursor ? state.data[tab].concat(items) : items;
                state.cursors[tab] = nextCursor;
                state.listError = null;
                renderList();
              } catch (error) {
                if (error.name === 'AbortError') return;
                if (requestId !== state.listRequestId || tab !== state.activeTab) return;

                state.listError = error;
                setConnection('error');
                renderList();
              } finally {
                if (requestId === state.listRequestId) state.listAbort = null;
              }
            }

            // Coalesce a burst of queue changes into at most one list request at a
            // time. The data_version snapshot is authoritative, so skipped
            // intermediate renders do not lose state.
            function scheduleActiveListRefresh() {
              state.listRefreshQueued = true;
              if (state.listRefreshTimer) return;

              state.listRefreshTimer = setTimeout(async function () {
                state.listRefreshTimer = null;
                while (state.listRefreshQueued) {
                  state.listRefreshQueued = false;
                  await refreshActiveList(true);
                }
              }, 100);
            }

            function applyOverview(overview) {
              state.overview = overview;
              state.counts = overview.counts || state.counts;
              state.dataVersion = overview.data_version;
              state.totals = overview.metrics || null;
              state.lastUpdate = Date.now();
              setConnection('ok', false);
              renderCounts();
              renderTotals();
              renderTabBadges();
              renderHeader(overview);
            }

            function setConnection(connection, render) {
              state.connection = connection;
              if (render !== false) renderHeader(state.overview);
            }

            function renderHeader(overview) {
              const dot = document.getElementById('status-dot');
              const meta = document.getElementById('meta');
              if (!dot || !meta) return;

              const stateClass = state.connection === 'ok' ? 'ok' : state.connection === 'stale' ? 'stale' : 'error';
              dot.className = 'status-dot ' + stateClass;

              const parts = [];
              if (state.connection === 'stale') parts.push('reconnecting');
              if (state.connection === 'error') parts.push('connection error');
              if (state.lastUpdate) parts.push('updated ' + relTime(state.lastUpdate) + ' ago');
              if (state.dataVersion !== null && state.dataVersion !== undefined) parts.push('data_version ' + state.dataVersion);
              if (overview && overview.next_pending_run_at) {
                parts.push('next pending in ' + formatDuration(overview.next_pending_run_at - (Date.now() / 1000)));
              }
              meta.textContent = parts.join(' · ');
            }

            function renderCounts() {
              const root = document.getElementById('counts');
              if (!root) return;
              root.replaceChildren();

              [
                ['executing', 'Executing'],
                ['claimed', 'Claimed'],
                ['pending', 'Pending'],
                ['done', 'Done'],
                ['failed', 'Failed']
              ].forEach(([key, label]) => {
                const card = document.createElement('div');
                card.className = 'count-card ' + key;
                const labelElement = document.createElement('div');
                labelElement.className = 'label';
                labelElement.textContent = label;
                const value = document.createElement('div');
                value.className = 'value';
                value.textContent = (state.counts[key] || 0).toLocaleString();
                card.append(labelElement, value);
                root.append(card);
              });
            }

            function renderTotals() {
              const root = document.getElementById('totals');
              if (!root) return;
              root.replaceChildren();
              if (!state.totals || !state.totals.totals) {
                root.style.display = 'none';
                return;
              }

              root.style.display = '';
              const totals = state.totals.totals;
              [
                ['total_runs', 'Runs'],
                ['total_successes', 'Successes'],
                ['total_failures', 'Failures'],
                ['total_timeouts', 'Timeouts'],
                ['total_skips', 'Skipped'],
                ['active_jobs', 'Active workers'],
                ['last_duration_ms', 'Last duration (ms)']
              ].forEach(([key, label]) => {
                const card = document.createElement('div');
                card.className = 'total-card';
                const labelElement = document.createElement('div');
                labelElement.className = 'label';
                labelElement.textContent = label;
                const value = document.createElement('div');
                value.className = 'value';
                value.textContent = totals[key] !== null && totals[key] !== undefined ? Number(totals[key]).toLocaleString() : '-';
                card.append(labelElement, value);
                root.append(card);
              });
            }

            function renderTabBadges() {
              ['executing', 'claimed', 'pending', 'done', 'failed'].forEach((key) => {
                const badge = document.querySelector('button[data-tab="' + key + '"] .badge');
                if (badge) badge.textContent = (state.counts[key] || 0).toLocaleString();
              });
            }

            function renderList() {
              const root = document.getElementById('list');
              const pagination = document.getElementById('pagination');
              if (!root) return;
              root.replaceChildren();
              if (pagination) pagination.replaceChildren();

              if (state.listError) {
                const error = document.createElement('div');
                error.className = 'empty';
                error.textContent = 'Unable to load jobs (' + state.listError.message + ')';
                root.append(error);
                return;
              }

              const items = state.data[state.activeTab] || [];
              if (items.length === 0) {
                const empty = document.createElement('div');
                empty.className = 'empty';
                empty.textContent = 'No jobs in this list';
                root.append(empty);
                return;
              }

              root.append(buildTable(state.activeTab, items));
              renderPagination();
            }

            function renderPagination() {
              const root = document.getElementById('pagination');
              if (!root || !['pending', 'done', 'failed'].includes(state.activeTab)) return;
              if (!state.cursors[state.activeTab]) return;

              const button = document.createElement('button');
              button.className = 'btn';
              button.type = 'button';
              button.textContent = 'Load more';
              button.addEventListener('click', () => refreshActiveList(false));
              root.append(button);
            }

            function buildTable(tab, items) {
              const table = document.createElement('table');
              const columns = tableColumns(tab);
              const head = document.createElement('thead');
              const headRow = document.createElement('tr');
              columns.forEach((column) => {
                const cell = document.createElement('th');
                cell.textContent = column.label;
                headRow.append(cell);
              });
              head.append(headRow);
              table.append(head);

              const body = document.createElement('tbody');
              items.forEach((item) => {
                const row = document.createElement('tr');
                columns.forEach((column) => {
                  const cell = document.createElement('td');
                  column.render(cell, item);
                  row.append(cell);
                });
                body.append(row);
              });
              table.append(body);
              return table;
            }

            function tableColumns(tab) {
              const id = { label: 'ID', render: (cell, item) => { cell.className = 'mono dim'; cell.textContent = item.id; } };
              const klass = { label: 'Class', render: (cell, item) => { cell.className = 'mono'; cell.textContent = item.class_name; } };
              const args = {
                label: 'Args',
                render: (cell, item) => {
                  cell.className = 'args-cell';
                  if (state.config && state.config.expose_args) {
                    if (item.args === null || item.args === undefined) {
                      cell.textContent = '(' + (item.args_count || 0) + ')';
                    } else {
                      const pre = document.createElement('pre');
                      pre.textContent = JSON.stringify(item.args);
                      cell.append(pre);
                    }
                  } else {
                    const hidden = document.createElement('span');
                    hidden.className = 'args-redacted';
                    hidden.textContent = (item.args_count || 0) + ' args (hidden)';
                    cell.append(hidden);
                  }
                }
              };
              const time = (key, label) => ({
                label: label,
                render: (cell, item) => { cell.className = 'dim mono'; cell.textContent = formatTime(item[key]); }
              });
              const duration = {
                label: 'Duration',
                render: (cell, item) => { cell.className = 'mono dim'; cell.textContent = item.duration_ms ? item.duration_ms + ' ms' : '-'; }
              };
              const error = {
                label: 'Error',
                render: (cell, item) => {
                  cell.className = 'err-msg';
                  if (!item.last_error_class) {
                    cell.textContent = '-';
                    return;
                  }
                  const errorClass = document.createElement('span');
                  errorClass.className = 'err-class';
                  errorClass.textContent = item.last_error_class;
                  cell.append(errorClass, document.createTextNode(' ' + (item.last_error_message || '')));
                }
              };

              if (tab === 'executing') return [id, klass, args, time('started_at', 'Started'), { label: 'Worker', render: (cell, item) => { cell.className = 'mono dim'; cell.textContent = item.locked_by; } }];
              if (tab === 'claimed') return [id, klass, args, time('locked_at', 'Claimed'), { label: 'Worker', render: (cell, item) => { cell.className = 'mono dim'; cell.textContent = item.locked_by; } }];
              if (tab === 'done') return [id, klass, args, time('finished_at', 'Finished'), duration];
              if (tab === 'failed') return [id, klass, args, time('finished_at', 'Finished'), duration, error];
              return [id, klass, args, time('run_at', 'Run at')];
            }

            function setActiveTab(tab) {
              if (tab === state.activeTab) return;
              state.activeTab = tab;
              state.cursors[tab] = null;
              state.listError = null;
              document.querySelectorAll('nav.tabs button').forEach((button) => {
                button.classList.toggle('active', button.dataset.tab === tab);
              });
              refreshActiveList(true);
            }

            function attachTabs() {
              document.querySelectorAll('nav.tabs button').forEach((button) => {
                button.addEventListener('click', () => setActiveTab(button.dataset.tab));
              });
            }

            function streamUrl() {
              return new URL(basePath() + '/api/stream', location.origin).toString();
            }

            function stopStream() {
              if (state.stream) state.stream.close();
              state.stream = null;
            }

            function startStream() {
              stopStream();
              setConnection('stale');

              const stream = new EventSource(streamUrl());
              state.stream = stream;

              stream.addEventListener('overview', (event) => {
                if (state.stream !== stream) return;
                try {
                  applyOverview(JSON.parse(event.data));
                  scheduleActiveListRefresh();
                } catch (_) {
                  setConnection('error');
                }
              });

              stream.addEventListener('unavailable', () => {
                if (state.stream === stream) setConnection('stale');
              });

              stream.addEventListener('open', () => {
                if (state.stream === stream) setConnection('ok');
              });

              stream.addEventListener('error', () => {
                if (state.stream !== stream) return;
                setConnection(stream.readyState === EventSource.CLOSED ? 'error' : 'stale');
              });
            }

            async function pollingTick() {
              if (state.pollingInFlight) return;
              state.pollingInFlight = true;
              try {
                await refreshOverview();
                await refreshActiveList(true);
              } finally {
                state.pollingInFlight = false;
              }
            }

            function startPolling() {
              pollingTick();
              state.pollingTimer = setInterval(pollingTick, state.config.poll_interval_ms);
            }

            function formatTime(seconds) {
              if (!seconds) return '-';
              const date = new Date(seconds * 1000);
              return isNaN(date.getTime()) ? '-' : date.toLocaleString();
            }

            function formatDuration(seconds) {
              if (!isFinite(seconds)) return '-';
              if (seconds <= 0) return 'now';
              if (seconds < 60) return Math.round(seconds) + 's';
              if (seconds < 3600) return Math.round(seconds / 60) + 'm';
              return Math.round(seconds / 3600) + 'h';
            }

            function relTime(timestamp) {
              return formatDuration((Date.now() - timestamp) / 1000);
            }

            async function boot() {
              attachTabs();
              await loadConfig();
              await Promise.all([refreshOverview(), refreshActiveList(true)]);

              if (state.config.transport === 'sse' && typeof EventSource !== 'undefined') {
                startStream();
              } else {
                startPolling();
              }

              setInterval(() => renderHeader(state.overview), 1000);
            }

            function start() {
              boot().catch((error) => {
                setConnection('error');
                if (window.console && console.error) console.error('Async::Background dashboard boot failed', error);
              });
            }

            window.addEventListener('beforeunload', () => {
              stopStream();
              if (state.pollingTimer) clearInterval(state.pollingTimer);
              if (state.listRefreshTimer) clearTimeout(state.listRefreshTimer);
              if (state.listAbort) state.listAbort.abort();
            }, { once: true });

            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', start, { once: true });
            } else {
              start();
            }
          })();
        JS

        INDEX_HTML = <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>%<title>s</title>
            <link rel="stylesheet" href="%<base>s/assets/app.css?v=%<asset_version>s">
          </head>
          <body data-mount-path="%<base>s">
            <header>
              <h1 id="title">%<title>s</h1>
              <span class="meta"><span id="status-dot" class="status-dot"></span><span id="meta"></span></span>
            </header>
            <main>
              <section id="counts" class="counts"></section>
              <section id="totals" class="totals"></section>
              <nav class="tabs">
                <button type="button" data-tab="executing" class="active">Executing <span class="badge">0</span></button>
                <button type="button" data-tab="claimed">Claimed <span class="badge">0</span></button>
                <button type="button" data-tab="pending">Pending <span class="badge">0</span></button>
                <button type="button" data-tab="done">Done <span class="badge">0</span></button>
                <button type="button" data-tab="failed">Failed <span class="badge">0</span></button>
              </nav>
              <section id="list"></section>
              <section id="pagination" class="pagination"></section>
            </main>
            <script defer src="%<base>s/assets/app.js?v=%<asset_version>s"></script>
          </body>
          </html>
        HTML

        module_function

        def asset_version
          @asset_version ||= Digest::SHA256.hexdigest("#{JS}\0#{CSS}")[0, 12]
        end

        def render_index(config)
          base = config.mount_path.to_s.sub(%r{/\z}, '')
          format(
            INDEX_HTML,
            title: CGI.escapeHTML(config.title.to_s),
            base: CGI.escapeHTML(base),
            asset_version: asset_version
          )
        end
      end
    end
  end
end
