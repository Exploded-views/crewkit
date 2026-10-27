#!/usr/bin/env bats
# land-batch: one throwaway batch branch of squashes, tested once, then each PR squash-merged in
# order with every check. Scenarios 1-31 are the core landing scenarios; the rest are new rules.

load orch-helpers

setup() { setup_orch; }

lb() { run "$BIN/land-batch" --yes "$@"; }

verdict() { # verdict PR SHA [AUTHOR]: an independent verdict comment on PR naming SHA
  jq -n --arg b "Verdict: MERGE $2 model=opus" --arg a "${3:-reviewer}" '[{author: {login: $a}, body: $b}]' \
    > "$STUB/pr/$1/comments.json"
}

@test "1 all green: merged in order, batch branch deleted, batch PR closed" {
  for n in 11 12 13; do mkpr $n; done
  lb 11 12 13
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 13 " ]
  no_batch_branches
  [ -e "$STUB/closed-901" ]
}

@test "2 a conflict drops one PR, the rest land" {
  mkpr 11 --shared AAA; mkpr 12 --shared BBB; mkpr 13
  lb 11 12 13
  [ "$status" -eq 20 ]
  [ "$(merged)" = "11 13 " ]
  [[ $output == *"#12: CONFLICT"* ]]
}

@test "2b a normal finish with some PRs dropped is not reported as a partial landing" {
  mkpr 11; mkpr 12
  echo true > "$STUB/pr/12/draft"
  lb 11 12
  [ "$status" -eq 20 ]
  [ "$(merged)" = "11 " ]
  [[ $output != *PARTIAL* ]]
  none -q PARTIAL "$JOURNAL"
}

@test "3 main moved while the batch ran: abort, nothing merged" {
  mkpr 11; mkpr 12
  hook on_poll "$(push_main_snippet)"
  lb 11 12
  [ "$status" -eq 7 ]
  [ -z "$(merged)" ]
  no_batch_branches
}

@test "4 a PR head changed while the batch ran: abort, nothing merged" {
  mkpr 11; mkpr 12
  hook on_poll "echo deadbeef > $STUB/pr/12/head"
  lb 11 12
  [ "$status" -eq 9 ]
  [ -z "$(merged)" ]
}

@test "5 a known flake reruns once, then everything lands" {
  mkpr 11; mkpr 12 --bad "flake\n FAIL  src/bigmem.test.ts > big thing"; mkpr 13
  lb 11 12 13
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 13 " ]
  [ "$(grep -c rerun-failed-jobs "$STUB/calls.log")" -eq 1 ]
}

@test "6 a real failure bisects to the culprit" {
  for n in 11 13 14; do mkpr $n; done
  mkpr 12 --bad "real\n FAIL  src/foo.test.ts > x"
  lb 11 12 13 14
  [ "$status" -eq 20 ]
  [ "$(merged)" = "11 13 14 " ]
  [[ $output == *"CULPRIT: #12"* ]]
  none -q rerun-failed-jobs "$STUB/calls.log"
  no_batch_branches
}

@test "7 an up-to-date requirement refusal is reported once, not retried" {
  for n in 11 12 13; do mkpr $n; done
  echo 1 > "$STUB/refuse_after"
  lb 11 12 13
  [ "$status" -eq 10 ]
  [ "$(merged)" = "11 " ]
  [ "$(grep -c REFUSED <<<"$output")" -eq 1 ]
  [ "$(merge_calls)" -eq 2 ]
}

@test "8 strict branch protection: stop before opening a batch PR" {
  mkpr 11
  touch "$STUB/protection_strict"
  lb 11
  [ "$status" -eq 10 ]
  none -q '^pr create' "$STUB/calls.log"
}

@test "9 a draft PR is skipped" {
  mkpr 11; mkpr 12
  echo true > "$STUB/pr/12/draft"
  lb 11 12
  [ "$status" -eq 20 ]
  [ "$(merged)" = "11 " ]
}

@test "10 a skipped check, or the aggregate check with no other green job, is not green" {
  mkpr 11; mkpr 12; mkpr 13; mkpr 14
  echo skipped > "$STUB/ci/$(cat "$STUB/pr/12/head")"   # a run that executed nothing: no run decides
  echo okonly > "$STUB/ci/$(cat "$STUB/pr/13/head")"    # ci-ok green, unit skipped: skipped isn't success
  runs_for 14 '[{"id":"alone","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"}]'
  jq -n '{jobs: [{name: "ci-ok", status: "completed", conclusion: "success", run_attempt: 1,
    started_at: "2026-01-01T00:00:00Z"}]}' > "$STUB/jobs/alone.json"   # ci-ok alone: no other green check
  lb 11 12 13 14
  [ "$(merged)" = "11 " ]
  [[ $output == *"#12: ci-ok is 'pending"* ]]
  [[ $output == *"#13: ci-ok is 'failure"* ]]
  [[ $output == *"#14: ci-ok is 'pending"* ]]
}

@test "11 a batch run with only skipped jobs times out (exit 75), nothing merged" {
  mkpr 11; mkpr 12
  touch "$STUB/batch_skipped"
  lb 11 12
  [ "$status" -eq 75 ]
  [ -z "$(merged)" ]
  no_batch_branches
}

@test "12 the batch PR is not a draft, and is labelled and titled do-not-merge" {
  mkpr 11
  lb 11
  none -q -- '--draft' "$STUB/calls.log"
  grep '^pr create' "$STUB/calls.log" | grep -q -- '--label do-not-merge'
  grep '^pr create' "$STUB/calls.log" | grep -q 'do not merge'
  grep -q '^label create do-not-merge' "$STUB/calls.log"
}

@test "13 a pending check is not red: poll until it succeeds" {
  mkpr 11; mkpr 12
  echo 3 > "$STUB/batch_pending"
  lb 11 12
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 " ]
  [[ $output != *bisecting* ]]
}

