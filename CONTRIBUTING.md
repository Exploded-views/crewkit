# Contributing

## Before your first commit

- Run `tools/install-hooks.sh` (or `pre-commit install`) once, from the clone or any of its
  worktrees: the hook is shared by all of them. It refuses when this clone sets its own
  `core.hooksPath` (`git config --local`); a global one, such as the push-gate dispatcher,
  chains to the clone's hooks.
- The hook runs markdownlint-cli2 (pinned, with the repo's config) on staged Markdown through
  `npx`, so contributors who change docs need Node.js. Without `npx`, a commit with staged
  Markdown is refused; one without Markdown doesn't need it.
- Keep a private denylist of terms that must never appear (client, product and people's
  names, internal hosts) outside the repo, and point `SCRUB_DENYLIST` at it. The default path
  is `~/.config/crewkit/denylist.txt`.

## Rules for changes

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
- Write the test first. [docs/testing.md](docs/testing.md) covers the suites, the RED records,
  mutation checks, coverage floors and performance budgets.

## Repo layout

| Path | What |
|---|---|
| `.claude-plugin/marketplace.json` | The `crewkit` plugin marketplace. |
| `plugins/agent-practice/` | The practice plugin: `skills/`, `rules/`, settings example. |
| `plugins/memory-notices/` | The memory notices plugin: `hooks/`, `bin/`, `skills/`. |
| `plugins/crew-lanes/`, `plugins/crew-orchestrator/`, `plugins/crew-nodes/` | The preview plugins: lanes, the Orchestrator's lander, cross-node tooling. |
| `install.sh`, `pins/` | The installer and the release pins it checks downloads against. |
| `perf-budgets.json`, `tools/perf.py` | p95 budgets for the hot paths (memory-notices hooks, installer re-runs), checked in CI. |
| `tests/`, `coverage-floors.json` | bats tests for the installer and plugins, unit tests for the tools, and the coverage floors. See [docs/testing.md](docs/testing.md). |
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
| `.pre-commit-config.yaml`, `tools/install-hooks.sh` | Two ways to run the scrub, the lint and markdownlint (`tools/lint-markdown.sh`) before each commit. |
| `.github/workflows/ci.yml` | CI: scrub (secret rules), gitleaks over every commit (`tools/secrets-scan.sh`, the pinned build), lint, markdown lint, shellcheck, an installer dry run, tests, mutation check, coverage ratchet. |

See also [SECURITY.md](SECURITY.md) and [CHANGELOG.md](CHANGELOG.md).
