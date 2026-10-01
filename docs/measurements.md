# Measurements and limits

## CPU and sampling

The default scan contains seven `top` readings spaced about two seconds apart. The first has no prior interval and is discarded, leaving six usable CPU intervals. A process appearing partway through a scan needs a consecutive prior reading before its CPU counts. Only processes present in the final reading appear in the report.

Average CPU is the arithmetic mean of valid observed intervals. Peak CPU is the highest valid interval. Process CPU uses 100% for one logical core; overall CPU uses 0–100% across all cores. Interval timing can vary on a busy Mac. Brief peaks may be missed, and a high average can be useful work.

Wakeup rates use counter differences divided by elapsed time. Missing or decreasing counters are unavailable. POWER is `top`'s relative CPU-and-wakeup score. It excludes GPU, disk, and networking energy and is neither watts nor Activity Monitor's complete Energy Impact. Kernel POWER is unavailable; combined kernel wakeups are shown for context and excluded from review scoring.

## Memory

`top` reports physical footprint, including compressed allocations. `ps` reports RSS after the sample. RSS is different: it excludes compressed allocations and can include shared resident pages. Grouped totals are approximate and should not be added together to explain all RAM.

System totals from `top` are rounded. Memory pressure comes from macOS and is a better signal of shortage than an app's allocation alone. Swap space in use can reflect earlier work; active swap measures bytes transferred during this counter window using `vm_stat` page sizes and swap counters.

Within-sample group graphs include helpers surviving in the final sample. Exited helpers are outside those graphs. Changed helper sets can affect memory deltas. Between-scan comparisons match group paths and user IDs, rather than PIDs. Growth in a short sample does not establish a leak.

## Groups and process metadata

The outer `.app` path identifies an application. Helpers outside that path can inherit an owning app through a same-user parent chain, bounded to 20 steps. Processes that cannot be associated are grouped by executable path and user. Grouping can be incomplete when paths are unavailable or a parent has exited.

PIDs describe one captured moment and may be reused. Metadata from `ps` is collected after `top` and can change between reads. Elapsed time, state, scheduling priority, and sleep assertions are context, not proof of a problem.

## System context and I/O

Sleep assertions reported by `pmset` may be expected during a call, playback, backup, download, or active display. Thermal state is macOS's pressure classification rather than a temperature sensor. Battery estimates and startup-volume availability are reported by macOS.

Network byte rates use only link-layer rows for `en` interfaces. Address rows, loopback, VPN, bridge, and peer-to-peer interfaces are omitted to reduce duplicate accounting. An unusual interface configuration may be outside that scope.

Disk I/O uses differences in rounded cumulative `iostat` device counters. Reads and writes are combined. The summary prefers `disk0`, and detail lists the exposed devices, which may include disk images. Counter windows are approximate. Rates describe devices/interfaces, not per-process activity or energy.

## Review priority

Default thresholds are CPU 25%, memory the larger of 1 GiB or 5% of RAM, power 25, and wakeups 20/s. A CPU peak at twice the threshold can be flagged as a burst.

```text
score = max(CPU / (2 × CPU threshold),
            footprint / (2 × memory threshold),
            POWER / (2 × power threshold),
            wakeups / (2 × wakeup threshold))

score += 0.25 for a system-sleep blocker
score += 0.50 for a large footprint under elevated memory pressure
```

A score of at least 1 is High. Other threshold crossings or bursts are Review; remaining rows are Low. Scores are displayed after multiplying by 100 and rounding. Custom thresholds recalculate browser views and filtered exports; original saved analysis stays at the defaults. These flags suggest what to inspect, not what to terminate.

## Sources

- [Apple: memory usage and memory pressure](https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac)
- [Apple: energy consumption](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac)
- [Apple's POWER implementation](https://github.com/apple-oss-distributions/top/blob/main/power.c)
- The installed macOS manuals for `top`, `ps`, `vm_stat`, `pmset`, `netstat`, `iostat`, `df`, and `lockf`
