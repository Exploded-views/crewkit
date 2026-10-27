#!/usr/bin/env python3
"""coverage-py-report.py IN OUT ROOT: coverage.py's JSON report as kcov's per-file report.

tools/coverage-floors.py reads kcov's coverage.json ({"files": [{"file", "covered_lines",
"total_lines", "percent_covered"}]}). This writes the same shape from `coverage json` output,
with paths made relative to ROOT (the repo); files outside ROOT are left out.

Exit 0 = written, 2 = unreadable input or usage. Stdlib only.
"""
import json
import pathlib
import sys


def convert(data, root):
    root = str(root).rstrip("/") + "/"
    files = []
    for path, info in sorted(data.get("files", {}).items()):
        if path.startswith("/"):
            if not path.startswith(root):
                continue
            path = path[len(root):]
        s = info["summary"]
        files.append({"file": path, "covered_lines": str(s["covered_lines"]),
                      "total_lines": str(s["num_statements"]),
                      "percent_covered": f"{float(s['percent_covered']):.2f}"})
    return {"files": files}


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        data = json.loads(pathlib.Path(argv[0]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"coverage-py-report: cannot read {argv[0]} ({e.__class__.__name__})", file=sys.stderr)
        return 2
    pathlib.Path(argv[1]).write_text(json.dumps(convert(data, argv[2]), indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
