process.chdir(require('node:path').resolve(__dirname, '..'));
const version = require('node:fs').readFileSync('VERSION', 'utf8').trim();
const fs = require('fs'),
  vm = require('vm'),
  assert = require('assert');
const ctx = {};
vm.createContext(ctx);
vm.runInContext(
  fs.readFileSync('src/rules.js', 'utf8') +
    '\n' +
    fs.readFileSync('src/core.js', 'utf8').replaceAll('__VERSION__', version),
  ctx
);
const R = ctx.ResourceCheck;
assert.equal(R.bytes('2048M+'), 2147483648);
assert.equal(R.bytes('4096K-'), 4194304);
assert.equal(R.bytes('N/A'), null);
function frame(sec, rows, idle = 80) {
  return `Processes: 8 total\n2026/09/30 14:00:0${sec}\nCPU usage: 10% user, 10% sys, ${idle}% idle\nPhysMem: 10G used (1G wired), 6G unused.\nPID PPID UID %CPU MEM #TH IDLEW POWER COMMAND\n${rows.join('\n')}\n`;
}
const rows = (cpu, wake) => [
  `10 1 501 ${cpu} 1200M 4 ${wake} ${cpu} Browser`,
  `11 10 501 10 800M 3 100 10 Helper`,
  '12 10 0 0 10M 1 0 0 OtherUser',
  '0 0 0 50 100M 5 100 0 kernel_task',
  '13 999 501 6 6M 1 0 6 top'
];
const base = rows(999, 10),
  mid = rows(20, 30),
  last = rows(40, 50);
last.push('15 1 501 0 6M 1 0 0 NewApp');
const input = {
  top: frame(0, base) + frame(2, mid) + frame(4, last),
  ps: '10 1 501 10 00:30 /Applications/Google Chrome.app/Contents/MacOS/Browser\n11 10 501 10 00:30 /usr/local/bin/Helper\n12 10 0 10 00:30 /usr/bin/OtherUser',
  pressure: '2',
  swap: 'vm.swapusage: total = 1024M used = 100.50M free = 923.50M',
  vm: 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 100.\nPages wired down: 200.\n',
  assertions:
    '  pid 10(Browser): [0x1234] 00:00:40 NoIdleSleepAssertion named: "video"\n  pid 11(Helper): [0x1235] 00:00:40 PreventUserIdleDisplaySleep named: "display"\n  pid 0(kernel_task): [0x1236] 00:00:40 UserIsActive named: "keyboard"',
  battery:
    "Now drawing from 'AC Power'\n -InternalBattery-0 71%; charging; 0:49 remaining present: true",
  disk: 'Filesystem 1024-blocks Used Available Capacity\n/dev/disk3s5 1000000 800000 200000 80%'
};
const info = {
  memory: 16 * 1024 ** 3,
  cores: 8,
  uid: 501,
  collectorPID: 999,
  interval: 2,
  watch: 0,
  thermal: 0,
  collectedAt: '2026-09-30T18:00:05Z'
};
const d = R.analyze(input, info),
  app = d.apps.find((x) => x.name === 'Google Chrome'),
  kernel = d.processes.find((x) => x.pid === 0);
assert.equal(d.sampleCount, 2);
assert.equal(d.sampleSeconds, 4);
assert.equal(app.cpu, 40);
assert.equal(app.memory, 2000 * 1024 ** 2);
assert.equal(app.wakeups, 10);
assert.equal(app.pids.length, 2);
assert.equal(app.sleep, true);
assert.equal(app.displaySleep, true);
assert.equal(kernel.energy, null);
assert.equal(kernel.cpu, 50);
assert.equal(d.collectorExcluded, 1);
assert.equal(d.processes.find((x) => x.pid === 15).cpu, null);
assert.equal(d.system.swap, 100.5 * 1024 ** 2);
assert.equal(d.system.compressed, 100 * 16384);
assert.equal(d.system.disk.available, 200000 * 1024);
assert.equal(d.system.pressure, 'Elevated');
assert.equal(d.system.battery.percent, 71);
assert.equal(d.processes.find((x) => x.pid === 12).appPath, null);
assert.equal(app.advice.level, 'High');
assert(app.advice.text.includes('tabs'));
assert.equal(d.processes.find((x) => x.pid === 11).system, false);
// A reset counter is unavailable, not a negative wakeup rate.
const resetInput = { ...input, top: frame(0, rows(0, 100)) + frame(2, rows(30, 3)) };
assert.equal(R.analyze(resetInput, info).processes.find((x) => x.pid === 10).wakeups, null);
// Older macOS fallback: no power columns, no pressure or battery, still usable CPU/memory.
function plainFrame(sec) {
  return `Processes: 1 total\n2026/09/30 14:00:0${sec}\nCPU usage: 10% user, 10% sys, 80% idle\nPhysMem: 10G used, 6G unused.\nPID PPID UID %CPU MEM #TH COMMAND\n20 1 501 30 200M 2 Some app with spaces\n`;
}
const fallback = R.analyze(
  {
    ...input,
    top: plainFrame(0) + plainFrame(2),
    ps: '',
    assertions: '',
    pressure: '',
    battery: '',
    disk: '',
    swap: '',
    vm: ''
  },
  info
);
assert.equal(fallback.energyAvailable, false);
assert.equal(fallback.processes[0].cpu, 30);
assert.equal(fallback.processes[0].command, 'Some app with spaces');
assert.equal(fallback.system.pressure, 'Unavailable');
assert.equal(fallback.system.swap, null);
assert.equal(fallback.system.battery.percent, null);
assert.equal(fallback.system.disk, null);
assert.throws(() => R.analyze({ ...input, top: frame(0, base) }, info), /No usable/);
console.log(
  'Passed collector checks: interval CPU, memory, wakeups, grouping, uid boundaries, sleep, kernel, missing data, and fallback.'
);
assert.equal(app.series.length, 3);
assert.equal(app.peakCPU, 50);
assert.equal(app.observedSamples, 2);
assert.equal(app.category, 'Browser');
assert.equal(d.processes.find((x) => x.pid === 10).residentMemory, 10 * 1024);
const n1 =
  'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#14> aa:bb 10 0 1000 10 0 2000 0\nen0 1500 192.168.1 192.168.1.1 10 0 1000 10 0 2000 0\nlo0 1500 <Link#1> 10 0 10000 10 0 10000 0';
