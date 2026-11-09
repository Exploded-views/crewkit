# Exit codes

Every crewkit script exits with a code from this one table, so a caller (a session, a lander,
a workflow) reads the same meaning from every tool. The common codes follow bitc's convention,
and a meaning shared by two tools uses the same number in both. A script's own header lists
the codes it can return.

## Common

| Code | Meaning | What the caller does |
|---|---|---|
| 0 | Done (or already done). | Carry on. |
| 1 | A step failed (a git or gh call, a write). | Read the message; fix or report. |
| 64 | Usage: a missing or malformed argument. | Fix the call. |
| 65 | Bad data: a value was refused (a wrong type for a state key, a self-review record). Nothing was written. | Fix the value. |
| 75 | Try again later: a lock stayed busy, or a resource is starved. | Wait, then run the same command again. Never treat it as a failure of the change. |
| 78 | Config: a required setting is missing or invalid. | Fix the settings ([settings.md](settings.md)). |

## Landing

Shared by `lane-land` (crew-lanes) and `land-batch` (crew-orchestrator).

| Code | Verdict | Meaning |
|---|---|---|
| 2 | NONE-ELIGIBLE | A batch lander found nothing it may land. |
| 7 | MAIN-MOVED | The main branch moved during the run; nothing more was merged. |
| 8 | MERGE-FAILED | The merge call failed, or returned without the PR becoming MERGED. |
| 9 | PR-CHANGED | A PR's head changed, or it became ineligible or not green, while it was being landed. |
| 10 | STRICT-PROTECTION | Branch protection requires up-to-date branches, which the batch lander can't satisfy. |
| 12 | POST-MERGE-MISMATCH | After a merge, the main branch's parent or tree isn't what was checked. Stop and investigate. |
| 14 | VERIFY-FAILED | The post-deploy verification failed. |
| 20 | PARTIAL | Some PRs landed and some were skipped (each with its reason). |
| 30 | PENDING | Checks on the head are still running, or the required check hasn't passed yet. |
| 31 | RED | A check on the head failed. |
| 32 | DIRTY | The PR conflicts with its base. |
| 33 | NO-VERDICT | No independent verdict accepts this exact head ([review-verdicts.md](review-verdicts.md)). |
| 34 | NEEDS-OWNER-PRESENT | Owner-gated, or the project's `high_risk_areas` aren't confirmed, and the owner isn't present. |
| 35 | MERGE-PAUSED | Landing is paused and the PR isn't exempt. |
| 36 | LANE-HEAD-STALE | The lane's recorded head isn't the PR's head. |
| 37 | NOT-READY | The PR is a draft, or not open. |
| 38 | PRECHECK-REFUSED | The project's `land.precheck_hook` refused it. |
| 39 | STATE-UNREADABLE | The campaign state doesn't parse or breaks its [schema](campaign-state.md). Every gate fails closed. |

## Installer

| Code | Tool | Meaning |
|---|---|---|
| 3 | `install.sh` | Paused: it needs a human. Either claude-memsync's bootstrap paused (do what it says, then re-run), or the memsync step paused before its bootstrap because no bootstrap flags were given after `--` (the other steps still ran; the note gives the command to finish). |

## Push gate

`push-gate/push-gate.sh` ([push-gate.md](push-gate.md)).

