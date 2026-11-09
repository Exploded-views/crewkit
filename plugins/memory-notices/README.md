# memory-notices

A Claude Code plugin on top of claude-memsync: two hooks, and the
[using-memsync](skills/using-memsync/SKILL.md) skill (a draft covering the stable parts:
reading shared notes, where new ones go, read-only health checks, and which commands are the
owner's).

| Hook | What it does |
|---|---|
| `SessionStart` | `bin/shared-index` prints a compact index of the shared (distilled) memory notes, names and file names only, as context for the new session. It never prints note bodies, stays under about 9,000 characters, and always exits 0. Notes come from other machines, so a name is shown only if it is a slug (otherwise the file stem), and a note with an unsafe file name is skipped and counted. |
| `SessionStart`, `UserPromptSubmit` | `bin/changes-hook` runs `claude-memsync changes --hook`, which tells the session which memory notes changed on another machine since it last looked. |

## Hook budget

These hooks run at every session start and every prompt, so each has a budget and a test that fails over it.

- `changes-hook` runs one `claude-memsync` at a time: a run that finds another still going exits 0 at once, printing nothing (a non-blocking `flock` where the host has one, otherwise a `mkdir` lock that is taken over when the PID it records is dead). The lock lives under `${XDG_STATE_HOME:-~/.local/state}/crewkit/memory-notices/`.
- It gives `claude-memsync` `CREWKIT_CHANGES_HOOK_TIMEOUT_MS` (default 2000) and then stops it, with the processes it started, by exact PID: TERM to its process group, KILL 200 ms later. A timeout prints nothing, exits 0, and adds one line to `changes-hook.log` there (at most one per minute). A normal run's output passes through unchanged, and the exit status is always 0.
- `shared-index` stops at `CREWKIT_SHARED_INDEX_TIMEOUT_MS` (default 2000) and prints the index it has by then. It reads only the notes directory, and only the first 4,000 bytes of each note, so what it reads does not depend on how big `$HOME` or `$TMPDIR` is.
- The harness's own 10 s limit stays in `hooks.json`, as a backstop far above these.

## Needs

- `claude-memsync` on your `PATH`, set up and syncing. Without it the change-notice hooks do
  nothing, and only the index runs.
- `python3` for `bin/shared-index`.
- `bash` for `bin/changes-hook` (macOS's stock 3.2 is enough).

## Where it reads

`shared-index` finds the personal sync directory from claude-memsync's `routes.json`
(`$XDG_CONFIG_HOME/claude-memsync/routes.json`), falling back to `~/.claudesync`. Set
`CLAUDE_MEMSYNC_DIR` to override it. It reads `<sync dir>/distilled/*.md` frontmatter.

## Install

```bash
claude plugin install memory-notices@crewkit
```
