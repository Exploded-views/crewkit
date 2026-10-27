---
name: using-bitc
description: >-
  Run heavy commands through bitc, the host slot pool runner, and read its exit codes
  correctly: 75 means try again later, 124 from wait means wait again, 69 means stop and
  report, 64 means fix the call. Use this when bitc is installed (or `pool_command` names it)
  and you are about to run lint, typecheck, tests, coverage, builds, browser or database
  suites; when a bitc command exited non-zero or printed STARVED; and for any job that can
  outlast your tool-call limit.
---

# Using bitc

bitc makes heavy commands take turns. `bitc run <pool> -- <command>` waits for a slot in a
named pool, runs the command with that pool's environment, and returns the command's own
exit code. If it can't start in time it exits **75** ("try again later"), never a fake
failure. The source of truth is bitc's own `docs/agent-guide.md` and `docs/exit-codes.md`;
this skill follows them. If they disagree, they win.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses
`pool_command` (for example `bitc run heavy --`), `orchestrator_name`.

## 1. Run heavy commands through a pool

```bash
bitc run <pool> -- <command> [args...]
```

- **Never run a heavy command bare**, and never run it bare because the pool was busy.
- Pool names belong to the host's owner. Use `pool_command` if set; otherwise `bitc status`
  or the repo's docs list them. Don't invent a pool.
- Don't edit bitc's config, kill another holder or delete files in its state directory.
  `bitc status` shows who holds what; report contention to `orchestrator_name`.

## 2. Read the exit code

| Code | Means | Do |
|---|---|---|
| the command's own | It ran; this is the real result (for example a failing test) | Treat it as the result |
| **75** | Starved (pool busy, queue, memory floor) or a remote failure after start | Wait a little, run the **same** command again. Never report it as a test failure |
| **124** | `bitc wait` only: the job is still running | Call `wait` again. Don't restart the job |
| **69** | Unavailable: internal error, bad hook, failed remote setup, no provider | Stop. Report the `bitc:` line. Don't retry |
| **64** | Usage: unknown pool, bad flag, refused by a rule | Fix the call; a `refused:` line says which pool to use |
| **66** | No such detached job | Check the job name |
| **78** | Invalid config | Stop and report. Not yours to fix |

Retry 75 a bounded number of times with a pause (for example 5 tries, a few seconds apart),
then report "starved" with the `STARVED <pool> (<reason>)` line. **A spent budget means
report, not retry**: once the tries are used up (counting tries made before you were asked),
stop and report; don't start a new round of retries on your own. An internal error is never
75, so a loop on 75 can't spin on a bug.

## 3. Long jobs: detach and wait

Anything that can outlast your tool-call limit (often about ten minutes):

```bash
bitc run --detach --name <job> <pool> -- <command>
bitc wait <job>           # at most about 9 minutes per call; exits 124 while it runs
```

- On 124, call `bitc wait <job>` again. Never start the job a second time.
- `wait` exits 0 whenever the command ran. Read its **first line**: `RESULT exit <code>` is
  the command's result, `RESULT starved` means 75. Prefer this to `--exit job`, which makes
  the command's own 75 or 69 look like bitc's.
- `bitc logs <job>` and `bitc cancel <job>` act on your own jobs only.

## Red flags

- Running the command bare after a 75, or calling a 75 a failing test.
- Re-running a detached job because `wait` returned 124.
- Retrying a 69 or a 78.
- Choosing a pool name that isn't in `pool_command`, `bitc status` or the repo's docs.
