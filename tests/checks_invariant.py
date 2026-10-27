#!/usr/bin/env python3
"""The invariant every crewkit lander relies on, checked over grids of CI states.

lib/checks.py is an allow-list: a head is green only when every run that decides finished with
conclusion "success" and every job of it is "success" or named in --ignored, the required check
passed, and every status context is "success". Anything else is pending (not finished, or a value
we can't read) or red (finished, and not success). Four review rounds each found a fail-open in a
state nobody had written down, so the states here are not hand labels: they are generated from
GitHub's documented status and conclusion values (the tables below), plus one value GitHub doesn't
document, so a state nobody listed can't be missing. Three grids:

  REQUIRED  the required workflow's run (every run state) x its required job x one more job
  OTHER     a green required run, plus another workflow's run x its job x the status contexts
  HISTORY   an older and a newer run of the required workflow x other workflows' runs

and NAMED cells, each a situation a review found, with its answer written down as well (so the
oracle is checked too). Each cell compares checks.py's answer (its first word and exit code) with
oracle(), the rule in a few lines, written from the docstring and not from checks.py's code.

Usage: python3 tests/checks_invariant.py [path/to/checks.py]   (exit 0 = every cell agrees)
Stdlib only.
"""
import contextlib
import importlib.util
import io
import itertools
import json
import pathlib
import sys

sys.dont_write_bytecode = True   # loading checks.py must leave no __pycache__ in the repo
ROOT = pathlib.Path(__file__).resolve().parent.parent

# GitHub's documented values (REST API version 2022-11-28):
# - workflow runs: https://docs.github.com/en/rest/actions/workflow-runs (the list endpoint's
#   `status` parameter names every run status and conclusion; GitHub also sends the conclusion
#   startup_failure for a run whose workflow couldn't start, which that list leaves out);
# - workflow jobs: https://docs.github.com/en/rest/actions/workflow-jobs (the job object's enums);
# - commit statuses: https://docs.github.com/en/rest/commits/statuses (a context's state).
RUN_STATUSES = ("queued", "in_progress", "completed", "waiting", "requested", "pending")
RUN_CONCLUSIONS = ("success", "failure", "neutral", "cancelled", "skipped", "timed_out",
                   "action_required", "stale", "startup_failure")
JOB_STATUSES = ("queued", "in_progress", "completed", "waiting", "requested", "pending")
JOB_CONCLUSIONS = ("success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required")
CONTEXT_STATES = ("error", "failure", "pending", "success")
UNDOCUMENTED = "not-a-documented-value"   # whatever GitHub adds next, and a missing field (None)


def pairs(statuses, conclusions):
    """Every (status, conclusion) a run or job can show: unfinished ones carry no conclusion."""
    unfinished = [(s, None) for s in statuses + (None, UNDOCUMENTED) if s != "completed"]
    return unfinished + [("completed", c) for c in conclusions + (None, UNDOCUMENTED)]


RUN_STATES, JOB_STATES = pairs(RUN_STATUSES, RUN_CONCLUSIONS), pairs(JOB_STATUSES, JOB_CONCLUSIONS)
HEAD = "ef" * 20
WF, OTHER_WF, EV = ".github/workflows/ci.yml", ".github/workflows/lint.yml", "pull_request"
REQ, IGNORED, NOISE = "ci-ok", "deploy-preview", "Mirror the newest real run"
IGNORED_NAMES = {IGNORED, "preview docs"}   # passed as --ignored "deploy-preview, preview docs"
MIRROR = [{"name": NOISE + " (label-noise runs only)", "conclusion": "failure"}]
NO_CONTEXTS = {"state": "pending", "total_count": 0, "statuses": []}
T = ["2026-01-01T0%d:00:00Z" % h for h in range(10)]


def run(rid, created, path=WF, status="completed", conclusion="success", event=EV, attempt=1):
    return {"id": rid, "path": path, "event": event, "created_at": created, "run_attempt": attempt,
            "head_sha": HEAD, "status": status, "conclusion": conclusion}