const n2 = n1.replace('1000 10 0 2000', '5000 10 0 4000');
const rates = R.counterRates(R.network(n1), R.network(n2), 2, ['inBytes', 'outBytes']);
assert.equal(rates.length, 1);
assert.equal(rates[0].inBytes, 2000);
assert.equal(rates[0].outBytes, 1000);
const io1 = ' disk0 disk2\nKB/t xfrs MB KB/t xfrs MB\n50 100 20.00 20 50 5.00',
  io2 = ' disk0 disk2\nKB/t xfrs MB KB/t xfrs MB\n50 120 30.00 20 70 6.00';
const diskRates = R.counterRates(R.ioCounters(io1), R.ioCounters(io2), 2, [
  'transfers',
  'megabytes'
]);
assert.equal(diskRates[0].megabytes, 5);
assert.equal(diskRates[0].transfers, 10);
assert.equal(
  R.psRows('10 1 501 100 00:30 S< -5 /Applications/My App.app/Contents/MacOS/app')['10'].state,
  'S<'
);
assert.equal(
  R.psRows('10 1 501 100 00:30 S< -5 /Applications/My App.app/Contents/MacOS/app')['10'].nice,
  -5
);
const vm0 =
  'Mach Virtual Memory Statistics: (page size of 4096 bytes)\nSwapins: 100.\nSwapouts: 200.';
const enhanced = R.analyze(
  {
    ...input,
    vmBefore: vm0,
    vm: vm0.replace('100.', '104.').replace('200.', '210.'),
    counterSeconds: '2',
    networkBefore: n1,
    networkAfter: n2,
    ioBefore: io1,
    ioAfter: io2
  },
  info
);
assert.equal(enhanced.system.swapActivity.inBytes, 8192);
assert.equal(enhanced.system.swapActivity.outBytes, 20480);
assert.equal(enhanced.system.network[0].inBytes, 2000);
const burst = ctx.ResourceRules.evaluate(
  {
    name: 'App',
    cpu: 10,
    peakCPU: 100,
    memory: 100,
    memoryChange: 0,
    wakeups: 0,
    energy: 10,
    sleep: false,
    series: [{ cpu: 100 }, { cpu: 0 }, { cpu: 0 }, { cpu: 0 }]
  },
  d.system
);
assert.equal(burst.pattern, 'CPU burst');
const relaxed = ctx.ResourceRules.evaluate(app, d.system, {
  cpu: 100,
  memory: 10000000000,
  energy: 100,
  wakeups: 100
});
assert(!relaxed.flags.includes('CPU'));
assert(!relaxed.flags.includes('Memory'));
// Missing counters must not be converted into zero or an apparent transfer rate.
for (const missing of [null, undefined, NaN, '100']) {
  assert.equal(
    R.counterRates({ disk0: { megabytes: missing } }, { disk0: { megabytes: 200 } }, 2, [
      'megabytes'
    ]).length,
    0
  );
}
assert.equal(
  R.counterRates({ disk0: { megabytes: 200 } }, { disk0: { megabytes: 100 } }, 2, ['megabytes'])
    .length,
  0
);
console.log(
  'Passed enhanced checks for series, group peaks, RSS, state/nice parsing, network deduplication, disk deltas, active swap, and custom thresholds.'
);
