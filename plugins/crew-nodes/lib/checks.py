#!/usr/bin/env python3
"""checks.py: is a PR's required check green on its exact head? The one implementation every
crewkit lander uses. The caller gathers the JSON; this decides, and makes no network calls.

  checks.py --head SHA --required-check NAME --workflow PATH [--event EV]
            --runs-json F --jobs-json F --statuses-json F
            [--ignored LIST] [--min-green N] [--noise-step-prefix P]

  runs-json      the workflow_runs array for the head (gh api repos/R/actions/runs?head_sha=SHA)
  jobs-json      one flat array of those runs' jobs, each with run_id and run_attempt, listed
                 with filter=latest (gh api repos/R/actions/runs/ID/jobs?filter=latest)
  statuses-json  the combined commit status (gh api repos/R/commits/SHA/status)

An allow-list: the head is green only when everything that decides says "success", and
everything else is pending (not finished, or a value it can't read) or red (finished, and not
"success": failure, but also skipped, neutral, cancelled, timed_out, stale, startup_failure or any
value GitHub adds). A false red is fine, since --ignored can name a check that may fail.

The runs that decide are each workflow's newest run on SHA (by created_at; runs created in the
same second all decide), and the required check's run: the newest run of the workflow file PATH
from event EV (default pull_request; empty for any). A run without head_sha, id, created_at or path,
and a status context without a name, can't be placed: pending. Two kinds of run are passed over, as if they weren't there: a run
with a job that ran a step starting with the noise-step prefix (it only mirrors another run), and
a run that finished "skipped" with every job skipped (it executed nothing, like a label-triggered
run). No job is ever taken from an older run. A run that decides is green only when it finished
with conclusion "success" and lists its jobs, every job is "success" or named in --ignored, and
every job is from the run's own attempt (a mixed list is pending, named "jobs from more than one
attempt"). A run that finished other than
"success" is green only when every job of it that isn't "success" is named in --ignored.

The required check is the job named NAME in the required check's run, and the status context
named NAME; either one not green decides, and with neither it is pending. When the job alone
decides it, at least --min-green (default 1) other "success" jobs of that run or "success"
contexts, not ignored, must exist, so a run where everything else was skipped proves nothing.
Every other status context counts unless it is in --ignored: success is green, failure and error
are red, anything else is pending; when the list holds fewer than total_count, the combined state
decides for the rest.

Prints "green", "pending: <names>" or "red: <names>", then, when a job decided the required
check, a second line "attempt: N" with its run's attempt (for a lander waiting on a rerun). Exit 0
green, 30 pending, 31 red (the shared codes in docs/exit-codes.md), 64 usage, 65 bad data (a head
that isn't 40 lowercase hex, or JSON that can't be read or has the wrong shape). --ignored may not
name the required check (64). Stdlib only.
"""
import argparse
import json
import re
import sys

SHA = re.compile(r"^[0-9a-f]{40}$")


class Usage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def listing(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def load(path, kind):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, kind):
        raise ValueError(f"{path} is not a JSON {kind.__name__}")
    return data


def worst(states):
    return "red" if "red" in states else "pending" if "pending" in states else "green"


def context_state(state):
    if state == "success":
        return "green"
    if state in ("failure", "error"):
        return "red"
    return "pending"


def job_state(job):
    """Only "success" is green; unfinished or unreadable is pending; any other finish is red."""
    if job.get("status") != "completed" or job.get("conclusion") is None:
        return "pending"
    return "green" if job["conclusion"] == "success" else "red"


def is_noise(job, noise):
    return bool(noise) and any((s.get("name") or "").startswith(noise) and s.get("conclusion") in ("success", "failure")
                               for s in job.get("steps") or [])


def run_state(run, js, ignored):
    """A deciding run itself and its jobs, ignored ones aside: (state, {job name: state}, why)."""
    if any(j.get("run_attempt") != run.get("run_attempt") for j in js):
        return "pending", {}, " (jobs from more than one attempt)"   # a list that can't be trusted
    jobs = {}
    for j in js:
        if j.get("name") not in ignored:
            jobs[j.get("name")] = worst([jobs.get(j.get("name"), "green"), job_state(j)])
    status, concl = run.get("status"), run.get("conclusion")
    if status != "completed" or concl is None:
        return "pending", jobs, ""
    if concl != "success":
        # Finished other than success: only ignored jobs may account for it, and at least one must.
        bad = [j for j in js if j.get("conclusion") != "success"]
        return ("green" if bad and all(j.get("name") in ignored for j in bad) else "red"), jobs, ""
    return ("green" if js else "pending"), jobs, ""   # green, but with no jobs listed proves nothing