def job(rid, name, conclusion="success", status="completed", attempt=1, steps=None):
    return {"run_id": rid, "run_attempt": attempt, "name": name, "status": status, "conclusion": conclusion,
            "started_at": "2026-01-01T00:00:00Z", "steps": steps or []}


def ctx(*named, combined="success", total=None):
    sts = [{"context": c, "state": s} for c, s in named]
    return {"state": combined, "total_count": len(sts) if total is None else total, "statuses": sts}


# ---- the rule ----------------------------------------------------------------------------------
def worst(says):
    return "red" if "red" in says else "pending" if "pending" in says else "green"


def context_says(state):
    return "green" if state == "success" else "red" if state in ("failure", "error") else "pending"


def oracle(runs, jobs, statuses, min_green=1):
    """The rule as a checklist, from checks.py's docstring: every item says green, pending or red,
    and the head is the worst of them. Written as tests over sets, not as checks.py's loop."""
    says = []
    finished = lambda x: x.get("status") == "completed" and x.get("conclusion") is not None   # noqa: E731
    verdict = lambda x: "pending" if not finished(x) else "green" if x["conclusion"] == "success" else "red"  # noqa: E731
    placed = lambda r: all(r.get(k) for k in ("head_sha", "created_at", "path")) and r.get("id") is not None  # noqa: E731
    says += ["pending" for r in runs if not placed(r)]                    # a run nobody can place
    mine = [r for r in runs if placed(r) and r["head_sha"] == HEAD]
    own = {r["id"]: [j for j in jobs if j.get("run_id") == r["id"]] for r in mine}
    mirror = lambda r: any(st.get("name", "").startswith(NOISE) and st.get("conclusion") in ("success", "failure")  # noqa: E731
                           for j in own[r["id"]] for st in j.get("steps") or [])
    ran_nothing = lambda r: (finished(r) and r["conclusion"] == "skipped"   # noqa: E731
                             and {j.get("conclusion") for j in own[r["id"]]} <= {"skipped"})
    candidates = [r for r in mine if not mirror(r) and not ran_nothing(r)]
    newest_of = lambda pool: [r for r in pool if not any(o["created_at"] > r["created_at"] for o in pool)]  # noqa: E731
    deciding = [r for r in candidates if r in newest_of([o for o in candidates if o["path"] == r["path"]])]
    req_runs = newest_of([o for o in candidates if o["path"] == WF and o["event"] == EV])
    for r in deciding + [r for r in req_runs if r not in deciding]:
        js = own[r["id"]]
        if {j.get("run_attempt") for j in js} - {r.get("run_attempt")}:
            says.append("pending")                                         # a mixed-attempt list
            continue
        says += [verdict(j) for j in js if j["name"] not in IGNORED_NAMES]
        run_says = verdict(r)
        if run_says == "red":                                              # excused only by ignored jobs
            failed = {j["name"] for j in js if j.get("conclusion") != "success"}
            run_says = "green" if failed and failed <= IGNORED_NAMES else "red"
        elif run_says == "green" and not js:
            run_says = "pending"                                           # green, but nothing listed
        says.append(run_says)
    listed = statuses.get("statuses") or []
    for c in listed:
        if not c.get("context"):
            says.append("pending")                                         # a context nobody can name
        elif c["context"] not in IGNORED_NAMES | {REQ}:
            says.append(context_says(c["state"]))
    if (statuses.get("total_count") or 0) > len(listed) and statuses.get("state") != "success":
        says.append(context_says(statuses.get("state")))                  # the ones not read
    # The required check: its status context and its job in the required run(s).
    req_ctx = [context_says(c["state"]) for c in listed if c.get("context") == REQ]
    req_jobs = [j for r in req_runs for j in own[r["id"]] if j["name"] == REQ and j.get("run_attempt") == r.get("run_attempt")]
    answers = req_ctx + [verdict(j) for j in req_jobs]
    required = worst(answers) if answers else "pending"
    if required == "green" and req_jobs and not req_ctx:
        company = sum(verdict(j) == "green" for r in req_runs for j in own[r["id"]] if j["name"] not in IGNORED_NAMES | {REQ})
        company += sum(c.get("state") == "success" for c in listed if c.get("context") and c["context"] not in IGNORED_NAMES | {REQ})
        required = required if company >= min_green else "pending"
    return worst(says + [required])


