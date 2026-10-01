/* Deterministic synthetic input for the demo and dashboard tests. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
const context = {};
vm.createContext(context);
for (const name of ['rules.js', 'core.js']) {
  vm.runInContext(
    fs.readFileSync(path.join(root, 'src', name), 'utf8').replaceAll('__VERSION__', version),
    context
  );
}

const specs = [
  ['Safari', 30, 2400, 5, 3],
  ['Xcode', 128, 1850, 3, 2],
  ['Photos', 12, 950, 3, 2],
  ['Music', 6, 380, 8, 1],
  ['Terminal', 2, 150, 1, 1]
];
const rows = [],
  paths = [];
let pid = 100;
for (const [name, cpu, memory, wake, count] of specs) {
  const parent = pid;
  for (let helper = 0; helper < count; helper++, pid++) {
    const command = helper ? name + ' Helper' : name;
    rows.push({
      pid,
      ppid: helper ? parent : 1,
      uid: 501,
      cpu: cpu / count,
      memory: memory / count,
      wake,
      command
    });
    paths.push(
      `${pid} ${helper ? parent : 1} 501 100000 01:23:45 S 0 /Applications/${name}.app/Contents/MacOS/${command}`
    );
  }
}
for (let i = 0; i < 110; i++, pid++) {
  const command = 'sample-service-' + String(i + 1).padStart(3, '0');
  rows.push({
    pid,
    ppid: 1,
    uid: 0,
    cpu: (i % 7) / 10,
    memory: 8 + (i % 21),
    wake: i % 3,
    command
  });
  paths.push(`${pid} 1 0 2048 02:10:00 Ss 0 /usr/libexec/${command}`);
}
function frame(index) {
  const scale = [0, 0.7, 1.1, 0.9, 1.2, 1, 1.1][index];
  return (
    [
      'Processes: ' + rows.length + ' total',
      '2026/10/01 12:00:' + String(index * 2).padStart(2, '0'),
      'CPU usage: 16% user, 4% sys, ' + [80, 82, 76, 81, 73, 78, 77][index] + '% idle',
      'PhysMem: 18G used (3G wired), 14G unused.',
      'PID PPID UID %CPU MEM #TH IDLEW POWER COMMAND',
      ...rows.map(
        (r) =>
          `${r.pid} ${r.ppid} ${r.uid} ${(r.cpu * scale).toFixed(1)} ${(r.memory + index * (r.uid === 501 ? 2 : 0)).toFixed(1)}M 6 ${index * r.wake * 2} ${(r.cpu * scale + r.wake / 10).toFixed(1)} ${r.command}`
      )
    ].join('\n') + '\n'
  );
}
const input = {
  top: Array.from({ length: 7 }, (_, i) => frame(i)).join(''),
  ps: paths.join('\n'),
  pressure: '1',
  swap: 'vm.swapusage: total = 1024M used = 256M free = 768M',
  vmBefore:
    'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nSwapins: 100.\nSwapouts: 200.',
  vm: 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages occupied by compressor: 65536.\nPages wired down: 196608.\nSwapins: 100.\nSwapouts: 200.',
  assertions:
    '  pid 110(Music): [0x1234] 00:12:00 PreventUserIdleSystemSleep named: "Sample audio playback"',
  battery:
    "Now drawing from 'Battery Power'\n -InternalBattery-0 76%; discharging; 3:40 remaining present: true",
  disk: 'Filesystem 1024-blocks Used Available Capacity\n/dev/disk3s5 1000000000 540000000 460000000 54%',
  boot: '{ sec = 1790712012, usec = 0 }',
  counterSeconds: '12',
  networkBefore: 'en0 1500 <Link#14> 00:00:00:00:00:00 10 0 1000 10 0 2000 0',
  networkAfter: 'en0 1500 <Link#14> 00:00:00:00:00:00 20 0 15100936 20 0 1742804 0',
  ioBefore: ' disk0\nKB/t xfrs MB\n50 100 20.00',
  ioAfter: ' disk0\nKB/t xfrs MB\n50 500 44.00'
};
const data = context.ResourceCheck.analyze(input, {
  memory: 32 * 1024 ** 3,
  cores: 10,
  uid: 501,
  collectorPID: 999999,
  interval: 2,
  watch: 0,
  thermal: 0,
  collectedAt: '2026-10-01T16:00:12Z',
  osVersion: 'macOS · sample system',
  launcherPath: './Mac Resource Check.command',
  warnings: []
});
data.demo = true;
data.outputDir = './Reports';
data.history = Array.from({ length: 5 }, (_, i) => ({
  collectedAt: new Date(Date.parse(data.collectedAt) - (4 - i) * 60000).toISOString(),
  system: {
    ...data.system,
    cpu: [34, 29, 25, 23, data.system.cpu][i],
    memoryUsed: (17 + i / 4) * 1024 ** 3
  },
  sampleSeconds: data.sampleSeconds,
  apps: data.apps.map((g) => ({
    id: g.id,
    name: g.name,
    cpu: g.cpu * (1 + (4 - i) / 20),
    memory: Math.max(0, g.memory - (4 - i) * 8 * 1024 ** 2),
    energy: g.energy,
    wakeups: g.wakeups,
    sleep: g.sleep,
    count: g.pids.length
  }))
}));
fs.writeFileSync(path.join(root, 'tests/fixtures/demo.json'), JSON.stringify(data) + '\n');
console.log(
  'Generated synthetic demo: ' +
    data.processes.length +
    ' processes, ' +
    data.history.length +
    ' scans.'
);
