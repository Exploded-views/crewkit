#!/usr/bin/env python3
"""check-watcher-settings.py: prove a public-repo watcher's settings.json allows no write tool.

Usage: tools/check-watcher-settings.py SETTINGS.json OWNER/REPO...

A watcher reads text strangers wrote, so it must not be able to change anything. Every
`permissions.allow` entry must be one of: a read-only or messaging tool (Read(...), Skill(loop),
CronCreate, CronList, CronDelete, ScheduleWakeup, SendMessage, ListAgents), Bash(date*), or
Bash(<path>/public-watch --since *), Bash(crewkit watchline repo *) or Bash(crewkit watchline log *). A raw `gh api` allow is refused even for a listed repository:
gh's flags can be bundled (-iXPOST), so no deny pattern can be sure to catch a write; public-watch
runs fixed GET-only argv instead. defaultMode, at the top level or under permissions, may only be
absent, default or plan.
`permissions.deny` must hold every entry in REQUIRED_DENY: the editing and web tools, gh api's
method, field, input and header flags, gh's and git's writing commands, and herdr and ssh (no
typing into another session, no other machine). Prints one line per
problem.

Exit 0 = read-only, 1 = a problem, 2 = usage or an unreadable file.
"""
import json
import re
import sys

SAFE = {"Skill(loop)", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup", "SendMessage",
        "ListAgents", "Bash(date*)"}
REQUIRED_DENY = [
    "Edit", "Write", "NotebookEdit", "WebFetch",
    "Bash(gh api -X*)", "Bash(gh api * -X*)", "Bash(gh api --method*)", "Bash(gh api * --method*)",
    "Bash(gh api * -f*)", "Bash(gh api * -F*)", "Bash(gh api * --field*)", "Bash(gh api * --raw-field*)",
    "Bash(gh api * --input*)", "Bash(gh api * -H*)", "Bash(gh api * --header*)",
    "Bash(gh issue*)", "Bash(gh pr*)", "Bash(gh release*)", "Bash(gh workflow*)", "Bash(gh run*)",
    "Bash(gh label*)", "Bash(gh repo*)", "Bash(gh secret*)", "Bash(git*)", "Bash(curl*)", "Bash(*>*)",
    "Bash(herdr*)", "Bash(ssh*)",
]
READ_RE = re.compile(r"\ARead\([^*?]+\)\Z")
WATCH_RE = re.compile(r"\ABash\(/[^ *?]*/public-watch --since \*\)\Z")
# A watcher may write fixed-field lines, never run `watchline check` (the orchestrator's side).
WATCHLINE_RE = re.compile(r"\ABash\(crewkit watchline (repo|log) \*\)\Z")


def problems(settings, repos):
    if not isinstance(settings, dict) or not isinstance(settings.get("permissions", {}), dict):
        return ["the settings and their permissions must be JSON objects"]
    perms = settings.get("permissions", {})
    allow, deny = perms.get("allow", []), perms.get("deny", [])
    if not isinstance(allow, list) or not isinstance(deny, list):
        return ["permissions.allow and permissions.deny must be lists"]
    out = []
    for a in allow:
        if not isinstance(a, str):
            out.append(f"allow: not a string: {a!r}")
        elif a.replace(" ", "").startswith("Bash(gh"):
            out.append(f"allow: {a} runs gh directly (bundled flags can write); allow public-watch instead")
        elif not (a in SAFE or READ_RE.match(a) or WATCH_RE.match(a) or WATCHLINE_RE.match(a)):
            out.append(f"allow: {a} can write, or isn't a read-only tool")
    for d in REQUIRED_DENY:
        if d not in deny:
            out.append(f"deny: missing {d}")
    for where, mode in (("defaultMode", settings.get("defaultMode")), ("permissions.defaultMode", perms.get("defaultMode"))):
        if mode not in (None, "default", "plan"):
            out.append(f"{where}: {mode!r} lets tools run without the allow list")
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        with open(argv[0]) as f:
            settings = json.load(f)
    except (OSError, ValueError) as e:
        print(f"check-watcher-settings: can't read {argv[0]} ({e.__class__.__name__})", file=sys.stderr)
        return 2
    found = problems(settings, argv[1:])
    for p in found:
        print(p)
    print(f"check-watcher-settings: {'read-only' if not found else f'{len(found)} problem(s)'}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
