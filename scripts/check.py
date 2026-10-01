"""Check syntax, documentation links, and public fixture hygiene."""
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from build import ROOT, version


def main():
    for name in ["Mac Resource Check.command", "Live Monitor.command", "src/launcher.sh", "src/live-monitor.sh"]:
        subprocess.run(["/bin/bash", "-n", str(ROOT / name)], check=True)
    for file in list((ROOT / "src").glob("*.js")) + list((ROOT / "scripts").glob("*.cjs")) + list((ROOT / "tests").glob("*.cjs")):
        subprocess.run(["node", "--check", str(file)], check=True)
    for file in ROOT.rglob("*.md"):
        if any(part in ["node_modules", ".test-output", "artifacts", ".git"] for part in file.parts):
            continue
        for target in re.findall(r"\]\(([^\s)]+)\)", file.read_text()):
            if "://" in target or target.startswith("#"):
                continue
            if not (file.parent / target.split("#")[0]).exists():
                raise ValueError(f"Broken link in {file.relative_to(ROOT)}: {target}")
    fixture = (ROOT / "tests/fixtures/demo.json").read_text()
    data = json.loads(fixture)
    assert data["demo"] is True and data["version"] == version()
    for value in ["/Users/", "api_key", "sk-proj-"]:
        if value in fixture or value in (ROOT / "docs/index.html").read_text():
            raise ValueError("Private or machine-specific data found in public demo")
    for file in (ROOT / "assets").glob("*.svg"):
        ET.parse(file)
    print("Syntax, documentation links, SVG assets, and synthetic fixture hygiene passed.")


if __name__ == "__main__":
    main()
