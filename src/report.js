'use strict';
const DATA = JSON.parse(document.getElementById('resource-data').textContent),
  $ = (id) => document.getElementById(id);
const esc = (x) =>
  String(x == null ? '' : x).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]
  );
const size = (x) =>
  x == null
    ? 'Unavailable'
    : Math.abs(x) >= 1073741824
      ? (x / 1073741824).toFixed(2) + ' GiB'
      : Math.abs(x) >= 1048576
        ? (x / 1048576).toFixed(1) + ' MiB'
        : Math.abs(x) >= 1024
          ? (x / 1024).toFixed(0) + ' KiB'
          : x.toFixed(0) + ' B';
const pct = (x) => (x == null ? '—' : x.toFixed(1) + '%'),
  num = (x) => (x == null ? '—' : x.toFixed(1)),
  rate = (x) => (x == null ? 'Unavailable' : size(x) + '/s');
const finite = (x) => typeof x === 'number' && Number.isFinite(x),
  width = (x) => Math.min(100, Math.max(0, x || 0)).toFixed(1) + '%';
const signed = (x, format) => (x == null ? 'No baseline' : (x > 0 ? '+' : '') + format(x));
const when = (x) => new Date(x).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
const duration = (x) =>
  x == null
    ? 'Unavailable'
    : x >= 86400
      ? (x / 86400).toFixed(1) + ' days'
      : x >= 3600
        ? (x / 3600).toFixed(1) + ' hours'
        : x >= 60
          ? Math.round(x / 60) + ' min'
          : Math.round(x) + ' sec';
