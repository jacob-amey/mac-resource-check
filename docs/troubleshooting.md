# Troubleshooting

## The launcher opens in an editor or macOS blocks it

Open Terminal, type `bash ` with a trailing space, drag **Mac Resource Check.command** into the window, and press Return. This runs the script through the shell and does not require changing macOS security settings. If macOS still blocks a quarantined download, use its normal **Privacy & Security → Open Anyway** flow after reviewing the source. Release ZIPs preserve executable permissions.

Keep **Live Monitor.command** beside **Mac Resource Check.command**. Put the folder somewhere you can write reports.

## The dashboard did not open

The report is still saved in **Reports**. Open **Mac Resource Report.html** in Safari or Chrome, or specify a browser:

```bash
bash "Mac Resource Check.command" --open-only --browser safari
```

If an explicit browser is unavailable, the launcher tries Safari. An app sandbox may block browser discovery or opening. Run the launcher from the normal Terminal app.

## Process collection failed or a metric is unavailable

Run from Terminal outside an app sandbox. The scanner does not need Full Disk Access or an administrator password. Unavailable optional counters leave the remaining report usable. Include the macOS version, hardware architecture, launcher flags, and exact error in a bug report; do not attach an unredacted personal snapshot.

## Another scan is using the report folder

Stop the existing live monitor with Control-C, or choose another `--output` folder. Concurrent collectors are blocked to preserve the journal. macOS releases the file lock when the collector exits. The empty **.mac-resource-check.lock** file stays in place and does not indicate that a scan is active. Do not remove it while a scanner is running. Use local storage; network-share behavior has not been tested.

## The report is old or watch mode stopped

The age indicator reflects the saved scan. Refreshing the HTML does not collect data. Keep the Terminal monitor running and use **Resume page updates** if paused. Collection stops when its process stops; the dashboard remains readable.

## Pins or preferences disappear

Some browsers restrict storage for local HTML files. Controls still work, but their settings may last only for the current page session. The public demo can be served through GitHub Pages. Real scans remain local files.

## An imported baseline is rejected

Import a complete **Mac Resource Data.json** snapshot below 50 MB. RAM, core count, and user profile must match when supplied. These checks do not uniquely identify a Mac; do not combine reports from different machines merely because their profiles match.

## History was backed up

Malformed entries or an incompatible profile are preserved in a history backup file before the journal is repaired or restarted. Keep the backup if investigating a problem. History retention defaults to 40 scans and can be changed with `--history`.
