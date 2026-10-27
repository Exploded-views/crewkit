#!/usr/bin/env python3
"""make.py OUT_DIR: write the shared check-state fixtures for lib/checks.py (tests/checks.bats).

Each case is a directory OUT_DIR/<case>/ holding runs.json (the workflow_runs array), jobs.json
(one flat array of jobs, each with run_id) and statuses.json (the combined commit status). SHAs
are built here, so no long hex literal sits in the repo. Prints one line per case:
<case> <head> <expected: green|pending|red>. Every case uses --required-check ci-ok,
--workflow .github/workflows/ci.yml, --event pull_request, --ignored deploy-preview and
--noise-step-prefix "Mirror the newest real run".

A run is any workflow run on the head: the required check's run is the newest one of --workflow
(and --event); every workflow counts through its own newest run. Mirror runs and runs that finished
"skipped" having executed nothing are passed over. Jobs are as listed with filter=latest.

Both landers' tests use these cases; change them only with both sides' tests.
"""
import json
import pathlib
import sys

HEAD = "ef" * 20
OTHER = "12" * 20
WF, EV = ".github/workflows/ci.yml", "pull_request"


def run(rid, created, attempt=1, path=WF, event=EV, head=HEAD, status="completed", conclusion="success"):
    return {"id": rid, "path": path, "event": event, "created_at": created, "run_attempt": attempt, "head_sha": head,
            "status": status, "conclusion": conclusion}


def job(rid, name, conclusion, status="completed", attempt=1, steps=None, started="2026-01-01T00:00:00Z"):
    return {"run_id": rid, "run_attempt": attempt, "name": name, "status": status,
            "conclusion": conclusion, "started_at": started, "steps": steps or []}


def green_run(rid, created="2026-01-01T00:00:00Z", attempt=1):
    return [job(rid, "unit", "success", attempt=attempt), job(rid, "ci-ok", "success", attempt=attempt)]


def statuses(*pairs):
    return {"state": "success", "statuses": [{"context": c, "state": s} for c, s in pairs]}