@test "14 a flake rerun waits for the new attempt, ignoring the stale failure" {
  mkpr 11; mkpr 12 --bad "flake\n FAIL  src/bigmem.test.ts"
  echo 2 > "$STUB/stale_after_rerun"
  lb 11 12
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 " ]
  [ "$(grep -c rerun-failed-jobs "$STUB/calls.log")" -eq 1 ]
}

@test "15a flakes match only FAIL lines" {
  mkpr 11; mkpr 12 --bad "real\nsetup bigmem.test.ts ok\n FAIL  src/real.test.ts"
  lb 11 12
  none -q rerun-failed-jobs "$STUB/calls.log"
  [[ $output == *"CULPRIT: #12"* ]]
}

@test "15b one unknown FAIL line among flakes is not a flake" {
  mkpr 11; mkpr 12 --bad "flake\n FAIL  src/bigmem.test.ts\n FAIL  src/real.test.ts"
  lb 11 12
  none -q rerun-failed-jobs "$STUB/calls.log"
  [[ $output == *"CULPRIT: #12"* ]]
}

@test "15c flake entries are literal text, not patterns" {
  mkpr 11; mkpr 12 --bad "flake\n FAIL  src/bigXmem.test.ts"
  lb 11 12
  none -q rerun-failed-jobs "$STUB/calls.log"
}

@test "16a a PR not based on the main branch is skipped" {
  mkpr 11; mkpr 12
  echo integrate/phase-1 > "$STUB/pr/12/base"
  lb 11 12
  [[ $output == *"#12: skipped (base-is-integrate/phase-1"* ]]
  [ "$(merged)" = "11 " ]
}

@test "16b a base change found at the recheck aborts with nothing merged" {
  mkpr 11; mkpr 12
  hook on_poll "echo integrate/x > $STUB/pr/12/base"
  lb 11 12
  [ "$status" -eq 9 ]
  [ -z "$(merged)" ]
}

@test "17a batch branch heads and blocked labels are refused" {
  mkpr 11; mkpr 12; mkpr 13
  echo batch/old > "$STUB/pr/11/ref"
  echo do-not-merge > "$STUB/pr/12/labels"
  lb 11 12 13
  [ "$(merged)" = "13 " ]
  [[ $output == *batch-branch-head* ]]
  [[ $output == *blocked-label* ]]
}

@test "17b a blocking label added before the merges aborts with nothing merged" {
  mkpr 11; mkpr 12
  hook on_poll "echo awaiting-approval > $STUB/pr/12/labels"
  lb 11 12
  [ "$status" -eq 9 ]
  [ -z "$(merged)" ]
}

@test "18a an owner-gated PR is skipped while the owner is away" {
  mkpr 11; mkpr 12
  mkdir -p "$ORCH_CAMPAIGN_DIR"
  echo '{"ownerPresent":false,"ownerGatedPrs":[12]}' > "$ORCH_CAMPAIGN_DIR/state.json"
  lb 11 12
  [ "$(merged)" = "11 " ]
  [[ $output == *owner-gated* ]]
}

@test "18b with the owner present, gated PRs land" {
  mkpr 11; mkpr 12
  mkdir -p "$ORCH_CAMPAIGN_DIR"
  echo '{"ownerPresent":true,"ownerGatedPrs":[12]}' > "$ORCH_CAMPAIGN_DIR/state.json"
  lb 11 12
  [ "$(merged)" = "11 12 " ]
}

@test "19 main moves between squashes: stop with a loud partial report" {
  for n in 11 12 13; do mkpr $n; done
  hook after_merge "$(push_main_snippet)"
  lb 11 12 13
  [ "$status" -eq 7 ]
  [ "$(merged)" = "11 " ]
  [[ $output == *"PARTIAL LANDING"* ]]
  [[ $output == *"NOT tested"* ]]
  grep -q '!!! PARTIAL' "$JOURNAL"
}

@test "20 a transient 'Base branch was modified' is retried" {
  for n in 11 12 13; do mkpr $n; done
  mkdir -p "$STUB/transient_once"; touch "$STUB/transient_once/12"
  lb 11 12 13
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 13 " ]
  [ "$(merge_calls)" -eq 4 ]
}

@test "21 a persistent squash failure stops and names what landed" {
  for n in 11 12 13; do mkpr $n; done
  mkdir -p "$STUB/transient_always"; touch "$STUB/transient_always/12"
  lb 11 12 13
  [ "$status" -eq 8 ]
  [ "$(merged)" = "11 " ]
  [[ $output == *"landed on main so far: #11; not landed: 12 13"* ]]
  grep -q '!!!' "$JOURNAL"
}

@test "22 something landed between the recheck and a squash: parent mismatch" {
  mkpr 11; mkpr 12
  mkdir -p "$STUB/race_before"; touch "$STUB/race_before/12"
  lb 11 12
  [ "$status" -eq 12 ]
  [[ $output == *"expected parent"* ]]
  [[ $output == *"PARTIAL LANDING"* ]]
}

@test "23 the squash tree differs from the tree tested" {
  mkpr 11; mkpr 12
  mkdir -p "$STUB/tree_tamper"; touch "$STUB/tree_tamper/11"
  lb 11 12
  [ "$status" -eq 12 ]
  [[ $output == *"differs from the tree tested"* ]]
}

@test "24 a timeout after a partial landing reports what landed" {
  mkpr 11; mkpr 12 --bad "real\n FAIL  src/z.test.ts"
  hook on_merge "touch $STUB/batch_skipped"
  lb 11 12
  [ "$status" -eq 75 ]
  [ "$(merged)" = "11 " ]
  [[ $output == *"landed on main so far: #11"* ]]
}

