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
| 3 | `install.sh` | claude-memsync's bootstrap paused: it needs a human. Do what it says, then re-run. |

## Lane tools

| Code | Tool | Meaning |
|---|---|---|
| 1 | `lane-hygiene` | The worktree is not clean (the JSON says why). |
| 1 | `lane-verdict check`, `lane-state get` | Not accepted / no such key. |
| 3 | `lane-refresh` | A merge conflict (files listed); nothing pushed. |
| 4 | `lane-refresh` | Merging would change the PR's diff against main; nothing pushed. |
| 5 | `lane-refresh` | The push didn't land on the remote. |
| 6 | `lane-refresh` | A stacked PR's parent isn't merged. |