T0, T1 = "2026-01-01T00:00:00Z", "2026-01-01T01:00:00Z"
CASES = {
    "green": ("green", [run(1, T0)], green_run(1), statuses()),
    "pending": ("pending", [run(1, T0)], [job(1, "unit", None, "in_progress"), job(1, "ci-ok", None, "queued")], statuses()),
    "red": ("red", [run(1, T0)], [job(1, "unit", "failure"), job(1, "ci-ok", "failure")], statuses()),
    # An allow-list: only "success" is green, so a skipped or neutral job is red (--ignored names
    # the ones that may be).
    "skipped-is-not-green": ("red", [run(1, T0)], [job(1, "unit", "skipped"), job(1, "ci-ok", "skipped")], statuses()),
    "okonly-is-not-green": ("red", [run(1, T0)], [job(1, "unit", "skipped"), job(1, "ci-ok", "success")], statuses()),
    "required-job-alone": ("pending", [run(1, T0)], [job(1, "ci-ok", "success")], statuses()),
    "other-workflow-same-name": ("red", [run(1, T0), run(2, T1, path=".github/workflows/lint.yml")],
                                 [job(1, "unit", "failure"), job(1, "ci-ok", "failure")] + green_run(2), statuses()),
    "push-event-ignored": ("red", [run(1, T0), run(2, T1, event="push")],
                           [job(1, "unit", "failure"), job(1, "ci-ok", "failure")] + green_run(2), statuses()),
    "newest-run-wins": ("red", [run(1, T0, attempt=2), run(2, T1)],
                        green_run(1, attempt=2) + [job(2, "unit", "failure"), job(2, "ci-ok", "failure")], statuses()),
    # Jobs are listed with filter=latest: a re-run's list holds its latest attempt only, and a list
    # that mixes attempts can't be trusted.
    "newest-attempt-wins": ("green", [run(1, T0, attempt=2)], green_run(1, attempt=2), statuses()),
    "mixed-attempts": ("pending", [run(1, T0, attempt=2)],
                       [job(1, "unit", "failure", attempt=1), job(1, "ci-ok", "failure", attempt=1)]
                       + green_run(1, attempt=2), statuses()),
    "noise-run-ignored": ("green", [run(1, T0), run(2, T1)],
                          green_run(1) + [job(2, "ci-ok", "failure", steps=[{"name": "Mirror the newest real run", "conclusion": "failure"}])],
                          statuses()),
    "noise-run-in-another-workflow": ("green", [run(1, T0), run(2, T1, path=".github/workflows/labels.yml")],
                                      green_run(1) + [job(2, "ci-ok", "failure", steps=[{"name": "Mirror the newest real run", "conclusion": "failure"}])],
                                      statuses()),
    "same-name-red-in-another-workflow": ("red", [run(1, T0), run(2, T1, path=".github/workflows/lint.yml")],
                                          green_run(1) + [job(2, "ci-ok", "failure")], statuses()),
    "other-head-ignored": ("green", [run(1, T0), run(2, T1, head=OTHER)],
                           green_run(1) + [job(2, "unit", "failure"), job(2, "ci-ok", "failure")], statuses()),
    "no-runs": ("pending", [], [], statuses()),
    "status-context-red": ("red", [run(1, T0)], green_run(1), statuses(("security/scan", "failure"))),
    "status-context-error": ("red", [run(1, T0)], green_run(1), statuses(("security/scan", "error"))),
    "status-context-pending": ("pending", [run(1, T0)], green_run(1), statuses(("security/scan", "pending"))),
    "status-context-ignored": ("green", [run(1, T0)], green_run(1), statuses(("deploy-preview", "failure"))),
    "required-check-is-a-context": ("green", [], [], statuses(("ci-ok", "success"))),
    "required-context-red": ("red", [], [], statuses(("ci-ok", "failure"))),
    # No other red: every job of the newest run of every workflow on the head counts.
    "other-job-in-run-red": ("red", [run(1, T0)], green_run(1) + [job(1, "e2e", "failure")], statuses()),
    "other-job-cancelled": ("red", [run(1, T0)], green_run(1) + [job(1, "e2e", "cancelled")], statuses()),
    "other-job-pending": ("pending", [run(1, T0)], green_run(1) + [job(1, "e2e", None, "in_progress")], statuses()),
    "other-jobs-skipped-or-neutral": ("red", [run(1, T0)],
                                      green_run(1) + [job(1, "docs", "skipped"), job(1, "lint", "neutral")], statuses()),
    "other-workflow-red": ("red", [run(1, T0), run(2, T1, path=".github/workflows/lint.yml")],
                           green_run(1) + [job(2, "lint", "failure")], statuses()),
    "other-workflow-old-run-red-ignored": ("green", [run(1, T0), run(2, T0, path=".github/workflows/lint.yml"),
                                                     run(3, T1, path=".github/workflows/lint.yml")],
                                           green_run(1) + [job(2, "lint", "failure"), job(3, "lint", "success")], statuses()),
    "other-job-ignored": ("green", [run(1, T0)], green_run(1) + [job(1, "deploy-preview", "failure")], statuses()),
    "required-job-green-context-red": ("red", [run(1, T0)], green_run(1), statuses(("ci-ok", "success"), ("security/scan", "failure"))),
    "same-name-job-red-context-green": ("red", [run(1, T0)], [job(1, "unit", "success"), job(1, "ci-ok", "failure")],
                                        statuses(("ci-ok", "success"))),
    "same-name-job-green-context-red": ("red", [run(1, T0)], green_run(1), statuses(("ci-ok", "failure"))),
    "empty-statuses": ("green", [run(1, T0)], green_run(1), {"state": "pending", "total_count": 0, "statuses": []}),
    # A run that can't speak yet is pending, never "nothing red" (the first review of land-batch).
    "newest-required-run-has-no-jobs": ("pending", [run(1, T0), run(2, T1)], green_run(1), statuses()),
    "other-workflow-run-has-no-jobs": ("pending", [run(1, T0), run(2, T1, path=".github/workflows/lint.yml")],
                                       green_run(1), statuses()),
    "other-workflow-run-failed-no-jobs": ("red", [run(1, T0), dict(run(2, T1, path=".github/workflows/lint.yml"),
                                                                   status="completed", conclusion="failure")],
                                          green_run(1), statuses()),
    "other-workflow-run-in-progress": ("pending", [run(1, T0), dict(run(2, T1, path=".github/workflows/lint.yml"),
                                                                    status="in_progress", conclusion=None)],
                                       green_run(1) + [job(2, "lint", "success")], statuses()),
    "required-run-failed-jobs-green": ("red", [dict(run(1, T0), status="completed", conclusion="failure")],
                                       green_run(1), statuses()),
    # No fallback: the newest run decides, unless it finished "skipped" having executed nothing
    # (a label- or event-triggered run), which is passed over like a mirror run.
    "newest-required-job-skipped-is-red": ("red", [run(1, T0), run(2, T1)],
                                           green_run(1) + [job(2, "unit", "skipped"), job(2, "ci-ok", "skipped")],
                                           statuses()),
    "all-skipped-run-passed-over": ("green", [run(1, T0), run(2, T1, conclusion="skipped")],
                                    green_run(1) + [job(2, "unit", "skipped"), job(2, "ci-ok", "skipped")], statuses()),
    "all-skipped-run-over-a-red-run": ("red", [run(1, T0, conclusion="failure"), run(2, T1, conclusion="skipped")],
                                       [job(1, "unit", "failure"), job(1, "ci-ok", "failure"),
                                        job(2, "unit", "skipped"), job(2, "ci-ok", "skipped")], statuses()),
    "ignored-job-failed-dependent-skipped": ("red", [run(1, T0, conclusion="failure")],
                                             green_run(1) + [job(1, "deploy-preview", "failure"), job(1, "e2e", "skipped")],
                                             statuses()),
    "failed-run-no-jobs": ("red", [run(1, T0, conclusion="failure")], [], statuses()),
    "cancelled-run-jobs-green": ("red", [run(1, T0, conclusion="cancelled")], green_run(1), statuses()),
    # A newer run whose required job was skipped still decides in full (#7's review).
    "newer-run-required-skipped-other-red": ("red", [run(1, T0), dict(run(2, T1), status="completed", conclusion="failure")],
                                             green_run(1) + [job(2, "ci-ok", "skipped"), job(2, "test", "failure")],
                                             statuses()),
    "newer-run-required-skipped-other-red-no-conclusion": ("red", [run(1, T0), run(2, T1)],
                                                           green_run(1) + [job(2, "ci-ok", "skipped"), job(2, "test", "failure")],
                                                           statuses()),
    # A newer run with a skipped required job decides; an older green one never vouches for it
    # (#7's re-review).
    "older-fallback-run-red-elsewhere": ("red", [dict(run(1, T0), status="completed", conclusion="failure"),
                                                 dict(run(2, T1), status="completed", conclusion="success")],
                                         [job(1, "ci-ok", "success"), job(1, "test", "success"), job(1, "lint", "failure"),
                                          job(2, "ci-ok", "skipped"), job(2, "test", "skipped")], statuses()),
    "older-fallback-run-red-elsewhere-no-conclusion": ("red", [run(1, T0), run(2, T1)],
                                                       [job(1, "ci-ok", "success"), job(1, "test", "success"), job(1, "lint", "failure"),
                                                        job(2, "ci-ok", "skipped"), job(2, "test", "success")], statuses()),
    "newer-run-without-the-required-job": ("pending", [run(1, T0), dict(run(2, T1), status="completed", conclusion="success")],
                                           green_run(1) + [job(2, "unit", "success")], statuses()),
    "statuses-beyond-the-first-page-red": ("red", [run(1, T0)], green_run(1),
                                           {"state": "failure", "total_count": 40, "statuses": [{"context": "a", "state": "success"}]}),
    "combined-failure-from-an-ignored-context": ("green", [run(1, T0)], green_run(1),
                                                 {"state": "failure", "total_count": 1,
                                                  "statuses": [{"context": "deploy-preview", "state": "failure"}]}),
    "okonly-but-a-green-context": ("green", [run(1, T0)], [job(1, "ci-ok", "success")],
                                   statuses(("security/scan", "success"))),
}


def main(out):
    out = pathlib.Path(out)
    for case, (expect, runs, jobs, st) in CASES.items():
        d = out / case
        d.mkdir(parents=True, exist_ok=True)
        (d / "runs.json").write_text(json.dumps(runs))
        (d / "jobs.json").write_text(json.dumps(jobs))
        (d / "statuses.json").write_text(json.dumps(st))
        print(case, HEAD, expect)


if __name__ == "__main__":
    main(sys.argv[1])