@test "25 stale batch PRs and branches are swept, fresh ones kept" {
  mkpr 11
  git push -q origin main:refs/heads/batch/20200101T000000Z
  git push -q origin main:refs/heads/batch/29990101T000000Z
  echo '[{"number":77,"headRefName":"batch/20200101T000000Z","title":"batch: #9 (do not merge, closed automatically)"}]' > "$STUB/prlist.json"
  lb 11
  [ -e "$STUB/closed-77" ]
  run git --git-dir="$STUB_BARE" rev-parse -q --verify refs/heads/batch/20200101T000000Z
  [ "$status" -ne 0 ]
  git --git-dir="$STUB_BARE" rev-parse -q --verify refs/heads/batch/29990101T000000Z
}

@test "26 the landing lock is shared: busy means exit 75 and nothing merged" {
  mkpr 11
  hold_lock 4
  CREWKIT_LOCK_WAIT_SECONDS=1 lb 11
  wait
  [ "$status" -eq 75 ]
  [ -z "$(merged)" ]
  [[ $output == *"landing lock busy"* ]]
}

@test "27 PRs sharing a commit not on main (stacked) are not batched together" {
  mkpr 11; mkpr_on 12 11; mkpr 13
  lb 11 12 13
  [ "$status" -eq 20 ]
  [[ $output == *"#12: shares commits"* ]]
  [ "$(merged)" = "11 13 " ]
}

@test "28 the batch branch is a chain of squashes, so the tested tree is GitHub's" {
  mkpr 11; mkpr 12
  lb 11 12
  [ "$status" -eq 0 ]
  [[ $output == *"#11 squashed into batch/"* ]]
  [[ $output != *differs* ]]
}

@test "29 a merge call that errors although the PR merged counts as landed" {
  for n in 11 12 13; do mkpr $n; done
  mkdir -p "$STUB/merged_but_error"; touch "$STUB/merged_but_error/12"
  lb 11 12 13
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 13 " ]
  [[ $output != *PARTIAL* ]]
  [[ $output == *"errored but the PR is MERGED"* ]]
}

@test "30 a lingering helper process does not hold the landing lock" {
  mkpr 11
  touch "$STUB/daemon"
  lb 11
  alive=0
  for p in $(cat "$STUB/daemon.pids"); do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" -eq 1 ]
  flock -n "$ORCH_STATE_DIR/locks/land.lock" true
  kill $(cat "$STUB/daemon.pids") 2>/dev/null || true
}

# 31: a run whose aggregate check only mirrors another run (a step named by
# ci.noise_step_prefix ran) is ignored, whichever way it concluded.
noise_runs() { # noise_runs PR NOISE_CONCLUSION REAL_CONCLUSION
  local h; h=$(cat "$STUB/pr/$1/head")
  echo '{"workflow_runs":[{"id":"noise","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:10:00Z"},{"id":"real","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"}]}' > "$STUB/runs/$h.json"
  jq -n --arg c "$2" '{jobs: [{name: "ci-ok", status: "completed", conclusion: $c, run_attempt: 1,
    started_at: "2026-01-01T00:10:00Z", steps: [{name: "Set up job", conclusion: "success"},
    {name: "Mirror the newest real run (label-noise runs only)", conclusion: $c}]}]}' > "$STUB/jobs/noise.json"
  jq -n --arg c "$3" '{jobs: [{name: "unit", status: "completed", conclusion: "success", run_attempt: 1,
    started_at: "2026-01-01T00:00:00Z", steps: []}, {name: "ci-ok", status: "completed", conclusion: $c,
    run_attempt: 1, started_at: "2026-01-01T00:05:00Z", steps: [{name: "Check jobs", conclusion: $c}]}]}' > "$STUB/jobs/real.json"
}

@test "31a a later mirror run's failure is ignored: the real run's success counts" {
  mkpr 11
  noise_runs 11 failure success
  user_setting "ci.noise_step_prefix: Mirror the newest real run"
  lb 11
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 " ]
}

@test "31b a later mirror run's success is ignored too: the real run failed" {
  mkpr 11
  noise_runs 11 success failure
  user_setting "ci.noise_step_prefix: Mirror the newest real run"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "31c without ci.noise_step_prefix the newest run counts" {
  mkpr 11
  noise_runs 11 failure success
  lb 11
  [ "$status" -eq 2 ]
}

# ---- new in crewkit ------------------------------------------------------------------------------

@test "a dry run (no --yes) reports the plan and changes nothing" {
  mkpr 11; mkpr 12
  run "$BIN/land-batch" 11 12
  [ "$status" -eq 0 ]
  [[ $output == *"#11 eligible"* ]]
  [[ $output == *"dry run"* ]]
  none -qE '^pr (create|merge)' "$STUB/calls.log"
  [ -z "$(merged)" ]
}

@test "usage errors exit 64" {
  run "$BIN/land-batch" --yes
  [ "$status" -eq 64 ]
  run "$BIN/land-batch" --yes 12abc
  [ "$status" -eq 64 ]
  run "$BIN/land-batch" --bogus 12
  [ "$status" -eq 64 ]
}

@test "the repo setting is required (exit 78)" {
  mkpr 11
  user_unset repo
  lb 11
  [ "$status" -eq 78 ]
  [[ $output == *"'repo'"* ]]
}

@test "ignored_checks naming the required check is a config error (78), not a forever-pending" {
  mkpr 11
  user_setting 'ignored_checks: "deploy-preview,  ci-ok "'
  lb 11
  [ "$status" -eq 78 ]
  [[ $output == *"ignored_checks names the required check 'ci-ok'"* ]]
  [ -z "$(merged)" ]
  user_setting "ignored_checks: deploy-preview, ci-ok-extra"
  lb 11
  [ "$status" -eq 0 ]
}

@test "until high_risk_areas is confirmed, nothing is batched (exit 78)" {
  mkpr 11
  user_unset high_risk_areas.confirmed_by
  lb 11
  [ "$status" -eq 78 ]
  [[ $output == *high_risk_areas.confirmed_by* ]]
  none -q '^pr create' "$STUB/calls.log"
}

@test "a high-risk PR without a verdict for its head is not landed; the rest are" {
  settings 'high_risk_areas.billing.paths: "src/billing/**, migrations/**"'
  mkpr 11; mkpr 12 --file src/billing/charge.ts; mkpr 13
  lb 11 12 13
  [ "$status" -eq 20 ]
  [ "$(merged)" = "11 13 " ]
  [[ $output == *"#12: skipped (high-risk(billing): no independent verdict for"* ]]
}

@test "a high-risk PR with a verdict for its exact head lands alone, after the batch" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 11; mkpr 12 --file src/billing/charge.ts; mkpr 13
  verdict 12 "$(cat "$STUB/pr/12/head")"
  lb 11 12 13
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 13 12 " ]
  [ "$(grep -c '^pr create' "$STUB/calls.log")" -eq 2 ]
  [[ $output == *"#12 lands alone (high-risk: billing)"* ]]
}

