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