const shellQuote = (x) => "'" + String(x).replace(/'/g, "'\\''") + "'";
const limitsDefault = ResourceRules.defaults(DATA.system.memory);
let state = {
  page: 'overview',
  mode: 'all',
  search: '',
  sort: 'priority',
  direction: -1,
  category: 'all',
  flagged: false,
  pinnedOnly: false,
  hideSystem: false,
  hideIdle: false,
  limit: 50,
  paused: false,
  baseline: 'auto'
};
let prefs = { theme: 'system', limits: { ...limitsDefault }, pins: [] },
  imported = null;
function readStore(store, key) {
  try {
    return JSON.parse(store.getItem(key) || 'null');
  } catch {
    return null;
  }
}
const safeStorage = (name) => {
  try {
    return window[name];
  } catch {
    return null;
  }
};
const SESSION = safeStorage('sessionStorage'),
  LOCAL = safeStorage('localStorage');
Object.assign(state, readStore(SESSION, 'resource-check-view-v2') || {});
Object.assign(prefs, readStore(LOCAL, 'resource-check-prefs-v2') || {});
imported = readStore(SESSION, 'resource-check-import-v2');
if (!['overview', 'investigate', 'history', 'settings'].includes(state.page))
  state.page = 'overview';
if (!['all', 'mine', 'processes'].includes(state.mode)) state.mode = 'all';
if (
  ![
    'priority',
    'cpu',
    'peakCPU',
    'memory',
    'memoryDelta',
    'energy',
    'wakeups',
    'threads',
    'sleep'
  ].includes(state.sort)
)
  state.sort = 'priority';
if (!['light', 'dark', 'system'].includes(prefs.theme)) prefs.theme = 'system';
if (!Array.isArray(prefs.pins)) prefs.pins = [];
prefs.pins = prefs.pins.filter((x) => typeof x === 'string').slice(0, 200);
if (
  !prefs.limits ||
  !Object.keys(limitsDefault).every((k) => finite(prefs.limits[k]) && prefs.limits[k] > 0)
)
  prefs.limits = { ...limitsDefault };
state.limit = Math.min(2000, Math.max(50, Number(state.limit) || 50));
state.direction = state.direction === 1 ? 1 : -1;
let visible = [],
  chartRows = {},
  detailRow = null,
  toastTimer;
function store() {
  try {
    SESSION.setItem('resource-check-view-v2', JSON.stringify(state));
    LOCAL.setItem('resource-check-prefs-v2', JSON.stringify(prefs));
  } catch {}
}
function toast(text) {
  $('toast').textContent = text;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    $('toast').hidden = true;
  }, 2800);
}
async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied');
  } catch {
    const box = document.createElement('textarea');
    box.value = text;
    box.style.position = 'fixed';
    box.style.left = '-9999px';
    document.body.append(box);
    box.select();
    const ok = document.execCommand('copy');
    box.remove();
    toast(ok ? 'Copied' : 'Select and copy the command manually');
  }
}
function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type: type || 'text/plain;charset=utf-8' })),
    a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function pinKey(r) {
  return (r.appPath || r.path) + ':' + r.uid;
}
function pinned(r) {
  return prefs.pins.includes(pinKey(r));
}
function togglePin(r) {
  const key = pinKey(r);
  prefs.pins = prefs.pins.includes(key)
    ? prefs.pins.filter((x) => x !== key)
    : prefs.pins.concat(key).slice(-200);
  render();
  toast(pinned(r) ? 'Pinned app' : 'Pin removed');
}
const scans = Array.isArray(DATA.history) ? DATA.history : [];
function baseline() {
  if (state.baseline === 'imported' && imported) return imported;
  if (state.baseline !== 'auto') {
    const found = scans.find((x) => x.collectedAt === state.baseline);
    if (found) return found;
  }
  return scans.filter((x) => x.collectedAt !== DATA.collectedAt).slice(-1)[0] || null;
}
function comparisonMap() {
  const b = baseline();
  return new Map(b ? b.apps.map((r) => [r.id, r]) : []);
}
function decorate(r) {
  return { ...r, advice: ResourceRules.evaluate(r, DATA.system, prefs.limits) };
}
function baseRows() {
  return (
    state.mode === 'processes'
      ? DATA.processes
      : state.mode === 'mine'
        ? DATA.apps.filter((r) => r.isMine && r.appPath)
        : DATA.apps
  ).map(decorate);
}
function metric(r, key, previous) {
  if (key === 'priority') return r.advice.score;
  if (key === 'sleep') return r.sleep === null ? -1 : Number(r.sleep);
  if (key === 'memoryDelta') {
    const change = memoryDelta(r, previous);
    return change == null ? -Infinity : change;
  }
  return r[key] == null ? -Infinity : r[key];
}
function memoryDelta(r, previous) {
  if (state.mode === 'processes') return r.memoryChange == null ? null : r.memoryChange;
  const before = previous.get(r.id);
  return before && finite(before.memory) && finite(r.memory) ? r.memory - before.memory : null;
}
function selectedRows() {
  const q = state.search.toLowerCase().trim(),
    before = comparisonMap();
  return baseRows()
    .filter(
      (r) =>
        (!state.flagged || r.advice.flags.length) &&
        (!state.pinnedOnly || pinned(r)) &&
        (!state.hideSystem || !r.system) &&
        (!state.hideIdle || (r.cpu || 0) >= 1 || (r.memory || 0) >= 104857600 || r.sleep) &&
        (state.category === 'all' || r.category === state.category) &&
        (!q ||
          (r.name + ' ' + (r.command || '') + ' ' + r.path + ' ' + (r.pids || [r.pid]).join(' '))
            .toLowerCase()
            .includes(q))
    )
    .sort((a, b) => {
      const av = metric(a, state.sort, before),
        bv = metric(b, state.sort, before);
      return (av === bv ? 0 : state.direction * (av - bv)) || a.name.localeCompare(b.name);
    });
}
function lineChart(points, field, color, format, xField = 'second', small = false) {
  const valid = points.filter((p) => finite(p[field]) && finite(p[xField]));
  if (!valid.length) return '<p class="small empty">No measurements available yet.</p>';
  const w = 600,
    h = small ? 36 : 145,
    left = small ? 0 : 62,
    right = 10,
    top = 12,
    bottom = small ? 2 : 22,
    vals = valid.map((p) => p[field]),
    xs = valid.map((p) => p[xField]);
  let lo = Math.min(...vals),
    hi = Math.max(...vals),
    xmin = Math.min(...xs),
    xmax = Math.max(...xs);
  if (lo === hi) {
    lo = Math.max(0, lo - 1);
    hi = hi + 1;
  }
  const x = (p) => left + ((p[xField] - xmin) / (xmax - xmin || 1)) * (w - left - right),
    y = (p) => top + ((hi - p[field]) / (hi - lo)) * (h - top - bottom);
  const path = valid
    .map((p, i) => (i ? 'L' : 'M') + x(p).toFixed(2) + ',' + y(p).toFixed(2))
    .join(' ');
  let grid = small
    ? ''
    : [0, 0.5, 1]
        .map((f) => {
          const yy = top + f * (h - top - bottom);
          return (
            '<line x1="' +
            left +
            '" x2="' +
            (w - right) +
            '" y1="' +
            yy +
            '" y2="' +
            yy +
            '" stroke="var(--line)"/><text x="' +
            (left - 6) +
            '" y="' +
            (yy + 3) +
            '" text-anchor="end" font-size="9" fill="var(--muted)">' +
            esc(format(hi - f * (hi - lo))) +
            '</text>'
          );
        })
        .join('');
  return (
    '<svg class="' +
    (small ? '' : 'line-chart') +
    '" viewBox="0 0 ' +
    w +
    ' ' +
    h +
    '" role="img" aria-label="' +
    esc(field + ' trend, ' + valid.length + ' measurements') +
    '"><title>' +
    esc('Range ' + format(Math.min(...vals)) + ' to ' + format(Math.max(...vals))) +
    '</title>' +
    grid +
    '<path d="' +
    path +
    '" fill="none" stroke="' +
    color +
    '" stroke-width="' +
    (small ? 3 : 2.5) +
    '" stroke-linecap="round"/>' +
    valid
      .map(
        (p) =>
          '<circle cx="' +
          x(p).toFixed(2) +
          '" cy="' +
          y(p).toFixed(2) +
          '" r="' +
          (small ? 0 : 3) +
          '" fill="' +
          color +
          '"><title>' +
          esc(format(p[field])) +
          '</title></circle>'
      )
      .join('') +
    '</svg>'
  );
}
function keyStat(value, label) {
  return (
    '<div class="key-stat"><strong>' + esc(value) + '</strong><span>' + esc(label) + '</span></div>'
  );
}
function theme() {
  const dark =
    prefs.theme === 'dark' ||
    (prefs.theme === 'system' &&
      window.matchMedia &&
      window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  $('theme').value = prefs.theme;
}
function summary() {
  if (DATA.demo) {
    $('demo-note').hidden = false;
    $('demo-note').textContent = 'Demo · Synthetic sample data. This page does not scan your Mac.';
  }
  const s = DATA.system;
  $('timestamp').textContent =
    when(DATA.collectedAt) +
    ' · ' +
    DATA.sampleSeconds +
    's sample · ' +
    DATA.processes.length +
    ' processes';
  $('cpu-total').textContent = pct(s.cpu);
  const cpuPoints = (DATA.systemSeries || []).map((p) => p.cpu).filter(finite);
  $('cpu-detail').textContent =
    DATA.cores + ' logical cores · peak ' + pct(cpuPoints.length ? Math.max(...cpuPoints) : null);
  $('cpu-spark').innerHTML = lineChart(
    DATA.systemSeries || [],
    'cpu',
    'var(--cpu)',
    pct,
    'second',
    true
  );
  $('pressure').textContent = s.pressure;
  $('pressure').style.color =
    s.pressure === 'Critical'
      ? 'var(--red)'
      : s.pressure === 'Elevated'
        ? 'var(--cpu)'
        : 'var(--ink)';
  $('memory-detail').textContent = size(s.memoryUsed) + ' / ' + size(s.memory) + ' reported used';
  $('swap-detail').textContent = 'Swap used ' + size(s.swap);
  $('battery').textContent =
    s.battery.percent === null ? s.battery.source : s.battery.percent + '% battery';
  $('power-detail').textContent = s.battery.source + ' · ' + s.battery.status;
  const blockers = DATA.apps.filter((r) => r.sleep).length,
    thermal = ['normal', 'fair', 'serious', 'critical'][s.thermal] || 'unavailable';
  $('sleep-detail').textContent =
    (DATA.sleepAvailable
      ? blockers + ' idle-sleep blocker' + (blockers === 1 ? '' : 's')
      : 'Sleep data unavailable') +
    ' · thermal ' +
    thermal;
  $('disk-free').textContent = s.disk ? size(s.disk.available) : 'Unavailable';
  $('disk-detail').textContent = s.disk
    ? s.disk.percent + '% used · ' + size(s.disk.total) + ' capacity'
    : 'Startup volume unavailable';
  $('disk-track').style.width = width(s.disk ? s.disk.percent : 0);
  $('swap-rate').textContent = s.swapActivity
    ? rate(s.swapActivity.inBytes + s.swapActivity.outBytes)
    : 'Unavailable';
  $('swap-rate-detail').textContent = s.swapActivity
    ? 'In ' + rate(s.swapActivity.inBytes) + ' · out ' + rate(s.swapActivity.outBytes)
    : 'Swap transfers could not be sampled';
  const net = s.network,
    down = net ? net.reduce((n, r) => n + r.inBytes, 0) : null,
    up = net ? net.reduce((n, r) => n + r.outBytes, 0) : null;
  $('network-rate').textContent = rate(down);
  $('network-detail').textContent = net
    ? 'Download · upload ' + rate(up)
    : 'Interface counters unavailable';
  const drive =
    s.diskActivity && (s.diskActivity.find((d) => d.name === 'disk0') || s.diskActivity[0]);
  $('io-detail').textContent = drive
    ? drive.name + ' I/O ' + drive.megabytes.toFixed(2) + ' MB/s · read + write'
    : 'Disk activity unavailable';
  $('system-version').textContent = DATA.osVersion + ' · uptime ' + duration(s.uptime);
  $('scan-count').textContent = scans.length + ' saved scan' + (scans.length === 1 ? '' : 's');
  $('warnings').innerHTML = DATA.warnings.length
    ? '<div class="warning">' + DATA.warnings.map(esc).join('<br>') + '</div>'
    : '';
  $('sample-quality').textContent = DATA.sampleCount + ' usable intervals';
  $('sample-chart').innerHTML = lineChart(DATA.systemSeries || [], 'cpu', 'var(--cpu)', pct);
  $('sample-stats').innerHTML =
    keyStat(DATA.sampleSeconds + ' sec', 'Observation window') +
    keyStat(DATA.processes.length, 'Processes in final sample') +
    keyStat(DATA.collectorExcluded, 'Collector processes excluded') +
    keyStat(
      DATA.processes.filter((p) => p.observedSamples === DATA.sampleCount).length,
      'Processes observed across all intervals'
    );
  $('system-context').innerHTML =
    keyStat(size(s.wired), 'Wired memory') +
    keyStat(size(s.compressed), 'Compressed memory') +
    keyStat(s.battery.remaining || 'Unavailable', 'Battery estimate reported by macOS') +
    keyStat(duration(s.uptime), 'Time since startup');
  $('interface-details').innerHTML =
    '<p class="small">Rates over about ' +
    (s.ioSampleSeconds || DATA.sampleSeconds) +
    ' seconds. Device counters can be rounded.</p>' +
    (net || [])
      .map(
        (n) =>
          '<p class="small">' +
          esc(n.name) +
          ': down ' +
          rate(n.inBytes) +
          ', up ' +
          rate(n.outBytes) +
          '</p>'
      )
      .join('') +
    (s.diskActivity || [])
      .map(
        (d) =>
          '<p class="small">' +
          esc(d.name) +
          ': ' +
          d.megabytes.toFixed(2) +
          ' MB/s · ' +
          d.transfers.toFixed(1) +
          ' transfers/s</p>'
      )
      .join('');
  if (DATA.watch) {
    $('live').innerHTML = '<button class="quiet" id="pause"></button>';
    $('pause').onclick = () => {
      state.paused = !state.paused;
      store();
      freshness();
    };
  }
  freshness();
}
function freshness() {
  if (DATA.demo) {
    $('freshness').textContent = 'Sample dashboard · explore filters, history, and process details';
    return;
  }
  const age = Math.max(0, (Date.now() - Date.parse(DATA.collectedAt)) / 1000),
    stale = DATA.watch && age > Math.max(90, DATA.watch * 3);
  $('freshness').classList.toggle('stale', !!stale);
  $('freshness').textContent = stale
    ? 'No recent scan · last capture ' + duration(age) + ' ago. The scanner may be stopped.'
    : DATA.watch
      ? 'Repeated scans every ' +
        DATA.watch +
        ' seconds · last capture ' +
        duration(age) +
        ' ago' +
        (state.paused ? ' · page updates paused' : ' · page refreshes while collection runs')
      : 'Saved snapshot · captured ' +
        duration(age) +
        ' ago. Run the script again to collect new data.';
  if ($('pause'))
    $('pause').textContent = state.paused ? 'Resume page updates' : 'Pause page updates';
}
function showPage(page) {
  state.page = page;
  document.querySelectorAll('[data-view]').forEach((el) => (el.hidden = el.dataset.view !== page));
  document.querySelectorAll('[data-page]').forEach((b) => {
    b.classList.toggle('active', b.dataset.page === page);
    b.setAttribute('aria-current', b.dataset.page === page ? 'page' : 'false');
  });
  store();
}
function chart(field, id, format, rows) {
  const top = rows
      .filter((r) => r[field] != null && r[field] > 0)
      .slice()
      .sort((a, b) => b[field] - a[field])
      .slice(0, 6),
    max = top.length ? top[0][field] : 1;
  chartRows[id] = top;
  $(id).innerHTML = top.length
    ? top
        .map(
          (r, i) =>
            '<button class="bar-row" data-chart="' +
            id +
            '" data-index="' +
            i +
            '"><span class="bar-caption"><span class="name" title="' +
            esc(r.name) +
            '">' +
            esc(r.name) +
            '</span><span class="value">' +
            format(r[field]) +
            '</span></span><span class="bar-track" style="display:block" aria-hidden="true"><span class="bar-fill" style="display:block;width:' +
            width((r[field] / max) * 100) +
            '"></span></span></button>'
        )
        .join('')
    : '<p class="small empty">No measured activity in this view.</p>';
}
function meter(value, max, format) {
  return (
    '<span class="value">' +
    format(value) +
    '</span><div class="mini" aria-hidden="true"><span style="width:' +
    width((value / max) * 100) +
    '"></span></div>'
  );
}
function renderOverview() {
  const s = DATA.system;
  let text =
    s.pressureValue > 1
      ? 'macOS reports ' +
        s.pressure.toLowerCase() +
        ' memory pressure. Review large allocations and active swap transfers.'
      : s.cpu >= 80
        ? 'CPU activity is high across the Mac. Review sustained users and check whether they are doing expected work.'
        : 'Memory pressure is ' +
          s.pressure.toLowerCase() +
          ' and total CPU is ' +
          pct(s.cpu) +
          '. Review the candidates below in the context of what you are doing.';
  if (s.thermal >= 2)
    text +=
      ' Thermal pressure is ' +
      ['normal', 'fair', 'serious', 'critical'][s.thermal] +
      '. Pause heavy work and check airflow.';
  if (s.disk && s.disk.available / s.disk.total < 0.1)
    text += ' The startup volume has less than 10% available space.';
  $('health').textContent = text;
  const flagged = visible
    .filter((r) => r.advice.flags.length)
    .sort(
      (a, b) =>
        Number(b.isMine && !!b.appPath) - Number(a.isMine && !!a.appPath) ||
        b.advice.score - a.advice.score
    )
    .slice(0, 3);
  $('focus').innerHTML = flagged.length
    ? flagged
        .map(
          (r) =>
            '<article class="focus-item"><div class="focus-name">' +
            esc(r.name) +
            ' <span class="status ' +
            r.advice.level.toLowerCase() +
            '">' +
            r.advice.level +
            '</span></div><p class="focus-copy">' +
            esc(r.advice.text) +
            '</p><p class="focus-metrics">' +
            pct(r.cpu) +
            ' CPU · ' +
            size(r.memory) +
            ' · ' +
            esc(r.advice.pattern) +
            '</p><button class="quiet" data-focus="' +
            esc(r.id) +
            '">Inspect evidence</button></article>'
        )
        .join('')
    : '<p class="small">No large loads in the current filter. Scan while a slowdown is happening to catch intermittent activity.</p>';
  chart('cpu', 'cpu-chart', pct, visible);
  chart('memory', 'memory-chart', size, visible);
  chart('energy', 'energy-chart', num, visible);
}
function renderList() {
  const subset = visible.slice(0, state.limit),
    before = comparisonMap(),
    b = baseline();
  $('list-title').textContent =
    state.mode === 'mine'
      ? 'My apps'
      : state.mode === 'processes'
        ? 'Individual processes'
        : 'Apps & services';
  $('count').textContent = visible.length + ' results';
  $('showing').textContent =
    'Showing ' + subset.length + ' of ' + visible.length + ' · averages and peaks cover the sample';
  $('more').hidden = subset.length >= visible.length;
  $('search').value = state.search;
  $('sort').value = state.sort;
  $('category').value = state.category;
  $('flagged').checked = state.flagged;
  $('pinned-only').checked = state.pinnedOnly;
  $('hide-system').checked = state.hideSystem;
  $('hide-idle').checked = state.hideIdle;
  $('baseline-label').textContent =
    state.mode === 'processes'
      ? 'Change = within this sample'
      : b
        ? 'Change vs ' + when(b.collectedAt)
        : 'Run another scan to compare changes';
  document.querySelectorAll('[data-mode]').forEach((el) => {
    el.classList.toggle('active', el.dataset.mode === state.mode);
    el.setAttribute('aria-pressed', String(el.dataset.mode === state.mode));
  });
  const labels = {
    priority: 'Priority',
    cpu: 'CPU average',
    memory: 'Memory',
    memoryDelta: state.mode === 'processes' ? 'Δ sample' : 'Δ baseline',
    energy: 'Power proxy',
    wakeups: 'Wakeups / s',
    threads: 'Threads',
    sleep: 'Sleep'
  };
  document.querySelectorAll('[data-sort]').forEach((el) => {
    const active = el.dataset.sort === state.sort;
    el.classList.toggle('active', active);
    el.textContent = labels[el.dataset.sort] + (active ? (state.direction < 0 ? ' ↓' : ' ↑') : '');
    el.parentElement.setAttribute(
      'aria-sort',
      active ? (state.direction < 0 ? 'descending' : 'ascending') : 'none'
    );
  });
  const scale = {
    cpu: Math.max(100, ...visible.map((r) => r.cpu || 0)),
    energy: Math.max(50, ...visible.map((r) => r.energy || 0))
  };
  $('rows').innerHTML = subset.length
    ? subset
        .map((r, i) => {
          const delta = memoryDelta(r, before);
          return (
            '<tr><td><button class="pin ' +
            (pinned(r) ? 'active' : '') +
            '" data-pin="' +
            i +
            '" aria-pressed="' +
            pinned(r) +
            '" aria-label="' +
            esc((pinned(r) ? 'Unpin ' : 'Pin ') + r.name) +
            '">' +
            (pinned(r) ? '★' : '☆') +
            '</button></td><td class="app-cell"><div class="app-name">' +
            esc(state.mode === 'processes' ? r.command : r.name) +
            '</div><div class="app-meta">' +
            esc(r.category) +
            ' · ' +
            (r.pids ? r.pids.length + ' processes' : 'PID ' + r.pid) +
            '</div><div class="app-meta">' +
            esc(r.advice.pattern) +
            '</div></td><td><span class="status ' +
            r.advice.level.toLowerCase() +
            '">' +
            r.advice.level +
            '</span><div class="app-meta">' +
            esc(r.advice.flags.join(' · ') || 'Light load') +
            '</div></td><td class="metric cpu">' +
            meter(r.cpu, scale.cpu, pct) +
            '<div class="app-meta">Peak ' +
            pct(r.peakCPU) +
            '</div></td><td class="metric memory">' +
            meter(r.memory, DATA.system.memory, size) +
            '<div class="app-meta">' +
            (r.memory == null
              ? ''
              : ((r.memory / DATA.system.memory) * 100).toFixed(1) + '% of RAM') +
            '</div></td><td><span class="delta ' +
            (delta > 0 ? 'up' : delta < 0 ? 'down' : '') +
            '">' +
            signed(delta, size) +
            '</span><div class="app-meta">Sample ' +
            signed(r.memoryChange == null ? null : r.memoryChange, size) +
            '</div></td><td class="metric energy">' +
            meter(r.energy, scale.energy, num) +
            '</td><td class="value">' +
            num(r.wakeups) +
            '</td><td class="value">' +
            r.threads +
            '</td><td>' +
            (r.sleep === null
              ? '<span class="small">Unavailable</span>'
              : r.sleep
                ? '<span class="status review">System</span>'
                : r.displaySleep
                  ? '<span class="status review">Display</span>'
                  : '<span class="small">—</span>') +
            '</td><td class="action-cell">' +
            esc(r.advice.text) +
            '<br><button class="quiet" data-inspect="' +
            i +
            '">Inspect details</button></td></tr>'
          );
        })
        .join('')
    : '<tr><td colspan="11" class="empty">No matches. Try another search or reset the filters.</td></tr>';
}
function historyPoints() {
  return scans.map((s) => ({
    time: Date.parse(s.collectedAt),
    cpu: s.system.cpu,
    memoryUsed: s.system.memoryUsed
  }));
}
function renderHistory() {
  const b = baseline(),
    previous = comparisonMap(),
    currentIDs = new Set(DATA.apps.map((a) => a.id));
  $('baseline').innerHTML =
    '<option value="auto">Previous scan (automatic)</option>' +
    scans
      .filter((s) => s.collectedAt !== DATA.collectedAt)
      .slice()
      .reverse()
      .map(
        (s) =>
          '<option value="' + esc(s.collectedAt) + '">' + esc(when(s.collectedAt)) + '</option>'
      )
      .join('') +
    (imported
      ? '<option value="imported">Imported · ' + esc(when(imported.collectedAt)) + '</option>'
      : '');
  $('baseline').value = state.baseline;
  $('comparison-note').textContent = b
    ? 'Baseline captured ' +
      when(b.collectedAt) +
      ' · compare app groups by path and user, with memory changes interpreted alongside pressure.'
    : 'No baseline yet. Run the script again, use Live Monitor, or import a Mac Resource Data.json snapshot.';
  const points = historyPoints();
  $('history-cpu').innerHTML = lineChart(points, 'cpu', 'var(--cpu)', pct, 'time');
  $('history-memory').innerHTML = lineChart(points, 'memoryUsed', 'var(--memory)', size, 'time');
  const caption = scans.length
    ? '<div class="chart-caption"><span>' +
      esc(when(scans[0].collectedAt)) +
      '</span><span>' +
      esc(when(scans[scans.length - 1].collectedAt)) +
      '</span></div>'
    : '';
  $('history-cpu').innerHTML += caption;
  $('history-memory').innerHTML += caption;
  if (b) {
    const newCount = DATA.apps.filter((r) => !previous.has(r.id)).length,
      ended = b.apps.filter((r) => !currentIDs.has(r.id)).length;
    $('comparison-stats').innerHTML =
      keyStat(
        signed(
          DATA.system.cpu == null || b.system.cpu == null ? null : DATA.system.cpu - b.system.cpu,
          pct
        ),
        'CPU change (percentage points)'
      ) +
      keyStat(
        signed(
          DATA.system.memoryUsed == null || b.system.memoryUsed == null
            ? null
            : DATA.system.memoryUsed - b.system.memoryUsed,
          size
        ),
        'Reported system memory change'
      ) +
      keyStat(newCount, 'Newly observed groups') +
      keyStat(ended, 'Groups no longer observed');
  } else $('comparison-stats').innerHTML = '';
  function changes(field, id, format) {
    const changed = DATA.apps
      .map((r) => {
        const old = previous.get(r.id);
        return {
          r,
          delta: old && finite(old[field]) && finite(r[field]) ? r[field] - old[field] : null
        };
      })
      .filter((x) => x.delta > 0)
      .sort((a, b) => b.delta - a.delta)
      .slice(0, 8);
    $(id).innerHTML = changed.length
      ? changed
          .map(
            (x) =>
              '<div class="change-row"><button data-history-app="' +
              esc(x.r.id) +
              '">' +
              esc(x.r.name) +
              '</button><strong class="delta up">' +
              signed(x.delta, format) +
              '</strong></div>'
          )
          .join('')
      : '<p class="small empty">' +
        (b ? 'No measured increases among matched groups.' : 'Take another scan to see changes.') +
        '</p>';
  }
  changes('memory', 'memory-changes', size);
  changes('cpu', 'cpu-changes', pct);
  $('history-rows').innerHTML = scans
    .slice()
    .reverse()
    .map(
      (s) =>
        '<tr><td>' +
        esc(when(s.collectedAt)) +
        (s.collectedAt === DATA.collectedAt ? ' · current' : '') +
        '</td><td>' +
        pct(s.system.cpu) +
        '</td><td>' +
        size(s.system.memoryUsed) +
        '</td><td>' +
        esc(s.system.pressure) +
        '</td><td>' +
        size(s.system.swap) +
        '</td><td>' +
        s.sampleSeconds +
        's</td><td>' +
        (s.collectedAt === DATA.collectedAt
          ? '—'
          : '<button class="quiet" data-baseline="' +
            esc(s.collectedAt) +
            '">Use baseline</button>') +
        '</td></tr>'
    )
    .join('');
}
function render() {
  visible = selectedRows();
  renderList();
  renderOverview();
  renderHistory();
  showPage(state.page);
  store();
}
function stateLabel(p) {
  return p.state
    ? { R: 'Running', S: 'Sleeping', I: 'Idle', T: 'Stopped', Z: 'Zombie', U: 'Waiting' }[
        p.state[0]
      ] || p.state
    : 'Unavailable';
}
function treeRows(ps) {
  const map = new Map(ps.map((p) => [p.pid, p])),
    out = [],
    seen = new Set();
  function visit(p, depth) {
    if (seen.has(p.pid)) return;
    seen.add(p.pid);
    out.push({ p, depth });
    ps.filter((x) => x.ppid === p.pid && x.pid !== p.pid)
      .sort((a, b) => (b.memory || 0) - (a.memory || 0))
      .forEach((x) => visit(x, Math.min(8, depth + 1)));
  }
  ps.filter((p) => !map.has(p.ppid) || p.ppid === p.pid)
    .sort((a, b) => (b.memory || 0) - (a.memory || 0))
    .forEach((p) => visit(p, 0));
  ps.forEach((p) => visit(p, 0));
  return out;
}
function openDialog(el) {
  if (typeof el.showModal === 'function') el.showModal();
  else {
    el.dataset.fallback = 'true';
    el.setAttribute('open', '');
  }
}
function closeDialog(el) {
  if (typeof el.close === 'function') el.close();
  else el.removeAttribute('open');
}
function inspect(original) {
  const row = decorate(original);
  detailRow = row;
  const ps = (row.processes || [row]).map(decorate),
    before = comparisonMap().get(row.id),
    rss = ps.some((p) => finite(p.residentMemory))
      ? ps.reduce((n, p) => n + (p.residentMemory || 0), 0)
      : null,
    delta =
      before && finite(before.memory) && finite(row.memory) ? row.memory - before.memory : null;
  $('inspect-title').textContent = row.name;
  $('inspect-body').innerHTML =
    '<p class="path">' +
    esc(row.appPath || row.path) +
    '</p><div class="evidence"><strong>' +
    esc(row.advice.pattern) +
    ' · ' +
    esc(row.advice.level) +
    ' review priority</strong><ul>' +
    (row.advice.reasons.length
      ? row.advice.reasons.map((r) => '<li>' + esc(r) + '</li>').join('')
      : '<li>No configured review threshold was crossed.</li>') +
    '</ul><p>' +
    esc(row.advice.text) +
    '</p></div><div class="key-stats">' +
    keyStat(
      pct(row.cpu),
      'Average CPU · ' +
        (row.cpu == null
          ? 'unavailable'
          : (row.cpu / DATA.cores).toFixed(1) + '% of total CPU capacity')
    ) +
    keyStat(pct(row.peakCPU), 'Highest observed CPU interval') +
    keyStat(size(row.memory), 'Current physical footprint') +
    keyStat(size(rss), 'Resident memory (RSS), collected after sample') +
    keyStat(
      signed(row.memoryChange == null ? null : row.memoryChange, size),
      'Footprint change during sample'
    ) +
    keyStat(
      row.pids ? signed(delta, size) : row.elapsed || 'Unavailable',
      row.pids ? 'Footprint change vs baseline' : 'Process elapsed time'
    ) +
    '</div><div class="two-col history-charts"><div><h3>CPU during sample</h3>' +
    lineChart(row.series || [], 'cpu', 'var(--cpu)', pct) +
    '</div><div><h3>Memory during sample</h3>' +
    lineChart(row.series || [], 'memory', 'var(--memory)', size) +
    '</div></div><p class="small">' +
    (row.observedSamples || 0) +
    ' of ' +
    DATA.sampleCount +
    ' usable CPU intervals. Helpers are grouped where paths or parent relationships identify an owner. Group growth can reflect a changing set of helpers.</p><div class="step"><strong>1. Verify the current activity</strong><p class="small">Open Activity Monitor, choose View → All Processes, then search the app name or a PID below. Check CPU, Memory, Energy, Disk, or Network.</p><button class="quiet" id="copy-open">Copy Activity Monitor command</button> <button class="quiet" id="copy-name">Copy app name</button> <button class="quiet" id="pin-detail">' +
    (pinned(row) ? 'Unpin app' : 'Pin app') +
    '</button></div><div class="step"><strong>2. Make a small change and compare</strong><p class="small">Save your work. Pause an unused task or close unused tabs/documents. Run another scan and use History & changes to see whether usage fell. Avoid quitting unfamiliar system services.</p></div><div class="process-detail"><h3>Process tree &amp; sleep assertions</h3><div class="table-scroll"><table><thead><tr><th>PID / executable / parent</th><th>CPU avg / peak</th><th>Footprint</th><th>State / elapsed</th><th>Threads / nice</th><th>Sleep assertion</th></tr></thead><tbody>' +
    treeRows(ps)
      .map(
        ({ p, depth }) =>
          '<tr><td><span class="tree-indent" style="--indent:' +
          depth * 12 +
          'px"></span><strong>' +
          p.pid +
          ' · ' +
          esc(p.command) +
          '</strong><div class="app-meta">Parent ' +
          p.ppid +
          ' · UID ' +
          p.uid +
          '</div><div class="path">' +
          esc(p.path) +
          '</div></td><td>' +
          pct(p.cpu) +
          '<div class="app-meta">Peak ' +
          pct(p.peakCPU) +
          '</div></td><td>' +
          size(p.memory) +
          '<div class="app-meta">RSS ' +
          size(p.residentMemory == null ? null : p.residentMemory) +
          '</div></td><td>' +
          esc(stateLabel(p)) +
          '<div class="app-meta">' +
          esc(p.elapsed || 'Unavailable') +
          '</div></td><td>' +
          p.threads +
          '<div class="app-meta">Nice ' +
          (p.nice == null ? '—' : p.nice) +
          '</div></td><td>' +
          esc(
            DATA.sleepAvailable
              ? (p.assertions || [])
                  .map((a) => a.type + ': ' + a.name + (a.duration ? ' (' + a.duration + ')' : ''))
                  .join('; ') || '—'
              : 'Unavailable'
          ) +
          '</td></tr>'
      )
      .join('') +
    '</tbody></table></div><p class="small">PIDs identify this snapshot and may be reused later. Sleep assertions are not proof of a fault.</p><button class="quiet" id="copy-pids">Copy PIDs</button> <button class="quiet" id="export-detail">Export these processes</button></div>';
  $('copy-open').onclick = () => copy("open -a 'Activity Monitor'");
  $('copy-name').onclick = () => copy(row.name);
  $('copy-pids').onclick = () => copy(ps.map((p) => p.pid).join(', '));
  $('pin-detail').onclick = () => {
    togglePin(row);
    $('pin-detail').textContent = pinned(row) ? 'Unpin app' : 'Pin app';
  };
  $('export-detail').onclick = () => exportCSV(ps, 'Mac Resource Processes.csv', true);
  if (!$('inspect').open) openDialog($('inspect'));
}
function csvCell(v) {
  if (v == null) return '""';
  let s = String(v);
  if (typeof v === 'string' && /^\s*[=+\-@]/.test(s)) s = "'" + s;
  return '"' + s.replace(/"/g, '""') + '"';
}
function exportCSV(rows, name, processes = false) {
  const before = comparisonMap(),
    head = [
      'App / process',
      'PIDs',
      'Category',
      'CPU average %',
      'CPU peak %',
      'Footprint bytes',
      'Within-sample footprint change bytes',
      'Baseline footprint change bytes',
      'Power proxy',
      'Wakeups per second',
      'Threads',
      'System sleep blocker',
      'Review level',
      'CPU pattern',
      'Suggestion'
    ],
    body = rows.map((r) => {
      const old = before.get(r.id);
      return [
        processes ? r.command : r.name,
        (r.pids || [r.pid]).join(' '),
        r.category,
        r.cpu,
        r.peakCPU,
        r.memory,
        r.memoryChange,
        old && finite(old.memory) && finite(r.memory) ? r.memory - old.memory : null,
        r.energy,
        r.wakeups,
        r.threads,
        r.sleep,
        r.advice.level,
        r.advice.pattern,
        r.advice.text
      ];
    });
  download(
    name,
    '\ufeff' + [head, ...body].map((row) => row.map(csvCell).join(',')).join('\r\n') + '\r\n',
    'text/csv;charset=utf-8'
  );
  toast('Exported ' + rows.length + ' rows');
}
function thresholds() {
  for (const [k, v] of Object.entries(prefs.limits))
    $('threshold-' + k).value = k === 'memory' ? Math.round(v / 1048576) : v;
}
function command() {
  let seconds = Number($('scan-duration').value),
    repeat = Number($('scan-repeat').value),
    browser = $('scan-browser').value;
  if (repeat && repeat < seconds + 4) {
    repeat = seconds + 4 <= 60 ? 60 : 120;
    $('scan-repeat').value = String(repeat);
  }
  const launcher = DATA.launcherPath || './Mac Resource Check.command',
    folder = DATA.outputDir || launcher.slice(0, launcher.lastIndexOf('/')) + '/Reports';
  const cmd =
    'bash ' +
    shellQuote(launcher) +
    ' --seconds ' +
    seconds +
    (repeat ? ' --watch ' + repeat : '') +
    ' --output ' +
    shellQuote(folder) +
    (browser !== 'default' ? ' --browser ' + browser : '');
  $('watch-command').textContent = cmd;
  if (DATA.demo) {
    $('scan-note').textContent =
      'Demo only. Download the launcher, then run it to collect a report from your Mac.';
    return cmd;
  }
  $('scan-note').textContent = repeat
    ? 'Run in Terminal; the dashboard opens automatically and updates while scanning. Press Control-C in Terminal to stop.'
    : 'Run in Terminal for one scan. The completed dashboard opens automatically. Browser refresh alone does not collect data.';
  return cmd;
}
async function importBaseline(file) {
  if (!file) return;
  if (file.size > 50 * 1024 * 1024) {
    toast('Snapshot is too large; use a file below 50 MB.');
    return;
  }
  try {
    const input = JSON.parse(await file.text());
    if (
      !input.system ||
      !Array.isArray(input.apps) ||
      !finite(input.system.memory) ||
      !['cpu', 'memoryUsed', 'swap'].every(
        (k) => input.system[k] === null || finite(input.system[k])
      ) ||
      !Number.isFinite(Date.parse(input.collectedAt)) ||
      !input.apps.every(
        (a) =>
          a &&
          typeof a.id === 'string' &&
          typeof a.name === 'string' &&
          ['cpu', 'memory'].every((k) => a[k] === null || finite(a[k]))
      )
    )
      throw new Error('format');
    if (
      input.system.memory !== DATA.system.memory ||
      (input.cores && input.cores !== DATA.cores) ||
      (input.currentUID && DATA.currentUID && input.currentUID !== DATA.currentUID)
    ) {
      toast('This snapshot has a different hardware or user profile.');
      return;
    }
    imported = {
      collectedAt: input.collectedAt,
      system: input.system,
      apps: input.apps.map((r) => ({
        id: r.id,
        name: r.name,
        cpu: r.cpu,
        memory: r.memory,
        energy: r.energy,
        wakeups: r.wakeups,
        sleep: r.sleep
      }))
    };
    try {
      SESSION.setItem('resource-check-import-v2', JSON.stringify(imported));
    } catch {}
    state.baseline = 'imported';
    state.page = 'history';
    render();
    toast('Baseline imported locally');
  } catch {
    toast('Choose a valid Mac Resource Data.json snapshot.');
  }
}
function resetFilters() {
  Object.assign(state, {
    search: '',
    category: 'all',
    flagged: false,
    pinnedOnly: false,
    hideSystem: false,
    hideIdle: false,
    limit: 50
  });
  render();
}
function bind() {
  document
    .querySelectorAll('[data-page]')
    .forEach((b) => (b.onclick = () => showPage(b.dataset.page)));
  document.querySelectorAll('[data-mode]').forEach(
    (b) =>
      (b.onclick = () => {
        state.mode = b.dataset.mode;
        state.limit = 50;
        render();
      })
  );
  document.querySelectorAll('[data-sort]').forEach(
    (b) =>
      (b.onclick = () => {
        state.direction = state.sort === b.dataset.sort ? -state.direction : -1;
        state.sort = b.dataset.sort;
        render();
      })
  );
  document.querySelectorAll('[data-jump-sort]').forEach(
    (b) =>
      (b.onclick = () => {
        state.sort = b.dataset.jumpSort;
        state.direction = -1;
        state.page = 'investigate';
        render();
      })
  );
  $('search').addEventListener('input', (e) => {
    state.search = e.target.value;
    state.limit = 50;
    render();
  });
  $('sort').onchange = (e) => {
    state.sort = e.target.value;
    state.direction = -1;
    state.limit = 50;
    render();
  };
  $('category').onchange = (e) => {
    state.category = e.target.value;
    state.limit = 50;
    render();
  };
  for (const [id, key] of [
    ['flagged', 'flagged'],
    ['pinned-only', 'pinnedOnly'],
    ['hide-system', 'hideSystem'],
    ['hide-idle', 'hideIdle']
  ])
    $(id).onchange = (e) => {
      state[key] = e.target.checked;
      state.limit = 50;
      render();
    };
  $('more').onclick = () => {
    state.limit += 50;
    render();
  };
  $('reset-filters').onclick = resetFilters;
  $('rows').addEventListener('click', (e) => {
    const pin = e.target.closest('[data-pin]'),
      detail = e.target.closest('[data-inspect]');
    if (pin) togglePin(visible[Number(pin.dataset.pin)]);
    if (detail) inspect(visible[Number(detail.dataset.inspect)]);
  });
  document.addEventListener('click', (e) => {
    const chart = e.target.closest('[data-chart]'),
      focus = e.target.closest('[data-focus]'),
      base = e.target.closest('[data-baseline]'),
      change = e.target.closest('[data-history-app]');
    if (chart) inspect(chartRows[chart.dataset.chart][Number(chart.dataset.index)]);
    if (focus) {
      const r = visible.find((r) => r.id === focus.dataset.focus);
      if (r) inspect(r);
    }
    if (base) {
      state.baseline = base.dataset.baseline;
      render();
    }
    if (change) {
      const r = DATA.apps.find((r) => r.id === change.dataset.historyApp);
      if (r) inspect(r);
    }
  });
  $('baseline').onchange = (e) => {
    state.baseline = e.target.value;
    render();
  };
  $('import-baseline').onclick = () => $('baseline-file').click();
  $('baseline-file').onchange = (e) => importBaseline(e.target.files[0]);
  $('export-list').onclick = () =>
    exportCSV(visible, 'Mac Resource Filtered List.csv', state.mode === 'processes');
  $('export-json').onclick = () =>
    download(
      'Mac Resource Data.json',
      JSON.stringify({ ...DATA, viewerPreferences: prefs }, null, 2),
      'application/json'
    );
  $('export-history').onclick = () =>
    download(
      'Mac Resource History.json',
      JSON.stringify({ version: 2, scans }, null, 2),
      'application/json'
    );
  $('print').onclick = () => window.print();
  $('apply-thresholds').onclick = () => {
    const next = {};
    for (const k of Object.keys(limitsDefault)) {
      const value = Number($('threshold-' + k).value);
      if (!finite(value) || value < 1 || value > Number($('threshold-' + k).max || 1000000)) {
        $('threshold-feedback').textContent =
          'Enter a positive value within the range shown for each threshold.';
        return;
      }
      next[k] = k === 'memory' ? value * 1048576 : value;
    }
    prefs.limits = next;
    $('threshold-feedback').textContent =
      'Applied. Review badges, filters, and exports now use these thresholds.';
    render();
  };
  $('reset-thresholds').onclick = () => {
    prefs.limits = { ...limitsDefault };
    thresholds();
    $('threshold-feedback').textContent = 'Default thresholds restored.';
    render();
  };
  $('theme').onchange = (e) => {
    prefs.theme = e.target.value;
    theme();
    store();
  };
  $('rescan').onclick = () => {
    command();
    openDialog($('rescan-dialog'));
  };
  ['scan-duration', 'scan-repeat', 'scan-browser'].forEach((id) => ($(id).onchange = command));
  $('copy-watch').onclick = () => copy(command());
  $('copy-open-dashboard').onclick = () =>
    copy(
      'bash ' +
        shellQuote(DATA.launcherPath) +
        ' --open-only --output ' +
        shellQuote(DATA.outputDir || '.')
    );
  $('copy-output-folder').onclick = () => copy(DATA.outputDir || '.');
  document
    .querySelectorAll('[data-close]')
    .forEach((b) => (b.onclick = () => closeDialog($(b.dataset.close))));
}
summary();
theme();
thresholds();
bind();
render();

if (window.matchMedia) {
  const m = window.matchMedia('(prefers-color-scheme: dark)');
  if (m.addEventListener) m.addEventListener('change', theme);
}
setInterval(freshness, 10000);
if (DATA.watch && !DATA.demo)
  setInterval(() => {
    if (
      !state.paused &&
      !document.querySelector('dialog[open]') &&
      !['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement.tagName)
    ) {
      store();
      location.reload();
    }
  }, 10000);
