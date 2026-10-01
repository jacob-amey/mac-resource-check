process.chdir(require('node:path').resolve(__dirname, '..'));
const version = require('node:fs').readFileSync('VERSION', 'utf8').trim();
/* Check dashboard behavior in an isolated DOM model; no browser or native UI access. */
const fs = require('fs'),
  vm = require('vm'),
  assert = require('assert');
const template = fs.readFileSync('src/report.html', 'utf8'),
  data = JSON.parse(fs.readFileSync('tests/fixtures/demo.json', 'utf8'));
const script =
  fs.readFileSync('src/rules.js', 'utf8') + '\n' + fs.readFileSync('src/report.js', 'utf8');
const elements = {},
  nodes = [],
  downloads = [],
  urls = new Map(),
  storeMap = new Map();
const camel = (s) => s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
class Element {
  constructor(tag = 'div', attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.dataset = {};
    for (const k in attrs) if (k.startsWith('data-')) this.dataset[camel(k.slice(5))] = attrs[k];
    this.style = {};
    this.events = {};
    this.parentElement = { setAttribute() {} };
    this.classList = { toggle() {} };
    this.hidden = false;
    this.open = false;
    this.value = '';
    this.max = attrs.max;
    this.checked = false;
    this.textContent = '';
  }
  set innerHTML(v) {
    this.html = v;
    for (const m of v.matchAll(/id="([^" ]+)"/g)) elements[m[1]] = new Element();
  }
  get innerHTML() {
    return this.html || '';
  }
  setAttribute(k, v) {
    this.attrs[k] = v;
    if (k === 'open') this.open = true;
  }
  removeAttribute(k) {
    delete this.attrs[k];
    if (k === 'open') this.open = false;
  }
  addEventListener(k, fn) {
    this.events[k] = fn;
  }
  showModal() {
    this.open = true;
  }
  close() {
    this.open = false;
  }
  click() {
    if (this.download) downloads.push({ name: this.download, blob: urls.get(this.href) });
    const e = { target: this };
    if (this.onclick) this.onclick(e);
    if (this.events.click) this.events.click(e);
  }
  closest(selector) {
    const a = selector.match(/^\[([^\]]+)\]$/);
    return a && this.attrs[a[1]] !== undefined ? this : null;
  }
  remove() {}
  select() {}
}
for (const m of template.matchAll(/<([a-z][a-z0-9]*)\b([^>]*)>/g)) {
  const attrs = {};
  for (const a of m[2].matchAll(/([\w-]+)="([^"]*)"/g)) attrs[a[1]] = a[2];
  const node = new Element(m[1], attrs);
  nodes.push(node);
  if (attrs.id) elements[attrs.id] = node;
}
elements['resource-data'].textContent = JSON.stringify(data);
const docEvents = {},
  document = {
    getElementById(id) {
      if (id === 'pause' && !elements[id]) return null;
      if (!elements[id]) throw Error('Missing DOM element: ' + id);
      return elements[id];
    },
    querySelectorAll(s) {
      const m = s.match(/^\[([^\]]+)\]$/);
      return m ? nodes.filter((n) => n.attrs[m[1]] !== undefined) : [];
    },
    querySelector(s) {
      return s === 'dialog[open]'
        ? Object.values(elements).find((e) => e.tagName === 'DIALOG' && e.open) || null
        : null;
    },
    activeElement: { tagName: 'BODY' },
    documentElement: { dataset: {} },
    addEventListener(k, f) {
      docEvents[k] = f;
    },
    createElement(tag) {
      return new Element(tag);
    },
    body: { append() {} },
    execCommand() {
      return true;
    }
  };
const storage = { getItem: (k) => storeMap.get(k) || null, setItem: (k, v) => storeMap.set(k, v) };
class MockBlob {
  constructor(parts, opts) {
    this.text = parts.join('');
    this.type = opts.type;
  }
}
const intervals = [],
  window = {
    sessionStorage: storage,
    localStorage: storage,
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    print() {
      window.printed = true;
    }
  };
const ctx = {
  window,
  document,
  navigator: { clipboard: { writeText: async () => {} } },
  location: {
    reload() {
      ctx.reloaded = true;
    }
  },
  setInterval: (f) => intervals.push(f),
  setTimeout: () => 0,
  clearTimeout() {},
  Blob: MockBlob,
  URL: {
    createObjectURL(b) {
      const key = 'blob:test-' + urls.size;
      urls.set(key, b);
      return key;
    },
    revokeObjectURL() {}
  },
  console
};
vm.createContext(ctx);
vm.runInContext(script, ctx);
const run = (s) => vm.runInContext(s, ctx),
  e = (id) => elements[id],
  button = (key, value) => nodes.find((n) => n.dataset[key] === value),
  change = (id, value) => {
    e(id).value = value;
    e(id).onchange({ target: e(id) });
  };
