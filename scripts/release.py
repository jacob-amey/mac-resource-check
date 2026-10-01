"""Create a reproducible user download containing no collected reports."""

import hashlib
import subprocess
import sys
import zipfile

from build import ROOT, version


def main():
    subprocess.run([sys.executable, str(ROOT / "scripts/build.py"), "--check"], check=True)
    release = ROOT / "artifacts"
    release.mkdir(exist_ok=True)
    filename = "mac-resource-check-" + version() + ".zip"
    target = release / filename
    files = ["Mac Resource Check.command", "Live Monitor.command", "QUICKSTART.md", "LICENSE", "docs/measurements.md", "docs/troubleshooting.md"]
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo("Mac Resource Check/" + ("README.md" if name == "QUICKSTART.md" else name), (2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            mode = 0o100755 if name.endswith(".command") else 0o100644
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, (ROOT / name).read_bytes())
    with zipfile.ZipFile(target) as archive:
        if archive.testzip():
            raise ValueError("Release archive verification failed")
    checksum = hashlib.sha256(target.read_bytes()).hexdigest()
    (release / (filename + ".sha256")).write_text(checksum + "  " + filename + "\n")
    print("Created", target.relative_to(ROOT))
    print("SHA-256", checksum)


if __name__ == "__main__":
    main()
