ObjC.import('Foundation');
function readFile(path) {
  var error = Ref(),
    result = $.NSString.stringWithContentsOfFileEncodingError(
      $(path),
      $.NSUTF8StringEncoding,
      error
    );
  if (!result) return '';
  return ObjC.unwrap(result);
}
function saveFile(path, content) {
  var error = Ref();
  if (
    !$(content).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, error)
  ) {
    throw new Error('Could not save report: ' + path);
  }
}
function run(args) {
  var rawDir = args[0],
    outputDir = args[1],
    collectorPID = +args[2],
    uid = +args[3],
    watch = +args[4];
  var input = {};
  [
    'top',
    'ps',
    'assertions',
    'pressure',
    'swap',
    'vm',
    'disk',
    'battery',
    'vmBefore',
    'networkBefore',
    'networkAfter',
    'ioBefore',
    'ioAfter',
    'counterSeconds',
    'boot'
  ].forEach(function (name) {
    input[name] = readFile(rawDir + '/' + name + '.txt');
  });
  var info = $.NSProcessInfo.processInfo,
    thermal = Number(info.thermalState);
  var data = ResourceCheck.analyze(input, {
    collectorPID: collectorPID,
    uid: uid,
    watch: watch,
    interval: 2,
    memory: Number(info.physicalMemory),
    cores: Number(info.processorCount),
    thermal: thermal,
    launcherPath: args[5],
    collectedAt: new Date().toISOString(),
    osVersion: ObjC.unwrap(info.operatingSystemVersionString),
    warnings: readFile(rawDir + '/warnings.txt')
      .trim()
      .split('\n')
      .filter(function (x) {
        return !!x;
      })
  });
  if (!input.ps.trim())
    data.warnings.push('Process paths unavailable; app grouping may be incomplete.');
  if (data.system.pressure === 'Unavailable')
    data.warnings.push('macOS memory pressure was unavailable.');
  if (!data.energyAvailable)
    data.warnings.push(
      'Power and idle-wakeup counters were unavailable; use CPU and Activity Monitor’s Energy pane.'
    );
  data.outputDir = outputDir;
  // Keep a bounded journal containing group-level measurements, not full process snapshots.
  function compact(snapshot) {
    return {
      collectedAt: snapshot.collectedAt,
      system: snapshot.system,
      sampleSeconds: snapshot.sampleSeconds,
      apps: snapshot.apps.map(function (g) {
        return {
          id: g.id,
          name: g.name,
          cpu: g.cpu,
          memory: g.memory,
          energy: g.energy,
          wakeups: g.wakeups,
          sleep: g.sleep,
          count: g.pids.length
        };
      })
    };
  }
  var signature = data.system.memory + ':' + data.cores + ':' + data.currentUID,
    history = [];
  var historyText = readFile(outputDir + '/Mac Resource History.json');
  if (historyText) {
    try {
      var journal = JSON.parse(historyText);
      function optionalNumber(n) {
        return n === null || (typeof n === 'number' && isFinite(n));
      }
      if (journal.signature === signature && Array.isArray(journal.scans)) {
        history = journal.scans.filter(function (x) {
          return (
            x &&
            x.system &&
            Array.isArray(x.apps) &&
            isFinite(Date.parse(x.collectedAt)) &&
            optionalNumber(x.system.cpu) &&
            optionalNumber(x.system.memoryUsed) &&
            optionalNumber(x.system.swap) &&
            typeof x.system.pressure === 'string' &&
            typeof x.sampleSeconds === 'number' &&
            x.apps.every(function (g) {
              return (
                g &&
                typeof g.id === 'string' &&
                typeof g.name === 'string' &&
                optionalNumber(g.cpu) &&
                optionalNumber(g.memory)
              );
            })
          );
        });
        if (history.length !== journal.scans.length) {
          saveFile(outputDir + '/Mac Resource History.backup-' + Date.now() + '.json', historyText);
          data.warnings.push(
            'Invalid history entries were ignored; the original history was preserved in a backup file.'
          );
        }
      } else {
        saveFile(
          outputDir + '/Mac Resource History.profile-backup-' + Date.now() + '.json',
          historyText
        );
        data.warnings.push(
          'History from a different hardware or user profile was preserved in a backup; a new history has been started.'
        );
      }
    } catch (error) {
      saveFile(outputDir + '/Mac Resource History.backup-' + Date.now() + '.json', historyText);
      data.warnings.push(
        'Unreadable history was preserved in a backup file; a new history has been started.'
      );
    }
  } else {
    try {
      var previous = JSON.parse(readFile(outputDir + '/Mac Resource Data.json'));
      if (
        previous.system.memory === data.system.memory &&
        previous.cores === data.cores &&
        (!previous.currentUID || previous.currentUID === data.currentUID)
      )
        history.push(compact(previous));
    } catch (error) {}
  }
  history.push(compact(data));
  history = history.slice(-Math.min(120, Math.max(1, Number(args[6]) || 40)));
  data.history = history;
  var json = JSON.stringify(data)
    .replace(/</g, '\\u003c')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
  saveFile(outputDir + '/Mac Resource Data.json', JSON.stringify(data, null, 2));
  saveFile(
    outputDir + '/Mac Resource History.json',
    JSON.stringify({ version: 2, signature: signature, scans: history })
  );
  function cell(value) {
    var text = value === null || value === undefined ? '' : String(value);
    // Keep spreadsheet formulas inert when exporting process-controlled names.
    if (typeof value === 'string' && /^\s*[=+\-@]/.test(text)) text = "'" + text;
    return '"' + text.replace(/"/g, '""') + '"';
  }
  var csv = [
    [
      'App / service',
      'PIDs',
      'CPU percent (one core = 100)',
      'Memory footprint bytes',
      'Power proxy score',
      'Idle wakeups per second',
      'Threads',
      'Prevents system sleep',
      'Priority',
      'Suggestion',
      'Peak CPU',
      'Footprint change within sample (bytes)',
      'CPU pattern',
      'Category'
    ]
      .map(cell)
      .join(',')
  ];
  data.apps.forEach(function (g) {
    csv.push(
      [
        g.name,
        g.pids.join(' '),
        g.cpu,
        g.memory,
        g.energy,
        g.wakeups,
        g.threads,
        g.sleep,
        g.advice.level,
        g.advice.text,
        g.peakCPU,
        g.memoryChange,
        g.advice.pattern,
        g.category
      ]
        .map(cell)
        .join(',')
    );
  });
  saveFile(outputDir + '/Mac Resource List.csv', csv.join('\r\n') + '\r\n');
  // Save HTML last, after the data and exports are ready; all writes are atomic.
  saveFile(
    outputDir + '/Mac Resource Report.html',
    REPORT_TEMPLATE.replace('__RESOURCE_DATA__', function () {
      return json;
    })
  );
  return 'Report ready: ' + outputDir + '/Mac Resource Report.html';
}