def decide(a, runs, jobs, statuses):
    """(output, exit code), by the rule in the module docstring."""
    ignored, name = set(listing(a.ignored)), a.required_check
    by_run = {}
    for j in jobs:
        by_run.setdefault(j.get("run_id"), []).append(j)

    def passed_over(run):
        js = by_run.get(run.get("id"), [])
        if any(is_noise(j, a.noise_step_prefix) for j in js):
            return True   # a mirror run speaks for nothing
        return (run.get("status") == "completed" and run.get("conclusion") == "skipped"
                and all(j.get("conclusion") == "skipped" for j in js))

    states = {}
    # A run that can't be placed (no head_sha, id, created_at or path) can't be passed over either.
    unreadable = [r for r in runs if not (r.get("head_sha") and r.get("id") is not None and r.get("created_at")
                                          and r.get("path"))]
    if unreadable:
        states["runs without head_sha, id, created_at or path"] = "pending"
    live = [r for r in runs if r not in unreadable and r.get("head_sha") == a.head and not passed_over(r)]

    def newest(rs):
        """Every run at the newest created_at: runs created in the same second all decide."""
        top = max((r.get("created_at") for r in rs), default=None)
        return [r for r in rs if r.get("created_at") == top]

    counted = []
    for path in dict.fromkeys(r.get("path") for r in live):
        counted += [(f"run {path}", r) for r in newest([r for r in live if r.get("path") == path])]
    req_runs = newest([r for r in live if r.get("path") == a.workflow and (not a.event or r.get("event") == a.event)])
    counted += [(f"run {r.get('path')} ({r.get('event')})", r) for r in req_runs
                if all(r is not run for _, run in counted)]

    for rkey, run in counted:
        st, js, why = run_state(run, by_run.get(run.get("id"), []), ignored)
        if st != "green":
            states[rkey + why] = worst([states.get(rkey + why, "green"), st])
        for jname, jst in js.items():
            if all(run is not r for r in req_runs) or jname != name:   # the required job is judged below
                states[jname] = worst([states.get(jname, "green"), jst])

    listed = statuses.get("statuses") or []
    if any(not s.get("context") for s in listed):
        states["a status context without a name"] = "pending"
    listed = [s for s in listed if s.get("context")]
    if (statuses.get("total_count") or 0) > len(statuses.get("statuses") or []) and statuses.get("state") != "success":
        states["commit statuses not all read"] = context_state(statuses.get("state"))
    required, company, attempt = [], 0, None
    for s in listed:
        ctx, st = s.get("context"), context_state(s.get("state"))
        if ctx in ignored:
            continue
        if ctx == name:
            required.append(st)
        else:
            states[ctx] = worst([states.get(ctx, "green"), st])
            company += st == "green"
    by_context = bool(required)
    for req_run in req_runs:
        js = by_run.get(req_run.get("id"), [])
        mine = [j for j in js if j.get("name") == name and j.get("run_attempt") == req_run.get("run_attempt")]
        if mine:
            attempt = req_run.get("run_attempt") if attempt is None else attempt
            required += [job_state(j) for j in mine]
            company += sum(1 for j in js if j.get("name") not in ignored and j.get("name") != name
                           and job_state(j) == "green")
    st = worst(required) if required else "pending"
    if st == "green" and attempt is not None and not by_context and company < a.min_green:
        st = "pending"   # a job alone must not prove a run where everything else was skipped
    states[name] = worst([states.get(name, "green"), st])   # with any same-named job elsewhere

    tail = "" if attempt is None else f"\nattempt: {attempt}"
    red = sorted(n for n, s in states.items() if s == "red")
    pending = sorted(n for n, s in states.items() if s == "pending")
    if red:
        return f"red: {', '.join(red)}{tail}", 31
    if pending:
        return f"pending: {', '.join(pending)}{tail}", 30
    return f"green{tail}", 0


def main(argv):
    p = Parser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--head", required=True)
    p.add_argument("--required-check", required=True)
    p.add_argument("--workflow", required=True)
    p.add_argument("--event", default="pull_request")
    p.add_argument("--runs-json", required=True)
    p.add_argument("--jobs-json", required=True)
    p.add_argument("--statuses-json", required=True)
    p.add_argument("--ignored", default="")
    p.add_argument("--min-green", type=int, default=1)
    p.add_argument("--noise-step-prefix", default="")
    try:
        a = p.parse_args(argv)
    except Usage as e:
        print(f"checks: {e}", file=sys.stderr)
        return 64
    if not SHA.match(a.head):
        print("checks: --head must be a full 40-character lowercase SHA", file=sys.stderr)
        return 65
    if a.required_check in listing(a.ignored):
        print("checks: --ignored can't name the required check", file=sys.stderr)
        return 64
    try:
        runs = load(a.runs_json, list)
        jobs = load(a.jobs_json, list)
        statuses = load(a.statuses_json, dict)
        out, code = decide(a, runs, jobs, statuses)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as e:
        # Unreadable, or JSON of the wrong shape (a run that isn't an object, a count that isn't a number).
        print(f"checks: cannot read the check data ({type(e).__name__}: {e})", file=sys.stderr)
        return 65
    print(out)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
