#!/usr/bin/env python3
"""Performance budgets for crewkit's hot paths, from perf-budgets.json.

Each scenario runs `trials` trials of `runs` runs, and the best trial's p95 wall time must stay
under its budget (load from other sessions disturbs single trials; a real slowdown shows in
all of them). In CI
(the CI environment variable is set) every budget is multiplied by `ci_headroom`, because
shared runners are noisier than a workstation. Scenarios:

  shared-index-150-notes       memory-notices' SessionStart index over 150 fake notes
  changes-hook-absent-overhead the guarded changes hook with claude-memsync absent, minus a
                               bare `sh -c true` (what the guard adds per prompt)
  install-dry-run              ./install.sh with nothing pinned
  install-plugins-rerun        ./install.sh --yes --only plugins when everything is already
                               installed, with a stub claude (install.sh's own cost; each real
                               claude CLI call adds about half a second on top)
  settings-lookup-10           ten lookups in one process (the file list is found once)
  lane-hygiene-clean           lane-hygiene on a clean lane worktree with 200 tracked files
  settings-lookup              one lib/settings.sh lookup that reads all three settings files
                               and falls to the default, minus a bare bash start
  land-batch-checks-one-pr     land-batch's dry run over one PR with the stub gh: settings, the
                               clone, and every eligibility check (labels, gates, high-risk
                               paths, the PR's own CI) that runs again before each merge
  pane-ask-read                crew-nodes' pane-ask --read with the stub ssh and herdr:
                               settings, one ssh call, the remote sh and herdr (each of its
                               herdr calls costs about the same, plus the network)
  changes-hook-present-fast    memory-notices' bin/changes-hook around a stub claude-memsync that
                               returns at once (what the wrapper adds to every prompt)
  changes-hook-timeout         the same around a stub that never returns: the wall time is the
                               wrapper's timeout (500 ms here) plus the kill, under timeout + 300 ms
  crewkit-node-report          crewkit node report with the stub herdr, three agents and a node
                               state: settings, sourcing the libraries, the herdr calls, one jq

Usage: tools/perf.py [--runs N]
Exit 0 = every p95 within budget, 1 = over budget or budgets out of sync, 2 = usage.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCENARIOS = ["shared-index-150-notes", "changes-hook-absent-overhead", "install-dry-run",
             "install-plugins-rerun", "settings-lookup", "settings-lookup-10", "lane-hygiene-clean",
             "land-batch-checks-one-pr", "pane-ask-read",
             "changes-hook-present-fast", "changes-hook-timeout",
             "crewkit-node-report"]


def p95(samples):
    s = sorted(samples)
    return s[int(0.95 * (len(s) - 1))] if s else 0.0


def best_p95(trial_samples):
    """The lowest p95 across trials: a trial disturbed by other load on the host doesn't fail
    the budget, while a real slowdown shows in every trial."""
    return min(p95(s) for s in trial_samples)


def trials(cfg):
    return int(cfg.get("trials", 3))


def headroom(cfg, env):
    return float(cfg.get("ci_headroom", 1.0)) if env.get("CI") else 1.0


def over_budget(measured, budgets, factor):
    """Failure lines: a p95 over budget x factor, or measured/budgeted scenarios out of sync. A budget
    with its own "ci_headroom" uses that instead of the factor (1.0: a hard limit, CI or not)."""
    fails = []
    for name, ms in sorted(measured.items()):
        if name not in budgets:
            fails.append(f"{name}: measured but has no budget in perf-budgets.json")
        elif ms > budgets[name]["p95_ms"] * (f := budgets[name].get("ci_headroom", factor) if factor != 1.0 else factor):
            fails.append(f"{name}: p95 {ms:.1f} ms is over its {budgets[name]['p95_ms']} ms budget"
                         + (f" (x{f} in CI)" if f != 1.0 else ""))
    for name in sorted(set(budgets) - set(measured)):
        fails.append(f"{name}: has a budget but no scenario measures it")
    return fails


def timed(cmd, runs, **kw):
    samples = []
    for _ in range(runs):
        t = time.perf_counter()
        subprocess.run(cmd, capture_output=True, check=False, **kw)
        samples.append((time.perf_counter() - t) * 1000)
    return samples


def measure(runs, n_trials=3):
    def bp(cmd, **kw):
        return best_p95([timed(cmd, runs, **kw) for _ in range(n_trials)])

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="crewkit-perf-"))
    out = {}

    sync = tmp / "sync" / "distilled"
    sync.mkdir(parents=True)
    for i in range(150):
        (sync / f"note-{i:03d}.md").write_text(
            f"---\nname: note-{i:03d}\ndescription: example note {i}\n---\n" + "body line\n" * 40)
    env = dict(os.environ, CLAUDE_MEMSYNC_DIR=str(tmp / "sync"))
    out["shared-index-150-notes"] = bp([sys.executable, str(ROOT / "plugins/memory-notices/bin/shared-index")], input=b"{}", env=env)

    hooks = json.loads((ROOT / "plugins/memory-notices/hooks/hooks.json").read_text())
    guard = hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
    bare_env = dict(os.environ, PATH="/usr/bin:/bin")
    hook = bp(["sh", "-c", guard], input=b"{}", env=bare_env)
    bare = bp(["sh", "-c", "true"], input=b"{}", env=bare_env)
    out["changes-hook-absent-overhead"] = max(0.0, hook - bare)

    out["install-dry-run"] = bp([str(ROOT / "install.sh")], cwd=ROOT)

    home, stubs = tmp / "home", tmp / "stubs"
    home.mkdir()
    stubs.mkdir()
    (stubs / "claude").write_text(
        "#!/bin/sh\ncase \"$*\" in\n"
        "  'plugin marketplace list --json') echo '[{\"name\": \"crewkit\"}]' ;;\n"
        "  'plugin list --json') echo '[{\"id\": \"agent-practice@crewkit\"}, {\"id\": \"memory-notices@crewkit\"}]' ;;\n"
        "esac\n")
    (stubs / "claude").chmod(0o755)
    ienv = dict(os.environ, HOME=str(home), PATH=f"{stubs}:{os.environ['PATH']}")
    subprocess.run([str(ROOT / "install.sh"), "--yes", "--only", "plugins"], env=ienv, capture_output=True)
    out["install-plugins-rerun"] = bp([str(ROOT / "install.sh"), "--yes", "--only", "plugins"], env=ienv)

    # One crew_setting lookup that misses every file and falls to the default (the slowest
    # path: all three files read), minus a bare bash start.
    proj = tmp / "proj" / ".claude"
    proj.mkdir(parents=True)
    for f in ("crewkit.md", "crewkit.local.md"):
        (proj / f).write_text("---\n" + "".join(f"key{i}: v{i}\n" for i in range(40)) + "---\n")
    (home / ".claude").mkdir(exist_ok=True)
    (home / ".claude" / "crewkit.md").write_text("---\nrepo: o/r\n---\n")
    senv = dict(os.environ, HOME=str(home))
    lookup = f"source '{ROOT / 'lib/settings.sh'}'; crew_setting not_set dflt >/dev/null"
    with_lookup = bp(["bash", "-c", lookup], cwd=proj.parent, env=senv)
    bare = bp(["bash", "-c", "true"], cwd=proj.parent, env=senv)
    out["settings-lookup"] = max(0.0, with_lookup - bare)
    ten = f"source '{ROOT / 'lib/settings.sh'}'; for i in 1 2 3 4 5 6 7 8 9 10; do crew_setting key$i dflt >/dev/null; done"
    out["settings-lookup-10"] = max(0.0, bp(["bash", "-c", ten], cwd=proj.parent, env=senv) - bare)

    # lane-hygiene on a clean lane worktree with 200 tracked files (it runs after every step).
    g = dict(os.environ, GIT_AUTHOR_NAME="p", GIT_AUTHOR_EMAIL="p@example.com",
             GIT_COMMITTER_NAME="p", GIT_COMMITTER_EMAIL="p@example.com", HOME=str(home))
    wt = tmp / "wt"
    subprocess.run(["git", "init", "-q", "-b", "lane/p", str(wt)], check=True, env=g)
    for i in range(200):
        (wt / f"f{i}.txt").write_text(f"{i}\n")
    subprocess.run(["git", "-C", str(wt), "add", "."], check=True, env=g)
    subprocess.run(["git", "-C", str(wt), "commit", "-qm", "base"], check=True, env=g)
    out["lane-hygiene-clean"] = bp([str(ROOT / "plugins/crew-lanes/bin/lane-hygiene"), str(wt), "lane/p"], env=g)

    cmd, kw = land_batch_dry_run(tmp)
    out["land-batch-checks-one-pr"] = bp(cmd, **kw)

    cmd, kw = pane_ask_read(tmp)
    out["pane-ask-read"] = bp(cmd, **kw)

    cmd, kw = changes_hook(tmp, hangs=False)
    out["changes-hook-present-fast"] = bp(cmd, **kw)
    cmd, kw = changes_hook(tmp, hangs=True)
    # The cost is a fixed sleep, so 5 runs of one trial say all there is to say (more would only add
    # 0.5 s each). Its limit, timeout + 300 ms, is a hard one (ci_headroom 1.0 in perf-budgets.json).
    out["changes-hook-timeout"] = best_p95([timed(cmd, 5, **kw)])
    cmd, kw = node_report(tmp)
    out["crewkit-node-report"] = bp(cmd, **kw)
    return out


def changes_hook(tmp, hangs):
    """memory-notices' changes-hook with a stub claude-memsync (never the real one) first on PATH,
    in a state dir of its own. hangs: the stub never returns, and the wrapper's timeout is 500 ms."""
    root = tmp / ("ch-hang" if hangs else "ch-fast")
    bindir = root / "bin"
    bindir.mkdir(parents=True)
    body = "sleep 5 &\nwait\n" if hangs else "echo notice\n"
    (bindir / "claude-memsync").write_text("#!/bin/sh\n" + body)
    (bindir / "claude-memsync").chmod(0o755)
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", XDG_STATE_HOME=str(root / "state"),
               CREWKIT_CHANGES_HOOK_TIMEOUT_MS="500")
    return [str(ROOT / "plugins/memory-notices/bin/changes-hook")], {"input": b"{}", "env": env}