# ---- the cells ---------------------------------------------------------------------------------
def required_grid():
    for (rs, rc), req, (ok, other) in itertools.product(
            RUN_STATES, JOB_STATES + [None],
            [("absent", None)] + [(n, s) for n in ("unit", IGNORED) for s in JOB_STATES]):
        jobs = [] if req is None else [job(1, REQ, req[1], req[0])]
        if other is not None:
            jobs.append(job(1, ok, other[1], other[0]))
        yield (f"required run={rs}/{rc} {REQ}={req and '/'.join(map(str, req))} other {ok}={other and '/'.join(map(str, other))}",
               [run(1, T[1], status=rs, conclusion=rc)], jobs, NO_CONTEXTS)


GREEN_REQUIRED = ([run(1, T[1])], [job(1, REQ), job(1, "unit")])
CONTEXT_CASES = [("none", NO_CONTEXTS)] + [
    (f"{who}={st}", ctx((who, st), combined=st or "pending")) for who in ("scan", IGNORED, REQ)
    for st in CONTEXT_STATES + (None, UNDOCUMENTED)] + [
    (f"unread combined={st}", ctx(("scan", "success"), combined=st, total=40)) for st in CONTEXT_STATES + (None, UNDOCUMENTED)]


def other_grid():
    other_jobs = [("absent", None)] + [("lint", s) for s in JOB_STATES] + [
        (IGNORED, ("completed", "failure")), (REQ, ("completed", "failure")), (REQ, ("completed", "success"))]
    for (rs, rc), (jn, js), (cn, st) in itertools.product(RUN_STATES, other_jobs, CONTEXT_CASES):
        jobs = list(GREEN_REQUIRED[1]) + ([] if js is None else [job(2, jn, js[1], js[0])])
        yield (f"other run={rs}/{rc} job {jn}={js and '/'.join(map(str, js))} contexts {cn}",
               GREEN_REQUIRED[0] + [run(2, T[2], OTHER_WF, rs, rc)], jobs, st)


def wf_run(kind, rid, when):
    """One run of the required workflow, of a kind from HISTORY_KINDS."""
    r, js = run(rid, when), [job(rid, REQ), job(rid, "unit")]
    if kind == "red":
        r["conclusion"], js = "failure", [job(rid, REQ, "failure"), job(rid, "unit")]
    elif kind == "pending":
        r["status"], r["conclusion"], js = "in_progress", None, [job(rid, REQ, None, "in_progress"), job(rid, "unit")]
    elif kind == "all-skipped":
        r["conclusion"], js = "skipped", [job(rid, REQ, "skipped"), job(rid, "unit", "skipped")]
    elif kind == "all-skipped-no-jobs":
        r["conclusion"], js = "skipped", []
    elif kind == "mirror":
        r["conclusion"], js = "failure", [job(rid, REQ, "failure", steps=MIRROR)]
    elif kind == "partly-skipped-red":
        r["conclusion"], js = "failure", [job(rid, REQ, "skipped"), job(rid, "unit", "failure")]
    elif kind == "required-skipped":
        js = [job(rid, REQ, "skipped"), job(rid, "unit")]
    elif kind.startswith("push-"):
        r = dict(wf_run(kind[5:], rid, when)[0][0], event="push")
        js = wf_run(kind[5:], rid, when)[1]
    return [r], js


HISTORY_KINDS = ("green", "red", "pending", "all-skipped", "all-skipped-no-jobs", "mirror",
                 "partly-skipped-red", "required-skipped", "push-green", "push-red")
OTHER_HISTORIES = {
    "none": ([], []),
    "green": ([run(5, T[0], OTHER_WF)], [job(5, "lint")]),
    "older red, newer green": ([run(5, T[0], OTHER_WF, conclusion="failure"), run(6, T[5], OTHER_WF)],
                               [job(5, "lint", "failure"), job(6, "lint")]),
    "older green, newer red": ([run(5, T[0], OTHER_WF), run(6, T[5], OTHER_WF, conclusion="failure")],
                               [job(5, "lint"), job(6, "lint", "failure")]),
}


