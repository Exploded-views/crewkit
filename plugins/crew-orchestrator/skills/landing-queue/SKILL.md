---
name: landing-queue
description: >-
  Run and read crew-orchestrator's landers (land-batch now; merge-when-green, wait-release-quiet
  and land-when-ready as they ship): what each exit code means (0, 2, 7, 8, 9, 10, 12, 20, 64,
  75, 78), dry run before --yes, high-risk PRs, owner gates and partial landings. Use this
  whenever you are about to run a lander, whenever you read or are told a lander's exit code or
  output (even just "it exited 20"), when someone says "land these", "batch them" or "merge
  when green", and before you would run `gh pr merge` by hand on a PR a lander could take.
---

# Landing queue

The landers do the mechanical part of landing: pinning heads, re-checking, ordering and
verifying. What "green" means, the ready/go/merged handshake, and who may land what are in
agent-practice's `landing` and `orchestrator` skills; follow those first. This skill is about
running the tools and reading what they say.

## Settings

Read through `lib/settings.sh`; the keys are in crewkit's `docs/settings.md`. The plugin README
lists the ones each lander uses. Two must be right before anything lands:

- `high_risk_areas.*`, confirmed by the human (`high_risk_areas.confirmed_by`). Without it,
  `land-batch` exits 78. Don't set `confirmed_by` yourself: it records the human's
  confirmation, and is never your own guess.
- `review.source`. Use `records` when every agent posts to GitHub as one account.

## Land a batch

1. **Dry run.** `land-batch PR...` with no `--yes` prints each PR's eligibility and the plan,
   and changes nothing. Read every skip reason before going on.
2. **Land.** `land-batch --yes PR...`. Run it in the foreground or detached with its log; don't
   wrap it in your own retry loop. If another lander holds the lock it waits up to
   `lock_wait_seconds`, then exits 75. `--lock-wait 0` makes it fail at once.
3. **Read the exit code**, not just the last line. 0 means everything landed; 20 means some
   did, and the summary names what was skipped, dropped or a culprit. The full table is in the
   plugin README.

## High-risk PRs

A PR that touches a high-risk area is never batched. `land-batch` lands it alone, after the
batch, and only with an independent verdict for its **exact head SHA** (a verdict record, or an
allow-listed reviewer's comment, per `review.source`), written by `review_model` (a comment
verdict says so with `model=<model>` on its line). If its head moves, the verdict no longer
counts: it needs a new review on the new head. Never write or edit a verdict record or
comment yourself to get a PR through.

## When it stops

- **75:** try again later (lock busy, CI not finished, a network step failed). Re-run as it is.
- **7 or 9:** main or a PR moved under it. Re-run; it rebuilds from scratch.
- **12, or any "PARTIAL LANDING" line:** main now holds a combination nobody tested. Stop
  landing, tell the coordinator what landed and what didn't (both are in
  `<state_dir>/landing.log`), and let CI on main run before anything else lands.
- **10:** branch protection requires up-to-date branches. That is the owner's setting. Report
  it; don't work around it.
- **78:** a setting is missing or invalid; the message names it.

Never fall back to merging by hand to get past a lander's refusal: the refusal is the check
doing its job. If you think it is wrong, report the PR, the exit code and the message to the
coordinator.