def node_report(tmp):
    """crewkit node report on a node with the stub herdr (three agents) and a node state."""
    root = tmp / "nr"
    pstub, bindir, home = root / "pstub", root / "bin", root / "home"
    sess = pstub / "herdr" / "local" / "default"
    for d in (sess, bindir, home / ".local" / "state" / "crewkit" / "node"):
        d.mkdir(parents=True)
    (sess / "default").touch()
    (bindir / "herdr").symlink_to(ROOT / "tests" / "stubs" / "herdr")
    panes = [{"pane_id": f"w1:p{i}", "workspace_id": "w1", "tab_id": "w1:t1", "agent": "claude", "name": n,
              "agent_status": "idle", "tokens": {"role": r}, "cwd": "/work/project"}
             for i, (n, r) in enumerate((("lead", "lead"), ("bridge", "bridge"), ("worker", "worker")), 1)]
    (sess / "panes.json").write_text(json.dumps(panes))
    (pstub / "herdr.log").touch()
    state = {"schema": 1, "node_id": "n-abcdefg234", "name": "lab", "session": "default", "registry_id": "r-abcdefg234",
             "join_token_sha256": "a" * 64, "lead": "lead", "bridge": "bridge", "joined_at": "2026-10-27T00:00:00Z"}
    (home / ".local" / "state" / "crewkit" / "node" / "default.json").write_text(json.dumps(state))
    env = dict(os.environ, HOME=str(home), PSTUB=str(pstub), PATH=f"{bindir}:{os.environ['PATH']}")
    cmd = [str(ROOT / "bin" / "crewkit"), "node", "report", "--session", "default"]
    # Once before timing: a fast failure must not be measured as a fast report.
    r = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True)
    if r.returncode != 0 or json.loads(r.stdout)["schema"] != 1:
        raise SystemExit(f"crewkit-node-report scenario: the command fails: {r.stderr.strip()}")
    return cmd, {"cwd": root, "env": env}


