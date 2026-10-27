# crewkit

Tools and practices for running a crew of Claude Code sessions against one repo, one `main`
and one host, with one session (the Orchestrator) coordinating the rest. They came out of running a team
like that day to day.

crewkit is the front door: a plugin marketplace, an installer, and the docs that tie the
pieces together. Some pieces live here; the binaries live in their own repos and crewkit
installs pinned releases of them.

## Status

0.1.0, a first draft. It holds the `agent-practice` and `memory-notices` plugins, two
previews in development that the installer doesn't install (`crew-lanes`, and `crew-orchestrator`
with `land-batch`), and the tested installer ([docs/install.md](docs/install.md)): a dry run by default, every
download checked against a sha256 pin and the release's own checksum file, and each binary's
version checked before it is used. It pins bitc v0.1.0 and claude-memsync v0.3.0-ev.1 for
Linux and macOS, amd64 and arm64. Settings are in [docs/settings.md](docs/settings.md) and
exit codes in [docs/exit-codes.md](docs/exit-codes.md).

## Pieces

| Piece | What it is | Where | State |
|---|---|---|---|
| **agent-practice** | Claude Code plugin: skills plus an always-on rules fragment for messaging and approvals, the Orchestrator, landing, independent review, host safety, secret-safe checks, crash recovery, herdr and bitc. | [plugins/agent-practice](plugins/agent-practice/) | Draft |
| **memory-notices** | Claude Code plugin: hooks for the shared memory index at session start and notices when a memory note changed on another machine, plus the `using-memsync` skill. Needs claude-memsync. | [plugins/memory-notices](plugins/memory-notices/) | Draft |
| **claude-memsync** | Syncs Claude Code memory across machines through a private git repo. | Upstream [MarimerLLC/claude-utils](https://github.com/MarimerLLC/claude-utils), installed from a pinned release of a fork. | v0.3.0-ev.1 (pre-release), pinned |
| **crew-lanes** | Claude Code plugin: a worktree and branch per lane, campaign state, review verdicts, paced GitHub writes and a gated lander. | [plugins/crew-lanes](plugins/crew-lanes/) | Preview, in development (M1) |
| **crew-orchestrator** | Claude Code plugin: the coordinating session's batch lander (`land-batch`) and the skill for running it. | [plugins/crew-orchestrator](plugins/crew-orchestrator/) | Preview, in development (M2) |
| **bitc** | Host slot pool runner: queues heavy commands, enforces a memory floor, optional remote providers with a spend cap. | Its own repo, installed from a pinned release. | v0.1.0, pinned. On macOS, local pools only. |
| **rtk** | CLI proxy that shortens command output before it reaches the model. | Upstream [rtk-ai/rtk](https://github.com/rtk-ai/rtk) | Recommended, installed separately |

## Getting started

### Inputs

- `CREWKIT_REPO` = `<owner/repo>`: the GitHub repo you install crewkit from (this one, or your
  fork).
- `CREWKIT_DIR` = `$HOME/<directory to clone into>`: where your clone of crewkit will live,
  under your home directory (written with `$HOME`, because a `~` inside quotes isn't
  expanded). Keep it; the plugin marketplace points at it.

#### Already set, for reference (no action needed)

- The installer dry-runs unless you pass `--yes`, so the first run only prints its plan.
- The marketplace is named `crewkit`, and its plugins are `agent-practice` and
  `memory-notices`.

### Steps

Set your inputs once:

```bash
CREWKIT_REPO="<owner/repo>"
CREWKIT_DIR="$HOME/<directory to clone into>"
```

Clone, look at the plan, then run it:

```bash
git clone "https://github.com/$CREWKIT_REPO.git" "$CREWKIT_DIR"
crewkit_install() { "$CREWKIT_DIR/install.sh" "$@"; }
crewkit_install          # dry run: prints every step, changes nothing
crewkit_install --yes    # do it, once the plan looks right
```

The installer fetches the pinned bitc and claude-memsync releases for your OS and
architecture, refuses any download whose sha256 doesn't match its pin, runs claude-memsync's
bootstrap, then installs the plugins from this repo's marketplace. See [docs/install.md](docs/install.md) for every step,
flag and exit code, and [docs/getting-started.md](docs/getting-started.md) for a first
session, [docs/settings.md](docs/settings.md) for every setting, and
[docs/exit-codes.md](docs/exit-codes.md) for the shared exit codes.

To install only the plugins, from the same clone:

```bash
claude plugin marketplace add "$CREWKIT_DIR"
claude plugin install agent-practice@crewkit
claude plugin install memory-notices@crewkit
```

Or in a session: `/plugin marketplace add` with your `CREWKIT_DIR`, then pick the plugins in
the `/plugin` panel. Then include the rules fragment and set your values, as
[docs/getting-started.md](docs/getting-started.md) describes.

## rtk

rtk rewrites shell commands (for example `git status` to `rtk git status`) through a
`PreToolUse` hook on the `Bash` tool, and filters their output. `rtk gain` shows how
many tokens it has saved you.

Alongside other `PreToolUse` hooks:

- Claude Code runs every matching hook for a tool call, independently. Give rtk its own entry
  with `"matcher": "Bash"`, and keep guard hooks as separate entries rather than chaining them
  in one script.
- Write guard hooks to judge the command as Claude wrote it, not rtk's rewritten form. A deny
  from any hook stops the call. Check the hooks docs for your Claude Code version if you
  depend on ordering.
- Allow `Bash(rtk *)` in your permissions if you use auto mode, so the rewritten commands are
  judged like the originals.
- Use `rtk proxy <cmd>` when you need unfiltered output.

## Repo layout

| Path | What |
|---|---|
| `.claude-plugin/marketplace.json` | The `crewkit` plugin marketplace. |
| `plugins/agent-practice/` | The practice plugin: `skills/`, `rules/`, settings example. |
| `plugins/memory-notices/` | The memory notices plugin: `hooks/`, `bin/`, `skills/`. |
| `install.sh`, `pins/` | The installer and the release pins it checks downloads against. |
| `perf-budgets.json`, `tools/perf.py` | p95 budgets for the hot paths (memory-notices hooks, installer re-runs), checked in CI. |
| `tests/`, `coverage-floors.json` | bats tests for the installer, unit tests for the tools, and the coverage floors. See [docs/testing.md](docs/testing.md). |
| `docs/` | Setup and reference guides, settings, exit codes and testing. |
| `evals/` | Prompts that test the skills' behaviour, with what should and shouldn't happen. |
| `tools/scrub.sh` | Pre-commit scrub: secrets, personal data, a private denylist. Prints counts and file names only. |
| `tools/lint-skills.py` | Checks skill frontmatter, manifests, hooks, eval cases, pins and relative links. |
| `tools/mutate.sh`, `tools/coverage.sh`, `tools/coverage-floors.py` | Mutation check, coverage under kcov, and the coverage ratchet. |
| `docs/exit-codes.md` | One exit-code table for every crewkit script. |
| `docs/review-verdicts.md` | Where verdicts come from, the verdict-record format, and the rules a lander applies. |
| `docs/campaign-state.md`, `tests/fixtures/` | The lanes' shared state schema, and fixtures shared by the writers' and readers' tests. |
| `lib/settings.sh`, `docs/settings.md` | The one settings reader every script sources, and its schema. See [docs/settings.md](docs/settings.md). |
| `tools/check-workflows.py` | Workflow lint: GitHub-hosted runners only, no `pull_request_target`, actions pinned by SHA, macOS jobs guarded off while the repo is private. One self-contained file other repos can vendor. |
| `.pre-commit-config.yaml`, `tools/install-hooks.sh` | Two ways to run the scrub and lint before each commit. |
| `.github/workflows/ci.yml` | CI: scrub (secret rules), lint, markdown lint, shellcheck, an installer dry run, tests, mutation check, coverage ratchet. |

## Contributing

- Run `tools/install-hooks.sh` (or `pre-commit install`) once.
- Keep a private denylist of terms that must never appear (client, product and people's
  names, internal hosts) outside the repo, and point `SCRUB_DENYLIST` at it. The default path
  is `~/.config/crewkit/denylist.txt`.
- No client names, hostnames, people's names, emails or incident details in skills. Cite
  lessons by number as placeholder links instead.
- Keep each `SKILL.md` under about 150 lines, written for Claude: steps, checks, red flags.
- Every change ships with its docs, and docs use placeholders only.
- Setup pages put **Inputs first**: one bullet per value the reader fills,
  `` `NAME` = `<placeholder>` `` with a one-line description, then "Already set" defaults. Steps
  set each input once (`NAME="<placeholder>"`) and then use only `$NAME`; a long value appears
  once; a command run twice (dry run, then real) is a shell function called with the flag
  that differs.
  `tools/lint-skills.py` checks this on the README, `docs/install.md` and
  `docs/getting-started.md`.

See [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md). Licence: [MIT](LICENSE).
