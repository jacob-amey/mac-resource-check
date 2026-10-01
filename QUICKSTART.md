# Mac Resource Check

Double-click **Mac Resource Check.command** to take a roughly 12-second scan. It opens the completed dashboard in your default browser, with Safari as a fallback. Reports are saved in **Reports** beside the script. macOS is required; no extra installs or administrator password are needed.

If double-clicking opens an editor, open Terminal, type `bash ` with the space, drag the launcher into the window, and press Return. See [troubleshooting](docs/troubleshooting.md) for macOS download restrictions and other issues.

Double-click **Live Monitor.command** to sample every 30 seconds. Keep the two launchers together. Press **Control-C in Terminal** to stop. Closing the dashboard or pausing its updates does not stop collection.

## Dashboard controls

- **Overview:** System context, leading apps, and suggested next steps.
- **Apps & processes:** Search, sort, filter, pin, and inspect app groups or individual processes.
- **History & changes:** Compare earlier scans or import a saved JSON baseline.
- **Preferences & guide:** Adjust thresholds, choose a theme, export data, or print to PDF.

Scan options builds a copyable Terminal command. Refreshing the browser alone does not collect new measurements.

## Optional commands

Run from the launcher folder:

```bash
bash "Mac Resource Check.command" --quick
bash "Mac Resource Check.command" --seconds 30 --watch 60
bash "Mac Resource Check.command" --browser chrome
bash "Mac Resource Check.command" --history 80
bash "Mac Resource Check.command" --no-open
bash "Mac Resource Check.command" --open-only
bash "Mac Resource Check.command" --help
```

High usage can be normal. The scanner reads statistics and writes local reports; it does not quit apps or change settings. Power is a relative CPU-and-wakeup score rather than watts. Footprint and RSS are different memory measures. See [measurement details](docs/measurements.md).

Reports may contain executable paths and sleep assertion descriptions. Review their contents before sharing. No data is uploaded. Live collection has been checked on macOS 27 on Apple silicon; other intended macOS 12+/Intel combinations remain to be verified.

Licensed under [MIT](LICENSE).