def pane_ask_read(tmp):
    """The stub ssh and herdr from tests/stubs (herdr in a fake remote home), and pane-ask --read."""
    root = tmp / "pa"
    pstub, bindir = root / "pstub", root / "bin"
    for d in (pstub / "remote" / ".local" / "bin", bindir, root / "home"):
        d.mkdir(parents=True)
    (bindir / "ssh").symlink_to(ROOT / "tests" / "stubs" / "ssh")
    (pstub / "remote" / ".local" / "bin" / "herdr").symlink_to(ROOT / "tests" / "stubs" / "herdr")
    (pstub / "screen").write_text("".join(f"line {i}\n" for i in range(200)))
    (pstub / "ssh.log").touch()
    (pstub / "herdr.log").touch()
    (root / "home" / ".claude").mkdir()
    (root / "home" / ".claude" / "crewkit.md").write_text("---\nnodes.default: lab\nnodes.lab.host: agent-host\n---\n")
    env = dict(os.environ, HOME=str(root / "home"), PSTUB=str(pstub), PATH=f"{bindir}:{os.environ['PATH']}")
    return [str(ROOT / "plugins/crew-nodes/bin/pane-ask"), "--read", "wX:pY"], {"cwd": root, "env": env}


def land_batch_dry_run(tmp):
    """A bare origin with one green PR, the stub gh from tests/stubs, and land-batch's command."""
    root = tmp / "lb"
    stub, bare, work, bindir = root / "stub", root / "origin.git", root / "work", root / "bin"
    for d in (stub / "pr" / "11", stub / "ci", bindir, root / "home"):
        d.mkdir(parents=True)
    (bindir / "gh").symlink_to(ROOT / "tests" / "stubs" / "gh")
    genv = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
    sh = (f"git init -q --bare -b main '{bare}' && git clone -q '{bare}' '{work}' 2>/dev/null && cd '{work}' && "
          "echo a > a.txt && git add a.txt && git commit -qm init && git push -q origin HEAD:main && "
          "git checkout -qb pr11 && echo b > b.txt && git add b.txt && git commit -qm pr && "
          "git push -q origin HEAD:refs/pull/11/head && git rev-parse HEAD")
    head = subprocess.run(["bash", "-c", sh], env=genv, capture_output=True, text=True, check=True).stdout.strip()
    for name, value in (("state", "OPEN"), ("base", "main"), ("ref", "feature-11"), ("labels", ""),
                        ("draft", "false"), ("head", head)):
        (stub / "pr" / "11" / name).write_text(value + "\n")
    (stub / "ci" / head).write_text("success\n")
    env = dict(genv, HOME=str(root / "home"), STUB=str(stub), STUB_BARE=str(bare),
               PATH=f"{bindir}:{os.environ['PATH']}", CREWKIT_REPO="OWNER/REPO",
               CREWKIT_STATE_DIR=str(root / "state"), CREWKIT_HIGH_RISK_AREAS_CONFIRMED_BY="owner",
               CREWKIT_CI_WORKFLOW=".github/workflows/ci.yml")
    return [str(ROOT / "plugins/crew-orchestrator/bin/land-batch"), "11"], {"cwd": work, "env": env}


def main(argv):
    cfg = json.loads((ROOT / "perf-budgets.json").read_text())
    runs = int(cfg.get("runs", 20))
    if argv[:1] == ["--runs"] and len(argv) == 2 and argv[1].isdigit():
        runs = int(argv[1])
    elif argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    factor = headroom(cfg, os.environ)
    measured = measure(runs, trials(cfg))
    for name in SCENARIOS:
        budget = cfg["budgets"].get(name, {}).get("p95_ms", "?")
        print(f"  {name:30} p95 {measured[name]:7.1f} ms   budget {budget} ms")
    fails = over_budget(measured, cfg["budgets"], factor)
    for f in fails:
        print(f"FAIL {f}")
    print(f"perf: best of {trials(cfg)} trials of {runs} runs, headroom x{factor}: " + ("over budget" if fails else "within budget"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