@test "a verdict for an older head does not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  verdict 12 "$OTHER_SHA"
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "a verdict written by the PR's own author does not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  echo lane-bot > "$STUB/pr/12/author"
  user_setting "review.reviewers: lane-bot,reviewer"
  verdict 12 "$(cat "$STUB/pr/12/head")" lane-bot
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "a GitHub App author (app/<slug>) is the same account as its comments' <slug>[bot]" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  echo app/review-bot > "$STUB/pr/12/author"   # gh pr view's login for an App; REST comments say review-bot[bot]
  user_setting "review.reviewers: review-bot[bot],reviewer"
  verdict 12 "$(cat "$STUB/pr/12/head")" "review-bot[bot]"
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
  verdict 12 "$(cat "$STUB/pr/12/head")" reviewer
  lb 12
  [ "$status" -eq 0 ]
}

@test "a verdict that only quotes the marker mid-comment does not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  jq -n --arg b "I would write 'Verdict: MERGE $(cat "$STUB/pr/12/head")' once fixed" \
    '[{author: {login: "reviewer"}, body: $b}]' > "$STUB/pr/12/comments.json"
  lb 12
  [ "$status" -eq 2 ]
}

@test "comments: a verdict from a login not in review.reviewers does not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  verdict 12 "$(cat "$STUB/pr/12/head")" someone-else
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "comments: with review.reviewers unset, no comment verdict counts" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  verdict 12 "$(cat "$STUB/pr/12/head")"
  user_unset review.reviewers
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"review.reviewers"* ]]
}

record() { # record PR SHA [VERDICT] [REVIEWER]: a verdict record from the review workflow
  local d="$ORCH_STATE_DIR/verdicts/$1"
  mkdir -p "$d"
  jq -n --argjson pr "$1" --arg sha "$2" --arg v "${3:-merge}" --arg r "${4-reviewer}" \
    '{schema: 1, pr: $pr, headSha: $sha, verdict: $v, round: 1, reviewer: $r, implementer: "lane-session",
      model: "opus", reviewedAt: "2026-01-01T00:00:00Z"}' > "$d/$2.json"
}

@test "records: a merge record for the exact head lands the high-risk PR" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 11; mkpr 12 --file src/billing/charge.ts
  record 12 "$(cat "$STUB/pr/12/head")"
  lb 11 12
  [ "$status" -eq 0 ]
  [ "$(merged)" = "11 12 " ]
}

@test "records: a comment verdict does not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  verdict 12 "$(cat "$STUB/pr/12/head")"
  lb 12
  [ "$status" -eq 2 ]
}

@test "records: a record for another head, a 'changes' verdict, no reviewer or bad JSON do not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  record 12 "$OTHER_SHA"
  cp "$ORCH_STATE_DIR/verdicts/12/$OTHER_SHA.json" "$ORCH_STATE_DIR/verdicts/12/$h.json"
  lb 12
  [ "$status" -eq 2 ]
  record 12 "$h" changes
  lb 12
  [ "$status" -eq 2 ]
  record 12 "$h" merge ""
  lb 12
  [ "$status" -eq 2 ]
  echo '{not json' > "$ORCH_STATE_DIR/verdicts/12/$h.json"
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "records: review.reviewers, when set, limits who may write a record" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  record 12 "$(cat "$STUB/pr/12/head")" merge stranger
  lb 12
  [ "$status" -eq 2 ]
  record 12 "$(cat "$STUB/pr/12/head")" merge reviewer
  lb 12
  [ "$status" -eq 0 ]
}

@test "records: a self-review, a later 'changes' round, or an unknown schema do not count" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head") f="$ORCH_STATE_DIR/verdicts/12/$h.json"
  record 12 "$h"
  jq '.implementer = .reviewer' "$f" > "$f.new" && mv "$f.new" "$f"
  lb 12
  [ "$status" -eq 2 ]
  record 12 "$h"
  jq '.round = 2 | .verdict = "changes"' "$f" > "$ORCH_STATE_DIR/verdicts/12/$h.2.json"
  lb 12
  [ "$status" -eq 2 ]
  rm "$ORCH_STATE_DIR/verdicts/12/$h.2.json"
  jq '.schema = 2' "$f" > "$f.new" && mv "$f.new" "$f"
  lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "records: a later 'merge' round beats an earlier 'changes'" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  record 12 "$h" changes
  jq '.round = 2 | .verdict = "merge"' "$ORCH_STATE_DIR/verdicts/12/$h.json" > "$ORCH_STATE_DIR/verdicts/12/$h.2.json"
  lb 12
  [ "$status" -eq 0 ]
}

@test "an unknown review.source is a config error" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: vibes'
  mkpr 12
  lb 12
  [ "$status" -eq 78 ]
}

