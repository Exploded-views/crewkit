---
name: crash-recovery
description: >-
  Bring a Claude Code session, or a whole team of sessions, back after a host restart,
  harness crash, usage-limit stall or account change: check worktrees for leftover
  mutation-test mutants before running anything, kill orphaned detached jobs by process
  group, distrust "built" stamps and verify shared state with a real query, relaunch work
  from ledgers (workflow resume is same-session only), re-create session crons and watches,
  and re-ask questions whose answers may have been lost. Use this whenever a session wakes
  after a crash or reboot, /tmp scratch is missing, a workflow resume fails, everything
  failed at once, or someone says "wake up" or "resume from your last state".
---

# Crash recovery

Assume nothing in your context or in `/tmp` survived. Recover from git, ledgers and durable
files, in this order.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses
`orchestrator_name`, `state_dir`, `durable_dir`.

## What survives

| Survives | Lost |
|---|---|
| Git: commits, pushed branches, PRs, issues, comments | Session context (until the transcript resumes) |
| Memory files; the coordinator's decision log and state file | Session crons and timers |
| Ledgers and state files in durable directories | Workflow resume handles (same session only) |
| Pool lock directory (locks release when holders die) | Everything in `/tmp` |
| Transcripts, if retention is long | In-flight mutations, which may be **left in source** |

## 1. Worktrees, before anything runs

For every worktree you own:

```bash
git -C <wt> status --porcelain
git -C <wt> diff --stat
```

- A modified product file is a **leftover mutant only if** the worktree was running a mutation
  proof (its ledger or harness says so) **and** the diff is a mutation target: a single-line
  change such as a condition set to `false` or a removed guard, on a line in the harness's
  table. Then restore it with `git -C <wt> show HEAD:<path> > <wt>/<path>` and confirm the file
  matches HEAD.
- **Any other modification may be real work.** Save it
  (`git -C <wt> diff > <durable_dir>/<wt-name>.diff`) and ask the session that owns the worktree.
- **Untracked new test files** are work in progress: keep them.
- A rebase or merge in progress: finish or abort it deliberately; don't leave it.
- Never let two agents commit in one worktree. A successor waits until the tree is quiet.

## 2. Processes

- Detached loops whose parent workflow died keep running. Find them with
  `ps -eo pid,pgid,etimes,args` and kill **by exact process group** (`kill -- -<pgid>`).
  Never a broad `pkill -f`; other sessions' jobs match too.
- Don't delete pool lock files; they release themselves.

## 3. Shared state that may lie

- Stamp files ("template built for schema X") can survive while what they describe didn't: a
  test database that came back empty. Verify with a real query (a table count), delete the
  stale stamp, rebuild.
- Check that service containers (test databases, caches) are actually running. They may not
  start on their own after a reboot, and local tests then fail while CI stays green.
- Rebuild any helper scripts that lived in `/tmp` from their durable copies, and move them.

## 4. Work

- **Relaunch from the ledger or state file** with fresh runs. Each side-effecting step should
  check what already exists before acting: an open PR for the branch, commits tagged with the
  issue number, a review carrying the standard header. That makes relaunching safe.
- **Re-run reviews a relaunch would skip** for work committed before the crash.
- **Usage-limit stalls:** things that "failed" during the stall failed together for one reason.
  Mark them cut by the usage limit and relaunch; don't triage them as real failures.

## 5. Time, messages and authority

- **List existing crons and timers, then re-create the missing ones.** Never duplicate.
- **Re-add artifact, comment or data watches.** After an account change, find published URLs again.
- **Messages sent just before the crash may never have arrived.** Re-ask every open question and
  say what you last received.
- **Written approvals still stand** (the decision log quotes them). Remembered ones don't: ask
  again.
- **Owner-present flags reset to false.** The owner says they're here again, after you ask.
- Re-read your memory notes for standing authority before acting.

## 6. Team order

1. The owner, or a coordinator that survived, sends each session a short wake-up:
   `restart: resume from your ledger, rebuild your crons, then report in one line`.
2. **Coordinator first:** the `orchestrator` skill's resume steps; then it collects status.
3. Each session: steps 1 to 5 above, then a one-line report.

## 7. Report

Send the coordinator one line: what you found (mutants restored, diffs saved, orphans killed,
state rebuilt), what you relaunched, what you're waiting on.

## Prevention

- Durable scripts and scratch in `durable_dir`, never `/tmp`.
- Ledgers updated as work happens: status, commits, verdicts, parked rulings, next step.
- Mutation harnesses restore in a trap on `EXIT INT TERM`.
- Holds and release windows live in `<state_dir>/state.md`, so a fresh coordinator knows if main is frozen.
