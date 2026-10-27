# crew-orchestrator

Tooling for the coordinating (Orchestrator) session of a crew of Claude Code sessions: landers
that merge reviewed PRs with every check. It is a preview, in development: this release has
`land-batch` and the `landing-queue` skill, and `install.sh` doesn't install it
(`claude plugin install crew-orchestrator@crewkit` does). The practice behind them is in
agent-practice's `orchestrator`, `landing` and `cross-session-messaging` skills; this plugin's
`landing-queue` skill covers running the tools.

The scripts need bash 4.4 or later, `python3`, `gh`, `git`, `jq` and `flock` (util-linux). Stock macOS bash
is 3.2: run `brew install bash` and put it first on `PATH`; the landers stop (exit 78) on an older
bash rather than run with checks that could fail open. Settings come from crewkit's settings files ([docs/settings.md](../../docs/settings.md));
nothing names a repo, host, check or label.

## Before the first run

Inputs, once per project, in its committed `.claude/crewkit.md`:

```text
---
repo: OWNER/REPO
required_check: <aggregate check name>
ci.workflow: .github/workflows/<workflow file>
high_risk_areas.<area>.paths: "<glob>, <glob>"
high_risk_areas.confirmed_by: <who confirmed the list>
high_risk_areas.confirmed_on: <YYYY-MM-DD>
review.source: records
---
```

- Until `high_risk_areas.confirmed_by` is set, `land-batch` refuses to run (exit 78). The
  setup flow for choosing the areas is in [docs/settings.md](../../docs/settings.md).
- `review.source` decides what counts as an independent verdict for a high-risk PR:
  `records` (written by the review workflow) or `comments` (from a login in
  `review.reviewers`). If every agent posts to GitHub as one account, use `records`: a login
  can't tell the author from the reviewer then. With `comments`, only the PR's conversation
  comments count; a verdict written in a PR review's body is not read, so post it as a comment.
- `review_model` (default `opus`): a high-risk PR's verdict must come from that model. A record
  names it in `model`; a comment verdict carries `model=<model>` on its first line, as in
  `Verdict: MERGE <full head SHA> model=opus`. Matching ignores case and accepts a whole token, so
  `claude-opus-5-5` matches `opus`. It's read from settings files only, never from the
  environment. Set it empty in a settings file only to stop checking the model.
  The rules are in [docs/review-verdicts.md](../../docs/review-verdicts.md).
- `ci.workflow` (required) names the workflow whose runs carry `required_check`, so a check of
  the same name in another workflow can't vouch for a PR; `ci.event` (default `pull_request`)
  names the event those runs come from.
- The campaign state (owner gates, merge pause) is read from `<campaign_dir>/state.json`
  ([docs/campaign-state.md](../../docs/campaign-state.md)). Without the file there are no gates;
  a file that can't be read or isn't a JSON object holds every PR. A merge pause is honoured
  unless `land.honor_merge_pause` is `false`.

## land-batch

```bash
land-batch PR [PR ...]            # dry run: checks every PR and prints the plan
land-batch --yes PR [PR ...]      # lands them
land-batch --yes --lock-wait 0 PR # fail at once (exit 75) if another lander holds the lock
```

It squashes every eligible PR onto the main branch in a throwaway batch branch, opens it as a
non-draft PR labelled `labels.do_not_merge`, and waits for `required_check` there. When that's
green it squash-merges each PR in order, pinned with `--match-head-commit`, and checks after
every squash that main's new commit has the previous main as its parent and the tree the batch
tested. When it's red it reruns once if every failure is a known flake (`flakes_file`), and
otherwise bisects to the culprit.

A PR is eligible when it is open, not a draft, based on `main_branch`, not from a batch branch,
without a blocking label, not owner-gated while the owner is away, and green on its own head.
Green is decided by `lib/checks.py` and verdicts by `lib/verdict.py`, the implementations every
crewkit lander shares. It is an allow-list: the required check, every job of each workflow's
newest run and every commit status context must say `success`, except the names in
`ignored_checks`, and so must the run itself, unless every job that didn't succeed is ignored; a
skipped or neutral job blocks until it is named there. `ignored_checks` naming `required_check` is a config error (exit 78). A run that hasn't
listed its jobs, a read that fails, a job list mixing attempts (the landers list jobs with
`filter=latest`) all leave a PR pending, never green; statuses beyond the ones read count by the
combined state (red when it is failure or error, pending otherwise). Just before the squashes,
each PR's own head is checked again, so a run or status that went red while the batch ran stops
the merge (exit 9). A GitHub App author (`app/<slug>`) counts as its comments' `<slug>[bot]`.
A PR that touches a `high_risk_areas` glob is never batched. It lands alone, after the batch,
and only with an independent verdict for its exact head. Every path the PR touches counts, both
sides of a rename included, and in a glob `*` matches across directories, so the rule errs
towards matching.

