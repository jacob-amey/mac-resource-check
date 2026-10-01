# Contributing

Use Node.js 22+ and Python 3.9+. `npm ci` installs the development-only formatter. End users do not need these tools.

```bash
npm ci
npm run format
npm run demo
npm run check
```

Edit `src/` rather than the generated `.command` files. Update tests for measurement or behavior changes. Use synthetic process data; do not commit personal reports, command arguments, or copied system diagnostics. `npm run demo` regenerates the public fixture through the real parsers and rebuilds generated files.

Before opening a pull request, explain the user-visible problem, what changed, and how you checked it. Mention any macOS versions or hardware you tested. Parser and dashboard tests run on Linux and macOS; native launcher tests are skipped on other platforms.

Manual browser checks are still needed for layout, keyboard focus, downloads, and local-file behavior. Do not describe isolated document-model checks as end-to-end browser tests. Keep compatibility claims tied to actual verification.

Change `VERSION` and `package.json` together for a release, update the changelog, add release notes, and follow [publishing](docs/publishing.md). Releases keep a small explicit file allowlist; report files must never be added to it.
