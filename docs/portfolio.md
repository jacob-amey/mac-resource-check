# Portfolio copy

## Short description

Mac Resource Check is a local macOS diagnostics tool that turns native process statistics into an offline dashboard. It groups app helpers, highlights resource-heavy activity, and compares scans so users can see whether a small change reduced CPU or memory use.

## Project summary

Mac Resource Check makes a useful resource report available from a single launcher. A short scan opens a self-contained HTML dashboard with CPU averages and peaks, memory pressure, power proxies, sleep blockers, and system I/O. Users can filter or pin apps, inspect helper processes, adjust review thresholds, and export results.

The project separates native collection from pure parsing, shared review rules, and the browser interface. Source files build into a standalone script that needs no runtime installation. A bounded journal supports comparisons across scans, while synthetic fixtures make the public demo and tests safe to share.

The main engineering tradeoffs are measurement quality and distribution simplicity. Initial CPU readings are discarded, missing counters remain unavailable, and advice distinguishes a large allocation from actual memory pressure. Release archives use an explicit file allowlist and checksums. Tests cover parsers, dashboard behavior, native rendering, collector locking, and history repair; manual browser and broader hardware checks remain documented work.

## Technical details

- **Stack:** Bash, JavaScript for Automation, Foundation/AppKit, vanilla JavaScript, CSS, SVG, Python build tools
- **Runtime dependencies:** Native macOS tools only
- **Development:** Node.js, Python, Prettier, GitHub Actions
- **Focus:** Process attribution, interval sampling, offline interaction, report privacy, reproducible packaging

## Useful discussion points

- How a same-user parent chain associates helper processes with an app.
- Why process CPU and whole-machine CPU use different percentage scales.
- Why memory pressure matters more than a large allocation alone.
- How a static browser report can refresh saved scans without executing native commands.
- Why public demos and test fixtures use generated data rather than real diagnostics.

Add the repository and public demo links after publishing. Keep claims tied to checks actually performed; do not present intended compatibility as a verified hardware matrix.
