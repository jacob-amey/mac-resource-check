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
      version: '__VERSION__',
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