def history_grid():
    for older, newer, newest, (on, (oruns, ojobs)) in itertools.product(
            ("absent",) + HISTORY_KINDS, ("absent",) + HISTORY_KINDS, ("absent", "all-skipped", "mirror"),
            OTHER_HISTORIES.items()):
        runs, jobs = list(oruns), list(ojobs)
        for kind, rid, when in ((older, 1, T[1]), (newer, 2, T[2]), (newest, 3, T[3])):
            if kind != "absent":
                r, js = wf_run(kind, rid, when)
                runs, jobs = runs + r, jobs + js
        yield f"history {older} then {newer} then {newest}; other {on}", runs, jobs, NO_CONTEXTS


def failed_ignored(conclusion="failure"):
    return [run(1, T[1], conclusion=conclusion)]


NAMED = [
    # crewkit's 9385b45 re-review, (1): the needs:/skipped-e2e repro. The ignored job failed, so
    # e2e (needs: deploy-preview) was skipped: skipped is not success, and e2e isn't ignored.
    ("ignored job failed, its needs: dependent skipped", "red", failed_ignored(),
     [job(1, REQ), job(1, "unit"), job(1, IGNORED, "failure"), job(1, "e2e", "skipped")], NO_CONTEXTS),
    ("a red ignored job inside the required run", "green", failed_ignored(),
     [job(1, REQ), job(1, "unit"), job(1, IGNORED, "failure")], NO_CONTEXTS),
    # (2): mixed attempts. The caller lists jobs with filter=latest, so a list mixing attempts is
    # data we can't trust: pending, never green.
    ("mixed attempts in one run's job list", "pending", [run(1, T[1], attempt=2)],
     [job(1, REQ, attempt=2), job(1, "unit", attempt=1)], NO_CONTEXTS),
    ("an older attempt's red job beside a green latest attempt", "pending", [run(1, T[1], attempt=2)],
     [job(1, REQ, "failure"), job(1, "unit", "failure"), job(1, REQ, attempt=2), job(1, "unit", attempt=2)], NO_CONTEXTS),
    ("a completed re-run whose latest attempt is green", "green", [run(1, T[1], attempt=2)],
     [job(1, REQ, attempt=2), job(1, "unit", attempt=2)], NO_CONTEXTS),
    # Observed 2026-10-26 on a real run after "Re-run failed jobs" on one matrix shard: with
    # filter=latest every job, the reused successful ones included, carries the new run_attempt
    # (GitHub copies reused jobs into the new attempt; filter=all lists both attempts in full). So
    # a partial re-run is green, and the mixed-attempt rule can't hold one on pending.
    ("partial re-run: reused jobs carry attempt N, green", "green", [run(1, T[1], attempt=2)],
     [job(1, REQ, attempt=2), job(1, "shard (1)", attempt=2), job(1, "shard (7)", attempt=2)], NO_CONTEXTS),
    ("partial re-run listed with filter=all: both attempts, pending", "pending", [run(1, T[1], attempt=2)],
     [job(1, REQ), job(1, "shard (1)"), job(1, "shard (7)", "failure"),
      job(1, REQ, attempt=2), job(1, "shard (1)", attempt=2), job(1, "shard (7)", attempt=2)], NO_CONTEXTS),
    ("jobs whose run_attempt field is missing", "pending", [run(1, T[1])],
     [dict(job(1, REQ), run_attempt=None), job(1, "unit")], NO_CONTEXTS),
    # (3): two runs of the other workflow, and a chain of passed-over runs deeper than one.
    ("two runs of the other workflow, the newer green", "green",
     [run(1, T[1]), run(2, T[2], OTHER_WF, conclusion="failure"), run(3, T[3], OTHER_WF)],
     [job(1, REQ), job(1, "unit"), job(2, "lint", "failure"), job(3, "lint")], NO_CONTEXTS),
    ("two runs of the other workflow, the newer red", "red",
     [run(1, T[1]), run(2, T[2], OTHER_WF), run(3, T[3], OTHER_WF, conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(2, "lint"), job(3, "lint", "failure")], NO_CONTEXTS),
    ("two all-skipped runs newer than a green run", "green",
     [run(1, T[1]), run(2, T[2], conclusion="skipped"), run(3, T[3], conclusion="skipped")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(3, REQ, "skipped")], NO_CONTEXTS),
    ("two all-skipped runs newer than a red run", "red",
     [run(1, T[1], conclusion="failure"), run(2, T[2], conclusion="skipped"), run(3, T[3], conclusion="skipped")],
     [job(1, REQ, "failure"), job(1, "unit"), job(2, REQ, "skipped"), job(3, REQ, "skipped")], NO_CONTEXTS),
    ("a red push-event run newer than a green pull_request run", "red",
     [run(1, T[1]), run(2, T[2], conclusion="failure", event="push")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "failure"), job(2, "unit")], NO_CONTEXTS),
    ("a newer green push-event run over a pull_request run red elsewhere", "red",
     [run(1, T[1], conclusion="failure"), run(2, T[2], event="push")],
     [job(1, REQ), job(1, "unit"), job(1, "lint", "failure"), job(2, REQ), job(2, "unit")], NO_CONTEXTS),
    ("a newer green push-event run over a failed pull_request run with green jobs", "red",
     [run(1, T[1], conclusion="failure"), run(2, T[2], event="push")],
     [job(1, REQ), job(1, "unit"), job(2, REQ), job(2, "unit")], NO_CONTEXTS),
    ("a cancelled run whose jobs all look green", "red", [run(1, T[1], conclusion="cancelled")],
     [job(1, REQ), job(1, "unit")], NO_CONTEXTS),
    ("a startup_failure run whose jobs all look green", "red", [run(1, T[1], conclusion="startup_failure")],
     [job(1, REQ), job(1, "unit")], NO_CONTEXTS),
    ("a startup_failure run with no jobs", "red", [run(1, T[1], conclusion="startup_failure")], [], NO_CONTEXTS),
    ("a failed run with no jobs listed", "red", [run(1, T[1], conclusion="failure")], [], NO_CONTEXTS),
    ("a cancelled run with no jobs listed", "red", [run(1, T[1], conclusion="cancelled")], [], NO_CONTEXTS),
    # The Orchestrator's three: label- and event-triggered runs that ran nothing are passed over.
    ("an all-skipped run newer than a green run", "green", [run(1, T[1]), run(2, T[2], conclusion="skipped")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(2, "unit", "skipped")], NO_CONTEXTS),
    ("an all-skipped run newer than a red run", "red",
     [run(1, T[1], conclusion="failure"), run(2, T[2], conclusion="skipped")],
     [job(1, REQ, "failure"), job(1, "unit"), job(2, REQ, "skipped"), job(2, "unit", "skipped")], NO_CONTEXTS),
    ("a partly skipped newer run with a failure", "red",
     [run(1, T[1]), run(2, T[2], conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(2, "test", "failure")], NO_CONTEXTS),
    ("a newer run whose required job was skipped, the rest green", "red",
     [run(1, T[1]), run(2, T[2])], [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(2, "unit")], NO_CONTEXTS),
    ("a run 'skipped' that executed a job is not passed over", "red", [run(1, T[1]), run(2, T[2], conclusion="skipped")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(2, "unit")], NO_CONTEXTS),
    ("skipped and neutral jobs beside a green required job", "red", [run(1, T[1])],
     [job(1, REQ), job(1, "unit"), job(1, "docs", "skipped"), job(1, "lint", "neutral")], NO_CONTEXTS),
    # crewkit: lane-land's own expectations.
    ("only a mirror run", "pending", [run(1, T[1], conclusion="failure")],
     [job(1, REQ, "failure", steps=MIRROR)], NO_CONTEXTS),
    ("the required job alone (too few other green checks)", "pending", [run(1, T[1])], [job(1, REQ)], NO_CONTEXTS),
    ("the required job alone, with a green context", "green", [run(1, T[1])], [job(1, REQ)], ctx(("scan", "success"))),
    ("an ignored job and a green context don't make company", "pending", [run(1, T[1])],
     [job(1, REQ), job(1, IGNORED)], ctx((IGNORED, "success"))),
    ("no runs and no contexts", "pending", [], [], NO_CONTEXTS),
    ("a run without status fields (unread)", "pending",
     [{k: v for k, v in run(1, T[1]).items() if k not in ("status", "conclusion")}], [job(1, REQ), job(1, "unit")], NO_CONTEXTS),
    # The Opus review of 40f1bbb: same-second runs, unplaceable data, several ignored names,
    # a mirror step that didn't run, and min-green above 1.
    ("same-second runs: a green pull_request run listed before a red push run", "red",
     [run(10, T[1]), run(11, T[1], conclusion="failure", event="push")],
     [job(10, REQ), job(10, "unit"), job(11, REQ, "failure"), job(11, "unit")], NO_CONTEXTS),
    ("same-second runs: a red push run listed before a green pull_request run", "red",
     [run(11, T[1], conclusion="failure", event="push"), run(10, T[1])],
     [job(10, REQ), job(10, "unit"), job(11, REQ, "failure"), job(11, "unit")], NO_CONTEXTS),
    ("same-second runs of another workflow, the red one listed second", "red",
     [run(1, T[1]), run(2, T[2], OTHER_WF), run(3, T[2], OTHER_WF, conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(2, "lint"), job(3, "lint", "failure")], NO_CONTEXTS),
    ("same-second required runs, one red", "red", [run(10, T[1]), run(11, T[1], conclusion="failure")],
     [job(10, REQ), job(10, "unit"), job(11, REQ, "failure"), job(11, "unit")], NO_CONTEXTS),
    # The re-review of d1ac7ef: a same-second twin that finished "success" with ci-ok skipped (a
    # PR opened and labelled at once). Each tied run's own required job must be judged.
    ("same-second required runs, the second's ci-ok skipped", "red", [run(10, T[1]), run(11, T[1])],
     [job(10, REQ), job(10, "unit"), job(11, REQ, "skipped"), job(11, "unit")], NO_CONTEXTS),
    ("same-second required runs, the first's ci-ok skipped", "red", [run(11, T[1]), run(10, T[1])],
     [job(10, REQ), job(10, "unit"), job(11, REQ, "skipped"), job(11, "unit")], NO_CONTEXTS),
    ("runs without a path: an older red one behind a newer green one", "pending",
     [run(1, T[1]), {k: v for k, v in run(2, T[0], conclusion="failure").items() if k != "path"},
      {k: v for k, v in run(3, T[2]).items() if k != "path"}],
     [job(1, REQ), job(1, "unit"), job(2, "lint", "failure"), job(3, "docs")], NO_CONTEXTS),
    ("a red run without an id", "pending", [run(1, T[1]), {k: v for k, v in run(2, T[2], OTHER_WF, conclusion="failure").items() if k != "id"}],
     [job(1, REQ), job(1, "unit")], NO_CONTEXTS),
    ("same-second required runs, both green", "green", [run(10, T[1]), run(11, T[1])],
     [job(10, REQ), job(10, "unit"), job(11, REQ), job(11, "unit")], NO_CONTEXTS),
    ("a red run with created_at null", "pending",
     [run(1, T[1]), run(2, T[1], OTHER_WF), dict(run(3, None, OTHER_WF, conclusion="failure"))],
     [job(1, REQ), job(1, "unit"), job(2, "lint"), job(3, "lint", "failure")], NO_CONTEXTS),
    ("the newest required run with created_at null, red", "pending", [run(1, T[1]), run(2, None, conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "failure"), job(2, "unit")], NO_CONTEXTS),
    ("a red run without head_sha", "pending",
     [run(1, T[1]), {k: v for k, v in run(2, T[2], OTHER_WF, conclusion="failure").items() if k != "head_sha"}],
     [job(1, REQ), job(1, "unit"), job(2, "lint", "failure")], NO_CONTEXTS),
    ("a failed status context without a name", "pending", [run(1, T[1])], [job(1, REQ), job(1, "unit")],
     {"state": "failure", "total_count": 1, "statuses": [{"state": "failure"}]}),
    ("a failing job whose name is part of an ignored name", "red", [run(1, T[1], conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(1, "preview", "failure")], NO_CONTEXTS),
    ("a second ignored name, with a space, failing", "green", [run(1, T[1], conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(1, "preview docs", "failure")], NO_CONTEXTS),
    ("two ignored jobs failed, their needs: dependent skipped", "red", [run(1, T[1], conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(1, IGNORED, "failure"), job(1, "preview docs", "failure"), job(1, "e2e", "skipped")],
     NO_CONTEXTS),
    ("a newer red run whose mirror step was skipped (it ran for real)", "red",
     [run(1, T[1]), run(2, T[2], conclusion="failure")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "failure", steps=[dict(MIRROR[0], conclusion="skipped")]), job(2, "unit")],
     NO_CONTEXTS),
    ("a run still in progress with conclusion skipped is not passed over: its skipped jobs are red", "red",
     [run(1, T[1]), run(2, T[2], status="in_progress", conclusion="skipped")],
     [job(1, REQ), job(1, "unit"), job(2, REQ, "skipped"), job(2, "unit", "skipped")], NO_CONTEXTS),
    ("min-green 2 with one other green job", "pending", [run(1, T[1])], [job(1, REQ), job(1, "unit")], NO_CONTEXTS, 2),
    ("min-green 2 with one other green job and a green context", "green", [run(1, T[1])], [job(1, REQ), job(1, "unit")],
     ctx(("scan", "success")), 2),
    ("min-green 2 with two other green jobs", "green", [run(1, T[1])], [job(1, REQ), job(1, "unit"), job(1, "lint")],
     NO_CONTEXTS, 2),
    ("min-green 3: an ignored green job doesn't make company", "pending", [run(1, T[1])],
     [job(1, REQ), job(1, "unit"), job(1, "lint"), job(1, IGNORED)], NO_CONTEXTS, 3),
    ("a run on another head is no run", "pending", [dict(run(1, T[1]), head_sha="12" * 20)],
     [job(1, REQ), job(1, "unit")], NO_CONTEXTS),
]


# ---- running it --------------------------------------------------------------------------------
def load_checks(path):
    spec = importlib.util.spec_from_file_location("checks_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def answer(checks, runs, jobs, statuses, min_green=1):
    data = {"runs": runs, "jobs": jobs, "statuses": statuses}
    checks.load = lambda path, kind: data[path]   # the cells' data, without a file per cell
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = checks.main(["--head", HEAD, "--required-check", REQ, "--workflow", WF, "--event", EV,
                            "--runs-json", "runs", "--jobs-json", "jobs", "--statuses-json", "statuses",
                            "--ignored", "deploy-preview, preview docs", "--noise-step-prefix", NOISE,
                            "--min-green", str(min_green)])
    word = (out.getvalue().split() or ["?"])[0].rstrip(":")
    if {"green": 0, "pending": 30, "red": 31}.get(word) != code:
        return f"?exit {code} for {out.getvalue().strip()!r}"
    return word


def cells():
    for grid in (required_grid(), other_grid(), history_grid()):
        for label, runs, jobs, statuses in grid:
            yield label, None, runs, jobs, statuses, 1
    for label, expect, runs, jobs, statuses, *min_green in NAMED:
        yield "named: " + label, expect, runs, jobs, statuses, (min_green or [1])[0]


def main(argv):
    checks = load_checks(pathlib.Path(argv[0]) if argv else ROOT / "lib" / "checks.py")
    wrong, count = [], 0
    for label, expect, runs, jobs, statuses, min_green in cells():
        count += 1
        want = oracle(runs, jobs, statuses, min_green)
        if expect is not None and want != expect:
            wrong.append(f"{label}: the oracle says {want}, the cell says {expect} (fix the oracle)")
            continue
        got = answer(checks, json.loads(json.dumps(runs)), json.loads(json.dumps(jobs)), json.loads(json.dumps(statuses)), min_green)
        if got != want:
            wrong.append(f"{label}: want {want}, got {got}")
    for w in wrong[:40]:
        print(w)
    if len(wrong) > 40:
        print(f"... and {len(wrong) - 40} more")
    print(f"checks invariant: {count} cells, {len(wrong)} wrong")
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
