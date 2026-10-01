#!/bin/bash
# Mac Resource Check 2.1.0. Uses only tools included with macOS.
# Read-only collection; never quits a process or changes system settings.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
launcher_path="$script_dir/$(basename -- "$0")"
output_dir="$script_dir/Reports"
sample_seconds=12
watch_seconds=0
open_report=1
open_only=0
browser=default
history_limit=40
lock_file=""
sleep_pid=""
version="2.1.0"

usage() {
    cat <<'HELP'
Mac Resource Check — a sorted visual report of macOS resource usage

Double-click this .command file for a detailed 12-second scan and automatic browser launch.

Options:
  --seconds N      Sample for N seconds (2–120, rounded up to 2-second intervals)
  --watch N        Repeat every N seconds (10–3600); stop with Control-C
  --output DIR     Save HTML, JSON, and CSV in DIR (default: Reports beside script)
  --browser NAME   default, safari, chrome, firefox, edge, or brave
  --open-only      Open the existing dashboard without taking a new scan
  --history N      Keep the last N scans for comparisons (1–120; default: 40)
  --quick          Take a shorter 4-second sample
  --no-open        Save the report without opening a browser
  --version        Show the program version
  --help           Show this help

Examples:
  bash "Mac Resource Check.command"
  bash "Mac Resource Check.command" --seconds 20
  bash "Mac Resource Check.command" --watch 30

No extra installs, administrator privileges, or internet connection required.
Power is a CPU / idle-wakeup proxy, not watts or Activity Monitor Energy Impact.
HELP
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
integer() { [[ "$1" =~ ^[0-9]+$ ]] && (( ${#1} <= 4 )); }
while (( $# )); do
    case "$1" in
        --seconds)
            [[ $# -ge 2 ]] || fail '--seconds needs a number.'
            integer "$2" || fail '--seconds must be an integer from 2 to 120.'
            sample_seconds=$((10#$2))
            (( sample_seconds >= 2 && sample_seconds <= 120 )) || fail '--seconds must be from 2 to 120.'
            shift 2 ;;
        --watch)
            [[ $# -ge 2 ]] || fail '--watch needs a number.'
            integer "$2" || fail '--watch must be an integer from 10 to 3600.'
            watch_seconds=$((10#$2))
            (( watch_seconds >= 10 && watch_seconds <= 3600 )) || fail '--watch must be from 10 to 3600.'
            shift 2 ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || fail '--output needs a folder path.'
            output_dir="$2"; shift 2 ;;
        --no-open) open_report=0; shift ;;
        --quick) sample_seconds=4; shift ;;
        --open-only) open_only=1; shift ;;
        --browser)
            [[ $# -ge 2 ]] || fail '--browser needs a name.'
            case "$2" in default|safari|chrome|firefox|edge|brave) browser="$2" ;; *) fail 'Unsupported browser. Use default, safari, chrome, firefox, edge, or brave.' ;; esac
            shift 2 ;;
        --history)
            [[ $# -ge 2 ]] || fail '--history needs a number.'
            integer "$2" || fail '--history must be an integer from 1 to 120.'
            history_limit=$((10#$2))
            (( history_limit >= 1 && history_limit <= 120 )) || fail '--history must be from 1 to 120.'
            shift 2 ;;
        --version) printf 'Mac Resource Check %s\n' "$version"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1. Use --help for usage." ;;
    esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'This script requires macOS.'
samples=$(((sample_seconds + 1) / 2 + 1))
effective_seconds=$(((samples - 1) * 2))
if (( watch_seconds && watch_seconds < effective_seconds + 2 )); then
    fail '--watch must be at least two seconds longer than the sample window.'
fi
/bin/mkdir -p -- "$output_dir" || fail 'Could not create the report folder. Try --output with a writable folder.'
output_dir="$(cd -- "$output_dir" && pwd -P)"
temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mac-resource-check.XXXXXXXX")"
cleanup() {
    if [[ -n "$sleep_pid" ]]; then
        kill -TERM "$sleep_pid" 2>/dev/null || true
        wait "$sleep_pid" 2>/dev/null || true
    fi
    /bin/rm -rf -- "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
collector_pid=$$
collector_uid="$(/usr/bin/id -u)"
report_file="$output_dir/Mac Resource Report.html"

cat > "$temp_dir/renderer.js" <<'RESOURCE_CHECK_JXA'
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

/* Pure parsing and analysis. Also exercised under Node in the development checks. */
var ResourceCheck = (function () {
  'use strict';
  function number(s) {
    var n = parseFloat(s);
    return isFinite(n) ? n : null;
  }
  function bytes(s) {
    var m = String(s || '').match(/^([\d.]+)\s*([BKMGT])(?:B)?[+-]?$/i);
    return m ? Number(m[1]) * Math.pow(1024, 'BKMGT'.indexOf(m[2].toUpperCase())) : null;
  }
  function mean(values) {
    var valid = values.filter(function (x) {
      return x !== null && isFinite(x);
    });
    return valid.length
      ? valid.reduce(function (a, b) {
          return a + b;
        }, 0) / valid.length
      : null;
  }
  function topFrames(raw) {
    var frames = [],
      current = null,
      rows = false,
      hasEnergy = false;
    raw.split(/\r?\n/).forEach(function (line) {
      if (/^Processes:/.test(line)) {
        current = { processes: {}, cpu: null, used: null, unused: null, timestamp: null };
        frames.push(current);
        rows = false;
      }
      if (!current) return;
      var date = line.match(/^(\d{4})\/(\d\d)\/(\d\d)\s+(\d\d):(\d\d):(\d\d)/);
      if (date)
        current.timestamp = new Date(
          +date[1],
          +date[2] - 1,
          +date[3],
          +date[4],
          +date[5],
          +date[6]
        ).getTime();
      var cpu = line.match(/^CPU usage:.*?([\d.]+)% idle/);
      if (cpu) current.cpu = 100 - Number(cpu[1]);
      var mem = line.match(/^PhysMem:\s+(\S+) used.*?,\s+(\S+) unused/);
      if (mem) {
        current.used = bytes(mem[1]);
        current.unused = bytes(mem[2]);
      }
      if (/^PID\s/.test(line)) {
        rows = true;
        hasEnergy = /\bPOWER\b/.test(line);
        return;
      }
      if (!rows || !/^\s*\d+\s/.test(line)) return;
      // COMMAND is deliberately last so that names with spaces remain intact.
      var m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/);
      if (!m) return;
      var rest = m[7],
        wake = null,
        power = null,
        command = rest;
      if (hasEnergy) {
        var energy = rest.match(/^(\S+)\s+(\S+)\s+(.*)$/);
        if (!energy) return;
        wake = number(energy[1]);
        power = number(energy[2]);
        command = energy[3];
      }
      current.processes[m[1]] = {
        pid: +m[1],
        ppid: +m[2],
        uid: +m[3],
        cpu: number(m[4]),
        memory: bytes(m[5]),
        threads: number(m[6]),
        wakeCounter: wake,
        energy: +m[1] === 0 ? null : power,
        command: command.trim()
      };
    });
    return frames;
  }
  function psRows(raw) {
    var result = {};
    raw.split(/\r?\n/).forEach(function (line) {
      var m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$/);
      if (m) {
        var extra = m[6].match(/^(\S+)\s+(-?\d+|-)\s+(.+)$/);
        result[m[1]] = {
          pid: +m[1],
          ppid: +m[2],
          uid: +m[3],
          rss: +m[4] * 1024,
          elapsed: m[5],
          state: extra ? extra[1] : null,
          nice: extra ? number(extra[2]) : null,
          path: (extra ? extra[3] : m[6]).trim()
        };
      }
    });
    return result;
  }
  function assertions(raw) {
    var result = {};
    raw.split(/\r?\n/).forEach(function (line) {
      var m = line.match(/^\s*pid\s+(\d+)\((.*?)\):.*?\]\s+\S+\s+(\S+)\s+named:\s*"(.*)"/);
      if (
        !m ||
        !/^(PreventUserIdleSystemSleep|PreventSystemSleep|PreventUserIdleDisplaySleep|NoIdleSleepAssertion)$/.test(
          m[3]
        )
      )
        return;
      if (!result[m[1]]) result[m[1]] = [];
      var duration = line.match(/\]\s+(\S+)/);
      result[m[1]].push({
        type: m[3],
        name: m[4],
        duration: duration ? duration[1] : null,
        displayOnly: m[3] === 'PreventUserIdleDisplaySleep'
      });
    });
    return result;
  }
  function systemMemory(raw) {
    var size = raw.match(/page size of (\d+) bytes/),
      page = size ? +size[1] : null,
      stats = {};
    raw.split(/\r?\n/).forEach(function (line) {
      var m = line.match(/^([^:]+):\s+(\d+)\./);
      if (m && page) stats[m[1]] = +m[2] * page;
    });
    return {
      swapins: stats['Swapins'] === undefined ? null : stats['Swapins'],
      swapouts: stats['Swapouts'] === undefined ? null : stats['Swapouts'],
      wired: stats['Pages wired down'] === undefined ? null : stats['Pages wired down'],
      compressed:
        stats['Pages occupied by compressor'] === undefined
          ? null
          : stats['Pages occupied by compressor'],
      free: stats['Pages free'] === undefined ? null : stats['Pages free']
    };
  }
  function disk(raw) {
    var lines = raw.trim().split(/\r?\n/),
      m = lines[lines.length - 1].match(/^\S+\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%/);
    return m
      ? { total: +m[1] * 1024, used: +m[2] * 1024, available: +m[3] * 1024, percent: +m[4] }
      : null;
  }
  function battery(raw) {
    var source = raw.match(/drawing from '([^']+)'/),
      m = raw.match(/(\d+)%;\s*([^;]+);\s*([^\n]+)/);
    return {
      source: source ? source[1] : 'Unavailable',
      percent: m ? +m[1] : null,
      status: m ? m[2].trim() : 'No battery reported',
      remaining: m ? m[3].replace(/present:.*$/, '').trim() : null
    };
  }
  function network(raw) {
    var result = {};
    (raw || '').split(/\r?\n/).forEach(function (line) {
      var parts = line.trim().split(/\s+/);
      if (!/^en\d+\*?$/.test(parts[0]) || !/^<Link#/.test(parts[2])) return;
      // Read the final 7 numeric fields. Link rows may omit a hardware address.
      var tail = parts.slice(-7),
        incoming = number(tail[2]),
        outgoing = number(tail[5]);
      if (incoming !== null && outgoing !== null)
        result[parts[0].replace(/\*$/, '')] = { inBytes: incoming, outBytes: outgoing };
    });
    return result;
  }
  function ioCounters(raw) {
    var devices = [],
      values = null;
    (raw || '').split(/\r?\n/).forEach(function (line) {
      if (/^\s*disk\d+/.test(line)) devices = line.trim().split(/\s+/);
      if (/^\s*[\d.]+\s/.test(line)) values = line.trim().split(/\s+/).map(number);
    });
    var result = {};
    if (values && values.length === devices.length * 3)
      devices.forEach(function (device, i) {
        if (values[i * 3 + 2] !== null)
          result[device] = { transfers: values[i * 3 + 1], megabytes: values[i * 3 + 2] };
      });
    return result;
  }
  function counterRates(before, after, seconds, fields) {
    var rows = [];
    if (!(seconds > 0)) return rows;
    Object.keys(after).forEach(function (name) {
      if (!before[name]) return;
      var row = { name: name },
        ok = true;
      fields.forEach(function (field) {
        var current = after[name][field],
          previous = before[name][field];
        if (
          typeof current !== 'number' ||
          typeof previous !== 'number' ||
          !isFinite(current) ||
          !isFinite(previous) ||
          current < previous
        )
          ok = false;
        row[field] = (current - previous) / seconds;
      });
      if (ok) rows.push(row);
    });
    return rows;
  }
  function analyze(input, info) {
    var frames = topFrames(input.top),
      last = frames[frames.length - 1];
    if (!last || frames.length < 2 || !Object.keys(last.processes).length) {
      throw new Error(
        'No usable process samples. Run the .command file from Terminal outside an app sandbox.'
      );
    }
    var ps = psRows(input.ps),
      sleep = assertions(input.assertions),
      processes = [],
      excluded = 0;
    var sleepAvailable = !!input.assertions.trim();
    var interval = info.interval || 2,
      energyAvailable = false,
      ram = info.memory;
    var pressureValue = number(input.pressure.trim()),
      pressure = { 1: 'Normal', 2: 'Elevated', 4: 'Critical' }[pressureValue] || 'Unavailable';
    Object.keys(last.processes).forEach(function (pid) {
      var p = last.processes[pid],
        meta = ps[pid],
        cpus = [],
        powers = [],
        wakeCounts = 0,
        wakeSeconds = 0;
      p.series = frames.map(function (frame, i) {
        var point = frame.processes[pid],
          before = i ? frames[i - 1].processes[pid] : null;
        return {
          second: (frame.timestamp - frames[0].timestamp) / 1000,
          memory: point ? point.memory : null,
          cpu:
            point && before && point.uid === before.uid && point.command === before.command
              ? point.cpu
              : null,
          energy:
            point && before && point.uid === before.uid && point.command === before.command
              ? point.energy
              : null
        };
      });
      // Never trust the first top sample; it has no prior interval.
      for (var i = 1; i < frames.length; i++) {
        var now = frames[i].processes[pid],
          before = frames[i - 1].processes[pid];
        if (!now || !before || now.uid !== before.uid || now.command !== before.command) continue;
        cpus.push(now.cpu);
        powers.push(now.energy);
        if (
          now.wakeCounter !== null &&
          before.wakeCounter !== null &&
          now.wakeCounter >= before.wakeCounter
        ) {
          wakeCounts += now.wakeCounter - before.wakeCounter;
          var dt = (frames[i].timestamp - frames[i - 1].timestamp) / 1000;
          wakeSeconds += dt > 0 ? dt : interval;
        }
      }
      var validCPU = cpus.filter(function (x) {
        return x !== null;
      });
      p.cpu = mean(validCPU);
      p.peakCPU = validCPU.length ? Math.max.apply(null, validCPU) : null;
      p.cpuSamples = cpus;
      p.energy = mean(powers);
      p.wakeups = wakeSeconds ? wakeCounts / wakeSeconds : null;
      p.observedSamples = cpus.filter(function (x) {
        return x !== null;
      }).length;
      p.busyFraction = cpus.length
        ? cpus.filter(function (x) {
            return x >= 25;
          }).length / cpus.length
        : 0;
      p.memoryChange =
        p.series[0].memory !== null && p.memory !== null ? p.memory - p.series[0].memory : null;
      if (meta && meta.uid === p.uid) {
        p.path = meta.path;
        p.elapsed = meta.elapsed;
        p.residentMemory = meta.rss;
        p.state = meta.state;
        p.nice = meta.nice;
      } else {
        p.path = p.command;
        p.elapsed = null;
        p.residentMemory = null;
        p.state = null;
        p.nice = null;
      }
      // Exclude this collector's processes only; the Terminal hosting it stays visible.
      if (
        (['top', 'ps', 'iostat', 'netstat'].indexOf(p.command) >= 0 &&
          p.ppid === info.collectorPID) ||
        p.pid === info.collectorPID
      ) {
        excluded++;
        return;
      }
      var match = p.path.match(/^(.*?\.app)(?:\/|$)/);
      p.appPath = match ? match[1] : null;
      if (meta && meta.uid === p.uid) p.command = p.path.split('/').pop();
      p.name = p.appPath
        ? p.appPath
            .split('/')
            .pop()
            .replace(/\.app$/, '')
        : p.command;
      p.isMine = p.uid === info.uid;
      p.system = p.pid <= 1 || !p.isMine || (!p.appPath && /^\/(System|usr|sbin)\//.test(p.path));
      p.assertions = sleep[pid] || [];
      p.sleep = sleepAvailable
        ? p.assertions.some(function (x) {
            return !x.displayOnly;
          })
        : null;
      p.displaySleep = sleepAvailable
        ? p.assertions.some(function (x) {
            return x.displayOnly;
          })
        : null;
      if (p.energy !== null) energyAvailable = true;
      processes.push(p);
    });
    // Attribute child helpers only to a parent with the same user; never cross launchd.
    var byPID = {};
    processes.forEach(function (p) {
      byPID[p.pid] = p;
    });
    processes.forEach(function (p) {
      if (p.appPath) return;
      var parent = byPID[p.ppid],
        seen = {},
        hops = 0;
      while (parent && parent.uid === p.uid && parent.pid > 1 && !seen[parent.pid] && hops++ < 20) {
        seen[parent.pid] = true;
        if (parent.appPath) {
          p.appPath = parent.appPath;
          p.name = parent.name;
          p.system = parent.system;
          break;
        }
        parent = byPID[parent.ppid];
      }
    });
    processes.forEach(function (p) {
      p.id = p.pid + ':' + p.uid + ':' + p.path;
      p.category = ResourceRules.category(p);
    });
    function advice(row) {
      return ResourceRules.evaluate(row, { memory: ram, pressureValue: pressureValue });
    }
    var groups = {};
    processes.forEach(function (p) {
      var key = (p.appPath || p.path) + ':' + p.uid;
      if (!groups[key])
        groups[key] = {
          id: key,
          name: p.name,
          path: p.path,
          appPath: p.appPath,
          uid: p.uid,
          isMine: p.isMine,
          system: p.appPath ? !p.isMine : p.system,
          pids: [],
          cpu: null,
          memory: null,
          energy: null,
          wakeups: null,
          threads: 0,
          sleep: sleepAvailable ? false : null,
          displaySleep: sleepAvailable ? false : null,
          processes: []
        };
      var g = groups[key];
      ['cpu', 'memory', 'energy', 'wakeups'].forEach(function (field) {
        if (p[field] !== null) g[field] = (g[field] || 0) + p[field];
      });
      g.threads += p.threads || 0;
      g.sleep = g.sleep || p.sleep;
      g.displaySleep = g.displaySleep || p.displaySleep;
      g.pids.push(p.pid);
      g.processes.push(p);
      p.advice = advice(p);
    });
    var apps = Object.keys(groups).map(function (key) {
      var g = groups[key];
      g.advice = advice(g);
      return g;
    });
    apps.forEach(function (g) {
      g.series = frames.map(function (frame, i) {
        var point = {
          second: (frame.timestamp - frames[0].timestamp) / 1000,
          cpu: null,
          memory: null,
          energy: null
        };
        g.processes.forEach(function (p) {
          ['cpu', 'memory', 'energy'].forEach(function (field) {
            var value = p.series[i][field];
            if (value !== null) point[field] = (point[field] || 0) + value;
          });
        });
        return point;
      });
      var measured = g.series
        .slice(1)
        .map(function (x) {
          return x.cpu;
        })
        .filter(function (x) {
          return x !== null;
        });
      g.cpu = mean(measured);
      g.energy = mean(
        g.series.slice(1).map(function (x) {
          return x.energy;
        })
      );
      g.peakCPU = measured.length ? Math.max.apply(null, measured) : null;
      g.busyFraction = measured.length
        ? measured.filter(function (x) {
            return x >= 25;
          }).length / measured.length
        : 0;
      g.observedSamples = measured.length;
      g.memoryChange =
        g.series[0].memory !== null && g.memory !== null ? g.memory - g.series[0].memory : null;
      g.category = ResourceRules.category(g);
      g.advice = advice(g);
    });
    apps.sort(function (a, b) {
      return b.advice.score - a.advice.score;
    });
    var swap = input.swap.match(/used\s*=\s*([\d.]+[BKMGT])/i),
      vm = systemMemory(input.vm);
    var totalCPU = mean(
      frames.slice(1).map(function (x) {
        return x.cpu;
      })
    );
    var elapsed = (last.timestamp - frames[0].timestamp) / 1000;
    var ioSeconds = number(input.counterSeconds || '') || elapsed || interval;
    var networkRates = counterRates(
      network(input.networkBefore),
      network(input.networkAfter),
      ioSeconds,
      ['inBytes', 'outBytes']
    );
    var diskRates = counterRates(ioCounters(input.ioBefore), ioCounters(input.ioAfter), ioSeconds, [
      'transfers',
      'megabytes'
    ]);
    var vmBefore = systemMemory(input.vmBefore || ''),
      swapActivity = null;
    if (
      vm.swapins !== null &&
      vm.swapouts !== null &&
      vmBefore.swapins !== null &&
      vmBefore.swapouts !== null &&
      vm.swapins >= vmBefore.swapins &&
      vm.swapouts >= vmBefore.swapouts
    ) {
      swapActivity = {
        inBytes: (vm.swapins - vmBefore.swapins) / ioSeconds,
        outBytes: (vm.swapouts - vmBefore.swapouts) / ioSeconds
      };
    }
    var boot = (input.boot || '').match(/sec\s*=\s*(\d+)/);
    return {
      version: '2.1.0',
      currentUID: info.uid,
      launcherPath: info.launcherPath,
      collectedAt: info.collectedAt,
      osVersion: info.osVersion,
      cores: info.cores,
      sampleSeconds: elapsed > 0 ? elapsed : (frames.length - 1) * interval,
      sampleCount: frames.length - 1,
      systemSeries: frames.slice(1).map(function (f) {
        return {
          second: (f.timestamp - frames[0].timestamp) / 1000,
          cpu: f.cpu,
          memoryUsed: f.used
        };
      }),
      watch: info.watch,
      collectorExcluded: excluded,
      energyAvailable: energyAvailable,
      sleepAvailable: sleepAvailable,
      warnings: info.warnings || [],
      system: {
        cpu: totalCPU,
        memory: ram,
        memoryUsed: last.used,
        memoryUnused: last.unused,
        pressure: pressure,
        pressureValue: pressureValue,
        swap: swap ? bytes(swap[1]) : null,
        wired: vm.wired,
        compressed: vm.compressed,
        disk: disk(input.disk),
        battery: battery(input.battery),
        thermal: info.thermal,
        uptime: boot ? Math.max(0, Date.parse(info.collectedAt) / 1000 - Number(boot[1])) : null,
        network: networkRates.length ? networkRates : null,
        diskActivity: diskRates.length ? diskRates : null,
        swapActivity: swapActivity,
        ioSampleSeconds: ioSeconds
      },
      apps: apps,
      processes: processes
    };
  }
  return {
    bytes: bytes,
    topFrames: topFrames,
    psRows: psRows,
    assertions: assertions,
    network: network,
    ioCounters: ioCounters,
    counterRates: counterRates,
    analyze: analyze
  };
})();

var REPORT_TEMPLATE = "<!doctype html>\n<html lang=\"en\">\n  <head>\n    <meta charset=\"utf-8\" />\n    <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" />\n    <meta\n      http-equiv=\"Content-Security-Policy\"\n      content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'\"\n    />\n    <title>Mac Resource Check</title>\n    <style>\n      :root {\n  color-scheme: light;\n  --bg: #f5f5f3;\n  --paper: #fff;\n  --soft: #f0f1ee;\n  --ink: #252b2b;\n  --muted: #63706c;\n  --line: #dce0db;\n  --cpu: #b65b31;\n  --memory: #756292;\n  --energy: #2c7a70;\n  --blue: #386c70;\n  --red: #aa3439;\n  --green: #21734a;\n  --radius: 10px;\n}\n:root[data-theme='dark'] {\n  color-scheme: dark;\n  --bg: #111923;\n  --paper: #1b2633;\n  --soft: #253243;\n  --ink: #edf2f8;\n  --muted: #a8b4c4;\n  --line: #344254;\n  --cpu: #efa474;\n  --memory: #b899ed;\n  --energy: #65c6ba;\n  --blue: #a1b7fa;\n  --red: #fa9da2;\n  --green: #80c89d;\n}\n* {\n  box-sizing: border-box;\n}\nbody {\n  margin: 0;\n  background: var(--bg);\n  color: var(--ink);\n  font:\n    14px/1.5 -apple-system,\n    BlinkMacSystemFont,\n    'Segoe UI',\n    sans-serif;\n}\nbutton,\ninput,\nselect {\n  font: inherit;\n  color: var(--ink);\n}\nbutton,\na.button {\n  cursor: pointer;\n}\nbutton:focus-visible,\na:focus-visible,\ninput:focus-visible,\nselect:focus-visible,\nsummary:focus-visible {\n  outline: 3px solid #7898ed;\n  outline-offset: 3px;\n}\nbutton:disabled {\n  opacity: 0.4;\n  cursor: default;\n}\na {\n  color: var(--blue);\n}\nh1,\nh2,\nh3,\np {\n  margin: 0;\n}\nh1 {\n  font-size: 26px;\n  letter-spacing: -0.7px;\n  line-height: 1.3;\n}\nh2 {\n  font-size: 16px;\n  font-weight: 650;\n}\nh3 {\n  font-size: 13px;\n  font-weight: 650;\n  margin-bottom: 8px;\n}\n[hidden] {\n  display: none !important;\n}\n.wrap {\n  max-width: 1540px;\n  margin: 0 auto;\n  padding: 28px 32px 44px;\n}\n.masthead,\n.section-top,\n.dialog-head {\n  display: flex;\n  justify-content: space-between;\n  align-items: center;\n  gap: 16px;\n}\n.masthead {\n  margin-bottom: 16px;\n}\n.brand {\n  display: flex;\n  gap: 13px;\n  align-items: center;\n}\n.mark {\n  background: #334743;\n  color: #fff;\n  width: 46px;\n  height: 46px;\n  border-radius: 10px;\n  display: grid;\n  place-items: center;\n  font-size: 28px;\n}\n.eyebrow {\n  font-size: 10px;\n  letter-spacing: 0.12em;\n  text-transform: uppercase;\n  font-weight: 700;\n  color: var(--muted);\n}\n.sub,\n.small,\n.detail {\n  font-size: 12px;\n  color: var(--muted);\n}\n.sub {\n  margin-top: 4px;\n}\n.tools,\n.button-row {\n  display: flex;\n  gap: 8px;\n  align-items: center;\n  flex-wrap: wrap;\n}\n.button,\n.quiet {\n  border: 1px solid var(--line);\n  border-radius: 8px;\n  background: var(--paper);\n  padding: 8px 12px;\n  text-decoration: none;\n  white-space: nowrap;\n}\n.button.primary {\n  background: var(--ink);\n  color: var(--bg);\n  border-color: var(--ink);\n}\n.quiet {\n  padding: 5px 9px;\n  font-size: 11px;\n}\n.link-button {\n  border: 0;\n  background: transparent;\n  color: var(--blue);\n  padding: 4px;\n  font-size: 12px;\n}\n.freshness {\n  font-size: 11px;\n  color: var(--muted);\n  margin-bottom: 14px;\n  min-height: 16px;\n}\n.freshness.stale {\n  color: var(--red);\n}\n.warning {\n  background: var(--soft);\n  border: 1px solid var(--line);\n  border-left: 3px solid var(--cpu);\n  border-radius: 9px;\n  padding: 12px 16px;\n  margin-bottom: 16px;\n  font-size: 12px;\n}\n.main-nav {\n  display: flex;\n  align-items: center;\n  gap: 6px;\n  border-bottom: 1px solid var(--line);\n  margin-bottom: 20px;\n  padding-bottom: 10px;\n  flex-wrap: wrap;\n}\n.main-nav button {\n  border: 0;\n  background: transparent;\n  color: var(--muted);\n  padding: 8px 13px;\n  border-radius: 8px;\n  font-size: 12px;\n}\n.main-nav button.active {\n  background: var(--ink);\n  color: var(--bg);\n  font-weight: 600;\n}\n.main-nav > span {\n  margin-left: auto;\n}\n.summary {\n  display: grid;\n  grid-template-columns: repeat(6, minmax(0, 1fr));\n  gap: 12px;\n  margin-bottom: 20px;\n}\n.card {\n  background: var(--paper);\n  border: 1px solid var(--line);\n  border-radius: var(--radius);\n  padding: 20px;\n}\n.card-label {\n  font-size: 11px;\n  color: var(--muted);\n  display: flex;\n  align-items: center;\n  gap: 5px;\n}\n.dot {\n  width: 6px;\n  height: 6px;\n  border-radius: 50%;\n  display: inline-block;\n  background: var(--blue);\n}\n.dot.cpu {\n  background: var(--cpu);\n}\n.dot.memory {\n  background: var(--memory);\n}\n.dot.energy {\n  background: var(--energy);\n}\n.big {\n  font-size: 26px;\n  line-height: 1.3;\n  font-weight: 650;\n  letter-spacing: -0.8px;\n  margin: 8px 0 4px;\n}\n.detail {\n  font-size: 11px;\n  line-height: 1.5;\n}\n.track,\n.mini,\n.bar-track {\n  background: var(--soft);\n  border-radius: 5px;\n  overflow: hidden;\n}\n.track {\n  height: 5px;\n  margin-top: 14px;\n}\n.track span {\n  display: block;\n  height: 100%;\n  background: var(--blue);\n}\n.spark {\n  height: 24px;\n  margin-top: 5px;\n}\n.spark svg {\n  width: 100%;\n  height: 24px;\n}\n.focus {\n  background: var(--soft);\n  border: 1px solid var(--line);\n  border-radius: var(--radius);\n  padding: 20px;\n  margin-bottom: 18px;\n}\n.section-top {\n  margin-bottom: 13px;\n}\n.health {\n  font-size: 13px;\n  line-height: 1.55;\n  margin-bottom: 14px;\n}\n.focus-grid,\n.charts {\n  display: grid;\n  grid-template-columns: repeat(3, minmax(0, 1fr));\n  gap: 12px;\n}\n.focus-item {\n  background: var(--paper);\n  border: 1px solid var(--line);\n  border-radius: 11px;\n  padding: 15px;\n}\n.focus-name {\n  font-weight: 650;\n  font-size: 13px;\n}\n.focus-copy {\n  font-size: 12px;\n  color: var(--muted);\n  margin: 6px 0 10px;\n}\n.focus-metrics {\n  font-size: 11px;\n  color: var(--muted);\n  margin: 6px 0;\n}\n.charts {\n  margin-bottom: 18px;\n}\n.chart .section-top {\n  margin-bottom: 4px;\n}\n.chart h2 {\n  font-size: 13px;\n}\n.bars {\n  margin-top: 14px;\n}\n.bar-row {\n  margin: 9px 0;\n  display: block;\n  border: 0;\n  background: transparent;\n  padding: 0;\n  width: 100%;\n  text-align: left;\n}\n.bar-caption {\n  display: flex;\n  justify-content: space-between;\n  gap: 10px;\n  font-size: 12px;\n  margin-bottom: 4px;\n}\n.bar-caption .name {\n  max-width: 74%;\n  overflow: hidden;\n  text-overflow: ellipsis;\n  white-space: nowrap;\n}\n.bar-track {\n  height: 7px;\n}\n.bar-fill {\n  height: 100%;\n  background: var(--cpu);\n  border-radius: 5px;\n}\n.memory .bar-fill,\n.memory .mini span {\n  background: var(--memory);\n}\n.energy .bar-fill,\n.energy .mini span {\n  background: var(--energy);\n}\n.two-col {\n  display: grid;\n  grid-template-columns: repeat(2, minmax(0, 1fr));\n  gap: 16px;\n  margin-bottom: 18px;\n}\n.key-stats {\n  display: grid;\n  grid-template-columns: repeat(2, minmax(0, 1fr));\n  gap: 12px;\n  margin-top: 16px;\n}\n.key-stat {\n  border-top: 1px solid var(--line);\n  padding-top: 10px;\n}\n.key-stat strong {\n  display: block;\n  font-size: 17px;\n  font-variant-numeric: tabular-nums;\n}\n.key-stat span {\n  font-size: 11px;\n  color: var(--muted);\n}\n.line-chart {\n  width: 100%;\n  height: 150px;\n  display: block;\n  margin-top: 12px;\n}\n.chart-caption {\n  display: flex;\n  justify-content: space-between;\n  gap: 10px;\n  color: var(--muted);\n  font-size: 10px;\n}\n.list {\n  background: var(--paper);\n  border: 1px solid var(--line);\n  border-radius: var(--radius);\n  overflow: hidden;\n}\n.list-head {\n  padding: 20px;\n}\n.list-toolbar {\n  display: flex;\n  justify-content: space-between;\n  gap: 12px;\n  flex-wrap: wrap;\n}\n.tabs {\n  display: flex;\n  background: var(--soft);\n  border-radius: 8px;\n  padding: 3px;\n  gap: 2px;\n}\n.tabs button {\n  border: 0;\n  background: transparent;\n  border-radius: 6px;\n  padding: 7px 10px;\n  font-size: 11px;\n  white-space: nowrap;\n}\n.tabs button.active {\n  background: var(--paper);\n  box-shadow: 0 1px 4px #0002;\n  font-weight: 600;\n}\n.filters,\n.filter-line {\n  display: flex;\n  gap: 8px;\n  align-items: center;\n  flex-wrap: wrap;\n}\n.filters input {\n  width: 210px;\n}\n.filters input,\n.filters select,\n.setting select,\n.setting-grid input,\n.setting-grid select {\n  border: 1px solid var(--line);\n  background: var(--paper);\n  border-radius: 7px;\n  padding: 8px;\n  font-size: 12px;\n  max-width: 100%;\n}\n.filter-line {\n  margin-top: 12px;\n  gap: 15px;\n}\n.filter-line > span {\n  margin-left: auto;\n}\n.check {\n  font-size: 11px;\n  display: flex;\n  gap: 5px;\n  align-items: center;\n  color: var(--muted);\n}\n.table-scroll {\n  overflow: auto;\n}\ntable {\n  border-collapse: collapse;\n  width: 100%;\n  min-width: 1320px;\n  font-size: 11px;\n}\nth {\n  background: var(--soft);\n  color: var(--muted);\n  padding: 10px 11px;\n  text-align: left;\n  border-bottom: 1px solid var(--line);\n  font-size: 10px;\n  font-weight: 600;\n  white-space: nowrap;\n}\nth button {\n  border: 0;\n  background: transparent;\n  padding: 0;\n  color: inherit;\n  font-size: inherit;\n}\nth button.active {\n  color: var(--ink);\n}\ntd {\n  padding: 12px 11px;\n  border-bottom: 1px solid var(--line);\n  vertical-align: top;\n}\ntbody tr:hover {\n  background: var(--soft);\n}\n.compact {\n  min-width: 650px;\n}\n.compact td {\n  padding: 10px;\n}\n.app-cell {\n  max-width: 205px;\n  min-width: 160px;\n}\n.app-name {\n  font-size: 12px;\n  font-weight: 650;\n  overflow-wrap: anywhere;\n}\n.app-meta {\n  font-size: 10px;\n  color: var(--muted);\n  margin-top: 3px;\n}\n.value {\n  font-weight: 650;\n  font-variant-numeric: tabular-nums;\n}\n.metric {\n  min-width: 96px;\n}\n.mini {\n  width: 74px;\n  height: 3px;\n  margin-top: 6px;\n}\n.mini span {\n  display: block;\n  height: 100%;\n  background: var(--cpu);\n}\n.status {\n  display: inline-block;\n  border: 1px solid var(--line);\n  border-radius: 15px;\n  padding: 3px 7px;\n  font-size: 10px;\n  font-weight: 650;\n  color: var(--muted);\n  white-space: nowrap;\n}\n.status.review {\n  color: var(--cpu);\n}\n.status.high {\n  color: var(--red);\n}\n.status.low {\n  color: var(--green);\n}\n.delta.up {\n  color: var(--red);\n}\n.delta.down {\n  color: var(--green);\n}\n.pin {\n  border: 0;\n  background: transparent;\n  font-size: 18px;\n  padding: 0;\n  color: var(--muted);\n}\n.pin.active {\n  color: var(--cpu);\n}\n.action-cell {\n  min-width: 245px;\n  max-width: 300px;\n  color: var(--muted);\n  line-height: 1.4;\n}\n.action-cell .quiet {\n  margin-top: 7px;\n}\n.list-foot {\n  display: flex;\n  justify-content: space-between;\n  align-items: center;\n  padding: 13px 20px;\n}\n.empty {\n  padding: 24px;\n  color: var(--muted);\n}\n.change-list {\n  margin-top: 12px;\n}\n.change-row {\n  display: flex;\n  justify-content: space-between;\n  align-items: center;\n  gap: 12px;\n  padding: 10px 0;\n  border-bottom: 1px solid var(--line);\n  font-size: 12px;\n}\n.change-row button {\n  border: 0;\n  background: transparent;\n  text-align: left;\n  color: var(--ink);\n  padding: 0;\n}\n.history-charts {\n  margin-top: 22px;\n}\n.setting-grid {\n  display: grid;\n  grid-template-columns: repeat(2, minmax(0, 1fr));\n  gap: 12px;\n  margin: 18px 0;\n}\n.setting-grid label,\n.setting {\n  display: grid;\n  gap: 6px;\n  font-size: 12px;\n  color: var(--muted);\n}\n.setting {\n  max-width: 250px;\n  margin: 15px 0;\n}\n.button-row {\n  margin: 16px 0;\n}\n.notes {\n  margin-top: 14px;\n  font-size: 12px;\n  color: var(--muted);\n}\nsummary {\n  cursor: pointer;\n  font-weight: 600;\n  color: var(--ink);\n}\n.guide details {\n  border-top: 1px solid var(--line);\n  padding: 14px 0;\n  font-size: 12px;\n}\n.guide p {\n  color: var(--muted);\n  margin-top: 9px;\n  line-height: 1.7;\n}\n.footer {\n  display: flex;\n  justify-content: space-between;\n  gap: 12px;\n  color: var(--muted);\n  font-size: 10px;\n  margin-top: 23px;\n}\n.sr-only {\n  position: absolute;\n  width: 1px;\n  height: 1px;\n  overflow: hidden;\n  clip: rect(0, 0, 0, 0);\n}\ndialog {\n  border: 1px solid var(--line);\n  border-radius: 18px;\n  padding: 25px;\n  width: min(1000px, calc(100% - 30px));\n  max-height: 90vh;\n  background: var(--paper);\n  color: var(--ink);\n  box-shadow: 0 20px 90px #0005;\n}\ndialog::backdrop {\n  background: #0b162975;\n  backdrop-filter: blur(3px);\n}\ndialog h2 {\n  font-size: 21px;\n}\ndialog p {\n  margin: 10px 0;\n}\n.dialog-head {\n  margin-bottom: 14px;\n}\n.path {\n  font:\n    11px/1.6 ui-monospace,\n    SFMono-Regular,\n    monospace;\n  color: var(--muted);\n  overflow-wrap: anywhere;\n}\n.command {\n  padding: 14px;\n  background: var(--soft);\n  border-radius: 8px;\n  user-select: all;\n}\n.evidence {\n  border-left: 3px solid var(--cpu);\n  padding: 12px 15px;\n  background: var(--soft);\n  border-radius: 8px;\n  margin: 15px 0;\n  font-size: 12px;\n}\n.evidence ul {\n  padding-left: 18px;\n  margin: 7px 0;\n}\n.process-detail {\n  margin-top: 22px;\n}\n.process-detail table {\n  min-width: 850px;\n}\n.step {\n  padding: 12px 0;\n  border-bottom: 1px solid var(--line);\n}\n.toast {\n  position: fixed;\n  bottom: 20px;\n  left: 50%;\n  transform: translateX(-50%);\n  padding: 10px 16px;\n  border-radius: 9px;\n  background: var(--ink);\n  color: var(--bg);\n  font-size: 12px;\n  z-index: 20;\n}\n.inline-stat {\n  display: inline-flex;\n  gap: 7px;\n  align-items: baseline;\n  margin-right: 15px;\n  font-size: 12px;\n}\n.inline-stat strong {\n  font-size: 17px;\n}\n.tree-indent {\n  display: inline-block;\n  width: var(--indent);\n  border-left: 1px solid var(--line);\n  height: 11px;\n  margin-right: 4px;\n}\n@media (max-width: 1250px) {\n  .summary {\n    grid-template-columns: repeat(3, minmax(0, 1fr));\n  }\n  .wrap {\n    padding: 22px;\n  }\n  .list-toolbar {\n    gap: 10px;\n  }\n  .filters {\n    flex: 1;\n  }\n  .filter-line > span {\n    margin-left: 0;\n  }\n}\n@media (max-width: 850px) {\n  .focus-grid,\n  .charts {\n    grid-template-columns: 1fr;\n  }\n  .two-col {\n    grid-template-columns: 1fr;\n  }\n  .masthead {\n    align-items: flex-start;\n  }\n  .tools {\n    justify-content: flex-end;\n  }\n  .big {\n    font-size: 24px;\n  }\n  .main-nav > span {\n    margin-left: 0;\n  }\n  .card {\n    padding: 16px;\n  }\n}\n@media (max-width: 580px) {\n  .wrap {\n    padding: 16px 10px;\n  }\n  .summary {\n    grid-template-columns: repeat(2, minmax(0, 1fr));\n    gap: 8px;\n  }\n  .masthead {\n    flex-direction: column;\n  }\n  .tools {\n    justify-content: flex-start;\n  }\n  .card-label {\n    font-size: 10px;\n  }\n  .big {\n    font-size: 22px;\n  }\n  .brand h1 {\n    font-size: 24px;\n  }\n  .setting-grid {\n    grid-template-columns: 1fr;\n  }\n  .filters input {\n    width: 100%;\n  }\n  .tabs {\n    width: 100%;\n    justify-content: space-between;\n  }\n  .main-nav button {\n    padding: 8px;\n  }\n  .section-top {\n    align-items: flex-start;\n    flex-wrap: wrap;\n  }\n  .footer {\n    flex-direction: column;\n  }\n}\n@media print {\n  body {\n    background: white;\n    color: #111;\n  }\n  .wrap {\n    padding: 0;\n    max-width: none;\n  }\n  .tools,\n  .main-nav,\n  .filters,\n  .tabs,\n  .filter-line,\n  .quiet,\n  .pin,\n  .list-foot,\n  .freshness,\n  .demo-note,\n  dialog,\n  .toast {\n    display: none !important;\n  }\n  .summary {\n    grid-template-columns: repeat(3, 1fr);\n  }\n  .card,\n  .focus {\n    break-inside: avoid;\n    box-shadow: none;\n  }\n  .table-scroll {\n    overflow: visible;\n    max-height: none !important;\n  }\n  table {\n    min-width: 0;\n    font-size: 9px;\n  }\n  .metric,\n  .app-cell,\n  .action-cell {\n    min-width: 0;\n  }\n  td,\n  th {\n    padding: 5px;\n  }\n  .mini {\n    width: 45px;\n  }\n  .charts {\n    grid-template-columns: repeat(3, 1fr);\n  }\n  .two-col {\n    grid-template-columns: 1fr;\n  }\n}\n\ndialog:not([open]) {\n  display: none;\n}\ndialog[data-fallback='true'] {\n  position: fixed;\n  top: 5vh;\n  left: 50%;\n  transform: translateX(-50%);\n  z-index: 10;\n}\n#history-view .compact {\n  min-width: 650px;\n}\n#history-view .table-scroll {\n  max-height: 410px;\n}\n.list .table-scroll {\n  max-height: 70vh;\n}\n.list thead th {\n  position: sticky;\n  top: 0;\n  z-index: 2;\n}\n.list th:first-child,\n.list td:first-child {\n  position: sticky;\n  left: 0;\n  min-width: 40px;\n  width: 40px;\n  background: var(--paper);\n  z-index: 3;\n}\n.list th:nth-child(2),\n.list td:nth-child(2) {\n  position: sticky;\n  left: 40px;\n  background: var(--paper);\n  z-index: 3;\n}\n.list th:first-child,\n.list th:nth-child(2) {\n  background: var(--soft);\n  z-index: 4;\n}\n\n.mark svg {\n  width: 28px;\n  height: 28px;\n}\n.skip-link {\n  position: absolute;\n  top: -70px;\n  left: 16px;\n  padding: 10px 16px;\n  background: var(--paper);\n  z-index: 30;\n}\n.skip-link:focus {\n  top: 12px;\n}\n.demo-note {\n  padding: 10px 14px;\n  margin-bottom: 14px;\n  background: var(--soft);\n  border: 1px solid var(--line);\n  border-left: 3px solid var(--energy);\n  border-radius: 6px;\n  font-size: 12px;\n  color: var(--muted);\n}\n@media (prefers-reduced-motion: reduce) {\n  * {\n    scroll-behavior: auto !important;\n  }\n}\n\n    </style>\n  </head>\n  <body>\n    <a class=\"skip-link\" href=\"#main-content\">Skip to dashboard</a>\n    <main class=\"wrap\" id=\"main-content\">\n      <header class=\"masthead\">\n        <div class=\"brand\">\n          <div class=\"mark\" aria-hidden=\"true\">\n            <svg viewBox=\"0 0 28 28\">\n              <path\n                d=\"M3 22h22M6 17V9m8 8V5m8 12v-6\"\n                fill=\"none\"\n                stroke=\"currentColor\"\n                stroke-width=\"2.5\"\n                stroke-linecap=\"round\"\n              />\n            </svg>\n          </div>\n          <div>\n            <p class=\"eyebrow\">Resource diagnostics \u00b7 2.1.0</p>\n            <h1>Mac Resource Check</h1>\n            <p class=\"sub\" id=\"timestamp\"></p>\n          </div>\n        </div>\n        <div class=\"tools\">\n          <span id=\"live\"></span><button class=\"button\" id=\"rescan\">Scan options</button\n          ><button class=\"button primary\" id=\"export-list\">Export this list</button>\n        </div>\n      </header>\n      <div id=\"demo-note\" class=\"demo-note\" role=\"note\" hidden>\n        Demo \u00b7 Synthetic sample data. This page does not scan your Mac.\n      </div>\n      <div class=\"freshness\" id=\"freshness\" role=\"status\"></div>\n      <div id=\"warnings\" role=\"status\"></div>\n      <nav class=\"main-nav\" aria-label=\"Dashboard sections\">\n        <button data-page=\"overview\" class=\"active\">Overview</button\n        ><button data-page=\"investigate\">Apps &amp; processes</button\n        ><button data-page=\"history\">History &amp; changes</button\n        ><button data-page=\"settings\">Preferences &amp; guide</button\n        ><span id=\"scan-count\" class=\"small\"></span>\n      </nav>\n      <section class=\"summary\" aria-label=\"System overview\">\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot cpu\"></span>CPU \u00b7 all cores</p>\n          <div class=\"big\" id=\"cpu-total\"></div>\n          <p class=\"detail\" id=\"cpu-detail\"></p>\n          <div id=\"cpu-spark\" class=\"spark\"></div>\n        </article>\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot memory\"></span>Memory pressure</p>\n          <div class=\"big\" id=\"pressure\"></div>\n          <p class=\"detail\" id=\"memory-detail\"></p>\n          <p class=\"detail\" id=\"swap-detail\"></p>\n        </article>\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot energy\"></span>Power &amp; sleep</p>\n          <div class=\"big\" id=\"battery\"></div>\n          <p class=\"detail\" id=\"power-detail\"></p>\n          <p class=\"detail\" id=\"sleep-detail\"></p>\n        </article>\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot disk\"></span>Startup disk available</p>\n          <div class=\"big\" id=\"disk-free\"></div>\n          <p class=\"detail\" id=\"disk-detail\"></p>\n          <div class=\"track\"><span id=\"disk-track\"></span></div>\n        </article>\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot memory\"></span>Swap activity</p>\n          <div class=\"big\" id=\"swap-rate\"></div>\n          <p class=\"detail\" id=\"swap-rate-detail\"></p>\n          <p class=\"detail\">Current transfers, separate from swap already used</p>\n        </article>\n        <article class=\"card\">\n          <p class=\"card-label\"><span class=\"dot energy\"></span>Network \u00b7 physical interfaces</p>\n          <div class=\"big\" id=\"network-rate\"></div>\n          <p class=\"detail\" id=\"network-detail\"></p>\n          <p class=\"detail\" id=\"io-detail\"></p>\n        </article>\n      </section>\n      <section data-view=\"overview\" id=\"overview-view\">\n        <article class=\"focus\">\n          <div class=\"section-top\">\n            <h2>What to check first</h2>\n            <span class=\"small\">High usage can be expected during useful work</span>\n          </div>\n          <div id=\"health\" class=\"health\"></div>\n          <div class=\"focus-grid\" id=\"focus\"></div>\n        </article>\n        <div class=\"charts\">\n          <article class=\"card chart\">\n            <div class=\"section-top\">\n              <h2>CPU leaders</h2>\n              <button class=\"quiet\" data-jump-sort=\"cpu\">Explore CPU</button>\n            </div>\n            <p class=\"small\">Average CPU \u00b7 100% equals one core</p>\n            <div class=\"bars cpu\" id=\"cpu-chart\"></div>\n          </article>\n          <article class=\"card chart\">\n            <div class=\"section-top\">\n              <h2>Memory leaders</h2>\n              <button class=\"quiet\" data-jump-sort=\"memory\">Explore memory</button>\n            </div>\n            <p class=\"small\">Footprint includes compressed allocations</p>\n            <div class=\"bars memory\" id=\"memory-chart\"></div>\n          </article>\n          <article class=\"card chart\">\n            <div class=\"section-top\">\n              <h2>Power proxy leaders</h2>\n              <button class=\"quiet\" data-jump-sort=\"energy\">Explore power</button>\n            </div>\n            <p class=\"small\">Relative CPU + idle-wakeup score, not watts</p>\n            <div class=\"bars energy\" id=\"energy-chart\"></div>\n          </article>\n        </div>\n        <div class=\"two-col\">\n          <article class=\"card\">\n            <div class=\"section-top\">\n              <h2>Inside this sample</h2>\n              <span id=\"sample-quality\" class=\"small\"></span>\n            </div>\n            <div id=\"sample-chart\"></div>\n            <div class=\"key-stats\" id=\"sample-stats\"></div>\n          </article>\n          <article class=\"card\">\n            <h2>System context</h2>\n            <div id=\"system-context\" class=\"key-stats\"></div>\n            <details class=\"notes\">\n              <summary>Network and disk interface details</summary>\n              <div id=\"interface-details\"></div>\n            </details>\n          </article>\n        </div>\n      </section>\n      <section data-view=\"investigate\" id=\"investigate-view\" hidden>\n        <article class=\"list\">\n          <div class=\"list-head\">\n            <div class=\"section-top\">\n              <div>\n                <h2 id=\"list-title\">Apps &amp; services</h2>\n                <p class=\"small\">\n                  Inspect a row for trends, helper processes, and suggested next steps.\n                </p>\n              </div>\n              <span class=\"small\" id=\"count\"></span>\n            </div>\n            <div class=\"list-toolbar\">\n              <div class=\"tabs\" aria-label=\"Process scope\">\n                <button data-mode=\"all\" class=\"active\">Apps &amp; services</button\n                ><button data-mode=\"mine\">My apps</button\n                ><button data-mode=\"processes\">Processes</button>\n              </div>\n              <div class=\"filters\">\n                <label class=\"sr-only\" for=\"search\">Search app, service, path, or PID</label\n                ><input id=\"search\" placeholder=\"Search name, path, or PID\" /><label\n                  class=\"sr-only\"\n                  for=\"category\"\n                  >Category</label\n                ><select id=\"category\">\n                  <option value=\"all\">All categories</option>\n                  <option>Browser</option>\n                  <option>Communication</option>\n                  <option>Development</option>\n                  <option>Media</option>\n                  <option>Productivity</option>\n                  <option>System service</option>\n                  <option>Other app</option>\n                  <option>Background task</option></select\n                ><label class=\"sr-only\" for=\"sort\">Sort by</label\n                ><select id=\"sort\">\n                  <option value=\"priority\">Review priority</option>\n                  <option value=\"cpu\">Average CPU</option>\n                  <option value=\"peakCPU\">Peak CPU</option>\n                  <option value=\"memory\">Memory</option>\n                  <option value=\"memoryDelta\">Memory change vs baseline</option>\n                  <option value=\"energy\">Power proxy</option>\n                  <option value=\"wakeups\">Wakeups</option>\n                  <option value=\"threads\">Threads</option>\n                  <option value=\"sleep\">Sleep blockers</option>\n                </select>\n              </div>\n            </div>\n            <div class=\"filter-line\">\n              <label class=\"check\"><input type=\"checkbox\" id=\"flagged\" />Needs review</label\n              ><label class=\"check\"><input type=\"checkbox\" id=\"pinned-only\" />Pinned only</label\n              ><label class=\"check\"\n                ><input type=\"checkbox\" id=\"hide-system\" />Hide system services</label\n              ><label class=\"check\"\n                ><input type=\"checkbox\" id=\"hide-idle\" />Hide very light usage</label\n              ><button class=\"link-button\" id=\"reset-filters\">Reset filters</button\n              ><span class=\"small\" id=\"baseline-label\"></span>\n            </div>\n          </div>\n          <div class=\"table-scroll\">\n            <table>\n              <caption class=\"sr-only\">\n                Resource usage and recommendations\n              </caption>\n              <thead>\n                <tr>\n                  <th><span class=\"sr-only\">Pin</span></th>\n                  <th>App / service</th>\n                  <th><button data-sort=\"priority\">Priority</button></th>\n                  <th><button data-sort=\"cpu\">CPU average</button></th>\n                  <th><button data-sort=\"memory\">Memory</button></th>\n                  <th><button data-sort=\"memoryDelta\">Change</button></th>\n                  <th><button data-sort=\"energy\">Power proxy</button></th>\n                  <th><button data-sort=\"wakeups\">Wakeups / s</button></th>\n                  <th><button data-sort=\"threads\">Threads</button></th>\n                  <th><button data-sort=\"sleep\">Sleep</button></th>\n                  <th>Next step</th>\n                </tr>\n              </thead>\n              <tbody id=\"rows\"></tbody>\n            </table>\n          </div>\n          <div class=\"list-foot\">\n            <span class=\"small\" id=\"showing\" aria-live=\"polite\"></span\n            ><button class=\"quiet\" id=\"more\">Show 50 more</button>\n          </div>\n        </article>\n      </section>\n      <section data-view=\"history\" id=\"history-view\" hidden>\n        <article class=\"card\">\n          <div class=\"section-top\">\n            <div>\n              <h2>History &amp; changes</h2>\n              <p class=\"small\">\n                Each point is a scan. Watch mode adds new scans; reopening the script also builds\n                history.\n              </p>\n            </div>\n            <div class=\"filters\">\n              <label for=\"baseline\" class=\"small\">Compare with</label\n              ><select id=\"baseline\"></select\n              ><button class=\"quiet\" id=\"import-baseline\">Import another snapshot</button\n              ><input id=\"baseline-file\" type=\"file\" accept=\".json,application/json\" hidden />\n            </div>\n          </div>\n          <p id=\"comparison-note\" class=\"small\"></p>\n          <div class=\"two-col history-charts\">\n            <div>\n              <h3>Overall CPU</h3>\n              <div id=\"history-cpu\"></div>\n            </div>\n            <div>\n              <h3>Reported memory used</h3>\n              <div id=\"history-memory\"></div>\n            </div>\n          </div>\n          <div class=\"key-stats\" id=\"comparison-stats\"></div>\n        </article>\n        <div class=\"two-col\">\n          <article class=\"card\">\n            <h2>Largest increases in memory</h2>\n            <div id=\"memory-changes\" class=\"change-list\"></div>\n          </article>\n          <article class=\"card\">\n            <h2>Largest increases in CPU</h2>\n            <div id=\"cpu-changes\" class=\"change-list\"></div>\n          </article>\n        </div>\n        <article class=\"card\">\n          <div class=\"section-top\">\n            <h2>Saved scans</h2>\n            <button class=\"quiet\" id=\"export-history\">Export history</button>\n          </div>\n          <div class=\"table-scroll\">\n            <table class=\"compact\">\n              <thead>\n                <tr>\n                  <th>Captured</th>\n                  <th>CPU</th>\n                  <th>Memory used</th>\n                  <th>Pressure</th>\n                  <th>Swap used</th>\n                  <th>Sample</th>\n                  <th>Compare</th>\n                </tr>\n              </thead>\n              <tbody id=\"history-rows\"></tbody>\n            </table>\n          </div>\n        </article>\n      </section>\n      <section data-view=\"settings\" id=\"settings-view\" hidden>\n        <div class=\"two-col\">\n          <article class=\"card\">\n            <h2>Review thresholds</h2>\n            <p class=\"small\">\n              Choose what deserves attention. Badges and suggestions update immediately;\n              measurements stay the same.\n            </p>\n            <div class=\"setting-grid\">\n              <label\n                >CPU average (%)<input\n                  id=\"threshold-cpu\"\n                  type=\"number\"\n                  min=\"1\"\n                  max=\"10000\"\n                  step=\"1\" /></label\n              ><label\n                >Memory footprint (MiB)<input\n                  id=\"threshold-memory\"\n                  type=\"number\"\n                  min=\"1\"\n                  max=\"1048576\"\n                  step=\"1\" /></label\n              ><label\n                >Power proxy score<input\n                  id=\"threshold-energy\"\n                  type=\"number\"\n                  min=\"1\"\n                  max=\"10000\"\n                  step=\"1\" /></label\n              ><label\n                >Idle wakeups / second<input\n                  id=\"threshold-wakeups\"\n                  type=\"number\"\n                  min=\"1\"\n                  max=\"100000\"\n                  step=\"1\"\n              /></label>\n            </div>\n            <button class=\"button\" id=\"apply-thresholds\">Apply thresholds</button>\n            <button class=\"quiet\" id=\"reset-thresholds\">Use defaults</button>\n            <p class=\"small\" id=\"threshold-feedback\" role=\"status\"></p>\n          </article>\n          <article class=\"card\">\n            <h2>Appearance &amp; exports</h2>\n            <label class=\"setting\"\n              >Theme<select id=\"theme\">\n                <option value=\"system\">Match your Mac</option>\n                <option value=\"light\">Light</option>\n                <option value=\"dark\">Dark</option>\n              </select></label\n            >\n            <p class=\"small\">\n              Pins and preferences are saved in this browser when local storage is available.\n            </p>\n            <div class=\"button-row\">\n              <button class=\"button\" id=\"export-json\">Export full snapshot</button\n              ><button class=\"button\" id=\"print\">Print / save PDF</button>\n            </div>\n            <p class=\"small\">\n              Export this list respects filters, sort order, and your review thresholds. The full\n              snapshot preserves the collected data and the default analysis.\n            </p>\n          </article>\n        </div>\n        <article class=\"card guide\">\n          <h2>Measurements, actions &amp; limits</h2>\n          <details open>\n            <summary>CPU averages, peaks, and short bursts</summary>\n            <p>\n              The first reading is discarded because it has no prior interval. Averages use observed\n              intervals; peaks show the highest interval, not an instantaneous maximum. The overall\n              CPU card measures all logical cores on a 0\u2013100% scale. Each process uses 100% for one\n              core. A short burst can be useful work. A process seen only once may have no usable\n              CPU reading.\n            </p>\n          </details>\n          <details>\n            <summary>Memory footprint, RSS, and memory growth</summary>\n            <p>\n              Footprint is macOS\u2019s physical footprint, including compressed allocations. Resident\n              memory (RSS) is a different reading from ps, collected just after the sample; it\n              excludes compressed allocations and can count shared pages. App totals combine helpers\n              and are approximate. In-sample group trends cover helpers still present in the final\n              reading; exited helpers are outside these curves. Within-sample changes can reflect a\n              changing set of helpers; changes between scans compare groups by executable/app path\n              and user. Growth across a short sample does not prove a leak. Use memory pressure and\n              active swap transfers for context.\n            </p>\n          </details>\n          <details>\n            <summary>Power, sleep assertions, network, and disk</summary>\n            <p>\n              Power proxy is top\u2019s POWER score: CPU activity plus idle wakeups. It is not watts or\n              Activity Monitor Energy Impact and does not include GPU, disk, or networking energy.\n              Kernel wakeups remain visible for context but do not drive review priority. Sleep\n              assertions can be normal during calls, playback, backups, or an active display.\n              Network rates cover en interfaces and exclude loopback, VPN, and peer-to-peer\n              interfaces to reduce duplicate accounting. Disk counters are rounded iostat counters,\n              with reads and writes combined. Exposed devices can include disk images. These rates\n              are system/device measurements, not per-process I/O.\n            </p>\n          </details>\n          <details>\n            <summary>How priority works</summary>\n            <p>\n              The score is the highest of average CPU, footprint, power, and wakeups divided by\n              twice their configured review threshold. Add 0.25 for an idle-system-sleep blocker,\n              and 0.50 if memory pressure is elevated and footprint crosses the memory threshold. A\n              score of 1 or more is High. Other threshold crossings or CPU bursts are Review. These\n              are investigation hints. Custom thresholds are browser preferences; the saved snapshot\n              retains default analysis.\n            </p>\n          </details>\n          <details>\n            <summary>History, privacy, and scan controls</summary>\n            <p>\n              The script keeps the latest 40 group-level scans by default, in Mac Resource\n              History.json beside the dashboard. --history changes the limit to 1\u2013120. History\n              belongs to this report folder and is checked against RAM, CPU count, and user ID;\n              avoid mixing reports from different Macs. Process comparisons use paths and users, not\n              PIDs, because PIDs can be reused. Pins track owning apps; all same-app helpers may\n              share a pin in process view. A browser cannot start a native scanner from this offline\n              file: use the supplied launcher or copy a command from Scan options. Refreshing the\n              page alone does not collect data. Watch mode refreshes the page without resetting your\n              view, with pause controls and a visible scan age. No information is uploaded; raw\n              network addresses are omitted from exports. Process paths and assertion descriptions\n              are included, so review reports before sharing.\n            </p>\n          </details>\n          <p class=\"small\">\n            References:\n            <a\n              href=\"https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac\"\n              target=\"_blank\"\n              rel=\"noreferrer\"\n              >Apple: memory</a\n            >\n            \u00b7\n            <a\n              href=\"https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac\"\n              target=\"_blank\"\n              rel=\"noreferrer\"\n              >Apple: energy</a\n            >\n            \u00b7\n            <a\n              href=\"https://github.com/apple-oss-distributions/top/blob/main/power.c\"\n              target=\"_blank\"\n              rel=\"noreferrer\"\n              >Apple\u2019s power-score source</a\n            >.\n          </p>\n        </article>\n      </section>\n      <footer class=\"footer\">\n        <span>Read-only scan \u00b7 local files \u00b7 no extra installs</span\n        ><span id=\"system-version\"></span>\n      </footer>\n    </main>\n    <dialog id=\"inspect\" aria-labelledby=\"inspect-title\">\n      <div class=\"dialog-head\">\n        <div>\n          <p class=\"eyebrow\">Evidence &amp; next steps</p>\n          <h2 id=\"inspect-title\"></h2>\n        </div>\n        <button class=\"quiet\" data-close=\"inspect\">Close</button>\n      </div>\n      <div id=\"inspect-body\"></div>\n    </dialog>\n    <dialog id=\"rescan-dialog\" aria-labelledby=\"rescan-title\">\n      <div class=\"dialog-head\">\n        <h2 id=\"rescan-title\">Choose your next scan</h2>\n        <button class=\"quiet\" data-close=\"rescan-dialog\">Close</button>\n      </div>\n      <p>\n        Double-click Mac Resource Check.command for a detailed scan. It automatically opens the\n        completed dashboard. The optional Live Monitor launcher repeats scans until you press\n        Control-C in Terminal.\n      </p>\n      <div class=\"setting-grid\">\n        <label\n          >Sample duration<select id=\"scan-duration\">\n            <option value=\"4\">Quick \u00b7 4 seconds</option>\n            <option value=\"12\" selected>Balanced \u00b7 12 seconds</option>\n            <option value=\"30\">Deeper \u00b7 30 seconds</option>\n            <option value=\"60\">Extended \u00b7 60 seconds</option>\n          </select></label\n        ><label\n          >Repeat scans<select id=\"scan-repeat\">\n            <option value=\"0\">One snapshot</option>\n            <option value=\"30\">Every 30 seconds</option>\n            <option value=\"60\">Every 60 seconds</option>\n            <option value=\"120\">Every 2 minutes</option>\n          </select></label\n        ><label\n          >Open in<select id=\"scan-browser\">\n            <option value=\"default\">Default browser</option>\n            <option value=\"safari\">Safari</option>\n            <option value=\"chrome\">Chrome</option>\n            <option value=\"firefox\">Firefox</option>\n            <option value=\"edge\">Edge</option>\n            <option value=\"brave\">Brave</option>\n          </select></label\n        >\n      </div>\n      <p class=\"path command\" id=\"watch-command\"></p>\n      <button class=\"button primary\" id=\"copy-watch\">Copy scan command</button>\n      <p class=\"small\" id=\"scan-note\"></p>\n      <div class=\"button-row\">\n        <button class=\"quiet\" id=\"copy-open-dashboard\">Copy reopen-dashboard command</button\n        ><button class=\"quiet\" id=\"copy-output-folder\">Copy report-folder path</button>\n      </div>\n    </dialog>\n    <div id=\"toast\" class=\"toast\" role=\"status\" hidden></div>\n    <script id=\"resource-data\" type=\"application/json\">\n      __RESOURCE_DATA__\n    </script>\n    <script>\n      /* Shared by the collector and the dashboard, so custom thresholds use the same rules. */\nvar ResourceRules = (function () {\n  function defaults(ram) {\n    return { cpu: 25, memory: Math.max(1073741824, ram * 0.05), energy: 25, wakeups: 20 };\n  }\n  function category(row) {\n    var s = (row.name + ' ' + (row.path || '')).toLowerCase();\n    if (/chrome|safari|webkit|firefox|brave|vivaldi|edge|\\barc\\b|opera|orion/.test(s))\n      return 'Browser';\n    if (/zoom|teams|webex|discord|slack|messages|facetime/.test(s)) return 'Communication';\n    if (/xcode|swift|clang|node|python|docker|visual studio|code helper|terminal|iterm/.test(s))\n      return 'Development';\n    if (/photos|photoanalysis|music|spotify|vlc|quicktime|mediaanalysis/.test(s)) return 'Media';\n    if (/word|excel|powerpoint|pages|numbers|notes|notion/.test(s)) return 'Productivity';\n    return row.system ? 'System service' : row.appPath ? 'Other app' : 'Background task';\n  }\n  function evaluate(row, system, limits) {\n    limits = limits || defaults(system.memory);\n    var kernel = row.pid === 0 || (row.pids && row.pids.indexOf(0) >= 0);\n    var cpu = row.cpu || 0,\n      mem = row.memory || 0,\n      power = row.energy || 0,\n      wake = kernel ? 0 : row.wakeups || 0;\n    var flags = [],\n      reasons = [];\n    if (cpu >= limits.cpu) {\n      flags.push('CPU');\n      reasons.push('Average CPU is above your review threshold.');\n    }\n    if (mem >= limits.memory) {\n      flags.push('Memory');\n      reasons.push(\n        system.pressureValue > 1\n          ? 'Large footprint while macOS reports memory pressure.'\n          : 'Large allocation; normal pressure alone does not establish a shortage.'\n      );\n    }\n    if (power >= limits.energy || wake >= limits.wakeups) {\n      flags.push('Energy');\n      reasons.push('CPU activity or frequent idle wakeups may affect battery life.');\n    }\n    if (row.sleep) {\n      flags.push('Sleep');\n      reasons.push('An assertion prevents idle system sleep.');\n    }\n    var intervals = (row.series || []).filter(function (x) {\n      return typeof x.cpu === 'number' && isFinite(x.cpu);\n    });\n    var busy = intervals.length\n      ? intervals.filter(function (x) {\n          return x.cpu >= limits.cpu;\n        }).length / intervals.length\n      : row.busyFraction;\n    var pattern =\n      row.cpu === null\n        ? 'Not enough samples'\n        : cpu >= limits.cpu && intervals.length < 2\n          ? 'CPU active \u00b7 short sample'\n          : cpu >= limits.cpu && busy >= 0.5\n            ? 'Sustained CPU'\n            : row.peakCPU >= limits.cpu * 2 && cpu < limits.cpu\n              ? 'CPU burst'\n              : 'Steady / light';\n    if (pattern === 'CPU burst') {\n      flags.push('Burst');\n      reasons.push('A brief CPU peak was much higher than the average.');\n    }\n    var score =\n      Math.max(\n        cpu / (limits.cpu * 2),\n        mem / (limits.memory * 2),\n        power / (limits.energy * 2),\n        wake / (limits.wakeups * 2)\n      ) + (row.sleep ? 0.25 : 0);\n    if (system.pressureValue > 1 && mem >= limits.memory) score += 0.5;\n    var level = score >= 1 ? 'High' : flags.length ? 'Review' : 'Low';\n    var text = flags.length\n      ? 'Save your work, pause a heavy task, then recheck. Quit and reopen the app if its load stays high.'\n      : 'No large load observed. Keep it open if you are using it.';\n    var label = (row.name + ' ' + (row.path || '')).toLowerCase();\n    if (/windowserver/.test(label))\n      text =\n        'Reduce open windows and screen effects; stop unused screen sharing or recording. Recheck CPU.';\n    else if (/kernel_task/.test(label))\n      text =\n        'Check airflow and disconnect unused peripherals. Pause heavy work if the Mac is hot; do not quit this process.';\n    else if (/\\bmds\\b|mdworker|spotlight/.test(label))\n      text =\n        'Spotlight may be indexing after an update or file changes. Let it finish; recheck later if it stays busy.';\n    else if (/backupd|timemachine/.test(label))\n      text =\n        'Check Time Machine for an active backup. Let it finish, or pause it through Time Machine if needed.';\n    else if (/photoanalysis|photolibrary|mediaanalysis/.test(label))\n      text =\n        'Photos may be analyzing or syncing your library. Let it finish while plugged in; recheck if it remains busy.';\n    else if (/powerd/.test(label))\n      text =\n        'macOS may keep the Mac awake while the screen is on. Review other sleep blockers first.';\n    else if (/amphetamine|caffeinate|keepingyouawake/.test(label) && row.sleep)\n      text = 'End this app\u2019s keep-awake session when you want normal sleep.';\n    else if (\n      /chrome|safari|firefox|brave|vivaldi|microsoft edge|\\barc\\b|opera|orion/.test(label) &&\n      flags.length\n    )\n      text =\n        'Close unused tabs, pause video streams, and review extensions. Use the browser task manager, if available, to identify a busy tab.';\n    else if (/zoom|teams|webex|discord|slack/.test(label) && flags.length)\n      text =\n        'End unused calls or screen sharing; close extra workspaces. Save work before quitting and reopening the app.';\n    else if (\n      /xcode|swift|clang|node|python|docker|code helper|visual studio|terminal|iterm/.test(label) &&\n      flags.length\n    )\n      text =\n        'Check for a build, server, container, or background task. Stop an unused task in its owning app or Terminal.';\n    else if (row.system && flags.length)\n      text =\n        'Inspect this service in Activity Monitor. Scheduled work can be expected; recheck before taking action.';\n    else if (flags.length === 1 && flags[0] === 'Memory' && system.pressureValue === 1)\n      text =\n        'This app has a large allocation, while memory pressure is normal. Close unused documents or windows if needed, then compare another scan.';\n    else if (row.sleep && flags.length === 1)\n      text =\n        'Check for a call, download, playback, or sync. Stop that activity if you want the Mac to sleep.';\n    return {\n      flags: flags,\n      reasons: reasons,\n      pattern: pattern,\n      score: Math.round(score * 100),\n      level: level,\n      text: text\n    };\n  }\n  return { defaults: defaults, category: category, evaluate: evaluate };\n})();\n\n'use strict';\nconst DATA = JSON.parse(document.getElementById('resource-data').textContent),\n  $ = (id) => document.getElementById(id);\nconst esc = (x) =>\n  String(x == null ? '' : x).replace(\n    /[&<>\"']/g,\n    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\"': '&quot;', \"'\": '&#39;' })[c]\n  );\nconst size = (x) =>\n  x == null\n    ? 'Unavailable'\n    : Math.abs(x) >= 1073741824\n      ? (x / 1073741824).toFixed(2) + ' GiB'\n      : Math.abs(x) >= 1048576\n        ? (x / 1048576).toFixed(1) + ' MiB'\n        : Math.abs(x) >= 1024\n          ? (x / 1024).toFixed(0) + ' KiB'\n          : x.toFixed(0) + ' B';\nconst pct = (x) => (x == null ? '\u2014' : x.toFixed(1) + '%'),\n  num = (x) => (x == null ? '\u2014' : x.toFixed(1)),\n  rate = (x) => (x == null ? 'Unavailable' : size(x) + '/s');\nconst finite = (x) => typeof x === 'number' && Number.isFinite(x),\n  width = (x) => Math.min(100, Math.max(0, x || 0)).toFixed(1) + '%';\nconst signed = (x, format) => (x == null ? 'No baseline' : (x > 0 ? '+' : '') + format(x));\nconst when = (x) => new Date(x).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });\nconst duration = (x) =>\n  x == null\n    ? 'Unavailable'\n    : x >= 86400\n      ? (x / 86400).toFixed(1) + ' days'\n      : x >= 3600\n        ? (x / 3600).toFixed(1) + ' hours'\n        : x >= 60\n          ? Math.round(x / 60) + ' min'\n          : Math.round(x) + ' sec';\nconst shellQuote = (x) => \"'\" + String(x).replace(/'/g, \"'\\\\''\") + \"'\";\nconst limitsDefault = ResourceRules.defaults(DATA.system.memory);\nlet state = {\n  page: 'overview',\n  mode: 'all',\n  search: '',\n  sort: 'priority',\n  direction: -1,\n  category: 'all',\n  flagged: false,\n  pinnedOnly: false,\n  hideSystem: false,\n  hideIdle: false,\n  limit: 50,\n  paused: false,\n  baseline: 'auto'\n};\nlet prefs = { theme: 'system', limits: { ...limitsDefault }, pins: [] },\n  imported = null;\nfunction readStore(store, key) {\n  try {\n    return JSON.parse(store.getItem(key) || 'null');\n  } catch {\n    return null;\n  }\n}\nconst safeStorage = (name) => {\n  try {\n    return window[name];\n  } catch {\n    return null;\n  }\n};\nconst SESSION = safeStorage('sessionStorage'),\n  LOCAL = safeStorage('localStorage');\nObject.assign(state, readStore(SESSION, 'resource-check-view-v2') || {});\nObject.assign(prefs, readStore(LOCAL, 'resource-check-prefs-v2') || {});\nimported = readStore(SESSION, 'resource-check-import-v2');\nif (!['overview', 'investigate', 'history', 'settings'].includes(state.page))\n  state.page = 'overview';\nif (!['all', 'mine', 'processes'].includes(state.mode)) state.mode = 'all';\nif (\n  ![\n    'priority',\n    'cpu',\n    'peakCPU',\n    'memory',\n    'memoryDelta',\n    'energy',\n    'wakeups',\n    'threads',\n    'sleep'\n  ].includes(state.sort)\n)\n  state.sort = 'priority';\nif (!['light', 'dark', 'system'].includes(prefs.theme)) prefs.theme = 'system';\nif (!Array.isArray(prefs.pins)) prefs.pins = [];\nprefs.pins = prefs.pins.filter((x) => typeof x === 'string').slice(0, 200);\nif (\n  !prefs.limits ||\n  !Object.keys(limitsDefault).every((k) => finite(prefs.limits[k]) && prefs.limits[k] > 0)\n)\n  prefs.limits = { ...limitsDefault };\nstate.limit = Math.min(2000, Math.max(50, Number(state.limit) || 50));\nstate.direction = state.direction === 1 ? 1 : -1;\nlet visible = [],\n  chartRows = {},\n  detailRow = null,\n  toastTimer;\nfunction store() {\n  try {\n    SESSION.setItem('resource-check-view-v2', JSON.stringify(state));\n    LOCAL.setItem('resource-check-prefs-v2', JSON.stringify(prefs));\n  } catch {}\n}\nfunction toast(text) {\n  $('toast').textContent = text;\n  $('toast').hidden = false;\n  clearTimeout(toastTimer);\n  toastTimer = setTimeout(() => {\n    $('toast').hidden = true;\n  }, 2800);\n}\nasync function copy(text) {\n  try {\n    await navigator.clipboard.writeText(text);\n    toast('Copied');\n  } catch {\n    const box = document.createElement('textarea');\n    box.value = text;\n    box.style.position = 'fixed';\n    box.style.left = '-9999px';\n    document.body.append(box);\n    box.select();\n    const ok = document.execCommand('copy');\n    box.remove();\n    toast(ok ? 'Copied' : 'Select and copy the command manually');\n  }\n}\nfunction download(name, text, type) {\n  const url = URL.createObjectURL(new Blob([text], { type: type || 'text/plain;charset=utf-8' })),\n    a = document.createElement('a');\n  a.href = url;\n  a.download = name;\n  document.body.append(a);\n  a.click();\n  a.remove();\n  setTimeout(() => URL.revokeObjectURL(url), 1000);\n}\nfunction pinKey(r) {\n  return (r.appPath || r.path) + ':' + r.uid;\n}\nfunction pinned(r) {\n  return prefs.pins.includes(pinKey(r));\n}\nfunction togglePin(r) {\n  const key = pinKey(r);\n  prefs.pins = prefs.pins.includes(key)\n    ? prefs.pins.filter((x) => x !== key)\n    : prefs.pins.concat(key).slice(-200);\n  render();\n  toast(pinned(r) ? 'Pinned app' : 'Pin removed');\n}\nconst scans = Array.isArray(DATA.history) ? DATA.history : [];\nfunction baseline() {\n  if (state.baseline === 'imported' && imported) return imported;\n  if (state.baseline !== 'auto') {\n    const found = scans.find((x) => x.collectedAt === state.baseline);\n    if (found) return found;\n  }\n  return scans.filter((x) => x.collectedAt !== DATA.collectedAt).slice(-1)[0] || null;\n}\nfunction comparisonMap() {\n  const b = baseline();\n  return new Map(b ? b.apps.map((r) => [r.id, r]) : []);\n}\nfunction decorate(r) {\n  return { ...r, advice: ResourceRules.evaluate(r, DATA.system, prefs.limits) };\n}\nfunction baseRows() {\n  return (\n    state.mode === 'processes'\n      ? DATA.processes\n      : state.mode === 'mine'\n        ? DATA.apps.filter((r) => r.isMine && r.appPath)\n        : DATA.apps\n  ).map(decorate);\n}\nfunction metric(r, key, previous) {\n  if (key === 'priority') return r.advice.score;\n  if (key === 'sleep') return r.sleep === null ? -1 : Number(r.sleep);\n  if (key === 'memoryDelta') {\n    const change = memoryDelta(r, previous);\n    return change == null ? -Infinity : change;\n  }\n  return r[key] == null ? -Infinity : r[key];\n}\nfunction memoryDelta(r, previous) {\n  if (state.mode === 'processes') return r.memoryChange == null ? null : r.memoryChange;\n  const before = previous.get(r.id);\n  return before && finite(before.memory) && finite(r.memory) ? r.memory - before.memory : null;\n}\nfunction selectedRows() {\n  const q = state.search.toLowerCase().trim(),\n    before = comparisonMap();\n  return baseRows()\n    .filter(\n      (r) =>\n        (!state.flagged || r.advice.flags.length) &&\n        (!state.pinnedOnly || pinned(r)) &&\n        (!state.hideSystem || !r.system) &&\n        (!state.hideIdle || (r.cpu || 0) >= 1 || (r.memory || 0) >= 104857600 || r.sleep) &&\n        (state.category === 'all' || r.category === state.category) &&\n        (!q ||\n          (r.name + ' ' + (r.command || '') + ' ' + r.path + ' ' + (r.pids || [r.pid]).join(' '))\n            .toLowerCase()\n            .includes(q))\n    )\n    .sort((a, b) => {\n      const av = metric(a, state.sort, before),\n        bv = metric(b, state.sort, before);\n      return (av === bv ? 0 : state.direction * (av - bv)) || a.name.localeCompare(b.name);\n    });\n}\nfunction lineChart(points, field, color, format, xField = 'second', small = false) {\n  const valid = points.filter((p) => finite(p[field]) && finite(p[xField]));\n  if (!valid.length) return '<p class=\"small empty\">No measurements available yet.</p>';\n  const w = 600,\n    h = small ? 36 : 145,\n    left = small ? 0 : 62,\n    right = 10,\n    top = 12,\n    bottom = small ? 2 : 22,\n    vals = valid.map((p) => p[field]),\n    xs = valid.map((p) => p[xField]);\n  let lo = Math.min(...vals),\n    hi = Math.max(...vals),\n    xmin = Math.min(...xs),\n    xmax = Math.max(...xs);\n  if (lo === hi) {\n    lo = Math.max(0, lo - 1);\n    hi = hi + 1;\n  }\n  const x = (p) => left + ((p[xField] - xmin) / (xmax - xmin || 1)) * (w - left - right),\n    y = (p) => top + ((hi - p[field]) / (hi - lo)) * (h - top - bottom);\n  const path = valid\n    .map((p, i) => (i ? 'L' : 'M') + x(p).toFixed(2) + ',' + y(p).toFixed(2))\n    .join(' ');\n  let grid = small\n    ? ''\n    : [0, 0.5, 1]\n        .map((f) => {\n          const yy = top + f * (h - top - bottom);\n          return (\n            '<line x1=\"' +\n            left +\n            '\" x2=\"' +\n            (w - right) +\n            '\" y1=\"' +\n            yy +\n            '\" y2=\"' +\n            yy +\n            '\" stroke=\"var(--line)\"/><text x=\"' +\n            (left - 6) +\n            '\" y=\"' +\n            (yy + 3) +\n            '\" text-anchor=\"end\" font-size=\"9\" fill=\"var(--muted)\">' +\n            esc(format(hi - f * (hi - lo))) +\n            '</text>'\n          );\n        })\n        .join('');\n  return (\n    '<svg class=\"' +\n    (small ? '' : 'line-chart') +\n    '\" viewBox=\"0 0 ' +\n    w +\n    ' ' +\n    h +\n    '\" role=\"img\" aria-label=\"' +\n    esc(field + ' trend, ' + valid.length + ' measurements') +\n    '\"><title>' +\n    esc('Range ' + format(Math.min(...vals)) + ' to ' + format(Math.max(...vals))) +\n    '</title>' +\n    grid +\n    '<path d=\"' +\n    path +\n    '\" fill=\"none\" stroke=\"' +\n    color +\n    '\" stroke-width=\"' +\n    (small ? 3 : 2.5) +\n    '\" stroke-linecap=\"round\"/>' +\n    valid\n      .map(\n        (p) =>\n          '<circle cx=\"' +\n          x(p).toFixed(2) +\n          '\" cy=\"' +\n          y(p).toFixed(2) +\n          '\" r=\"' +\n          (small ? 0 : 3) +\n          '\" fill=\"' +\n          color +\n          '\"><title>' +\n          esc(format(p[field])) +\n          '</title></circle>'\n      )\n      .join('') +\n    '</svg>'\n  );\n}\nfunction keyStat(value, label) {\n  return (\n    '<div class=\"key-stat\"><strong>' + esc(value) + '</strong><span>' + esc(label) + '</span></div>'\n  );\n}\nfunction theme() {\n  const dark =\n    prefs.theme === 'dark' ||\n    (prefs.theme === 'system' &&\n      window.matchMedia &&\n      window.matchMedia('(prefers-color-scheme: dark)').matches);\n  document.documentElement.dataset.theme = dark ? 'dark' : 'light';\n  $('theme').value = prefs.theme;\n}\nfunction summary() {\n  if (DATA.demo) {\n    $('demo-note').hidden = false;\n    $('demo-note').textContent = 'Demo \u00b7 Synthetic sample data. This page does not scan your Mac.';\n  }\n  const s = DATA.system;\n  $('timestamp').textContent =\n    when(DATA.collectedAt) +\n    ' \u00b7 ' +\n    DATA.sampleSeconds +\n    's sample \u00b7 ' +\n    DATA.processes.length +\n    ' processes';\n  $('cpu-total').textContent = pct(s.cpu);\n  const cpuPoints = (DATA.systemSeries || []).map((p) => p.cpu).filter(finite);\n  $('cpu-detail').textContent =\n    DATA.cores + ' logical cores \u00b7 peak ' + pct(cpuPoints.length ? Math.max(...cpuPoints) : null);\n  $('cpu-spark').innerHTML = lineChart(\n    DATA.systemSeries || [],\n    'cpu',\n    'var(--cpu)',\n    pct,\n    'second',\n    true\n  );\n  $('pressure').textContent = s.pressure;\n  $('pressure').style.color =\n    s.pressure === 'Critical'\n      ? 'var(--red)'\n      : s.pressure === 'Elevated'\n        ? 'var(--cpu)'\n        : 'var(--ink)';\n  $('memory-detail').textContent = size(s.memoryUsed) + ' / ' + size(s.memory) + ' reported used';\n  $('swap-detail').textContent = 'Swap used ' + size(s.swap);\n  $('battery').textContent =\n    s.battery.percent === null ? s.battery.source : s.battery.percent + '% battery';\n  $('power-detail').textContent = s.battery.source + ' \u00b7 ' + s.battery.status;\n  const blockers = DATA.apps.filter((r) => r.sleep).length,\n    thermal = ['normal', 'fair', 'serious', 'critical'][s.thermal] || 'unavailable';\n  $('sleep-detail').textContent =\n    (DATA.sleepAvailable\n      ? blockers + ' idle-sleep blocker' + (blockers === 1 ? '' : 's')\n      : 'Sleep data unavailable') +\n    ' \u00b7 thermal ' +\n    thermal;\n  $('disk-free').textContent = s.disk ? size(s.disk.available) : 'Unavailable';\n  $('disk-detail').textContent = s.disk\n    ? s.disk.percent + '% used \u00b7 ' + size(s.disk.total) + ' capacity'\n    : 'Startup volume unavailable';\n  $('disk-track').style.width = width(s.disk ? s.disk.percent : 0);\n  $('swap-rate').textContent = s.swapActivity\n    ? rate(s.swapActivity.inBytes + s.swapActivity.outBytes)\n    : 'Unavailable';\n  $('swap-rate-detail').textContent = s.swapActivity\n    ? 'In ' + rate(s.swapActivity.inBytes) + ' \u00b7 out ' + rate(s.swapActivity.outBytes)\n    : 'Swap transfers could not be sampled';\n  const net = s.network,\n    down = net ? net.reduce((n, r) => n + r.inBytes, 0) : null,\n    up = net ? net.reduce((n, r) => n + r.outBytes, 0) : null;\n  $('network-rate').textContent = rate(down);\n  $('network-detail').textContent = net\n    ? 'Download \u00b7 upload ' + rate(up)\n    : 'Interface counters unavailable';\n  const drive =\n    s.diskActivity && (s.diskActivity.find((d) => d.name === 'disk0') || s.diskActivity[0]);\n  $('io-detail').textContent = drive\n    ? drive.name + ' I/O ' + drive.megabytes.toFixed(2) + ' MB/s \u00b7 read + write'\n    : 'Disk activity unavailable';\n  $('system-version').textContent = DATA.osVersion + ' \u00b7 uptime ' + duration(s.uptime);\n  $('scan-count').textContent = scans.length + ' saved scan' + (scans.length === 1 ? '' : 's');\n  $('warnings').innerHTML = DATA.warnings.length\n    ? '<div class=\"warning\">' + DATA.warnings.map(esc).join('<br>') + '</div>'\n    : '';\n  $('sample-quality').textContent = DATA.sampleCount + ' usable intervals';\n  $('sample-chart').innerHTML = lineChart(DATA.systemSeries || [], 'cpu', 'var(--cpu)', pct);\n  $('sample-stats').innerHTML =\n    keyStat(DATA.sampleSeconds + ' sec', 'Observation window') +\n    keyStat(DATA.processes.length, 'Processes in final sample') +\n    keyStat(DATA.collectorExcluded, 'Collector processes excluded') +\n    keyStat(\n      DATA.processes.filter((p) => p.observedSamples === DATA.sampleCount).length,\n      'Processes observed across all intervals'\n    );\n  $('system-context').innerHTML =\n    keyStat(size(s.wired), 'Wired memory') +\n    keyStat(size(s.compressed), 'Compressed memory') +\n    keyStat(s.battery.remaining || 'Unavailable', 'Battery estimate reported by macOS') +\n    keyStat(duration(s.uptime), 'Time since startup');\n  $('interface-details').innerHTML =\n    '<p class=\"small\">Rates over about ' +\n    (s.ioSampleSeconds || DATA.sampleSeconds) +\n    ' seconds. Device counters can be rounded.</p>' +\n    (net || [])\n      .map(\n        (n) =>\n          '<p class=\"small\">' +\n          esc(n.name) +\n          ': down ' +\n          rate(n.inBytes) +\n          ', up ' +\n          rate(n.outBytes) +\n          '</p>'\n      )\n      .join('') +\n    (s.diskActivity || [])\n      .map(\n        (d) =>\n          '<p class=\"small\">' +\n          esc(d.name) +\n          ': ' +\n          d.megabytes.toFixed(2) +\n          ' MB/s \u00b7 ' +\n          d.transfers.toFixed(1) +\n          ' transfers/s</p>'\n      )\n      .join('');\n  if (DATA.watch) {\n    $('live').innerHTML = '<button class=\"quiet\" id=\"pause\"></button>';\n    $('pause').onclick = () => {\n      state.paused = !state.paused;\n      store();\n      freshness();\n    };\n  }\n  freshness();\n}\nfunction freshness() {\n  if (DATA.demo) {\n    $('freshness').textContent = 'Sample dashboard \u00b7 explore filters, history, and process details';\n    return;\n  }\n  const age = Math.max(0, (Date.now() - Date.parse(DATA.collectedAt)) / 1000),\n    stale = DATA.watch && age > Math.max(90, DATA.watch * 3);\n  $('freshness').classList.toggle('stale', !!stale);\n  $('freshness').textContent = stale\n    ? 'No recent scan \u00b7 last capture ' + duration(age) + ' ago. The scanner may be stopped.'\n    : DATA.watch\n      ? 'Repeated scans every ' +\n        DATA.watch +\n        ' seconds \u00b7 last capture ' +\n        duration(age) +\n        ' ago' +\n        (state.paused ? ' \u00b7 page updates paused' : ' \u00b7 page refreshes while collection runs')\n      : 'Saved snapshot \u00b7 captured ' +\n        duration(age) +\n        ' ago. Run the script again to collect new data.';\n  if ($('pause'))\n    $('pause').textContent = state.paused ? 'Resume page updates' : 'Pause page updates';\n}\nfunction showPage(page) {\n  state.page = page;\n  document.querySelectorAll('[data-view]').forEach((el) => (el.hidden = el.dataset.view !== page));\n  document.querySelectorAll('[data-page]').forEach((b) => {\n    b.classList.toggle('active', b.dataset.page === page);\n    b.setAttribute('aria-current', b.dataset.page === page ? 'page' : 'false');\n  });\n  store();\n}\nfunction chart(field, id, format, rows) {\n  const top = rows\n      .filter((r) => r[field] != null && r[field] > 0)\n      .slice()\n      .sort((a, b) => b[field] - a[field])\n      .slice(0, 6),\n    max = top.length ? top[0][field] : 1;\n  chartRows[id] = top;\n  $(id).innerHTML = top.length\n    ? top\n        .map(\n          (r, i) =>\n            '<button class=\"bar-row\" data-chart=\"' +\n            id +\n            '\" data-index=\"' +\n            i +\n            '\"><span class=\"bar-caption\"><span class=\"name\" title=\"' +\n            esc(r.name) +\n            '\">' +\n            esc(r.name) +\n            '</span><span class=\"value\">' +\n            format(r[field]) +\n            '</span></span><span class=\"bar-track\" style=\"display:block\" aria-hidden=\"true\"><span class=\"bar-fill\" style=\"display:block;width:' +\n            width((r[field] / max) * 100) +\n            '\"></span></span></button>'\n        )\n        .join('')\n    : '<p class=\"small empty\">No measured activity in this view.</p>';\n}\nfunction meter(value, max, format) {\n  return (\n    '<span class=\"value\">' +\n    format(value) +\n    '</span><div class=\"mini\" aria-hidden=\"true\"><span style=\"width:' +\n    width((value / max) * 100) +\n    '\"></span></div>'\n  );\n}\nfunction renderOverview() {\n  const s = DATA.system;\n  let text =\n    s.pressureValue > 1\n      ? 'macOS reports ' +\n        s.pressure.toLowerCase() +\n        ' memory pressure. Review large allocations and active swap transfers.'\n      : s.cpu >= 80\n        ? 'CPU activity is high across the Mac. Review sustained users and check whether they are doing expected work.'\n        : 'Memory pressure is ' +\n          s.pressure.toLowerCase() +\n          ' and total CPU is ' +\n          pct(s.cpu) +\n          '. Review the candidates below in the context of what you are doing.';\n  if (s.thermal >= 2)\n    text +=\n      ' Thermal pressure is ' +\n      ['normal', 'fair', 'serious', 'critical'][s.thermal] +\n      '. Pause heavy work and check airflow.';\n  if (s.disk && s.disk.available / s.disk.total < 0.1)\n    text += ' The startup volume has less than 10% available space.';\n  $('health').textContent = text;\n  const flagged = visible\n    .filter((r) => r.advice.flags.length)\n    .sort(\n      (a, b) =>\n        Number(b.isMine && !!b.appPath) - Number(a.isMine && !!a.appPath) ||\n        b.advice.score - a.advice.score\n    )\n    .slice(0, 3);\n  $('focus').innerHTML = flagged.length\n    ? flagged\n        .map(\n          (r) =>\n            '<article class=\"focus-item\"><div class=\"focus-name\">' +\n            esc(r.name) +\n            ' <span class=\"status ' +\n            r.advice.level.toLowerCase() +\n            '\">' +\n            r.advice.level +\n            '</span></div><p class=\"focus-copy\">' +\n            esc(r.advice.text) +\n            '</p><p class=\"focus-metrics\">' +\n            pct(r.cpu) +\n            ' CPU \u00b7 ' +\n            size(r.memory) +\n            ' \u00b7 ' +\n            esc(r.advice.pattern) +\n            '</p><button class=\"quiet\" data-focus=\"' +\n            esc(r.id) +\n            '\">Inspect evidence</button></article>'\n        )\n        .join('')\n    : '<p class=\"small\">No large loads in the current filter. Scan while a slowdown is happening to catch intermittent activity.</p>';\n  chart('cpu', 'cpu-chart', pct, visible);\n  chart('memory', 'memory-chart', size, visible);\n  chart('energy', 'energy-chart', num, visible);\n}\nfunction renderList() {\n  const subset = visible.slice(0, state.limit),\n    before = comparisonMap(),\n    b = baseline();\n  $('list-title').textContent =\n    state.mode === 'mine'\n      ? 'My apps'\n      : state.mode === 'processes'\n        ? 'Individual processes'\n        : 'Apps & services';\n  $('count').textContent = visible.length + ' results';\n  $('showing').textContent =\n    'Showing ' + subset.length + ' of ' + visible.length + ' \u00b7 averages and peaks cover the sample';\n  $('more').hidden = subset.length >= visible.length;\n  $('search').value = state.search;\n  $('sort').value = state.sort;\n  $('category').value = state.category;\n  $('flagged').checked = state.flagged;\n  $('pinned-only').checked = state.pinnedOnly;\n  $('hide-system').checked = state.hideSystem;\n  $('hide-idle').checked = state.hideIdle;\n  $('baseline-label').textContent =\n    state.mode === 'processes'\n      ? 'Change = within this sample'\n      : b\n        ? 'Change vs ' + when(b.collectedAt)\n        : 'Run another scan to compare changes';\n  document.querySelectorAll('[data-mode]').forEach((el) => {\n    el.classList.toggle('active', el.dataset.mode === state.mode);\n    el.setAttribute('aria-pressed', String(el.dataset.mode === state.mode));\n  });\n  const labels = {\n    priority: 'Priority',\n    cpu: 'CPU average',\n    memory: 'Memory',\n    memoryDelta: state.mode === 'processes' ? '\u0394 sample' : '\u0394 baseline',\n    energy: 'Power proxy',\n    wakeups: 'Wakeups / s',\n    threads: 'Threads',\n    sleep: 'Sleep'\n  };\n  document.querySelectorAll('[data-sort]').forEach((el) => {\n    const active = el.dataset.sort === state.sort;\n    el.classList.toggle('active', active);\n    el.textContent = labels[el.dataset.sort] + (active ? (state.direction < 0 ? ' \u2193' : ' \u2191') : '');\n    el.parentElement.setAttribute(\n      'aria-sort',\n      active ? (state.direction < 0 ? 'descending' : 'ascending') : 'none'\n    );\n  });\n  const scale = {\n    cpu: Math.max(100, ...visible.map((r) => r.cpu || 0)),\n    energy: Math.max(50, ...visible.map((r) => r.energy || 0))\n  };\n  $('rows').innerHTML = subset.length\n    ? subset\n        .map((r, i) => {\n          const delta = memoryDelta(r, before);\n          return (\n            '<tr><td><button class=\"pin ' +\n            (pinned(r) ? 'active' : '') +\n            '\" data-pin=\"' +\n            i +\n            '\" aria-pressed=\"' +\n            pinned(r) +\n            '\" aria-label=\"' +\n            esc((pinned(r) ? 'Unpin ' : 'Pin ') + r.name) +\n            '\">' +\n            (pinned(r) ? '\u2605' : '\u2606') +\n            '</button></td><td class=\"app-cell\"><div class=\"app-name\">' +\n            esc(state.mode === 'processes' ? r.command : r.name) +\n            '</div><div class=\"app-meta\">' +\n            esc(r.category) +\n            ' \u00b7 ' +\n            (r.pids ? r.pids.length + ' processes' : 'PID ' + r.pid) +\n            '</div><div class=\"app-meta\">' +\n            esc(r.advice.pattern) +\n            '</div></td><td><span class=\"status ' +\n            r.advice.level.toLowerCase() +\n            '\">' +\n            r.advice.level +\n            '</span><div class=\"app-meta\">' +\n            esc(r.advice.flags.join(' \u00b7 ') || 'Light load') +\n            '</div></td><td class=\"metric cpu\">' +\n            meter(r.cpu, scale.cpu, pct) +\n            '<div class=\"app-meta\">Peak ' +\n            pct(r.peakCPU) +\n            '</div></td><td class=\"metric memory\">' +\n            meter(r.memory, DATA.system.memory, size) +\n            '<div class=\"app-meta\">' +\n            (r.memory == null\n              ? ''\n              : ((r.memory / DATA.system.memory) * 100).toFixed(1) + '% of RAM') +\n            '</div></td><td><span class=\"delta ' +\n            (delta > 0 ? 'up' : delta < 0 ? 'down' : '') +\n            '\">' +\n            signed(delta, size) +\n            '</span><div class=\"app-meta\">Sample ' +\n            signed(r.memoryChange == null ? null : r.memoryChange, size) +\n            '</div></td><td class=\"metric energy\">' +\n            meter(r.energy, scale.energy, num) +\n            '</td><td class=\"value\">' +\n            num(r.wakeups) +\n            '</td><td class=\"value\">' +\n            r.threads +\n            '</td><td>' +\n            (r.sleep === null\n              ? '<span class=\"small\">Unavailable</span>'\n              : r.sleep\n                ? '<span class=\"status review\">System</span>'\n                : r.displaySleep\n                  ? '<span class=\"status review\">Display</span>'\n                  : '<span class=\"small\">\u2014</span>') +\n            '</td><td class=\"action-cell\">' +\n            esc(r.advice.text) +\n            '<br><button class=\"quiet\" data-inspect=\"' +\n            i +\n            '\">Inspect details</button></td></tr>'\n          );\n        })\n        .join('')\n    : '<tr><td colspan=\"11\" class=\"empty\">No matches. Try another search or reset the filters.</td></tr>';\n}\nfunction historyPoints() {\n  return scans.map((s) => ({\n    time: Date.parse(s.collectedAt),\n    cpu: s.system.cpu,\n    memoryUsed: s.system.memoryUsed\n  }));\n}\nfunction renderHistory() {\n  const b = baseline(),\n    previous = comparisonMap(),\n    currentIDs = new Set(DATA.apps.map((a) => a.id));\n  $('baseline').innerHTML =\n    '<option value=\"auto\">Previous scan (automatic)</option>' +\n    scans\n      .filter((s) => s.collectedAt !== DATA.collectedAt)\n      .slice()\n      .reverse()\n      .map(\n        (s) =>\n          '<option value=\"' + esc(s.collectedAt) + '\">' + esc(when(s.collectedAt)) + '</option>'\n      )\n      .join('') +\n    (imported\n      ? '<option value=\"imported\">Imported \u00b7 ' + esc(when(imported.collectedAt)) + '</option>'\n      : '');\n  $('baseline').value = state.baseline;\n  $('comparison-note').textContent = b\n    ? 'Baseline captured ' +\n      when(b.collectedAt) +\n      ' \u00b7 compare app groups by path and user, with memory changes interpreted alongside pressure.'\n    : 'No baseline yet. Run the script again, use Live Monitor, or import a Mac Resource Data.json snapshot.';\n  const points = historyPoints();\n  $('history-cpu').innerHTML = lineChart(points, 'cpu', 'var(--cpu)', pct, 'time');\n  $('history-memory').innerHTML = lineChart(points, 'memoryUsed', 'var(--memory)', size, 'time');\n  const caption = scans.length\n    ? '<div class=\"chart-caption\"><span>' +\n      esc(when(scans[0].collectedAt)) +\n      '</span><span>' +\n      esc(when(scans[scans.length - 1].collectedAt)) +\n      '</span></div>'\n    : '';\n  $('history-cpu').innerHTML += caption;\n  $('history-memory').innerHTML += caption;\n  if (b) {\n    const newCount = DATA.apps.filter((r) => !previous.has(r.id)).length,\n      ended = b.apps.filter((r) => !currentIDs.has(r.id)).length;\n    $('comparison-stats').innerHTML =\n      keyStat(\n        signed(\n          DATA.system.cpu == null || b.system.cpu == null ? null : DATA.system.cpu - b.system.cpu,\n          pct\n        ),\n        'CPU change (percentage points)'\n      ) +\n      keyStat(\n        signed(\n          DATA.system.memoryUsed == null || b.system.memoryUsed == null\n            ? null\n            : DATA.system.memoryUsed - b.system.memoryUsed,\n          size\n        ),\n        'Reported system memory change'\n      ) +\n      keyStat(newCount, 'Newly observed groups') +\n      keyStat(ended, 'Groups no longer observed');\n  } else $('comparison-stats').innerHTML = '';\n  function changes(field, id, format) {\n    const changed = DATA.apps\n      .map((r) => {\n        const old = previous.get(r.id);\n        return {\n          r,\n          delta: old && finite(old[field]) && finite(r[field]) ? r[field] - old[field] : null\n        };\n      })\n      .filter((x) => x.delta > 0)\n      .sort((a, b) => b.delta - a.delta)\n      .slice(0, 8);\n    $(id).innerHTML = changed.length\n      ? changed\n          .map(\n            (x) =>\n              '<div class=\"change-row\"><button data-history-app=\"' +\n              esc(x.r.id) +\n              '\">' +\n              esc(x.r.name) +\n              '</button><strong class=\"delta up\">' +\n              signed(x.delta, format) +\n              '</strong></div>'\n          )\n          .join('')\n      : '<p class=\"small empty\">' +\n        (b ? 'No measured increases among matched groups.' : 'Take another scan to see changes.') +\n        '</p>';\n  }\n  changes('memory', 'memory-changes', size);\n  changes('cpu', 'cpu-changes', pct);\n  $('history-rows').innerHTML = scans\n    .slice()\n    .reverse()\n    .map(\n      (s) =>\n        '<tr><td>' +\n        esc(when(s.collectedAt)) +\n        (s.collectedAt === DATA.collectedAt ? ' \u00b7 current' : '') +\n        '</td><td>' +\n        pct(s.system.cpu) +\n        '</td><td>' +\n        size(s.system.memoryUsed) +\n        '</td><td>' +\n        esc(s.system.pressure) +\n        '</td><td>' +\n        size(s.system.swap) +\n        '</td><td>' +\n        s.sampleSeconds +\n        's</td><td>' +\n        (s.collectedAt === DATA.collectedAt\n          ? '\u2014'\n          : '<button class=\"quiet\" data-baseline=\"' +\n            esc(s.collectedAt) +\n            '\">Use baseline</button>') +\n        '</td></tr>'\n    )\n    .join('');\n}\nfunction render() {\n  visible = selectedRows();\n  renderList();\n  renderOverview();\n  renderHistory();\n  showPage(state.page);\n  store();\n}\nfunction stateLabel(p) {\n  return p.state\n    ? { R: 'Running', S: 'Sleeping', I: 'Idle', T: 'Stopped', Z: 'Zombie', U: 'Waiting' }[\n        p.state[0]\n      ] || p.state\n    : 'Unavailable';\n}\nfunction treeRows(ps) {\n  const map = new Map(ps.map((p) => [p.pid, p])),\n    out = [],\n    seen = new Set();\n  function visit(p, depth) {\n    if (seen.has(p.pid)) return;\n    seen.add(p.pid);\n    out.push({ p, depth });\n    ps.filter((x) => x.ppid === p.pid && x.pid !== p.pid)\n      .sort((a, b) => (b.memory || 0) - (a.memory || 0))\n      .forEach((x) => visit(x, Math.min(8, depth + 1)));\n  }\n  ps.filter((p) => !map.has(p.ppid) || p.ppid === p.pid)\n    .sort((a, b) => (b.memory || 0) - (a.memory || 0))\n    .forEach((p) => visit(p, 0));\n  ps.forEach((p) => visit(p, 0));\n  return out;\n}\nfunction openDialog(el) {\n  if (typeof el.showModal === 'function') el.showModal();\n  else {\n    el.dataset.fallback = 'true';\n    el.setAttribute('open', '');\n  }\n}\nfunction closeDialog(el) {\n  if (typeof el.close === 'function') el.close();\n  else el.removeAttribute('open');\n}\nfunction inspect(original) {\n  const row = decorate(original);\n  detailRow = row;\n  const ps = (row.processes || [row]).map(decorate),\n    before = comparisonMap().get(row.id),\n    rss = ps.some((p) => finite(p.residentMemory))\n      ? ps.reduce((n, p) => n + (p.residentMemory || 0), 0)\n      : null,\n    delta =\n      before && finite(before.memory) && finite(row.memory) ? row.memory - before.memory : null;\n  $('inspect-title').textContent = row.name;\n  $('inspect-body').innerHTML =\n    '<p class=\"path\">' +\n    esc(row.appPath || row.path) +\n    '</p><div class=\"evidence\"><strong>' +\n    esc(row.advice.pattern) +\n    ' \u00b7 ' +\n    esc(row.advice.level) +\n    ' review priority</strong><ul>' +\n    (row.advice.reasons.length\n      ? row.advice.reasons.map((r) => '<li>' + esc(r) + '</li>').join('')\n      : '<li>No configured review threshold was crossed.</li>') +\n    '</ul><p>' +\n    esc(row.advice.text) +\n    '</p></div><div class=\"key-stats\">' +\n    keyStat(\n      pct(row.cpu),\n      'Average CPU \u00b7 ' +\n        (row.cpu == null\n          ? 'unavailable'\n          : (row.cpu / DATA.cores).toFixed(1) + '% of total CPU capacity')\n    ) +\n    keyStat(pct(row.peakCPU), 'Highest observed CPU interval') +\n    keyStat(size(row.memory), 'Current physical footprint') +\n    keyStat(size(rss), 'Resident memory (RSS), collected after sample') +\n    keyStat(\n      signed(row.memoryChange == null ? null : row.memoryChange, size),\n      'Footprint change during sample'\n    ) +\n    keyStat(\n      row.pids ? signed(delta, size) : row.elapsed || 'Unavailable',\n      row.pids ? 'Footprint change vs baseline' : 'Process elapsed time'\n    ) +\n    '</div><div class=\"two-col history-charts\"><div><h3>CPU during sample</h3>' +\n    lineChart(row.series || [], 'cpu', 'var(--cpu)', pct) +\n    '</div><div><h3>Memory during sample</h3>' +\n    lineChart(row.series || [], 'memory', 'var(--memory)', size) +\n    '</div></div><p class=\"small\">' +\n    (row.observedSamples || 0) +\n    ' of ' +\n    DATA.sampleCount +\n    ' usable CPU intervals. Helpers are grouped where paths or parent relationships identify an owner. Group growth can reflect a changing set of helpers.</p><div class=\"step\"><strong>1. Verify the current activity</strong><p class=\"small\">Open Activity Monitor, choose View \u2192 All Processes, then search the app name or a PID below. Check CPU, Memory, Energy, Disk, or Network.</p><button class=\"quiet\" id=\"copy-open\">Copy Activity Monitor command</button> <button class=\"quiet\" id=\"copy-name\">Copy app name</button> <button class=\"quiet\" id=\"pin-detail\">' +\n    (pinned(row) ? 'Unpin app' : 'Pin app') +\n    '</button></div><div class=\"step\"><strong>2. Make a small change and compare</strong><p class=\"small\">Save your work. Pause an unused task or close unused tabs/documents. Run another scan and use History & changes to see whether usage fell. Avoid quitting unfamiliar system services.</p></div><div class=\"process-detail\"><h3>Process tree &amp; sleep assertions</h3><div class=\"table-scroll\"><table><thead><tr><th>PID / executable / parent</th><th>CPU avg / peak</th><th>Footprint</th><th>State / elapsed</th><th>Threads / nice</th><th>Sleep assertion</th></tr></thead><tbody>' +\n    treeRows(ps)\n      .map(\n        ({ p, depth }) =>\n          '<tr><td><span class=\"tree-indent\" style=\"--indent:' +\n          depth * 12 +\n          'px\"></span><strong>' +\n          p.pid +\n          ' \u00b7 ' +\n          esc(p.command) +\n          '</strong><div class=\"app-meta\">Parent ' +\n          p.ppid +\n          ' \u00b7 UID ' +\n          p.uid +\n          '</div><div class=\"path\">' +\n          esc(p.path) +\n          '</div></td><td>' +\n          pct(p.cpu) +\n          '<div class=\"app-meta\">Peak ' +\n          pct(p.peakCPU) +\n          '</div></td><td>' +\n          size(p.memory) +\n          '<div class=\"app-meta\">RSS ' +\n          size(p.residentMemory == null ? null : p.residentMemory) +\n          '</div></td><td>' +\n          esc(stateLabel(p)) +\n          '<div class=\"app-meta\">' +\n          esc(p.elapsed || 'Unavailable') +\n          '</div></td><td>' +\n          p.threads +\n          '<div class=\"app-meta\">Nice ' +\n          (p.nice == null ? '\u2014' : p.nice) +\n          '</div></td><td>' +\n          esc(\n            DATA.sleepAvailable\n              ? (p.assertions || [])\n                  .map((a) => a.type + ': ' + a.name + (a.duration ? ' (' + a.duration + ')' : ''))\n                  .join('; ') || '\u2014'\n              : 'Unavailable'\n          ) +\n          '</td></tr>'\n      )\n      .join('') +\n    '</tbody></table></div><p class=\"small\">PIDs identify this snapshot and may be reused later. Sleep assertions are not proof of a fault.</p><button class=\"quiet\" id=\"copy-pids\">Copy PIDs</button> <button class=\"quiet\" id=\"export-detail\">Export these processes</button></div>';\n  $('copy-open').onclick = () => copy(\"open -a 'Activity Monitor'\");\n  $('copy-name').onclick = () => copy(row.name);\n  $('copy-pids').onclick = () => copy(ps.map((p) => p.pid).join(', '));\n  $('pin-detail').onclick = () => {\n    togglePin(row);\n    $('pin-detail').textContent = pinned(row) ? 'Unpin app' : 'Pin app';\n  };\n  $('export-detail').onclick = () => exportCSV(ps, 'Mac Resource Processes.csv', true);\n  if (!$('inspect').open) openDialog($('inspect'));\n}\nfunction csvCell(v) {\n  if (v == null) return '\"\"';\n  let s = String(v);\n  if (typeof v === 'string' && /^\\s*[=+\\-@]/.test(s)) s = \"'\" + s;\n  return '\"' + s.replace(/\"/g, '\"\"') + '\"';\n}\nfunction exportCSV(rows, name, processes = false) {\n  const before = comparisonMap(),\n    head = [\n      'App / process',\n      'PIDs',\n      'Category',\n      'CPU average %',\n      'CPU peak %',\n      'Footprint bytes',\n      'Within-sample footprint change bytes',\n      'Baseline footprint change bytes',\n      'Power proxy',\n      'Wakeups per second',\n      'Threads',\n      'System sleep blocker',\n      'Review level',\n      'CPU pattern',\n      'Suggestion'\n    ],\n    body = rows.map((r) => {\n      const old = before.get(r.id);\n      return [\n        processes ? r.command : r.name,\n        (r.pids || [r.pid]).join(' '),\n        r.category,\n        r.cpu,\n        r.peakCPU,\n        r.memory,\n        r.memoryChange,\n        old && finite(old.memory) && finite(r.memory) ? r.memory - old.memory : null,\n        r.energy,\n        r.wakeups,\n        r.threads,\n        r.sleep,\n        r.advice.level,\n        r.advice.pattern,\n        r.advice.text\n      ];\n    });\n  download(\n    name,\n    '\\ufeff' + [head, ...body].map((row) => row.map(csvCell).join(',')).join('\\r\\n') + '\\r\\n',\n    'text/csv;charset=utf-8'\n  );\n  toast('Exported ' + rows.length + ' rows');\n}\nfunction thresholds() {\n  for (const [k, v] of Object.entries(prefs.limits))\n    $('threshold-' + k).value = k === 'memory' ? Math.round(v / 1048576) : v;\n}\nfunction command() {\n  let seconds = Number($('scan-duration').value),\n    repeat = Number($('scan-repeat').value),\n    browser = $('scan-browser').value;\n  if (repeat && repeat < seconds + 4) {\n    repeat = seconds + 4 <= 60 ? 60 : 120;\n    $('scan-repeat').value = String(repeat);\n  }\n  const launcher = DATA.launcherPath || './Mac Resource Check.command',\n    folder = DATA.outputDir || launcher.slice(0, launcher.lastIndexOf('/')) + '/Reports';\n  const cmd =\n    'bash ' +\n    shellQuote(launcher) +\n    ' --seconds ' +\n    seconds +\n    (repeat ? ' --watch ' + repeat : '') +\n    ' --output ' +\n    shellQuote(folder) +\n    (browser !== 'default' ? ' --browser ' + browser : '');\n  $('watch-command').textContent = cmd;\n  if (DATA.demo) {\n    $('scan-note').textContent =\n      'Demo only. Download the launcher, then run it to collect a report from your Mac.';\n    return cmd;\n  }\n  $('scan-note').textContent = repeat\n    ? 'Run in Terminal; the dashboard opens automatically and updates while scanning. Press Control-C in Terminal to stop.'\n    : 'Run in Terminal for one scan. The completed dashboard opens automatically. Browser refresh alone does not collect data.';\n  return cmd;\n}\nasync function importBaseline(file) {\n  if (!file) return;\n  if (file.size > 50 * 1024 * 1024) {\n    toast('Snapshot is too large; use a file below 50 MB.');\n    return;\n  }\n  try {\n    const input = JSON.parse(await file.text());\n    if (\n      !input.system ||\n      !Array.isArray(input.apps) ||\n      !finite(input.system.memory) ||\n      !['cpu', 'memoryUsed', 'swap'].every(\n        (k) => input.system[k] === null || finite(input.system[k])\n      ) ||\n      !Number.isFinite(Date.parse(input.collectedAt)) ||\n      !input.apps.every(\n        (a) =>\n          a &&\n          typeof a.id === 'string' &&\n          typeof a.name === 'string' &&\n          ['cpu', 'memory'].every((k) => a[k] === null || finite(a[k]))\n      )\n    )\n      throw new Error('format');\n    if (\n      input.system.memory !== DATA.system.memory ||\n      (input.cores && input.cores !== DATA.cores) ||\n      (input.currentUID && DATA.currentUID && input.currentUID !== DATA.currentUID)\n    ) {\n      toast('This snapshot has a different hardware or user profile.');\n      return;\n    }\n    imported = {\n      collectedAt: input.collectedAt,\n      system: input.system,\n      apps: input.apps.map((r) => ({\n        id: r.id,\n        name: r.name,\n        cpu: r.cpu,\n        memory: r.memory,\n        energy: r.energy,\n        wakeups: r.wakeups,\n        sleep: r.sleep\n      }))\n    };\n    try {\n      SESSION.setItem('resource-check-import-v2', JSON.stringify(imported));\n    } catch {}\n    state.baseline = 'imported';\n    state.page = 'history';\n    render();\n    toast('Baseline imported locally');\n  } catch {\n    toast('Choose a valid Mac Resource Data.json snapshot.');\n  }\n}\nfunction resetFilters() {\n  Object.assign(state, {\n    search: '',\n    category: 'all',\n    flagged: false,\n    pinnedOnly: false,\n    hideSystem: false,\n    hideIdle: false,\n    limit: 50\n  });\n  render();\n}\nfunction bind() {\n  document\n    .querySelectorAll('[data-page]')\n    .forEach((b) => (b.onclick = () => showPage(b.dataset.page)));\n  document.querySelectorAll('[data-mode]').forEach(\n    (b) =>\n      (b.onclick = () => {\n        state.mode = b.dataset.mode;\n        state.limit = 50;\n        render();\n      })\n  );\n  document.querySelectorAll('[data-sort]').forEach(\n    (b) =>\n      (b.onclick = () => {\n        state.direction = state.sort === b.dataset.sort ? -state.direction : -1;\n        state.sort = b.dataset.sort;\n        render();\n      })\n  );\n  document.querySelectorAll('[data-jump-sort]').forEach(\n    (b) =>\n      (b.onclick = () => {\n        state.sort = b.dataset.jumpSort;\n        state.direction = -1;\n        state.page = 'investigate';\n        render();\n      })\n  );\n  $('search').addEventListener('input', (e) => {\n    state.search = e.target.value;\n    state.limit = 50;\n    render();\n  });\n  $('sort').onchange = (e) => {\n    state.sort = e.target.value;\n    state.direction = -1;\n    state.limit = 50;\n    render();\n  };\n  $('category').onchange = (e) => {\n    state.category = e.target.value;\n    state.limit = 50;\n    render();\n  };\n  for (const [id, key] of [\n    ['flagged', 'flagged'],\n    ['pinned-only', 'pinnedOnly'],\n    ['hide-system', 'hideSystem'],\n    ['hide-idle', 'hideIdle']\n  ])\n    $(id).onchange = (e) => {\n      state[key] = e.target.checked;\n      state.limit = 50;\n      render();\n    };\n  $('more').onclick = () => {\n    state.limit += 50;\n    render();\n  };\n  $('reset-filters').onclick = resetFilters;\n  $('rows').addEventListener('click', (e) => {\n    const pin = e.target.closest('[data-pin]'),\n      detail = e.target.closest('[data-inspect]');\n    if (pin) togglePin(visible[Number(pin.dataset.pin)]);\n    if (detail) inspect(visible[Number(detail.dataset.inspect)]);\n  });\n  document.addEventListener('click', (e) => {\n    const chart = e.target.closest('[data-chart]'),\n      focus = e.target.closest('[data-focus]'),\n      base = e.target.closest('[data-baseline]'),\n      change = e.target.closest('[data-history-app]');\n    if (chart) inspect(chartRows[chart.dataset.chart][Number(chart.dataset.index)]);\n    if (focus) {\n      const r = visible.find((r) => r.id === focus.dataset.focus);\n      if (r) inspect(r);\n    }\n    if (base) {\n      state.baseline = base.dataset.baseline;\n      render();\n    }\n    if (change) {\n      const r = DATA.apps.find((r) => r.id === change.dataset.historyApp);\n      if (r) inspect(r);\n    }\n  });\n  $('baseline').onchange = (e) => {\n    state.baseline = e.target.value;\n    render();\n  };\n  $('import-baseline').onclick = () => $('baseline-file').click();\n  $('baseline-file').onchange = (e) => importBaseline(e.target.files[0]);\n  $('export-list').onclick = () =>\n    exportCSV(visible, 'Mac Resource Filtered List.csv', state.mode === 'processes');\n  $('export-json').onclick = () =>\n    download(\n      'Mac Resource Data.json',\n      JSON.stringify({ ...DATA, viewerPreferences: prefs }, null, 2),\n      'application/json'\n    );\n  $('export-history').onclick = () =>\n    download(\n      'Mac Resource History.json',\n      JSON.stringify({ version: 2, scans }, null, 2),\n      'application/json'\n    );\n  $('print').onclick = () => window.print();\n  $('apply-thresholds').onclick = () => {\n    const next = {};\n    for (const k of Object.keys(limitsDefault)) {\n      const value = Number($('threshold-' + k).value);\n      if (!finite(value) || value < 1 || value > Number($('threshold-' + k).max || 1000000)) {\n        $('threshold-feedback').textContent =\n          'Enter a positive value within the range shown for each threshold.';\n        return;\n      }\n      next[k] = k === 'memory' ? value * 1048576 : value;\n    }\n    prefs.limits = next;\n    $('threshold-feedback').textContent =\n      'Applied. Review badges, filters, and exports now use these thresholds.';\n    render();\n  };\n  $('reset-thresholds').onclick = () => {\n    prefs.limits = { ...limitsDefault };\n    thresholds();\n    $('threshold-feedback').textContent = 'Default thresholds restored.';\n    render();\n  };\n  $('theme').onchange = (e) => {\n    prefs.theme = e.target.value;\n    theme();\n    store();\n  };\n  $('rescan').onclick = () => {\n    command();\n    openDialog($('rescan-dialog'));\n  };\n  ['scan-duration', 'scan-repeat', 'scan-browser'].forEach((id) => ($(id).onchange = command));\n  $('copy-watch').onclick = () => copy(command());\n  $('copy-open-dashboard').onclick = () =>\n    copy(\n      'bash ' +\n        shellQuote(DATA.launcherPath) +\n        ' --open-only --output ' +\n        shellQuote(DATA.outputDir || '.')\n    );\n  $('copy-output-folder').onclick = () => copy(DATA.outputDir || '.');\n  document\n    .querySelectorAll('[data-close]')\n    .forEach((b) => (b.onclick = () => closeDialog($(b.dataset.close))));\n}\nsummary();\ntheme();\nthresholds();\nbind();\nrender();\n\nif (window.matchMedia) {\n  const m = window.matchMedia('(prefers-color-scheme: dark)');\n  if (m.addEventListener) m.addEventListener('change', theme);\n}\nsetInterval(freshness, 10000);\nif (DATA.watch && !DATA.demo)\n  setInterval(() => {\n    if (\n      !state.paused &&\n      !document.querySelector('dialog[open]') &&\n      !['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement.tagName)\n    ) {\n      store();\n      location.reload();\n    }\n  }, 10000);\n;\n    </script>\n  </body>\n</html>\n";
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

RESOURCE_CHECK_JXA

optional_read() {
    local label="$1" destination="$2"
    shift 2
    if ! "$@" > "$destination" 2> "$temp_dir/optional-error.txt"; then
        : > "$destination"
        printf '%s unavailable; the rest of the report is still usable.\n' "$label" >> "$temp_dir/warnings.txt"
    fi
}

launch_dashboard() {
    [[ -s "$report_file" ]] || fail 'No dashboard exists yet. Run a normal scan first.'
    local browser_bundle="" browser_path=""
    case "$browser" in
        safari) browser_bundle=com.apple.Safari ;;
        chrome) browser_bundle=com.google.Chrome ;;
        firefox) browser_bundle=org.mozilla.firefox ;;
        edge) browser_bundle=com.microsoft.edgemac ;;
        brave) browser_bundle=com.brave.Browser ;;
        default)
            # Resolve the HTTPS handler to avoid an HTML association that opens an editor.
            browser_path="$(/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); var u=$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL($.NSURL.URLWithString("https://example.invalid")); u ? ObjC.unwrap(u.path) : ""' 2>/dev/null || true)"
            ;;
    esac
    printf 'Opening your dashboard in a web browser…\n'
    if [[ -n "$browser_bundle" ]] && /usr/bin/open -b "$browser_bundle" "$report_file"; then return; fi
    if [[ -n "$browser_path" && -d "$browser_path" ]] && /usr/bin/open -a "$browser_path" "$report_file"; then return; fi
    if /usr/bin/open -b com.apple.Safari "$report_file"; then return; fi
    printf 'Automatic browser launch failed. Your dashboard is saved at:\n%s\nTry --browser chrome or open the HTML file in a browser.\n' "$report_file" >&2
}

if (( open_only )); then launch_dashboard; exit 0; fi

# Keep one open descriptor for the report folder. BSD file locks attach to that
# descriptor, survive the lock helper's exit, and release when this shell exits.
# Keep the empty file in place so concurrent collectors always lock the same inode.
lock_file="$output_dir/.mac-resource-check.lock"
exec 9>"$lock_file"
/usr/bin/lockf -s -t 0 9 || fail 'Another scan is already using this report folder, or locking is unavailable. Stop it, or choose a different --output folder.'

printf 'Mac Resource Check\nSampling for about %s seconds. Use your Mac normally during the scan.\n' "$effective_seconds"
if (( watch_seconds )); then printf 'Repeating every %s seconds. Press Control-C to stop.\n' "$watch_seconds"; fi
while :; do
    started_at="$(/bin/date +%s)"
    : > "$temp_dir/warnings.txt"
    optional_read 'Initial virtual memory statistics' "$temp_dir/vmBefore.txt" /usr/bin/vm_stat
    optional_read 'Initial network counters' "$temp_dir/networkBefore.txt" /usr/sbin/netstat -ibn
    optional_read 'Initial disk counters' "$temp_dir/ioBefore.txt" /usr/sbin/iostat -d -I -n 64 -c 1
    counter_started="$(/bin/date +%s)"
    # COMMAND is last to preserve spaces in names. -F/-R reduce collection overhead.
    # -c n preserves absolute memory and wakeup counters; CPU/POWER remain interval based.
    if ! /usr/bin/top -l "$samples" -s 2 -n 99999 -o pid -F -R -c n \
        -stats pid,ppid,uid,cpu,mem,threads,idlew,power,command > "$temp_dir/top.txt" 2> "$temp_dir/top-error.txt"; then
        if ! /usr/bin/top -l "$samples" -s 2 -n 99999 -o pid -F -R -c n \
            -stats pid,ppid,uid,cpu,mem,threads,command > "$temp_dir/top.txt" 2> "$temp_dir/top-error.txt"; then
            /bin/cat "$temp_dir/top-error.txt" >&2
            fail 'macOS process collection failed. Run this .command file in Terminal outside an app sandbox.'
        fi
        printf 'Power and wakeup columns were not supported on this macOS version.\n' >> "$temp_dir/warnings.txt"
    fi
    # comm is the executable name/path, not the full arguments (which can contain secrets).
    optional_read 'Process paths' "$temp_dir/ps.txt" /bin/ps -ww -axo pid=,ppid=,uid=,rss=,etime=,state=,nice=,comm=
    optional_read 'Memory pressure' "$temp_dir/pressure.txt" /usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level
    optional_read 'Swap usage' "$temp_dir/swap.txt" /usr/sbin/sysctl vm.swapusage
    optional_read 'Virtual memory statistics' "$temp_dir/vm.txt" /usr/bin/vm_stat
    optional_read 'Network counters' "$temp_dir/networkAfter.txt" /usr/sbin/netstat -ibn
    optional_read 'Disk counters' "$temp_dir/ioAfter.txt" /usr/sbin/iostat -d -I -n 64 -c 1
    printf '%s\n' "$(( $(/bin/date +%s) - counter_started ))" > "$temp_dir/counterSeconds.txt"
    optional_read 'System uptime' "$temp_dir/boot.txt" /usr/sbin/sysctl -n kern.boottime
    optional_read 'Sleep assertions' "$temp_dir/assertions.txt" /usr/bin/pmset -g assertions
    optional_read 'Battery status' "$temp_dir/battery.txt" /usr/bin/pmset -g batt
    disk_path=/
    [[ -d /System/Volumes/Data ]] && disk_path=/System/Volumes/Data
    optional_read 'Startup disk space' "$temp_dir/disk.txt" /bin/df -k "$disk_path"
    /usr/bin/osascript -l JavaScript "$temp_dir/renderer.js" "$temp_dir" "$output_dir" \
        "$collector_pid" "$collector_uid" "$watch_seconds" "$launcher_path" "$history_limit"
    if (( open_report )); then
        launch_dashboard
        open_report=0
    fi
    (( watch_seconds )) || break
    now="$(/bin/date +%s)"
    delay=$((watch_seconds - (now - started_at)))
    (( delay > 0 )) || delay=1
    /bin/sleep "$delay" &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=""
done
printf 'Done. Double-click this script again to take another snapshot.\n'
