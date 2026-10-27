#!/usr/bin/env python3
"""ci-ok.py: the decision behind ci.yml's ci-ok job, the one check main's ruleset requires.

Reads RESULTS, every needed job's result: `toJSON(needs)` ({job: {"result": ...}}), or a plain
list of results (`toJSON(needs.*.result)`). It passes only when there is at least one and every
one is "success", with one exception: a job whose own `if:` is the private-repo guard
(`${{ !github.event.repository.private }}`, see tools/check-workflows.py) may be "skipped"
when PRIVATE is "true" (`${{ github.event.repository.private }}`). The guarded jobs are read
from WORKFLOW (default .github/workflows/ci.yml), so the list can't drift from the guards. A
skip on a public repo, with PRIVATE unset, of an unguarded job, or from a plain list fails, as
does any failure, cancellation, empty list or unreadable input. Exit 0 = all green, 1 = not.
"""
import importlib.util
import json
import os
import pathlib
import sys


def guarded_jobs(workflow):
    spec = importlib.util.spec_from_file_location(
        "check_workflows", pathlib.Path(__file__).resolve().parent / "check-workflows.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    lines = [mod.strip_comment(l) for l in pathlib.Path(workflow).read_text(encoding="utf-8").splitlines()]
    return mod.guarded_jobs(lines)


def main():
    try:
        results = json.loads(os.environ["RESULTS"])
    except (KeyError, ValueError):
        print("ci-ok: RESULTS is missing or not JSON")
        return 1
    if isinstance(results, dict):
        if not all(isinstance(v, dict) and "result" in v for v in results.values()):
            print("ci-ok: RESULTS is not toJSON(needs): every job needs a result")
            return 1
        named = {job: v["result"] for job, v in results.items()}
    elif isinstance(results, list):
        named = {f"job {n + 1}": r for n, r in enumerate(results)}
    else:
        named = {}
    if not named:
        print("ci-ok: no job results to judge")
        return 1
    skipped = [job for job, r in named.items() if r == "skipped"]
    allowed = set()
    if skipped and os.environ.get("PRIVATE") == "true":
        try:
            allowed = guarded_jobs(os.environ.get("WORKFLOW", ".github/workflows/ci.yml"))
        except OSError as e:
            print(f"ci-ok: cannot read the workflow to find the private-repo guards ({e.__class__.__name__})")
            return 1
        except ValueError as e:
            print(f"ci-ok: {e}")
            return 1
    bad = [f"{job}: {r!r}" for job, r in named.items() if r != "success" and not (r == "skipped" and job in allowed)]
    if bad:
        print("ci-ok: not every needed job succeeded: " + ", ".join(bad))
        return 1
    passed = [job for job in skipped if job in allowed]
    note = f" ({', '.join(passed)} skipped: private repo)" if passed else ""
    print(f"ci-ok: all {len(named)} needed jobs succeeded{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