The landers read every setting from the main checkout of the repository they run in, from
whichever of its worktrees they are started, so a lane worktree's own `.claude/crewkit.local.md`
never applies to a landing (exit 78 if the main checkout can't be found). Run them inside the
project's repository: outside any repository, settings are read from the current directory up. Gate settings are file-only: `CREWKIT_*` can't change them
([settings](../../docs/settings.md)).

All the landers share one landing lock, `<state_dir>/locks/land.lock` (crew-lanes' `lane-land`
takes it too). Each run appends to `<state_dir>/landing.log` (merges, stops and the summary) and writes its
full output to `<state_dir>/logs/`. A partial landing (some PRs merged, then a stop) is reported
loudly in both, with what landed and what didn't.

## Exit codes

All the landers use these codes, following bitc's convention for 64, 75 and 78.

| Code | Meaning | What to do |
|---|---|---|
| 0 | Everything asked for landed (or the dry run found nothing wrong). | Nothing. |
| 2 | No PR was eligible. | Read the skip reasons. |
| 7 | The main branch moved under the lander. | Re-run; it rebuilds from the new main. |
| 8 | A squash failed. | Read the message; check the PR. |
| 9 | A PR changed or became ineligible between batching and merging. | Re-run. |
| 10 | Branch protection requires branches to be up to date. | The owner turns that off, or land another way. |
| 12 | After a squash, main's commit had the wrong parent or tree. | Stop and look at main before landing anything else. |
| 20 | Some landed; others were skipped, dropped or culprits. | Read the summary. |
| 64 | Usage error. | Fix the command. |
| 75 | Try again later: the landing lock is busy, CI didn't finish in `poll_max` polls, or a fetch, push or clone failed. | Re-run later. |
| 78 | Configuration: a required setting is missing or invalid, or the high-risk areas aren't confirmed. | Fix the setting the message names. |

## Settings

`repo`, `main_branch`, `checkout`, `required_check`, `min_green_checks`, `ignored_checks`,
`ci.noise_step_prefix`, `ci.workflow`, `ci.event`, `labels.do_not_merge`, `labels.awaiting_approval`,
`branch_prefix.batch`, `state_dir`, `campaign_dir`, `flakes_file`, `poll_seconds`, `poll_max`,
`merge_retries`, `stale_seconds`, `lock_wait_seconds`, `high_risk_areas.*`, `review.source`,
`review.reviewers`, `review.verdict_dir`, `review.markers`, `review.require_sha`, `review_model`,
`land.honor_merge_pause`. Defaults and meanings are in [docs/settings.md](../../docs/settings.md).

## Status

| Piece | State |
|---|---|
| `land-batch`, `lib/landing.sh`, the `landing-queue` skill, on the shared `lib/verdict.py` and `lib/checks.py` | In this release (preview). |
| `merge-when-green`, `wait-release-quiet`, `land-when-ready` | Planned. |
| `crew-log` and the `orchestrator-log` skill | Planned. |

## Checks

Every check below runs in CI. To run them locally, from the repo root:

```bash
tests/run.sh                                            # every bats suite
python3 -m unittest discover -s tests -p 'test_*.py'    # the Python tools' tests
python3 tools/lint-skills.py                            # skills, settings, links, the mutants matrix
python3 tools/check-workflows.py                        # hosted runners only, pinned actions
python3 tools/mutate.py tests/mutants/land-batch.json   # a mutation spec (one per file in tests/mutants)
python3 tools/perf.py                                   # performance budgets
tools/scrub.sh --require-denylist                       # private terms and secrets, before every push
```

Coverage runs only in CI (see [docs/testing.md](../../docs/testing.md)). Write every change test
first and record the failing run in [docs/tdd/](../../docs/tdd/). Every safety line gets a mutant,
and floors in `coverage-floors.json` only ever go up.
