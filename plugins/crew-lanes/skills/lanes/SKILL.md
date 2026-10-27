---
name: lanes
description: >-
  Run remediation lanes: one worktree and branch per lane, created with lane-new, worked test
  first, checked by gates and an independent review, and landed by a gated script. Use this when
  starting, resuming or inspecting a lane, when asked to fix a group of defects in parallel
  sessions, and before running any crew-lanes script.
---

# Lanes

A lane is one unit of remediation work: a packet of related issues, its own worktree and
branch, and a PR that lands only through the gated lander. crew-lanes is a preview, in
development (M1); this skill grows with each script.

## Settings

Read through `lib/settings.sh`; the keys are in crewkit's `docs/settings.md`. Uses `checkout`,
`main_branch`, `branch_prefix.lane`, `lane.worktree_dir`, `lane.note_dir`, `lane.setup_hook`,
`campaign_dir`, `lock_wait_seconds`, `repo`, `state_dir`, `gh_write.*`, and for landing
`required_check`, `ci.*`, `min_green_checks`, `ignored_checks`, `review.*`, `land.*`.

## Start a lane

```bash
lane-new <lane> [base]
```

It creates or reuses `<checkout>/.claude/worktrees/<lane>` on branch `lane/<lane>`, commits a
lane note and pushes, so a draft PR can open. It prints `WORKTREE <path> BRANCH <branch> HEAD
<sha>`; read the path from that line. Running it again is safe.

- Work only inside the lane's worktree. Never `git stash` (the stash is shared by every
  worktree) and never edit another lane's files.
- Scratch goes in the worktree's `.lane/`, which git ignores.
- The packet's exemptions (paths this lane may touch that a forbidden-move scan would
  otherwise flag) are in `.lane/exemptions.txt`.
- Dependencies and generated code come from `lane.setup_hook`; don't install them by hand.

## Check the worktree after every step

```bash
lane-hygiene <worktree> <branch> [--main-head <sha>] [product files...]
```

It prints one JSON object (`clean`, `headSha`, `branchOk`, `productHash`, `detail`) and exits 0
when clean, 1 when not. Uncommitted or untracked files, a `.lane/*.patch` left behind, an
operation in progress, the wrong branch or a moved main checkout all make it not clean. The
stash and the rest of `.lane/` don't. Fix what `detail` names before the next step; don't
clean another session's files.

## Review verdicts

An independent reviewer records a verdict for the exact head with
`lane-verdict record <pr> <head> merge|changes --reviewer <who> --implementer <who> --model <m>`;
a later round never overwrites an earlier one. Never record a verdict on your own work, and
never write a record by hand. `lane-verdict check <pr> <head> --implementer <who>` is what the
lander asks. The format is in crewkit's `docs/review-verdicts.md`.

## Writing to GitHub

Every lane write to GitHub goes through `gh-write` (comments, reviews, labels, marking a PR
ready), never raw `gh`: it is serialised, spaced out, retried, journalled, and idempotent by
header, so a relaunched lane never double-posts. Give each comment a stable header such as
`Lane <lane>: <step>`.

```bash
gh-write issue-comment <issue> "<header>" <body-file>
gh-write pr-review <pr> "<header>" <body-file>
gh-write label <issue|pr> <add> [<remove>]
gh-write pr-ready <pr>
```

## Refresh a PR from main

```bash
lane-refresh <pr>
```

It merges main into the PR's head in a temporary worktree (never the lane's own), refuses to
push if the diff against main would no longer be exactly the PR's own change, never
force-pushes, and checks the push landed. Exit 3 is a conflict (files listed): resolve it in
the lane, never by taking one side wholesale. Exit 4 means main already holds part of the
change: tell the coordinator. Exit 6 means a stacked PR's parent hasn't landed: wait for it.

## Land a lane

```bash
lane-land <lane>
```

The coordinator lands, not the lane. `lane-land` takes the landing lock and checks, in order:
the merge pause, that the PR is open and not a draft, that the lane's recorded head is the PR's
head, green checks on that exact head (decided by crewkit's shared `lib/checks.py`: the
`required_check` job from `ci.workflow`, nothing red or pending anywhere else; set `ci.workflow`
first, lane-land won't run without it), no conflicts, the owner gate (and every PR needs the
owner present until the project's `high_risk_areas` are confirmed), the project's
`land.precheck_hook`, and an independent verdict for that exact head. Only then does it squash
the PR pinned to that head, check it merged, record it, and label the closing issues. The last
line is the verdict; the exit codes are in crewkit's `docs/exit-codes.md`. A refusal is never
worked around: report it. Run it from the main checkout in the coordinating session, never from
a lane's worktree: settings are read from the current directory upwards, so a lane's own
`.claude/crewkit.local.md` would apply.

## Campaign state

The campaign's shared state is `<campaign_dir>/state.json`; its schema is crewkit's
`docs/campaign-state.md`. Change it only with `lane-state set KEY VALUE` (locked, atomic,
type-checked), and read it with `lane-state get KEY`. Never edit the file by hand, and never set
`ownerPresent` except on the owner's own word.

## Red flags

- About to run lane work in the main checkout instead of the lane's worktree.
- About to stash, or to reset another lane's branch.
- A lane that seems stuck: relaunch it from its packet, don't resume a dead session.
