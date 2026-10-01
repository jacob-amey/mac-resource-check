"""Native launcher/renderer tests: synthetic input, no browser launch."""
import csv
import json
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Mac Resource Check.command"


class ArgumentTests(unittest.TestCase):
    def test_version_and_help(self):
        version = (ROOT / "VERSION").read_text().strip()
        for flag, expected in [("--version", version), ("--help", "--history")]:
            result = subprocess.run(["bash", str(LAUNCHER), flag], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, result.stdout)

    def test_invalid_arguments(self):
        for args in [["--browser", "unknown"], ["--history", "0"], ["--seconds", "121"], ["--watch", "99999"], ["--seconds"], ["--output", ""]]:
            with self.subTest(args=args):
                result = subprocess.run(["bash", str(LAUNCHER), *args], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Error:", result.stderr)


@unittest.skipUnless(platform.system() == "Darwin", "JXA and locking require macOS")
class NativeTests(unittest.TestCase):
    def setUp(self):
        parent = ROOT / ".test-output"
        parent.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="launcher-", dir=parent)
        self.folder = Path(self.temp.name)
        self.reports = self.folder / "Reports"
        self.log = self.folder / "open.log"
        self.reads = self.folder / "top.log"
        self.log.write_text("")
        self.reads.write_text("")
        self.browser = self.folder / "Test Browser.app"
        self.browser.mkdir()
        def frame(second):
            return f'Processes: 3 total\n2026/10/01 09:00:0{second}\nCPU usage: 10% user, 10% sys, 80% idle\nPhysMem: 10G used, 22G unused.\nPID PPID UID %CPU MEM #TH IDLEW POWER COMMAND\n21 1 501 10 100M 2 {second} 10 Example\n22 1 501 20 200M 2 {second} 20 Formula\n23 1 501 5 30M 2 {second} 5 Literal\n'
        top = self.folder / "top.txt"
        top.write_text(frame(0) + frame(2) + frame(4))
        ps = self.folder / "ps.txt"
        ps.write_text('21 1 501 1024 00:30 S 0 /Applications/<img onerror=bad>.app/Contents/MacOS/Example\n22 1 501 2048 00:30 S 0 /Applications/=2+2.app/Contents/MacOS/Formula\n23 1 501 1000 00:30 S 0 /Applications/$&.app/Contents/MacOS/Literal\n')
        def executable(name, content):
            target = self.folder / name
            target.write_text("#!/bin/bash\n" + content + "\n")
            target.chmod(0o755)
            return shlex.quote(str(target))
        fake_top = executable("fake-top", 'printf "top\\n" >> "$TOP_SPY_LOG"\n/bin/sleep "${TEST_DELAY:-0}"\n/bin/cat ' + shlex.quote(str(top)))
        fake_ps = executable("fake-ps", "/bin/cat " + shlex.quote(str(ps)))
        fake_lookup = executable("fake-lookup", 'printf "%s\\n" ' + shlex.quote(str(self.browser)))
        fake_open = executable("fake-open", 'printf "%s\\n" "__OPEN__" "$@" >> "$OPEN_SPY_LOG"\n[[ -s "${!#}" ]] || exit 90\nif [[ "${FAIL_PRIMARY:-0}" == 1 && "$2" != com.apple.Safari ]]; then exit 1; fi')
        source = LAUNCHER.read_text().replace("/usr/bin/top", fake_top).replace("/bin/ps -ww", fake_ps + " -ww").replace("/usr/bin/open", fake_open).replace("/usr/bin/osascript -l JavaScript -e", fake_lookup)
        self.target = self.folder / "Test Scanner.command"
        self.target.write_text(source)
        self.target.chmod(0o755)
        self.env = {**os.environ, "OPEN_SPY_LOG": str(self.log), "TOP_SPY_LOG": str(self.reads)}

    def tearDown(self):
        self.temp.cleanup()

    def command(self, *args):
        return ["/bin/bash", str(self.target), "--output", str(self.reports), *args]

    def scan(self, *args, **env):
        result = subprocess.run(self.command(*args), env={**self.env, **env}, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_lock_released()

    def assert_lock_released(self):
        lock = self.reports / ".mac-resource-check.lock"
        if lock.exists():
            result = subprocess.run(["/usr/bin/lockf", "-s", "-t", "0", str(lock), "/usr/bin/true"], timeout=5)
            self.assertEqual(result.returncode, 0)

    def test_browser_routing(self):
        self.scan()
        self.assertIn("-a\n" + str(self.browser), self.log.read_text())
        self.log.write_text("")
        self.scan("--browser", "chrome")
        self.assertIn("-b\ncom.google.Chrome", self.log.read_text())
        self.log.write_text("")
        self.scan("--browser", "chrome", FAIL_PRIMARY="1")
        self.assertEqual(self.log.read_text().count("__OPEN__"), 2)
        self.assertIn("com.apple.Safari", self.log.read_text())

    def test_no_open_and_reopen(self):
        self.scan("--no-open")
        self.assertEqual(self.log.read_text(), "")
        for report in self.reports.iterdir():
            self.assertEqual(report.stat().st_mode & 0o077, 0)
        self.reads.write_text("")
        self.scan("--open-only")
        self.assertEqual(self.reads.read_text(), "")
        self.assertEqual(self.log.read_text().count("__OPEN__"), 1)

    def test_existing_lock_file_does_not_block(self):
        self.reports.mkdir()
        (self.reports / ".mac-resource-check.lock").write_text("old content")
        self.scan("--no-open")

    def test_history_limit_and_repair(self):
        for _ in range(3):
            self.scan("--history", "2", "--no-open")
        journal = self.reports / "Mac Resource History.json"
        self.assertEqual(len(json.loads(journal.read_text())["scans"]), 2)
        journal.write_text("broken journal")
        self.scan("--no-open")
        self.assertEqual(len(list(self.reports.glob("Mac Resource History.backup-*.json"))), 1)
        self.assertTrue(json.loads((self.reports / "Mac Resource Data.json").read_text())["warnings"])

    def test_html_and_csv_escaping(self):
        self.scan("--no-open")
        html = (self.reports / "Mac Resource Report.html").read_text()
        encoded = re.search(r'<script id="resource-data" type="application/json">([\s\S]*?)</script>', html)[1]
        self.assertNotIn("<", encoded)
        names = [a["name"] for a in json.loads(encoded)["apps"]]
        self.assertIn("<img onerror=bad>", names)
        self.assertIn("$&", names)
        with (self.reports / "Mac Resource List.csv").open(newline="") as handle:
            rows = list(csv.reader(handle))
        self.assertTrue(any(row[0] == "'=2+2" for row in rows))

    def test_concurrent_scan_is_rejected(self):
        process = subprocess.Popen(self.command("--no-open"), env={**self.env, "TEST_DELAY": "2"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            lock = self.reports / ".mac-resource-check.lock"
            while not lock.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(lock.exists())
            result = subprocess.run(self.command("--no-open"), env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Another scan", result.stderr)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assert_lock_released()

    def test_watch_interrupt_releases_lock(self):
        process = subprocess.Popen(self.command("--seconds", "2", "--watch", "10", "--no-open"), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 16
            journal = self.reports / "Mac Resource History.json"
            count = 0
            while time.monotonic() < deadline:
                if journal.exists():
                    count = len(json.loads(journal.read_text())["scans"])
                if count >= 2:
                    break
                time.sleep(0.1)
            self.assertGreaterEqual(count, 2)
            os.killpg(process.pid, signal.SIGINT)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=5)
        self.assert_lock_released()


if __name__ == "__main__":
    unittest.main()
