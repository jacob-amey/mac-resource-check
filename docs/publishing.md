# Publishing to GitHub

## Repository details

- **Name:** `mac-resource-check`
- **Description:** Local macOS resource scanner with an offline dashboard, process inspection, and scan history.
- **Topics:** `macos`, `system-monitor`, `performance`, `bash`, `javascript`, `dashboard`, `developer-tools`
- **License:** MIT

The repository includes maintainable source, generated launchers, a synthetic demo, tests, documentation, and GitHub workflows. Real report data is excluded. The release ZIP is a separate download for people who only want to use the scanner.

## First upload

Open Terminal in this project's folder. Review what Git will include, then create the first commit using your configured Git identity:

```bash
git init -b main
git add .
git diff --cached --stat
git commit -m "Prepare Mac Resource Check 2.1.0"
```

With an authenticated GitHub CLI, create and push a public repository:

```bash
gh repo create mac-resource-check --public --source=. --remote=origin --push \
  --description "Local macOS resource scanner with an offline dashboard, process inspection, and scan history."
```

Alternatively, create an **empty** GitHub repository called `mac-resource-check`. Do not initialize it with a README or license, since these files are already included. Copy the remote URL shown by GitHub:

```bash
git remote add origin YOUR_REPOSITORY_URL
git push -u origin main
```

Run these commands inside this project's isolated repository, not from a parent folder containing unrelated files. Add the suggested topics through the repository's About settings. Enable private vulnerability reporting under Security if you want to receive reports through that route.

## Demo and portfolio

Under **Settings → Pages**, choose **Deploy from a branch**, select `main`, and select `/docs`. GitHub will provide a public demo URL once deployment finishes. Add that URL to the repository's Website field. The page is a synthetic-data demo; it never collects visitor system statistics.

The README illustration is labeled as an interface overview, not a screenshot. Before replacing it with a real screenshot, capture the synthetic demo and check that no personal report data or account details are visible. The ready-to-use project summary is in [portfolio](portfolio.md).

## Release checklist

- Run `npm ci`, `npm run demo`, and `npm run check`.
- Open the synthetic demo in Safari and Chrome. Check narrow/wide layouts, keyboard navigation, dialogs, imports, downloads, and print output. This manual browser check has not yet been performed in this workspace.
- Run a normal scan in macOS Terminal and confirm automatic browser opening. Browser routing is covered by tests that mock the opener.
- Run a live monitor, wait for two scans, and stop it with Control-C.
- Verify compatibility on any additional macOS/hardware combinations you intend to claim.
- Run `npm run release`. Check the ZIP contents and checksum.
- Update `VERSION`, `package.json`, `CHANGELOG.md`, and `docs/releases/VERSION.md` together when making another release.

## Create the release

After CI and the manual checks pass, tag the release:

```bash
git tag v2.1.0
git push origin v2.1.0
```

The tag workflow reruns checks, builds the archive, and creates a **draft** GitHub release with the ZIP, checksum, and versioned release notes. Review the draft in GitHub and click Publish when ready. The workflow does not publish releases automatically.

For a manual release, upload the files from `artifacts/` through GitHub's release editor and copy the matching notes from `docs/releases/`. Do not upload the local `Reports` folder.

GitHub Actions are pinned to reviewed commit SHAs, use restricted permissions, and do not run fork code under privileged pull-request triggers. Dependabot is configured for formatter and action updates. See [GitHub's secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use).
