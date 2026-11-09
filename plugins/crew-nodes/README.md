# crew-nodes

Cross-node tooling for a crew of Claude Code sessions spread over several machines (nodes),
layered over [herdr](https://github.com/herdrdev/herdr). It is a preview, in development: this
release has `pane-ask`. `install.sh` installs it with the other plugins (or
`claude plugin install crew-nodes@crewkit` does).

[cross-node.md](cross-node.md) is the model around it: nodes, the hub, bridges and the outbox,
who may say what across machines, and what keeps working when a machine is off.

The scripts need bash, `jq`, `ssh` and herdr. Settings come from crewkit's settings files
([docs/settings.md](../../docs/settings.md#nodes)); nothing names a host, pane or person.

## Before the first run

Inputs, per node, in `~/.claude/crewkit.md` (or a project's `.claude/crewkit.md`). Every
`nodes.*` key is file-only: `CREWKIT_*` can't change where pane-ask connects or which sessions it
refuses.

```text
---
nodes.default: <node name>
nodes.<node name>.machine: <saved herdr machine label>   # or, without a profile:
nodes.<node name>.host: <ssh target>
nodes.<node name>.herdr: ~/.local/bin/herdr               # herdr's path there, over ssh
nodes.<node name>.bridge: <agent name or pane id>         # who pane-ask talks to by default
nodes.<node name>.lead_pane: <agent name or pane id>, ... # never typed into
nodes.prefix: <your session's name>
---
```

- `machine` is preferred when the node has a saved herdr machine profile (`herdr machine list
  --json` lists them): pane-ask then runs `herdr --machine <label>` locally, which needs herdr
  0.9.1 or later on both machines. Without one, it uses ssh to `host` and runs herdr there by its
  path, since a non-interactive ssh shell usually doesn't have it on `PATH`.
- `bridge` is the session on the node set up to receive messages from other nodes.
- `lead_pane` lists the node's lead sessions, which only their owner types into, separated by
  commas or spaces. pane-ask refuses a target on the list as typed and as `herdr agent get` resolves it: its
  `pane_id`, and its `name` when it has one (not `agent`, which is the agent's kind, such as
  `claude`). Case is ignored. So a lead listed by id can't be reached by name, or the reverse.
- Every `nodes.*` key is read only from `~/.claude/crewkit.md`: a project's settings files and
  `CREWKIT_*` can't change them.

## pane-ask

```bash
pane-ask "status of the export?"               # this host's bridge to the node's bridge: "NAME: ...", wait, print the reply
pane-ask --node agent-host --timeout 600 "..." # the same, to a named node's bridge
pane-ask --read --lines 120                    # print the other bridge's tail; sends nothing
```

`--host SSH_TARGET` and `--machine LABEL` must match a configured node's `host` or `machine`
(with these, a `lead_pane` of any node is refused).

**Bridge to bridge only.** agent-practice's rule is SendMessage only, never typing into another
session through herdr (its `herdr` skill): text typed into a session reads as if its owner wrote
it. That rule stands. Across hosts, `SendMessage` can't reach, so `pane-ask` carries one message,
labelled with the sender's name so the receiving session can tell it from its owner's input,
and only between bridges:

- The caller must be this host's bridge (the `bridge` of a node marked `nodes.<name>.this_host: true`;
  a host may have several), and the target must be the other node's configured bridge
  (`nodes.<name>.bridge`). Anything else is refused with exit 45, before the node is called.
  `--read` follows the same rule; a `--status` read, when it exists, is read-only and exempt.
- A host with several herdr sessions has several nodes marked `this_host`; each then needs
  `nodes.<name>.session`, which selects the local herdr session and tells which node a caller is in
  (`HERDR_SESSION`). Without it pane-ask exits 78 for a local target, and 45 for a caller.
- A session that is not a bridge sends to its own host's bridge with `SendMessage`; the bridge
  relays. Spokes' bridges prompt each other directly; nothing prompts the hub's bridge from another
  node, because the hub only reaches out (it pulls spokes' outboxes).
- On one host, sessions use `SendMessage`, never `pane-ask`. The one local case is a watch
  daemon waking its own host's bridge pane, with ids and counts, never item text: a caller with
  no `HERDR_PANE_ID` in its environment (in no herdr pane), sending to the bridge of a local node.
  Every other local target is refused (exit 45), and so is a local send from a caller that is
  in a pane.

**This is a guard rail, not enforcement.** The caller is judged by `HERDR_PANE_ID`, an
environment check: it stops accidents, not a determined caller. A caller can claim another pane,
and any session can unset the variable. Real enforcement waits on a herdr feature (access
control).

It is a thin wrapper over herdr's agent commands, which do the hard part:

1. `herdr agent get`: an agent whose status isn't in `nodes.idle_statuses` (default
   `idle,done`) is busy. `blocked` (a dialog waiting for its owner) is refused at once; another
   busy state is waited for with `herdr agent wait` (or refused at once with
   `nodes.wait_idle: false`). Still busy: exit 75, nothing sent.
2. `herdr agent prompt <target> "NAME: MESSAGE" --wait --timeout <ms>`, once. herdr pastes the
   text and Enter in one submission, refuses a blocked agent (`agent_blocked`), and waits for the
   agent to go working and settle again; it returns `agent_prompt_stalled` when no activity shows
   within five seconds, and `timeout` when the wait runs out.
3. `herdr agent read <target> --source recent-unwrapped --lines <nodes.scan_lines>`, printed from
   the last line holding the message's first 40 characters on.

**A timeout does not prove the message wasn't delivered.** pane-ask never sends a message twice,
and neither should you: after exit 40 (or a failed send, exit 1), read the target with `--read`
before deciding anything.

Over ssh the message travels on stdin, not on the ssh command line, and the herdr path and other
arguments are single-quoted for the remote shell, so quotes, `$`, backticks and newlines arrive as
they are and nothing in them runs on the node. The ssh target, machine label and target must not
start with `-`; ssh runs with `BatchMode=yes`, so it never waits at a password prompt.

**The node's login shell must be POSIX-like** (sh, bash, dash, zsh, ksh): sshd runs the remote
command through it, and pane-ask's quoting is POSIX single-quoting. fish and csh read a backslash
inside single quotes differently, so pane-ask refuses a `nodes.<name>.herdr` that holds one
(exit 78).

**Where the message is visible.** herdr takes the prompt only as a command-line argument
(`herdr agent prompt <target> <text>`; it has no stdin form). So the message is not in the local
`ssh` command's arguments, but on the node it is in the argv of the `herdr agent prompt` process,
and with a machine profile it is in the argv of the local `herdr --machine` process: other users
of that machine can see it with `ps` while the turn runs. Don't send secrets with pane-ask.

The wait costs the calling session nothing: it is one shell command, blocked until herdr returns.

### herdr versions

- `herdr agent prompt --wait` with the activity check pane-ask relies on: 0.9.0 or later on the
  node (`agent_blocked` came in 0.8.2, `agent_prompt_stalled` in 0.7.5; 0.9.0 made the wait
  require observed activity). An older herdr refuses `--wait` and pane-ask says so (exit 1).
- A saved machine profile (`--machine`): 0.9.1 or later on both machines.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | The turn settled; the reply is printed (or `--read` printed the tail). | Nothing. |
| 1 | An ssh or herdr call failed. | Read the message. If the send failed, read the target before sending again. |
| 40 | `timeout` or `agent_prompt_stalled`: no settled reply in time. The message may have been delivered. | Don't resend. `pane-ask --read` later. |
| 41 | The turn ended at an approval or question dialog (`blocked`); the screen is printed. | Tell the node's owner; don't answer it through herdr. |
| 45 | NOT-A-BRIDGE: the caller isn't this host's bridge, the target isn't the node's bridge, or the target is on this host and the local rule doesn't allow it. The message says which; nothing was called. | On one host use `SendMessage`; across hosts send from your host's bridge. |
| 64 | Usage. | Fix the command. |
| 65 | The target is a lead pane (`nodes.<name>.lead_pane`); nothing sent. | Talk to the node's bridge instead. |
| 75 | The agent was busy or blocked and stayed so; nothing sent. | Try again later. |
| 78 | A setting is missing or invalid. | Fix the setting the message names. |

The codes are also in [docs/exit-codes.md](../../docs/exit-codes.md).

## Settings

`nodes.default`, `nodes.<name>.this_host`, `nodes.<name>.machine`, `nodes.<name>.host`, `nodes.<name>.herdr`,
`nodes.<name>.bridge`, `nodes.<name>.lead_pane`, `nodes.local_herdr`, `nodes.prefix`,
`nodes.timeout_seconds`, `nodes.wait_idle`, `nodes.idle_statuses`, `nodes.read_lines`,
`nodes.scan_lines`, and `orchestrator_name` (the prefix's default). Every `nodes.*` key is read
only from `~/.claude/crewkit.md`. Defaults and meanings are in
[docs/settings.md](../../docs/settings.md#nodes).

## Status

| Piece | State |
|---|---|
| `pane-ask` | In this release (preview). |
| A bridge skill: running the session on a node that receives other nodes' messages | Planned. |
| A lead skill: a node's lead session working with its bridge | Planned. |
| A PreToolUse guard that refuses `herdr pane run`, `send-text` and `send-keys` aimed at a `lead_pane` from settings (a guard against mistakes, not a security boundary) | Planned. |
| An outbox helper | Planned. |
| Bridge and remote-lead templates | Planned. |
| A bootstrap-a-spoke checklist (setting up a new node) | Planned. |

## Checks

The checks are the repo's own; see [crew-orchestrator's list](../crew-orchestrator/README.md#checks)
and [docs/testing.md](../../docs/testing.md). pane-ask's suite is `tests/pane-ask.bats`, with stub
ssh and herdr (`tests/stubs/`); its mutants are in `tests/mutants/pane-ask.json`.
