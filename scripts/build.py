"""Build the standalone launchers and the public, synthetic-data demo."""

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def version():
    value = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("VERSION must contain a semantic version, such as 2.1.0")
    if json.loads((ROOT / "package.json").read_text())["version"] != value:
        raise ValueError("VERSION and package.json must agree")
    return value


def source(name):
    return (SRC / name).read_text().replace("__VERSION__", version())


def template():
    return source("report.html").replace("__STYLES__", source("report.css")).replace(
        "__RESOURCE_SCRIPT__", source("rules.js") + "\n" + source("report.js")
    )


def embedded_json(data):
    return json.dumps(data, separators=(",", ":"), ensure_ascii=True).replace("<", "\\u003c")


def artifacts():
    html = template()
    renderer = "\n".join([
        source("rules.js"), source("core.js"),
        "var REPORT_TEMPLATE = " + json.dumps(html) + ";", source("jxa.js")
    ])
    result = {
        ROOT / "Mac Resource Check.command": source("launcher.sh").replace("__RENDERER__", renderer),
        ROOT / "Live Monitor.command": source("live-monitor.sh")
    }
    fixture = ROOT / "tests/fixtures/demo.json"
    if not fixture.exists():
        raise ValueError("Demo fixture is missing. Run node scripts/demo.cjs first.")
    data = json.loads(fixture.read_text())
    if not data.get("demo") or data["version"] != version():
        raise ValueError("Regenerate the demo fixture after changing VERSION")
    result[ROOT / "docs/index.html"] = html.replace("__RESOURCE_DATA__", embedded_json(data))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated files are stale")
    args = parser.parse_args()
    stale = []
    for path, text in artifacts().items():
        if args.check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            if path.suffix == ".command":
                path.chmod(0o755)
            print("Built", path.relative_to(ROOT))
    if stale:
        print("Generated files need a rebuild: " + ", ".join(stale), file=sys.stderr)
        return 1
    if args.check:
        print("Generated launchers and demo match their sources.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
