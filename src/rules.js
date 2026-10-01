/* Shared by the collector and the dashboard, so custom thresholds use the same rules. */
var ResourceRules = (function () {
  function defaults(ram) {
    return { cpu: 25, memory: Math.max(1073741824, ram * 0.05), energy: 25, wakeups: 20 };
  }
  function category(row) {
    var s = (row.name + ' ' + (row.path || '')).toLowerCase();
    if (/chrome|safari|webkit|firefox|brave|vivaldi|edge|\barc\b|opera|orion/.test(s))
      return 'Browser';
    if (/zoom|teams|webex|discord|slack|messages|facetime/.test(s)) return 'Communication';
    if (/xcode|swift|clang|node|python|docker|visual studio|code helper|terminal|iterm/.test(s))
      return 'Development';
    if (/photos|photoanalysis|music|spotify|vlc|quicktime|mediaanalysis/.test(s)) return 'Media';
    if (/word|excel|powerpoint|pages|numbers|notes|notion/.test(s)) return 'Productivity';
    return row.system ? 'System service' : row.appPath ? 'Other app' : 'Background task';
  }
  function evaluate(row, system, limits) {
    limits = limits || defaults(system.memory);
    var kernel = row.pid === 0 || (row.pids && row.pids.indexOf(0) >= 0);
    var cpu = row.cpu || 0,
      mem = row.memory || 0,
      power = row.energy || 0,
      wake = kernel ? 0 : row.wakeups || 0;
    var flags = [],
      reasons = [];
    if (cpu >= limits.cpu) {
      flags.push('CPU');
      reasons.push('Average CPU is above your review threshold.');
    }
    if (mem >= limits.memory) {
      flags.push('Memory');
      reasons.push(
        system.pressureValue > 1
          ? 'Large footprint while macOS reports memory pressure.'
          : 'Large allocation; normal pressure alone does not establish a shortage.'
      );
    }
    if (power >= limits.energy || wake >= limits.wakeups) {
      flags.push('Energy');
      reasons.push('CPU activity or frequent idle wakeups may affect battery life.');
    }
    if (row.sleep) {
      flags.push('Sleep');
      reasons.push('An assertion prevents idle system sleep.');
    }
    var intervals = (row.series || []).filter(function (x) {
      return typeof x.cpu === 'number' && isFinite(x.cpu);
    });
    var busy = intervals.length
      ? intervals.filter(function (x) {
          return x.cpu >= limits.cpu;
        }).length / intervals.length
      : row.busyFraction;
    var pattern =
      row.cpu === null
        ? 'Not enough samples'
        : cpu >= limits.cpu && intervals.length < 2
          ? 'CPU active · short sample'
          : cpu >= limits.cpu && busy >= 0.5
            ? 'Sustained CPU'
            : row.peakCPU >= limits.cpu * 2 && cpu < limits.cpu
              ? 'CPU burst'
              : 'Steady / light';
    if (pattern === 'CPU burst') {
      flags.push('Burst');
      reasons.push('A brief CPU peak was much higher than the average.');
    }
    var score =
      Math.max(
        cpu / (limits.cpu * 2),
        mem / (limits.memory * 2),
        power / (limits.energy * 2),
        wake / (limits.wakeups * 2)
      ) + (row.sleep ? 0.25 : 0);
    if (system.pressureValue > 1 && mem >= limits.memory) score += 0.5;
    var level = score >= 1 ? 'High' : flags.length ? 'Review' : 'Low';
    var text = flags.length
      ? 'Save your work, pause a heavy task, then recheck. Quit and reopen the app if its load stays high.'
      : 'No large load observed. Keep it open if you are using it.';
    var label = (row.name + ' ' + (row.path || '')).toLowerCase();
    if (/windowserver/.test(label))
      text =
        'Reduce open windows and screen effects; stop unused screen sharing or recording. Recheck CPU.';
    else if (/kernel_task/.test(label))
      text =
        'Check airflow and disconnect unused peripherals. Pause heavy work if the Mac is hot; do not quit this process.';
    else if (/\bmds\b|mdworker|spotlight/.test(label))
      text =
        'Spotlight may be indexing after an update or file changes. Let it finish; recheck later if it stays busy.';
    else if (/backupd|timemachine/.test(label))
      text =
        'Check Time Machine for an active backup. Let it finish, or pause it through Time Machine if needed.';
    else if (/photoanalysis|photolibrary|mediaanalysis/.test(label))
      text =
        'Photos may be analyzing or syncing your library. Let it finish while plugged in; recheck if it remains busy.';
    else if (/powerd/.test(label))
      text =
        'macOS may keep the Mac awake while the screen is on. Review other sleep blockers first.';
    else if (/amphetamine|caffeinate|keepingyouawake/.test(label) && row.sleep)
      text = 'End this app’s keep-awake session when you want normal sleep.';
    else if (
      /chrome|safari|firefox|brave|vivaldi|microsoft edge|\barc\b|opera|orion/.test(label) &&
      flags.length
    )
      text =
        'Close unused tabs, pause video streams, and review extensions. Use the browser task manager, if available, to identify a busy tab.';
    else if (/zoom|teams|webex|discord|slack/.test(label) && flags.length)
      text =
        'End unused calls or screen sharing; close extra workspaces. Save work before quitting and reopening the app.';
    else if (
      /xcode|swift|clang|node|python|docker|code helper|visual studio|terminal|iterm/.test(label) &&
      flags.length
    )
      text =
        'Check for a build, server, container, or background task. Stop an unused task in its owning app or Terminal.';
    else if (row.system && flags.length)
      text =
        'Inspect this service in Activity Monitor. Scheduled work can be expected; recheck before taking action.';
    else if (flags.length === 1 && flags[0] === 'Memory' && system.pressureValue === 1)
      text =
        'This app has a large allocation, while memory pressure is normal. Close unused documents or windows if needed, then compare another scan.';
    else if (row.sleep && flags.length === 1)
      text =
        'Check for a call, download, playback, or sync. Stop that activity if you want the Mac to sleep.';
    return {
      flags: flags,
      reasons: reasons,
      pattern: pattern,
      score: Math.round(score * 100),
      level: level,
      text: text
    };
  }
  return { defaults: defaults, category: category, evaluate: evaluate };
})();
