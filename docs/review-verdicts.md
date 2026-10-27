# Review verdicts

A change lands only after an independent review says MERGE for its exact head commit. The
landers (`lane-land` in crew-lanes, `land-batch` in crew-orchestrator) accept a
verdict from one of two sources, set per project with `review.source` ([settings](settings.md)):

- **`comments`:** a PR conversation comment by a login in `review.reviewers` (required) that
  isn't the PR's author, whose first line starts with one of `review.markers` and names the full
  head SHA. Use this when reviewers post as their own GitHub accounts.
- **`records`:** a verdict record written by the review workflow. Use this when every agent
  posts to GitHub as the same account, so "the commenter isn't the author" proves nothing.

## One implementation

Every lander decides a verdict through the same file, `lib/verdict.py`, vendored byte-for-byte
into each plugin (`tools/vendor-lib.sh`; the lint fails on a copy that differs), with one test
suite (`tests/verdict.bats`) over the shared fixtures. A lander only gathers the inputs (the
records directory and the lane's implementer, or every page of comments and the PR author) and
acts on the answer. Two copies of these rules is how the same bug ships twice.

## Comment verdicts

The lander reads every conversation comment, every page (`gh api repos/<repo>/issues/<pr>/
comments --paginate`), and the PR's author. Review bodies don't count.

1. **Candidates** are comments by a login in `review.reviewers`, not the PR's author (a PR
   whose author has no login, such as a deleted account, gets no comment verdict), whose
   first line (after leading whitespace) names the full head SHA or starts with a marker's first
   word (`Verdict:`).
2. The **latest candidate by `created_at`** decides, so a later `Verdict: CHANGES-REQUESTED`,
   with or without a SHA, or a `Verdict: MERGE` for another head, blocks an earlier MERGE.
3. It approves only if its **first line** starts with a marker followed by whitespace or the end
   of the line (`Verdict: MERGE-WITH-FIXES` is not `Verdict: MERGE`) and, with
   `review.require_sha` (the default), contains the full head. Nothing after the first line
   counts: a body that says "after the fix I expect Verdict: MERGE" approves nothing.
4. When the lander asks for a model (see [The review model](#the-review-model)), that first
   line must also carry a word `model=<model>` anywhere on it (by convention after the head:
   `Verdict: MERGE <head> model=opus`), and every `model=` on it must match.

## Verdict records

Records live in `<review.verdict_dir>/<pr>/` (default `<state_dir>/verdicts`). Round 1 for a
head is `<headSha>.json`; each later round is `<headSha>.<round>.json`, with the round 2 or
more and no leading zero. Any other file name starting with the head refuses it. Files are never
overwritten, so every round stays for audit, and each is written through a temp file and a
rename. `lane-verdict record` writes them; `lane-verdict check` applies the rules below.

```text
{
  "schema": 1,
  "pr": 101,
  "headSha": "<40 hex>",
  "verdict": "merge",
  "round": 2,
  "reviewer": "<reviewing session or agent>",
  "implementer": "<session or agent that wrote the head>",
  "model": "opus",
  "reviewedAt": "2026-10-26T04:00:00Z"
}
```

`verdict` is `merge` or `changes`. The writer refuses a record whose reviewer is empty or equal
to the implementer, a head that isn't a full 40-hex SHA, or any other verdict.

### When a lander accepts one

It reads every `<headSha>*.json` for the PR's **current** head (a full 40-hex SHA), and every
JSON value in each file (a file can hold more than one). Every record's body `round` must equal
its file's round. At the **highest round, every record** must:

1. be readable, with `schema` 1;
2. have `pr` and `headSha` matching the PR and its head;
3. say `verdict: merge` (so a later `changes` round, or a `changes` record tied at the top
   round, refuses the head);
4. name a `reviewer` that is non-empty, isn't the record's `implementer`, and is in
   `review.reviewers` when that is set;
5. when the PR belongs to a lane in the [campaign state](campaign-state.md), name the lane's
   `implementer` (so a record can't name someone else to hide a self-review);
6. when the lander asks for a model, have a `model` that matches it.

A PR without a lane can be landed on records only when `review.reviewers` is set. Separately,
the lander treats a lane whose recorded `headSha` isn't the PR's head as stale.

Anything else, including no record or an unreadable one, means no verdict: the change waits.

### What records prove, and what they don't

A record shows that the review workflow wrote it only if the implementing sessions can't write
`review.verdict_dir`. On one host with one account that is a convention, not an enforcement:
keep the directory outside every lane's worktree and treat a hand-written record like a forged
approval. Where reviewers have their own accounts, `review.source: comments` is the stronger
choice.

## The review model

`review_model` (default `opus`) is the model independent reviews run on. A lander passes it to
`verdict.py --model` when the PR needs it. Leaving the flag out fails closed: `verdict.py`
then asks for `opus`, and `lane-verdict check` for the `review_model` setting. Only an explicit
empty value (`--model ""`, or `review_model: ""`) checks no model.

- **Matching** ignores case: a model matches when it equals `review_model` or holds it as a
  whole token after splitting on `-`, `_`, `.`, `:`, `/` and spaces. `opus` matches `opus`,
  `claude-opus-5-5` and `Claude Opus 5.5`, never `opusx` or `sonnet`. A missing model never
  matches.
- **When it's asked for:** the orchestrator's landers, for high-risk PRs (they classify each
  PR against `high_risk_areas`). `lane-land` asks on every landing, since it can't yet tell a
  high-risk PR from another: it fails closed until lane gates classify risk.
- **What it proves:** like a record's other fields, the model is what the reviewer wrote down.
  On one account it is a convention, not an enforcement, but it is explicit and auditable.
- **Who can change it:** only a settings file. Any session can set its own environment, and an
  environment value could weaken the check (empty, or `claude`, which matches any Claude
  model), so `review_model`, like every gate setting, is file-only: `CREWKIT_REVIEW_MODEL` is
  ignored (`CREW_FILE_ONLY` in `lib/settings.sh`; see [settings.md](settings.md)). Landers read
  every setting from the repository's main checkout (`crew_cd_main_checkout`), wherever they
  are run from, so a lane's own worktree settings (`.claude/crewkit.local.md` there) never
  apply to a landing.
- **The threat model:** lanes run as the same user as the coordinating session, so they are
  trusted not to be malicious. A lane could still edit the main checkout's settings files,
  start a lander with `HOME` pointing at its own `~/.claude/crewkit.md` (for any key the project
  files don't set) or with a fake `gh` first on `PATH`, or write the campaign state (say
  `lane-state set ownerPresent true`) or a verdict record directly. Gate settings being
  file-only, and every setting coming from the main checkout, stops accidents and drift (a
  lane's leftover local settings, a stray environment variable), not an adversary. Run landers from the
  coordinating session, and keep the settings files under review like code.

## Shared fixtures

`tests/fixtures/verdicts/make.py OUT_DIR` writes one verdict dir per case and
`tests/fixtures/comments/make.py OUT_DIR` one comment list per case, each printing the expected
answer. With `--model-cases` first, each writes the review model cases instead, whose lines
carry one more column, the model asked for. `tests/verdict.bats` runs every case through
`lib/verdict.py`. They build the SHAs at
run time, so no long hex literal sits in the repo.
