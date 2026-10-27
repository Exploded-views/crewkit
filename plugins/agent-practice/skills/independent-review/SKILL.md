---
name: independent-review
description: >-
  Decide whether a change needs an independent review, pick the model, and run an
  adversarial MERGE review of someone else's PR, posted as a formal review pinned to one
  head SHA ("Reviewed head:", findings, "Verdict: MERGE" or "Verdict: FIX"), with guard-line
  mutation probes for security-relevant lines. Use this whenever you are asked to review a PR
  for merge, give a verdict, unblock a PR stuck on self-approval, do a security or
  adversarial review, set up review steps in a workflow, or choose which model reviews and
  which implements, even if the user only says "take a look at #123 before it lands".
---

# Independent review

An author can't approve its own work; the permission system rightly refuses that. A
**different session** reviews adversarially and posts a verdict pinned to one commit. You
**report, you don't fix**: fixes go back to the author.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses `repo`,
`review_model` (`opus`), `implement_model` (`sonnet`), `high_risk_areas` (`money, trust,
security, authorization, infrastructure`), `required_check`, `orchestrator_name`.

## When it's required

| Change | Review |
|---|---|
| Touches any of `high_risk_areas`, or the secret-scan / guard configuration itself | Independent adversarial review on `review_model`, always. Lands alone. |
| Minor fixes, tests, tooling, docs | A review by a session that isn't the author (the coordinator's own is fine). |
| Anything | Never the author's own review. |

The area a change touches decides, not the label on its issue.

## Model choice

- **`review_model` (strongest) for everything that judges:** reviews, re-reviews, audits,
  verdicts, rulings, reconciling state, short checks that need logic.
- **`implement_model` for long, output-heavy steps:** implementation, fix rounds, running gates,
  merges and pushes, mechanical sweeps.
- **No model** for checks a script can do; have the agent relay its JSON verbatim, and fail
  closed on anything unparseable.
- **Set `model` explicitly on every Agent dispatch and workflow step.** Omitted, it inherits the
  session's model. In scripts, default to `review_model` and list the steps that may go
  cheaper, so a new step is safe by default.
- Measure before re-tiering; the expensive step is rarely the one anyone guesses.

## 1. Pin the head and isolate

```bash
gh pr view N -R <repo> --json headRefOid,isDraft,files,body
git fetch origin pull/N/head && git worktree add --detach <scratch>/pr-N <full sha>
```

Your verdict covers that commit only. Review in your own worktree, never the author's. Keep
every clone, script and output in a per-PR scratch folder.

## 2. Write down the claim

From the PR body, linked issues and ledger: what it claims to fix, and what it claims not to
touch. Then don't trust any of it.

## 3. Verify against the code

- **The defect is fixed:** replay old and new behaviour on the issue's inputs and adversarial ones.
- **Tests fail without the fix:** revert the product change (`git revert --no-commit HEAD`), run
  the tests, watch them fail, then `git revert --abort`.
- **Guard-line probes:** for each security-relevant line added or changed (auth check, tenant or
  org filter, role gate), mutate just that line (condition to `false`, filter removed), run the
  relevant tests, expect at least one failure. Target by line number and assert the line's
  content first; restore in a `trap ... EXIT INT TERM`; check against `git show HEAD:` after.
  A survivor blocks, but first rule out a harness bug: a mutant that broke compilation
  collects zero tests and reads as "0 failed".
- **Callers:** every caller of what changed, and why each still holds.
- **Risk areas:** tenant scoping, injection, ReDoS, money and units, migrations and N-1
  compatibility, secrets in logs.
- **Siblings:** the same pattern elsewhere. Unfixed siblings become findings.

## Adversarial prompts (when dispatching a reviewer)

Give the reviewer the diff and the code, **not your conclusion**. A reviewer handed a hypothesis
tends to confirm it. Useful asks:

- "Find the input on which this change is wrong. If you can't, say what you tried."
- "Which caller breaks? List every caller and check each."
- "Mutate each guard line the PR touches; report killed or survived with counts."
- "What does this PR silently remove or revert compared with main?"
- "Assume the tests are too weak. Which assertion would still pass with the fix reverted?"

## 4. Post it as a formal review

`gh pr review N -R <repo> --comment --body-file review.md`. A plain `gh pr comment` doesn't
count: landing scripts look for formal reviews.

```text
Adversarial review: independent (#N)
Reviewed head: <full 40-char sha>

Scope: <files and line ranges; what is untouched>

**Verified against the code.** <what you ran, and the result>
- **The defect is fixed.** <old input -> old output; new output>
- **Tests fail without the fix.** <which tests>
- **Guard-line probes.** <line: killed (N fail) | survived>
- **Callers.** <each, and why it holds>
- **Risk areas.** <checked, and why safe>

**Findings**
1. <High|Medium|Low> (<blocking|non-blocking>): <file:line>. <concrete failure>. Suggested fix: ...
2. Nit: ...

<one line: why nothing blocks, or what blocks>

Verdict: MERGE
```

Use `Verdict: FIX: <blocking items>` when something blocks.

## Rules

- **Any push after the verdict voids it.** Re-review the new commits (scoped) and post a new
  pinned verdict.
- If CI is still running, say "Landing still needs `required_check` SUCCESS."
- Small findings in the same area fold into the same PR. Larger or elsewhere: file an issue
  before merge and list the numbers.
- **Rounds must converge.** A follow-up review verifies the earlier findings were addressed and
  looks for genuine new defects; it doesn't add fresh demands each round.
- Security findings by class and location only; no exploit detail in public text.
- Report to the coordinator: `#N independent MERGE at <sha8>; follow-ups #a, #b` (or `FIX: ...`).
