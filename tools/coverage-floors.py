#!/usr/bin/env python3
"""Coverage ratchet: per-file line-coverage floors that may only move up.

Fails (exit 1) when any of these hold:
  - a file's line coverage in the kcov report is below its floor;
  - a file with a floor is missing from the report;
  - with --base-floors: a floor is lower than on the merge base, or was removed.

--update raises each floor to the file's current coverage (rounded down to 0.1) and never
lowers one. Commit that as its own visible change.

Usage:
  tools/coverage-floors.py --report <coverage.json> [--report <another>] [--floors coverage-floors.json]
                           [--base-floors <base copy of the floors file>] [--update]

Exit 0 = ok, 1 = a floor is broken, 2 = usage (missing or unreadable file).
Stdlib only.
"""
import argparse
import json
import math
import pathlib
import sys


def load(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"coverage-floors: cannot read {path} ({e.__class__.__name__})", file=sys.stderr)
        sys.exit(2)


def current(report):
    """{path relative to the repo: line %} from a kcov coverage.json (paths under /src/, or
    already relative, as tools/coverage-py-report.py writes them)."""
    out = {}
    for f in report.get("files", []):
        rel = f["file"].split("/src/", 1)[-1]
        total = int(f["total_lines"])
        out[rel] = 100.0 * int(f["covered_lines"]) / total if total else 100.0
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--report", required=True, action="append",
                    help="a kcov coverage.json, or coverage.py's via tools/coverage-py-report.py; repeatable")
    ap.add_argument("--floors", default="coverage-floors.json")
    ap.add_argument("--base-floors")
    ap.add_argument("--update", action="store_true")
    args = ap.parse_args()

    now = {}
    for report in args.report:
        now.update(current(load(report)))
    floors = load(args.floors)
    failures = []

    if args.update:
        for name, value in floors.items():
            if name in now:
                value["lines"] = max(value["lines"], math.floor(now[name] * 10) / 10)
        pathlib.Path(args.floors).write_text(json.dumps(floors, indent=2) + "\n", encoding="utf-8")

    for name, value in sorted(floors.items()):
        if name not in now:
            failures.append(f"{name} has a floor but is not in the coverage report")
        elif now[name] + 1e-9 < value["lines"]:
            failures.append(f"{name} lines at {now[name]:.2f}% are below the {value['lines']}% floor")
        else:
            print(f"ok   {name} {now[name]:.2f}% (floor {value['lines']}%)")

    if args.base_floors:
        for name, value in sorted(load(args.base_floors).items()):
            if name not in floors:
                failures.append(f"{name}'s floor was removed (base had {value['lines']}%)")
            elif floors[name]["lines"] < value["lines"]:
                failures.append(f"{name}'s floor was lowered from {value['lines']}% to {floors[name]['lines']}%")

    for f in failures:
        print(f"FAIL {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