assert.equal(e('rows').html.match(/<tr>/g).length, 50);
assert.equal(run('state.page'), 'overview');
assert(!e('overview-view').hidden);
assert(e('investigate-view').hidden);
assert(e('cpu-chart').html.includes('bar-fill'));
assert(e('history-cpu').html.includes('svg'));
assert.equal(run('visible[0].advice.score>=visible[1].advice.score'), true);
button('page', 'investigate').click();
assert(!e('investigate-view').hidden);
assert(e('overview-view').hidden);
change('sort', 'memory');
assert.equal(run('visible[0].memory>=visible[1].memory'), true);
e('search').value = 'no-such-process-xyz';
e('search').events.input({ target: e('search') });
assert(e('rows').html.includes('No matches'));
e('reset-filters').click();
change('category', 'Browser');
assert.equal(run('visible.every(r=>r.category==="Browser")'), true);
e('reset-filters').click();
const topID = run('pinKey(visible[0])');
e('rows').events.click({ target: new Element('button', { 'data-pin': '0' }) });
assert(run('prefs.pins').includes(topID));
e('pinned-only').checked = true;
e('pinned-only').onchange({ target: e('pinned-only') });
assert.equal(run('visible.every(pinned)'), true);
assert.equal(run('visible.length'), 1);
e('reset-filters').click();
button('mode', 'mine').click();
assert.equal(run('visible.every(r=>r.isMine&&r.appPath)'), true);
button('mode', 'processes').click();
assert.equal(run('visible.length'), data.processes.length);
assert(e('baseline-label').textContent.includes('within this sample'));
e('more').click();
assert.equal(e('rows').html.match(/<tr>/g).length, 100);
e('flagged').checked = true;
e('flagged').onchange({ target: e('flagged') });
assert.equal(run('visible.every(r=>r.advice.flags.length)'), true);
e('reset-filters').click();
e('rows').events.click({ target: new Element('button', { 'data-inspect': '0' }) });
assert(e('inspect').open);
assert(e('inspect-body').html.includes('Process tree'));
assert(e('inspect-body').html.includes('Parent '));
assert(e('inspect-body').html.includes('Resident memory'));
e('export-detail').click();
assert(downloads.at(-1).name.endsWith('Processes.csv'));
button('close', 'inspect').click();
assert(!e('inspect').open);
button('mode', 'all').click();
change('sort', 'memory');
e('export-list').click();
assert.equal(downloads.at(-1).name, 'Mac Resource Filtered List.csv');
assert(downloads.at(-1).blob.text.includes('CPU peak %'));
assert.equal(downloads.at(-1).blob.text.split('\r\n').length, run('visible.length') + 2);
assert.equal(run('csvCell("=2+2")'), '"\'=2+2"');
assert.equal(run('csvCell(-50)'), '"-50"');
assert.equal(run('esc("<img onerror=bad>")'), '&lt;img onerror=bad&gt;');
button('page', 'settings').click();
change('theme', 'dark');
assert.equal(document.documentElement.dataset.theme, 'dark');
e('threshold-cpu').value = 1;
e('threshold-memory').value = 64;
e('threshold-energy').value = 1;
e('threshold-wakeups').value = 1;
e('apply-thresholds').click();
assert.equal(run('prefs.limits.cpu'), 1);
assert.equal(run('prefs.limits.memory'), 64 * 1048576);
assert(e('threshold-feedback').textContent.includes('Applied'));
e('threshold-cpu').value = 0;
e('apply-thresholds').click();
assert.equal(run('prefs.limits.cpu'), 1);
e('reset-thresholds').click();
assert.equal(run('prefs.limits.cpu'), 25);
e('scan-duration').value = '30';
e('scan-repeat').value = '30';
e('scan-browser').value = 'chrome';
e('rescan').click();
assert(e('rescan-dialog').open);
assert(e('watch-command').textContent.includes('--watch 60'));
assert(e('watch-command').textContent.includes('--browser chrome'));
assert(e('watch-command').textContent.includes('--output'));
button('close', 'rescan-dialog').click();
e('export-json').click();
assert.equal(JSON.parse(downloads.at(-1).blob.text).version, version);
e('export-history').click();
assert.equal(JSON.parse(downloads.at(-1).blob.text).scans.length, data.history.length);
e('print').click();
assert(window.printed);
assert(storeMap.get('resource-check-prefs-v2'));
assert(storeMap.get('resource-check-view-v2'));
(async () => {
  const imported = {
    ...data,
    collectedAt: '2026-09-29T18:00:00Z',
    apps: data.apps.map((a) => ({ ...a, memory: Math.max(0, (a.memory || 0) - 104857600) }))
  };
  await ctx.importBaseline({ size: 1000, text: async () => JSON.stringify(imported) });
  assert.equal(run('state.baseline'), 'imported');
  assert(e('memory-changes').html.includes('+100.0 MiB'));
  assert.equal(run('state.page'), 'history');
  const previous = run('imported.collectedAt');
  await ctx.importBaseline({
    size: 1000,
    text: async () => JSON.stringify({ ...imported, system: { ...data.system, memory: 1 } })
  });
  assert.equal(run('imported.collectedAt'), previous);
  assert(e('toast').textContent.includes('different hardware'));
  console.log(
    'Passed detailed-dashboard checks: navigation, sorting, filters, pins, process tree, exports, formulas, theme, thresholds, scan builder, history, imported comparison, and persistence.'
  );
})().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
