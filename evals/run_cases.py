"""Run eval cases once per arm and save each reply with the skills it loaded.

Usage: python3 -I evals/run_cases.py base|plugin <repo> <out dir> <empty run dir> <id,id,...>

Both arms: claude -p with no user/project settings, CLAUDE.md, memory or MCP, and only the
Skill tool. "plugin" adds every crewkit plugin and the rules fragment (as install.sh installs
it). --safe-mode is not usable here: it drops --plugin-dir. Uses Sonnet; each case is one
model call per arm. Check the output with evals/leakcheck.sh before sharing or committing it.
"""
import json, pathlib, subprocess, sys
mode, repo, out_dir, run_dir, ids = sys.argv[1], *map(pathlib.Path, sys.argv[2:5]), sys.argv[5].split(",")
if mode not in ("base", "plugin"):
    sys.exit("usage: run_cases.py base|plugin <repo> <out dir> <run dir> <ids>")
cases = {c["id"]: c for c in json.loads((repo / "evals/cases.json").read_text())["cases"]}
out_dir.mkdir(parents=True, exist_ok=True)

# A fake shared-memory index, so memory-notices never shows this machine's real notes: its
# shared-index hook reads CLAUDE_MEMSYNC_DIR, and a silent claude-memsync stub first on PATH
# turns the change-notice hook into a no-op. Both arms get the same environment.
import os, tempfile
fake = pathlib.Path(tempfile.mkdtemp(prefix="crewkit-eval-"))
(fake / "sync" / "distilled").mkdir(parents=True)
for slug, desc in [("deploy-freeze", "When deploys are frozen and who can lift a freeze"),
                   ("review-before-merge", "Every PR gets an independent review before it lands"),
                   ("on-call-contacts", "How to reach the owner for urgent decisions")]:
    (fake / "sync" / "distilled" / f"{slug}.md").write_text(
        f"---\nname: {slug}\ndescription: {desc}\n---\n\nExample note for evals.\n")
(fake / "bin").mkdir()
(fake / "bin" / "claude-memsync").write_text("#!/bin/sh\nexit 0\n")
(fake / "bin" / "claude-memsync").chmod(0o755)
env = dict(os.environ, CLAUDE_MEMSYNC_DIR=str(fake / "sync"),
           PATH=f"{fake / 'bin'}:{os.environ['PATH']}")
for cid in ids:
    c = cases[cid]
    prompt = (f"Context: {c['context']}\n\n{c['prompt']}\n\n"
              "This is a dry run: don't run commands. Say exactly what you would do next and "
              "which commands you would run, in order.")
    cmd = ["claude", "-p", "--model", "sonnet", "--no-session-persistence", "--setting-sources", "",
           "--strict-mcp-config", "--tools", "Skill", "--output-format", "stream-json", "--verbose"]
    if mode == "plugin":
        for plugin in sorted((repo / "plugins").iterdir()):   # every crewkit plugin, as installed
            if (plugin / ".claude-plugin" / "plugin.json").is_file():
                cmd += ["--plugin-dir", str(plugin)]
        cmd += ["--append-system-prompt-file", str(repo / "plugins/agent-practice/rules/CLAUDE-fragment.md")]
    r = subprocess.run(cmd + ["--", prompt], cwd=run_dir, env=env, capture_output=True, text=True, timeout=400)
    result, skills = "", []
    for line in r.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "assistant":
            for block in ev["message"].get("content", []):
                if block.get("type") == "tool_use" and block.get("name") == "Skill":
                    skills.append(block.get("input", {}).get("skill") or block.get("input", {}).get("command"))
        if ev.get("type") == "result":
            result = ev.get("result", "")
    (out_dir / f"{cid}.txt").write_text(f"skills used: {skills}\n\n{result}\n" + (f"\n[exit {r.returncode}]\n{r.stderr[-2000:]}" if r.returncode else ""))
    print(cid, r.returncode, skills, len(result), flush=True)
