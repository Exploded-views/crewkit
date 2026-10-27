# memory-notices

A Claude Code plugin on top of claude-memsync: two hooks, and the
[using-memsync](skills/using-memsync/SKILL.md) skill (a draft covering the stable parts:
reading shared notes, where new ones go, read-only health checks, and which commands are the
owner's).

| Hook | What it does |
|---|---|
| `SessionStart` | `bin/shared-index` prints a compact index of the shared (distilled) memory notes, names and file names only, as context for the new session. It never prints note bodies, stays under about 9,000 characters, and always exits 0. Notes come from other machines, so a name is shown only if it is a slug (otherwise the file stem), and a note with an unsafe file name is skipped and counted. |
| `SessionStart`, `UserPromptSubmit` | `claude-memsync changes --hook` tells the session which memory notes changed on another machine since it last looked. |

## Needs

- `claude-memsync` on your `PATH`, set up and syncing. Without it the change-notice hooks do
  nothing, and only the index runs.
- `python3` for `bin/shared-index`.

## Where it reads

`shared-index` finds the personal sync directory from claude-memsync's `routes.json`
(`$XDG_CONFIG_HOME/claude-memsync/routes.json`), falling back to `~/.claudesync`. Set
`CLAUDE_MEMSYNC_DIR` to override it. It reads `<sync dir>/distilled/*.md` frontmatter.

## Install

```bash
claude plugin install memory-notices@crewkit
```
