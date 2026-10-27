---
name: landing
description: >-
  Land a PR on a main that several Claude sessions or people merge to, and confirm it shipped.
  Covers what "green" means (not a draft, the required check SUCCESS on the exact head, and no
  other workflow on that head failed), the freshness rule for merging on an existing green
  result, merge-main-never-rebase, the ready/go/merged handshake, a squash pinned with
  --match-head-commit, batched landing, and verifying that production reports the SHA. Use
  this whenever you are about to merge, mark ready, call a PR green, send "ready", land a
  queue, or say something "shipped", even if the user only says "land it", "merge when green"
  or "the release succeeded, next one".
---

# Landing

Every rule here exists because skipping it once turned a shared `main` red for everyone or
shipped something nobody verified.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses `repo`,
`required_check` (`ci-ok`), `extra_checks`, `sensitive_paths`, `freshness_command`,
`land_command`, `health_url`, `verify_workflow`, `orchestrator_name`, `high_risk_areas`,
`reply_timeout_urgent` / `reply_timeout_normal`.

## 1. Green

**Green = not a draft, AND `required_check` concluded SUCCESS on the current head, AND no
other workflow on that head commit failed.**

```bash
gh pr view N -R <repo> --json isDraft,headRefOid --jq '[.isDraft,.headRefOid]'
# every check run on the head, not just the required one; take the newest run per name
gh api --paginate "repos/<repo>/commits/<head>/check-runs?per_page=100" \
  --jq '.check_runs[] | [.name,.status,.conclusion,.started_at] | @tsv'
```

- A draft skips every job, so "0 failed, 0 pending" reads as green. **Skipped is not
  success**.
- Several runs of one check can exist; take the most recently started, never "the last row".
- A failure outside the required check still blocks: the aggregate check may not include
  every workflow (a workflow linter, say), so a head whose latest run of one of those failed
  is not green. If a check in `extra_checks` failed, don't land.
- The aggregate check should fail on any needed job that failed, was cancelled or was
  skipped without a reason it can verify. If yours doesn't, say so to the coordinator.

## 2. Freshness

Requiring "up to date with main" never converges on a busy main. Merging on a stale green
turns main red. **Merging on the existing green result is fine only if every condition below is true:**

1. The head is green (section 1).
2. None of the files the PR changes were also changed on main after its base.
3. No landed commit touches a sensitive path: migrations and schema, lockfiles, dependency
   manifests (when dependencies or engines changed; scripts-only is a judgement call, say so),
   shared test config, and **any workflow that runs on `pull_request`**, however small the
   change. For `high_risk_areas` PRs, also auth, env and boot, and middleware code.
4. Nothing landed that closes an issue this PR has an expected-fail test for.

```bash
gh api --paginate "repos/<repo>/pulls/N/files?per_page=100" --jq '.[].filename'   # PR files
gh api "repos/<repo>/compare/<head>...main" --jq '.ahead_by, .files[].filename'   # landed since base
```

The compare API caps at 300 files: at the cap, treat it as a refresh. If any read fails, the
answer is REFRESH (fail closed). Capture output before grepping it; `cmd | grep -q` under
`pipefail` can fail for long input. Use `freshness_command`
if it is set. Docs-only PRs never need a refresh.

**To refresh: merge main into the branch, never rebase,** push, wait for green on the new head,
and ask the coordinator for a reserved slot.

**After resolving a conflict,** compare `git diff origin/main HEAD` with the diff of the
branch's own commits; they must match line for line. An extra line is a change from main
that got silently reverted. Never take a side wholesale until that holds.

## 3. Before "ready"

- [ ] Green on the exact head; freshness checked; one-line overlap note written.
- [ ] Required review on this head (the `independent-review` skill); follow-ups filed.
- [ ] The plan or ledger re-read for parked rulings ("not before X"). CI can't know them.
- [ ] A dependency change updated every lockfile the deploy platform uses.
- [ ] Owner-present gate respected, if it applies.

## 4. Handshake

```text
ready: #N <one-line what> <head sha8> | overlap: none since base <sha8> | review: independent MERGE at <sha8>
```

Send to `orchestrator_name` (find it with `ListAgents`). Then `go #N` means proceed; `hold #N`
means wait (holds and release windows bind every session). With no reply after the timeout
(urgent user-facing fix / otherwise), use your own judgement and tell the coordinator after.

## 5. Merge pinned

Re-check freshness right before merging; main moves while you wait.

```bash
gh pr merge N -R <repo> --squash --match-head-commit <full head sha>
```

`--match-head-commit` makes GitHub refuse if anything was pushed after your check. Never use
`--admin`. Report `merged #N <merge sha>` to the coordinator.

**Queues:** with `land_command`, pass the whole ordered list in one call. It should land one at
a time under a file lock, stop at the first problem, and refuse a head with no formal review,
a failed extra check, or an owner gate not cleared. Don't chain background waiters on a
pattern match.

## 6. Shipped

**A tip shipped only when post-merge verification passed on that SHA and production reports
that same SHA.** A green release run is not a deploy: a gate run at merge time can succeed
without deploying anything.

```bash
curl -fsS <health_url>   # read the commit field; compare with: git rev-parse origin/main
gh run list -R <repo> --workflow <verify_workflow> --commit <sha> --json conclusion,status
```

- Bind checks to the exact commit SHA, never to a branch name or run title; "not concluded yet"
  means wait, never a verdict.
- After a platform outage, confirm each event-driven step fired; dispatch it by hand if not.
- Before changing a production setting that redeploys, compare production's SHA with main's
  tip. If main is ahead, say the change will ship those commits ungated.

## Shared CI is shared

- **Prove a new check can pass** (a dispatched or dry run) before it runs on every merge.
- New gates start report-only and are armed after a clean burn-in. Arming is the owner's call.
- A check failing on every merge for a known reason gets switched off or made report-only at
  once, with the reason on the tracking issue.
- Before landing a new lint rule or check, list the open PRs it would fail and tell their
  authors. Start from a baseline that only shrinks.
- Treat a release-blocking failure as a real bug, not flake, until proven: one re-run to get
  moving, then an issue and a test-first fix.
- **Main goes red:** one re-run to confirm, hold landings, split the hunt by suspect; fix
  forward if it's quick (decide the time box first), otherwise revert.

## Owner-present gates

A step that needs the owner at the keys (hand-run production SQL, `--apply` repairs, platform
secrets or deploy triggers, first writes to a new account, PRs marked owner-gated) runs only
after you ask and the owner replies that they are here. A relay, a stored flag or a cron tick
doesn't count. Enforce it in the landing script, not only in prompts.