| Code | Command | Meaning |
|---|---|---|
| 1 | `hook` | BLOCKED: a finding, or a gate error (fails closed). Fix the commits; only the owner may bypass. |
| 1 | `install` | Refused: someone else's global `core.hooksPath` is set, or the copy failed. Nothing replaced. |
| 1 | `--doctor`, `gate-check` | At least one check is FAIL. |
| 2 | `--doctor`, `gate-check` | Their own error (settings unreadable, the root can't be listed, not a repository). |
| 78 | `install` | An owner step comes first (the denylist, or the verified gitleaks); nothing changed. |
| 1 | `doctor-watch` | A FAIL (`--doctor` exited 1 with FAIL lines); a failed notify keeps this code. |
| 2 | `doctor-watch` | The doctor's own error: any `--doctor` exit but 0, or 1 with FAIL lines (2, a crash's 127, a signal's 137 or 143). Never read as ok. |
| 78 | `schedule` | The gate isn't installed yet (`install --yes` first). |

## crewkit

The `crewkit` command and its verbs ([crewkit.md](crewkit.md)). A verb that changes state is a dry
run without `--yes`.

| Code | Verdict | Meaning |
|---|---|---|
| 3 | PAUSED | Owner-only steps were printed and not run (folder trust, secrets, the push-gate denylist, ACLs). Do them, then run the same command again. |
| 42 | DRILL-FAILED | The end-of-join drill failed in one of its parts (the report pull, the lead pane's status, or the page to the owner); the message names the part. |
| 43 | NOT-A-TERMINAL | `crewkit open` attaches to a node's lead pane, which is for the owner at a terminal; it ran without one and attached nothing. |
| 44 | TOKEN-REFUSED | A join token was refused: unknown, already used, expired, or issued for another node. |
| 45 | NOT-A-BRIDGE | A herdr pane prompt that the transport rule doesn't allow (`pane-ask` is the sender; `crewkit ask` hands its message to the local hub-bridge, which runs `pane-ask`): the caller isn't this host's bridge, the target isn't the other node's configured bridge, or the target is on this host. Across hosts only bridge prompts bridge; on one host sessions use `SendMessage`. A guard rail, not enforcement. |
| 64 | USAGE | A missing or malformed argument, or no such verb. |
| 75 | BUSY | A lock stayed held for `lock_wait_seconds`, or a host limit (`limits.*`) refused the work. Wait, then run the same command again. |
| 78 | CONFIG | A required setting is missing or invalid, or the machine isn't set up for the verb. One case: bash older than 4.4 (on macOS: `brew install bash`, and put it first on `PATH`). |

## Node tools

| Code | Tool | Meaning |
|---|---|---|
| 1 | `pane-ask` | An ssh or herdr call failed. If the send itself failed, the message may still have been delivered: read the target before sending again. |
| 40 | `pane-ask` | REPLY-TIMEOUT: herdr's wait ended with `timeout` or `agent_prompt_stalled`. The message may have been delivered: never send it again blindly; read it later (`pane-ask --read`). |
| 41 | `pane-ask` | BLOCKED: the turn ended at an approval or question dialog, which waits for the owner. The screen is printed. |
| 45 | `pane-ask` | NOT-A-BRIDGE: the caller isn't this host's bridge (the `bridge` of a node marked `nodes.<name>.this_host`), the target isn't the node's configured bridge (`nodes.<name>.bridge`), or the target is on this host (sessions there use `SendMessage`; the one exception is a watch daemon, a caller with no `HERDR_PANE_ID`, sending to this host's bridge). Applies to `--read` too. Nothing was called on the node. This is a guard rail, not enforcement: a caller can claim another pane or unset the variable; real enforcement waits on a herdr feature. |
| 65 | `pane-ask` | The target is one of the node's lead panes (`nodes.<name>.lead_pane`); nothing sent. |
| 75 | `pane-ask` | The agent was busy or blocked and stayed so; nothing sent. |

## Watcher tools

| Code | Tool | Meaning |
|---|---|---|
| 1 | `public-watch` | A gh call failed; nothing was printed for that run (never "nothing new"). |
| 1 | `tools/check-watcher-settings.py` | The settings allow a write tool, or miss a required deny. |
| 2 | `tools/check-watcher-settings.py` | Usage, or the settings file can't be read. |
| 0 | `watchline.py check` | Done, whatever it dropped (the count is on stderr). |
| 2 | `watchline.py check` | Its input can't be read. |

## Lane tools

| Code | Tool | Meaning |
|---|---|---|
| 1 | `lane-hygiene` | The worktree is not clean (the JSON says why). |
| 1 | `lane-verdict check`, `lane-state get` | Not accepted / no such key. |
| 3 | `lane-refresh` | A merge conflict (files listed); nothing pushed. |
| 4 | `lane-refresh` | Merging would change the PR's diff against main; nothing pushed. |
| 5 | `lane-refresh` | The push didn't land on the remote. |
| 6 | `lane-refresh` | A stacked PR's parent isn't merged. |
