# Getting started

This walks through a first crew: one Orchestrator session and one worker on the same repo
and host. It assumes you ran [install.sh](install.md), or at least installed the plugins.

## Inputs

- `OWNER_NAME` = `<your name>`: the human with final authority, as sessions should address you.
- `ORCHESTRATOR_NAME` = `<orchestrator session name>`: the coordinating session's name, as
  `ListAgents` will show it (for example `orchestrator`).
- `REPO` = `<owner/repo>`: the GitHub repo the crew works on.

### Already set, for reference (no action needed)

- Every other setting has a default; the
  [agent-practice README](../plugins/agent-practice/README.md#settings) lists them.
- `install.sh` already copied the rules fragment to `~/.claude/rules/agent-practice.md`.

## 1. Set your values

Set your inputs once, then write your user settings file. If `~/.claude/agent-practice.md`
already exists, the snippet leaves it alone and you edit those three keys in it instead.

```bash
OWNER_NAME="<your name>"
ORCHESTRATOR_NAME="<orchestrator session name>"
REPO="<owner/repo>"
```

```bash
SETTINGS="$HOME/.claude/agent-practice.md"
if [ -e "$SETTINGS" ]; then
  echo "$SETTINGS exists; edit owner_name, orchestrator_name and repo in it instead"
else
  mkdir -p "$(dirname "$SETTINGS")"
  cat > "$SETTINGS" <<EOF
---
owner_name: "$OWNER_NAME"
orchestrator_name: $ORCHESTRATOR_NAME
repo: $REPO
---
EOF
fi
```

For one project only, write the same keys to `.claude/agent-practice.local.md` in that repo
(git-ignored) instead. The project file wins. The full list of keys, with comments, is in
[settings.example.md](../plugins/agent-practice/settings.example.md).

## 2. Include the rules fragment

The plugin's skills load on demand, but some rules must apply even when no skill has loaded.
`install.sh` copies the fragment to `~/.claude/rules/agent-practice.md`. If you installed the
plugins by hand, copy
[rules/CLAUDE-fragment.md](../plugins/agent-practice/rules/CLAUDE-fragment.md) there yourself.

## 3. Start the Orchestrator

Start a session in a durable directory (not `/tmp`), name it `$ORCHESTRATOR_NAME`,
and tell it it is the Orchestrator. The `orchestrator` skill takes it from there: the
decisions log, the state file, and how it starts and briefs other sessions.

## 4. Start a worker

Ask the Orchestrator to start one, or start one yourself with a short brief that names the
Orchestrator. Workers report to it with `SendMessage`; the `cross-session-messaging` skill
covers what a relayed approval must quote and what no relay can approve.

## 5. Optional pieces

- **memory-notices** shows each session the shared memory index and tells running sessions
  when a note changed on another machine. It needs claude-memsync set up first.
- **bitc** gives the crew one shared slot pool for heavy commands. Set `pool_command` in your
  settings once it is installed.
- **rtk** shortens command output; see the [README](../README.md#rtk).