@test "high-risk globs: * matches across directories; other paths are not high risk" {
  settings 'high_risk_areas.infra.paths: "deploy/*"'
  mkpr 11 --file deploy/prod/app.yaml; mkpr 12 --file src/deploy.txt
  lb 11 12
  [ "$(merged)" = "12 " ]
  [[ $output == *"high-risk(infra)"* ]]
}

@test "required_check names the aggregate check" {
  mkpr 11
  user_setting "required_check: gate"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: gate is 'pending"* ]]
}

@test "labels.do_not_merge names the batch label and the blocking label" {
  mkpr 11; mkpr 12
  echo hold > "$STUB/pr/12/labels"
  user_setting "labels.do_not_merge: hold"
  lb 11 12
  [ "$(merged)" = "11 " ]
  grep '^pr create' "$STUB/calls.log" | grep -q -- '--label hold'
}

@test "branch_prefix.batch names the batch branch" {
  mkpr 11
  user_setting "branch_prefix.batch: try/"
  lb 11
  [ "$status" -eq 0 ]
  [[ $output == *"squashed into try/"* ]]
  grep '^pr create' "$STUB/calls.log" | grep -q -- '--head try/'
}

campaign() { # campaign [JQ_FILTER]: the shared fixture (tests/fixtures/campaign-state.py), with
  # each lane's headSha set to its PR's real head when the test made that PR, then JQ_FILTER
  local heads='{}' d
  for d in "$STUB"/pr/*/; do heads=$(jq --arg pr "$(basename "$d")" --arg h "$(cat "$d/head")" '. + {($pr): $h}' <<<"$heads"); done
  mkdir -p "$ORCH_CAMPAIGN_DIR"
  python3 "$REPO/tests/fixtures/campaign-state.py" |
    jq --argjson heads "$heads" '.lanes |= with_entries(if $heads[(.value.pr | tostring)] then .value.headSha = $heads[(.value.pr | tostring)] else . end)' |
    jq "${1:-.}" > "$ORCH_CAMPAIGN_DIR/state.json"
}

@test "campaign fixture: owner-gated PRs (a number and a numeric string) wait; others land" {
  mkpr 101; mkpr 102; mkpr 103
  campaign
  lb 101 102 103
  [ "$status" -eq 20 ]
  [ "$(merged)" = "103 " ]
  [[ $output == *"#101: skipped (owner-gated"* ]]
  [[ $output == *"#102: skipped (owner-gated"* ]]
}

@test "campaign fixture: a PR of an owner-gated lane waits too" {
  mkpr 102; mkpr 103
  campaign '.ownerGatedPrs = []'
  lb 102 103
  [ "$(merged)" = "103 " ]
  [[ $output == *"#102: skipped (owner-gated"* ]]
}

@test "campaign fixture: with the owner present, gated PRs land" {
  mkpr 101; mkpr 102
  campaign '.ownerPresent = true'
  lb 101 102
  [ "$status" -eq 0 ]
  [ "$(merged)" = "101 102 " ]
}

@test "a lane whose recorded head differs from the PR's head is stale: skipped" {
  mkpr 101; mkpr 103
  campaign '.ownerPresent = true | .lanes["fix-login"].headSha = ("ab" * 20)'
  lb 101 103
  [ "$status" -eq 20 ]
  [ "$(merged)" = "103 " ]
  [[ $output == *"#101: skipped (lane-head-stale(fix-login reports ababababa))"* ]]
}

@test "a lane head is compared exactly: a short prefix of the real head is stale" {
  mkpr 101
  h=$(cat "$STUB/pr/101/head")
  campaign ".ownerPresent = true | .lanes[\"fix-login\"].headSha = \"${h:0:7}\""
  lb 101
  [ "$status" -eq 2 ]
  [[ $output == *lane-head-stale* ]]
}

@test "records: the lane's implementer must match the record's, and may not review" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 101 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/101/head") d="$ORCH_STATE_DIR/verdicts/101"
  mkdir -p "$d"
  jq -n --arg sha "$h" '{schema: 1, pr: 101, headSha: $sha, verdict: "merge", round: 1, reviewer: "reviewer", implementer: "someone-else", model: "opus"}' > "$d/$h.json"
  campaign '.ownerPresent = true'
  lb 101
  [ "$status" -eq 2 ]
  jq '.implementer = "lane-session"' "$d/$h.json" > "$d/$h.new" && mv "$d/$h.new" "$d/$h.json"
  lb 101
  [ "$status" -eq 0 ]
}

@test "records: a reviewer who is the lane's implementer does not count, whatever the record says" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 101 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/101/head") d="$ORCH_STATE_DIR/verdicts/101"
  mkdir -p "$d"
  jq -n --arg sha "$h" '{schema: 1, pr: 101, headSha: $sha, verdict: "merge", round: 1, reviewer: "lane-session", implementer: "lane-session", model: "opus"}' > "$d/$h.json"
  campaign '.ownerPresent = true'
  user_setting 'review.reviewers: ""'
  lb 101
  [ "$status" -eq 2 ]
}

@test "a merge pause is honoured by default; land.honor_merge_pause false ignores it" {
  mkpr 104
  campaign '.mergePaused = true'
  lb 104
  [ "$status" -eq 2 ]
  [[ $output == *merge-paused* ]]
  user_setting "land.honor_merge_pause: false"
  lb 104
  [ "$(merged)" = "104 " ]
}

@test "an honoured merge pause holds every PR except the exempt ones" {
  mkpr 103; mkpr 104
  campaign '.mergePaused = true'
  lb 103 104
  [ "$status" -eq 20 ]
  [ "$(merged)" = "103 " ]
  [[ $output == *"#104: skipped (merge-paused)"* ]]
}

@test "a missing campaign state means no gates" {
  mkpr 101
  lb 101
  [ "$(merged)" = "101 " ]
  [[ $output == *"no campaign state"* ]]
}

@test "--lock-wait overrides lock_wait_seconds" {
  mkpr 11
  hold_lock 4
  CREWKIT_LOCK_WAIT_SECONDS=60 run "$BIN/land-batch" --yes --lock-wait 1 11
  wait
  [ "$status" -eq 75 ]
}

@test "the journal records each merge and the summary" {
  mkpr 11
  lb 11
  grep -q 'land-batch: merged #11' "$JOURNAL"
  grep -q 'land-batch: batch done: landed #11' "$JOURNAL"
}

@test "a PR whose changed files can't be read (no merge base) is not landed" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 11
  git checkout -q --orphan orphan
  git rm -rqf .
  mkdir -p src/billing && echo x > src/billing/a.ts
  git add src/billing/a.ts
  git commit -qm orphan
  git push -q origin HEAD:refs/pull/31/head
  pr_meta 31 "$(git rev-parse HEAD)"
  git checkout -q main
  lb 11 31
  [ "$(merged)" = "11 " ]
  [[ $output == *"#31: skipped (changed-files-unreadable)"* ]]
}

@test "15d a known flake beside a real failure in another job is not rerun" {
  mkpr 11; mkpr 12 --bad "flake\n FAIL  src/bigmem.test.ts" --bad2 "real\n FAIL  e2e/login.spec.ts"
  lb 11 12
  [ "$status" -eq 20 ]
  none -q rerun-failed-jobs "$STUB/calls.log"
  [[ $output == *"CULPRIT: #12"* ]]
  [[ $output == *"failed job 'e2e' is not a known flake"* ]]
}

# ---- the Opus review's findings (each fails without its fix) -------------------------------------

@test "review 1a: a rename out of a high-risk directory is high risk" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkdir -p src/billing && echo x > src/billing/charge.ts
  git add src/billing/charge.ts && git commit -qm billing && git push -q origin HEAD:main
  git checkout -q -B pr12 main
  mkdir -p src/other && git mv src/billing/charge.ts src/other/charge.ts && git commit -qm move
  git push -q origin HEAD:refs/pull/12/head
  pr_meta 12 "$(git rev-parse HEAD)"
  git checkout -q main
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"#12: skipped (high-risk(billing)"* ]]
}

@test "review 1b: a non-ASCII path in a high-risk directory is high risk" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file "src/billing/tarifé.ts"
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"#12: skipped (high-risk(billing)"* ]]
}

@test "review 2: a corrupt or unreadable campaign state holds every PR" {
  mkpr 11
  mkdir -p "$ORCH_CAMPAIGN_DIR"
  echo '{not json' > "$ORCH_CAMPAIGN_DIR/state.json"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: skipped (campaign-unreadable"* ]]
  echo '{}' > "$ORCH_CAMPAIGN_DIR/state.json"
  chmod 000 "$ORCH_CAMPAIGN_DIR/state.json"
  lb 11
  chmod 600 "$ORCH_CAMPAIGN_DIR/state.json"
  [ "$status" -eq 2 ]
  [[ $output == *"campaign-unreadable"* ]]
  echo '[]' > "$ORCH_CAMPAIGN_DIR/state.json"
  lb 11
  [ "$status" -eq 2 ]
}

comment() { # comment PR LOGIN TIME BODY: append a PR comment
  local f="$STUB/pr/$1/comments.json"
  [[ -e $f ]] || echo '[]' > "$f"
  jq --arg a "$2" --arg t "$3" --arg b "$4" '. + [{author: {login: $a}, createdAt: $t, body: $b}]' "$f" > "$f.new" && mv "$f.new" "$f"
}

@test "review 3a: a marker must end at whitespace or the line's end (MERGE-WITH-FIXES is not MERGE)" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE-WITH-FIXES $(cat "$STUB/pr/12/head") model=opus"
  lb 12
  [ "$status" -eq 2 ]
  comment 12 reviewer 2026-01-01T00:01:00Z "Verdict: MERGE $(cat "$STUB/pr/12/head") model=opus"
  lb 12
  [ "$status" -eq 0 ]
}

@test "review 3b: the latest verdict on the head decides; a later CHANGES-REQUESTED overrides a MERGE" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE $h model=opus"
  comment 12 reviewer 2026-01-01T00:05:00Z "Verdict: CHANGES-REQUESTED $h"
  lb 12
  [ "$status" -eq 2 ]
  comment 12 reviewer 2026-01-01T00:09:00Z "Verdict: MERGE $h (fixed) model=opus"
  lb 12
  [ "$status" -eq 0 ]
}

@test "review 3c: comment order on the page doesn't matter, createdAt does" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  comment 12 reviewer 2026-01-01T00:05:00Z "Verdict: CHANGES-REQUESTED $h"
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE $h model=opus"
  lb 12
  [ "$status" -eq 2 ]
}

runs_for() { # runs_for PR JSON_ARRAY_OF_RUNS: the PR head's runs; each run's jobs from jobs/<id>.json
  echo "{\"workflow_runs\": $2}" > "$STUB/runs/$(cat "$STUB/pr/$1/head").json"
}
jobs_of() { # jobs_of RUN_ID ATTEMPT CONCLUSION: a unit job and the aggregate check
  jq -n --argjson a "$2" --arg c "$3" '{jobs: [{name: "unit", status: "completed", conclusion: "success", run_attempt: $a, started_at: "2026-01-01T00:00:00Z"},
    {name: "ci-ok", status: "completed", conclusion: $c, run_attempt: $a, started_at: "2026-01-01T00:00:01Z"}]}' > "$STUB/jobs/$1.json"
}

@test "review 5a: ci.workflow and ci.event pick the runs that count" {
  mkpr 11
  runs_for 11 '[{"id":"lint","path":".github/workflows/lint.yml","event":"pull_request","created_at":"2026-01-01T00:09:00Z"},
               {"id":"push","path":".github/workflows/ci.yml","event":"push","created_at":"2026-01-01T00:08:00Z"},
               {"id":"ci","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"}]'
  jobs_of lint 1 success; jobs_of push 1 success; jobs_of ci 1 failure
  user_setting "ci.workflow: .github/workflows/ci.yml" "ci.event: pull_request"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "review 5b: the newest run decides, whatever its attempt number" {
  mkpr 11
  runs_for 11 '[{"id":"old","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z","run_attempt":2},
               {"id":"new","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T01:00:00Z"}]'
  jobs_of old 2 success; jobs_of new 1 failure
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "review 6: in records mode, a PR with no lane needs review.reviewers" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head") d="$ORCH_STATE_DIR/verdicts/12"
  mkdir -p "$d"
  jq -n --arg sha "$h" '{schema: 1, pr: 12, headSha: $sha, verdict: "merge", round: 1, reviewer: "anyone", implementer: "someone", model: "opus"}' > "$d/$h.json"
  user_setting 'review.reviewers: ""'
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"review.reviewers"* ]]
}

@test "review 7: a failed fetch after a squash stops the run (exit 12)" {
  for n in 11 12; do mkpr $n; done
  hook after_merge "chmod 000 $STUB_BARE/objects"
  lb 11 12
  chmod 755 "$STUB_BARE/objects"
  [ "$status" -eq 12 ]
  [[ $output == *"cannot fetch main after #11"* ]]
}

@test "review 9: the stale sweep leaves a labelled batch-shaped PR whose title isn't a batch's" {
  mkpr 11
  git push -q origin main:refs/heads/batch/20200101T000000Z
  echo '[{"number":77,"headRefName":"batch/20200101T000000Z","title":"fix: something"},
         {"number":78,"headRefName":"batch/20200101T000000Z-2","title":"batch: #5 (do not merge, closed automatically)"}]' > "$STUB/prlist.json"
  lb 11
  [ ! -e "$STUB/closed-77" ]
  [ -e "$STUB/closed-78" ]
}

@test "review B: ci.workflow is required (exit 78); ci.event defaults to pull_request" {
  mkpr 11
  user_unset ci.workflow
  lb 11
  [ "$status" -eq 78 ]
  [[ $output == *"'ci.workflow'"* ]]
  user_setting "ci.workflow: .github/workflows/ci.yml"
  runs_for 11 '[{"id":"push","path":".github/workflows/ci.yml","event":"push","created_at":"2026-01-01T00:09:00Z"},
               {"id":"pr","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"}]'
  jobs_of push 1 success; jobs_of pr 1 failure
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "review D: a later marker-shaped verdict without the SHA, or for another head, blocks an earlier MERGE" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE $h model=opus"
  comment 12 reviewer 2026-01-01T00:05:00Z "Verdict: CHANGES-REQUESTED (see the inline notes)"
  lb 12
  [ "$status" -eq 2 ]
  comment 12 reviewer 2026-01-01T00:06:00Z "Verdict: MERGE $h model=opus"
  lb 12
  [ "$status" -eq 0 ]
}

@test "review D: a later verdict for another head blocks too" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE $h model=opus"
  comment 12 reviewer 2026-01-01T00:05:00Z "Verdict: MERGE $OTHER_SHA model=opus"
  lb 12
  [ "$status" -eq 2 ]
}

@test "review D: comments are read from the paginated issue-comments API" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  comment 12 reviewer 2026-01-01T00:00:00Z "Verdict: MERGE $(cat "$STUB/pr/12/head") model=opus"
  lb 12
  [ "$status" -eq 0 ]
  grep -q '^api repos/OWNER/REPO/issues/12/comments?per_page=100 --paginate' "$STUB/calls.log"
}

@test "checks: a red commit status context on a PR's head holds it" {
  mkpr 11; mkpr 12
  mkdir -p "$STUB/status"
  echo '{"state":"failure","statuses":[{"context":"security/scan","state":"failure"}]}' > "$STUB/status/$(cat "$STUB/pr/12/head").json"
  lb 11 12
  [ "$(merged)" = "11 " ]
  [[ $output == *"#12: ci-ok is 'failure'"* ]]
}

@test "checks: an ignored status context doesn't hold a PR" {
  mkpr 12
  mkdir -p "$STUB/status"
  echo '{"state":"failure","statuses":[{"context":"security/scan","state":"failure"}]}' > "$STUB/status/$(cat "$STUB/pr/12/head").json"
  user_setting "ignored_checks: security/scan"
  lb 12
  [ "$(merged)" = "12 " ]
}

# ---- review_model: a high-risk PR's verdict must come from the review model -------------------

@test "review_model: a high-risk record by another model doesn't land the PR" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head") d="$ORCH_STATE_DIR/verdicts/12"
  mkdir -p "$d"
  jq -n --arg sha "$h" '{schema: 1, pr: 12, headSha: $sha, verdict: "merge", round: 1, reviewer: "reviewer",
    implementer: "lane-session", model: "sonnet"}' > "$d/$h.json"
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *review_model* ]]
  jq '.model = "claude-opus-5-5"' "$d/$h.json" > "$d/x" && mv "$d/x" "$d/$h.json"
  lb 12
  [ "$status" -eq 0 ]
}

@test "review_model: a comment verdict must name the model on its line" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  jq -n --arg b "Verdict: MERGE $h" '[{author: {login: "reviewer"}, createdAt: "2026-01-01T00:00:00Z", body: $b}]' > "$STUB/pr/12/comments.json"
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"review_model needs a model on the verdict line"* ]]
  jq -n --arg b "Verdict: MERGE $h model=opus" '[{author: {login: "reviewer"}, createdAt: "2026-01-01T00:00:00Z", body: $b}]' > "$STUB/pr/12/comments.json"
  lb 12
  [ "$status" -eq 0 ]
}

@test "review_model: an empty review_model checks no model" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review_model: ""'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head")
  jq -n --arg b "Verdict: MERGE $h" '[{author: {login: "reviewer"}, createdAt: "2026-01-01T00:00:00Z", body: $b}]' > "$STUB/pr/12/comments.json"
  lb 12
  [ "$status" -eq 0 ]
}

# ---- the second review of land-batch -------------------------------------------------------------

@test "review 9b-1: a failed jobs read leaves CI pending; an older green run can't vouch" {
  mkpr 11
  runs_for 11 '[{"id":"old","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"},
               {"id":"new","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T01:00:00Z"}]'
  jobs_of old 1 success
  mkdir -p "$STUB/jobs_fail"; touch "$STUB/jobs_fail/new"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'pending"* ]]
  [ -z "$(merged)" ]
}

@test "review 9b-2: statuses are read a hundred per page" {
  mkpr 11
  lb 11
  grep -qE "^api repos/OWNER/REPO/commits/[0-9a-f]{40}/status\?per_page=100" "$STUB/calls.log"
}

@test "jobs are listed with filter=latest (checks.py reads a mixed-attempt list as pending)" {
  mkpr 11
  lb 11
  grep -qE "^api repos/OWNER/REPO/actions/runs/[^/]+/jobs\?filter=latest&per_page=100 --paginate" "$STUB/calls.log"
}

@test "review 9b-3: a PR whose author can't be named gets no comment verdict" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  : > "$STUB/pr/12/author"
  verdict 12 "$(cat "$STUB/pr/12/head")"
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"author"* ]]
}

@test "review 9b-4: a failed commit-status read leaves CI pending, never green" {
  mkpr 11
  touch "$STUB/status_fail"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'pending"* ]]
  [ -z "$(merged)" ]
}

@test "a PR whose own head turns red while the batch runs is not merged (exit 9)" {
  mkpr 11; mkpr 12
  hook on_poll "echo failure > '$STUB/ci/$(cat "$STUB/pr/12/head")'"
  lb 11 12
  [ "$status" -eq 9 ]
  [[ $output == *"#12"*"CI on its head is no longer green"* ]]
  [ -z "$(merged)" ]
}

@test "checks: a red job in another workflow on the PR's head holds it as red" {
  mkpr 11
  runs_for 11 '[{"id":"ci","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"},
               {"id":"lint","path":".github/workflows/lint.yml","event":"pull_request","created_at":"2026-01-01T00:01:00Z"}]'
  jobs_of ci 1 success
  jq -n '{jobs: [{name: "lint", status: "completed", conclusion: "failure", run_attempt: 1, started_at: "2026-01-01T00:01:00Z"}]}' > "$STUB/jobs/lint.json"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "checks: a failed job in another workflow's unfinished run is red already, not pending" {
  mkpr 11
  runs_for 11 '[{"id":"ci","path":".github/workflows/ci.yml","event":"pull_request","created_at":"2026-01-01T00:00:00Z"},
               {"id":"lint","path":".github/workflows/lint.yml","event":"pull_request","created_at":"2026-01-01T00:01:00Z",
                "status":"in_progress","conclusion":null}]'
  jobs_of ci 1 success
  jq -n '{jobs: [{name: "lint", status: "completed", conclusion: "failure", run_attempt: 1, started_at: "2026-01-01T00:01:00Z"}]}' > "$STUB/jobs/lint.json"
  lb 11
  [ "$status" -eq 2 ]
  [[ $output == *"#11: ci-ok is 'failure'"* ]]
}

@test "gate settings are file-only: CREWKIT_* can't drop a high-risk area or add a reviewer" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  CREWKIT_HIGH_RISK_AREAS_BILLING_PATHS=nomatch lb 12   # the third review's repro
  [ "$status" -eq 2 ]
  [[ $output == *"no independent verdict"* ]]
  [ -z "$(merged)" ]
  verdict 12 "$(cat "$STUB/pr/12/head")" intruder
  CREWKIT_REVIEW_REVIEWERS=intruder lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}

@test "settings come from the main checkout: a lane worktree's local file can't drop a high-risk area" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"'
  mkpr 12 --file src/billing/charge.ts
  git -C "$W" worktree add -q "$BATS_TEST_TMPDIR/lane" -b lane-x main
  mkdir -p "$BATS_TEST_TMPDIR/lane/.claude"
  printf -- '---\nhigh_risk_areas.billing.paths: nomatch\nreview_model: ""\n---\n' > "$BATS_TEST_TMPDIR/lane/.claude/crewkit.local.md"
  cd "$BATS_TEST_TMPDIR/lane" || return 1
  lb 12
  [ "$status" -eq 2 ]
  [[ $output == *"no independent verdict"* ]]
  [ -z "$(merged)" ]
}

@test "review_model: the environment can't weaken or empty it (settings files only)" {
  settings 'high_risk_areas.billing.paths: "src/billing/**"' 'review.source: records'
  mkpr 12 --file src/billing/charge.ts
  h=$(cat "$STUB/pr/12/head") d="$ORCH_STATE_DIR/verdicts/12"
  mkdir -p "$d"
  jq -n --arg sha "$h" '{schema: 1, pr: 12, headSha: $sha, verdict: "merge", round: 1, reviewer: "reviewer",
    implementer: "lane-session", model: "claude-sonnet-5-5"}' > "$d/$h.json"
  CREWKIT_REVIEW_MODEL=claude lb 12
  [ "$status" -eq 2 ]
  CREWKIT_REVIEW_MODEL="" lb 12
  [ "$status" -eq 2 ]
  [ -z "$(merged)" ]
}
