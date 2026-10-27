#!/usr/bin/env bats
# crew-lanes: lane-land, the gated lander for one lane's PR.

load lanes-helpers

setup() {
  setup_lanes
  use_stub_gh
  CREWKIT_REVIEW_VERDICT_DIR="$BATS_TEST_TMPDIR/verdicts"
  CREWKIT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  user_setting "state_dir: $CREWKIT_STATE_DIR" "review.verdict_dir: $CREWKIT_REVIEW_VERDICT_DIR"
  export CREWKIT_GH_WRITE_MIN_GAP_MS=0 CREWKIT_GH_WRITE_BACKOFF_SECONDS=0
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" \
    "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "labels.fixed_in_main: lane:fixed"
  HEAD=$(hex40 a)
  stub_ready_pr 12 x "$HEAD"
  "$BIN/lane-state" set lanes.x.pr 12
  "$BIN/lane-state" set lanes.x.headSha "$HEAD"
  "$BIN/lane-state" set lanes.x.implementer impl
  "$BIN/lane-state" set lanes.x.status ready
}

approve() { "$BIN/lane-verdict" record 12 "${1:-$HEAD}" merge --reviewer rev --implementer impl --model opus >/dev/null; }
verdict_line() { printf '%s\n' "$output" | tail -1; }

@test "a ready, green, approved PR is squash-merged pinned to its head, and recorded" {
  approve
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  [[ $(verdict_line) == MERGED* ]]
  grep -q -- "pr merge 12 -R o/r --squash --match-head-commit $HEAD" "$STUB/calls.log"
  run "$BIN/lane-state" get lanes.x.status; [ "$output" = merged ]
  run "$BIN/lane-state" get lanes.x.mergedSha; [ "$output" = "$(hex40 f)" ]
  grep -q "landed lane x PR #12" "$CREWKIT_CAMPAIGN_DIR/journal.md"
}

@test "the closing issues are labelled through gh-write" {
  approve
  "$BIN/lane-land" x >/dev/null
  grep -qx lane:fixed "$STUB/labels/7"
}

@test "no verdict for the head: NO-VERDICT (33), nothing merged" {
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == NO-VERDICT* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a verdict for an older head doesn't count" {
  approve "$(hex40 b)"
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "a record naming a different implementer than the lane's is refused" {
  "$BIN/lane-verdict" record 12 "$HEAD" merge --reviewer rev --implementer someone-else --model opus >/dev/null
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "a lane with no implementer in the state can't land on records" {
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); del d["lanes"]["x"]["implementer"]; json.dump(d,open(p,"w"))' "$CREWKIT_CAMPAIGN_DIR/state.json"
  approve
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $output == *"has no implementer in the campaign state"* ]]
}

@test "comment verdicts count only from review.reviewers and must name the full head" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "intruder"}, body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  pr_set 12 '.comments += [{author: {login: "rev-a"}, body: "Verdict: MERGE aaaaaaaaa model=opus"}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  pr_set 12 --arg h "$HEAD" '.comments += [{author: {login: "rev-a"}, body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "a newer comment verdict asking for changes overrides an older merge" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "rev-a"}, body: ("Verdict: MERGE " + $h + " model=opus")}, {author: {login: "rev-a"}, body: ("Verdict: CHANGES " + $h)}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "comment verdicts need review.reviewers to be set" {
  settings "repo: o/r" "review.source: comments" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "anyone"}, body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $output == *"review.reviewers is not set"* ]]
}

@test "a pending job: PENDING (30)" {
  approve
  ci_set jobs '.[1] |= (.status = "in_progress" | .conclusion = null)'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  [[ $(verdict_line) == *unit* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a failed job: RED (31), naming it" {
  approve
  ci_set jobs '.[1].conclusion = "failure"'
  run "$BIN/lane-land" x
  [ "$status" -eq 31 ]
  [[ $(verdict_line) == RED*unit* ]]
}

@test "a red job in another workflow's run on the head blocks too" {
  approve
  ci_set runs --arg h "$HEAD" '. += [{id: 200, path: ".github/workflows/lint.yml", event: "pull_request", head_sha: $h, created_at: "2026-10-26T10:00:00Z", run_attempt: 1, status: "completed", conclusion: "success"}]'
  ci_set jobs '. += [{run_id: 200, run_attempt: 1, name: "markdown", status: "completed", conclusion: "failure", started_at: "2026-10-26T10:01:00Z", steps: []}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 31 ]
  [[ $(verdict_line) == *markdown* ]]
}

@test "an ignored check never blocks" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "ignored_checks: deploy-preview"
  ci_set status '.statuses = [{context: "deploy-preview", state: "failure"}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "the required check missing on the head: PENDING" {
  approve
  ci_set jobs 'map(select(.name != "ci-ok"))'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  [[ $output == *ci-ok* ]]
}

@test "too few other green checks: PENDING" {
  approve
  ci_set jobs 'map(select(.name == "ci-ok"))'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "min_green_checks: 0"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "a CI read that fails is PENDING, never green" {
  approve
  for kind in runs jobs status; do
    touch "$STUB/ci/fail_$kind"
    run "$BIN/lane-land" x
    [ "$status" -eq 30 ] || { echo "fail_$kind: status $status: $output"; return 1; }
    rm "$STUB/ci/fail_$kind"
  done
  none -q '^pr merge' "$STUB/calls.log"
}

@test "one run whose jobs can't be read is PENDING, even with the required run green" {
  approve
  ci_set runs --arg h "$HEAD" '. += [{id: 200, path: ".github/workflows/lint.yml", event: "pull_request", head_sha: $h, created_at: "2026-10-26T10:00:00Z", run_attempt: 1, status: "completed", conclusion: "success"}]'
  touch "$STUB/ci/fail_jobs_200"
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  [[ $(verdict_line) == *"run 200"* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "check data lib/checks.py can't read is PENDING, never green" {
  approve
  ci_set status '[]'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  [[ $(verdict_line) == *"could not decide"* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "the checks are read for the PR's exact head" {
  approve
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  grep -q "api repos/o/r/actions/runs?head_sha=$HEAD&per_page=100 --paginate" "$STUB/calls.log"
  # every page of a run's jobs, and 100 statuses per page (checks.py treats a combined status
  # with more contexts than were listed as that combined state)
  # filter=latest: checks.py reads a jobs list from mixed attempts as pending
  grep -q "api repos/o/r/actions/runs/100/jobs?filter=latest&per_page=100 --paginate" "$STUB/calls.log"
  grep -q "api repos/o/r/commits/$HEAD/status?per_page=100" "$STUB/calls.log"
}

@test "comment verdicts are read from every page of the PR's comments" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "rev-a"}, body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  grep -q "api repos/o/r/issues/12/comments?per_page=100 --paginate" "$STUB/calls.log"
}

@test "a PR whose author can't be read (a deleted account) fails closed on comment verdicts" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.author = null | .comments = [{author: {login: "rev-a"}, body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == NO-VERDICT*author* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a dirty merge state: DIRTY (32)" {
  approve
  pr_set 12 '.mergeStateStatus = "DIRTY"'
  run "$BIN/lane-land" x
  [ "$status" -eq 32 ]
}

@test "a draft or closed PR: NOT-READY (37)" {
  approve
  pr_set 12 '.isDraft = true'
  run "$BIN/lane-land" x
  [ "$status" -eq 37 ]
  pr_set 12 '.isDraft = false | .state = "CLOSED"'
  run "$BIN/lane-land" x
  [ "$status" -eq 37 ]
}

@test "an already-merged PR is recorded, not merged again" {
  pr_set 12 --arg m "$(hex40 e)" '.state = "MERGED" | .mergeCommit = {oid: $m}'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  [[ $(verdict_line) == ALREADY-MERGED* ]]
  none -q '^pr merge' "$STUB/calls.log"
  run "$BIN/lane-state" get lanes.x.status; [ "$output" = merged ]
}

@test "the lane's recorded head differs from the PR's: LANE-HEAD-STALE (36)" {
  approve
  "$BIN/lane-state" set lanes.x.headSha "$(hex40 c)"
  run "$BIN/lane-land" x
  [ "$status" -eq 36 ]
}

@test "a merge pause holds everything but exempt PRs" {
  approve
  "$BIN/lane-state" set mergePaused true
  run "$BIN/lane-land" x
  [ "$status" -eq 35 ]
  "$BIN/lane-state" set mergePauseExempt '[12]'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "an owner-gated PR or lane needs the owner present" {
  approve
  "$BIN/lane-state" set ownerGatedPrs '["12"]'
  run "$BIN/lane-land" x
  [ "$status" -eq 34 ]
  "$BIN/lane-state" set ownerGatedPrs '[]'
  "$BIN/lane-state" set ownerGatedLanes '["x"]'
  run "$BIN/lane-land" x
  [ "$status" -eq 34 ]
  "$BIN/lane-state" set ownerPresent true
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "unconfirmed high_risk_areas means every PR needs the owner present" {
  approve
  settings "repo: o/r" "review.source: records" "ci.workflow: .github/workflows/ci.yml"
  run "$BIN/lane-land" x
  [ "$status" -eq 34 ]
  [[ $output == *high_risk_areas* ]]
}

@test "land.precheck_hook can refuse a landing (PRECHECK-REFUSED, 38)" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" 'land.precheck_hook: echo "needs a migration run: $PR $HEAD"; exit 1'
  run "$BIN/lane-land" x
  [ "$status" -eq 38 ]
  [[ $output == *"needs a migration run: 12 $HEAD"* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a head that moves before the merge: MERGE-FAILED (8), nothing recorded" {
  approve
  # The stub's merge refuses a pin that isn't the head: simulate the head moving after the checks.
  cp "$REPO/tests/stub-gh" "$BATS_TEST_TMPDIR/real-stub"
  printf '#!/usr/bin/env bash\nif [ "$1 $2" = "pr merge" ]; then jq ".headRefOid = \\"%s\\"" "$STUB/pr/12.json" > "$STUB/pr/12.tmp" && mv "$STUB/pr/12.tmp" "$STUB/pr/12.json"; fi\nexec "%s" "$@"\n' "$(hex40 d)" "$BATS_TEST_TMPDIR/real-stub" > "$BATS_TEST_TMPDIR/stubbin/gh"
  chmod +x "$BATS_TEST_TMPDIR/stubbin/gh"
  run "$BIN/lane-land" x
  [ "$status" -eq 8 ]
  [[ $(verdict_line) == MERGE-FAILED* ]]
  run "$BIN/lane-state" get lanes.x.status; [ "$output" = ready ]
}

@test "a clean lane worktree is removed after landing; a dirty one is kept" {
  "$BIN/lane-new" x >/dev/null
  approve
  "$BIN/lane-land" x >/dev/null
  [ ! -d "$MAIN/.claude/worktrees/x" ]
}

@test "a dirty lane worktree is kept, with a warning" {
  "$BIN/lane-new" x >/dev/null
  echo wip > "$MAIN/.claude/worktrees/x/wip.txt"
  approve
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  [ -d "$MAIN/.claude/worktrees/x" ]
  [[ $output == *"kept"* ]]
}

@test "a held landing lock exits 75" {
  approve
  mkdir -p "$CREWKIT_STATE_DIR/locks"
  exec 9>"$CREWKIT_STATE_DIR/locks/land.lock"
  flock 9
  CREWKIT_LOCK_WAIT_SECONDS=1 run "$BIN/lane-land" x
  exec 9>&-
  [ "$status" -eq 75 ]
}

@test "a lane with no PR in the state, or no lane name: usage (64)" {
  run "$BIN/lane-land"
  [ "$status" -eq 64 ]
  run "$BIN/lane-land" no-such-lane
  [ "$status" -eq 64 ]
}

@test "a corrupt campaign state fails closed: STATE-UNREADABLE (39), nothing merged" {
  approve
  "$BIN/lane-state" set mergePaused true
  # Corrupt it after the lane's PR is known: no gate may silently read as "off".
  printf '{"lanes": {"x": {"pr": 12' > "$CREWKIT_CAMPAIGN_DIR/state.json"
  run "$BIN/lane-land" x
  [ "$status" -eq 39 ]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a state that parses but breaks the schema fails closed too" {
  approve
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ownerPresent"]="yes"; json.dump(d,open(p,"w"))' "$CREWKIT_CAMPAIGN_DIR/state.json"
  run "$BIN/lane-land" x
  [ "$status" -eq 39 ]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "a marker that only starts the verdict word doesn't count (MERGE-WITH-FIXES is not MERGE)" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "rev-a"}, createdAt: "2026-10-26T01:00:00Z", body: ("Verdict: MERGE-WITH-FIXES " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "the latest verdict comment by createdAt wins, whatever the list order" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [
    {author: {login: "rev-a"}, createdAt: "2026-10-26T03:00:00Z", body: ("Verdict: CHANGES-REQUESTED " + $h)},
    {author: {login: "rev-a"}, createdAt: "2026-10-26T01:00:00Z", body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "a merge call that returns but doesn't merge: MERGE-FAILED, nothing recorded" {
  approve
  touch "$STUB/merge_noop"
  run "$BIN/lane-land" x
  [ "$status" -eq 8 ]
  run "$BIN/lane-state" get lanes.x.status; [ "$output" = ready ]
}

@test "ci.workflow is required: unset, a config error (78), nothing merged" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26"
  run "$BIN/lane-land" x
  [ "$status" -eq 78 ]
  [[ $output == *ci.workflow* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "the required check must come from ci.workflow and ci.event" {
  approve
  ci_set runs '.[0].path = ".github/workflows/imposter.yml"'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  ci_set runs '.[0].path = ".github/workflows/ci.yml" | .[0].event = "push"'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "ci.event: push"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "a run that only mirrors another (ci.noise_step_prefix) speaks for nothing" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "ci.noise_step_prefix: Mirror the newest"
  ci_set jobs '.[0].steps = [{name: "Mirror the newest real run", status: "completed", conclusion: "success"}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
}

@test "commit status contexts count by their state" {
  approve
  ci_set status '.statuses = [{context: "external/scan", state: "success"}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "a pending or failed status context blocks" {
  approve
  ci_set status '.statuses = [{context: "external/scan", state: "pending"}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 30 ]
  ci_set status '.statuses[0].state = "error"'
  run "$BIN/lane-land" x
  [ "$status" -eq 31 ]
  [[ $(verdict_line) == *external/scan* ]]
}

@test "a merge call that errors but did merge is recorded as merged" {
  approve
  cp "$BATS_TEST_TMPDIR/stubbin/gh" "$BATS_TEST_TMPDIR/real-stub"
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\nif [ "$1 $2" = "pr merge" ]; then echo "gh: timed out waiting for a response" >&2; exit 1; fi\nexit $rc\n' "$BATS_TEST_TMPDIR/real-stub" > "$BATS_TEST_TMPDIR/stubbin/gh"
  chmod +x "$BATS_TEST_TMPDIR/stubbin/gh"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  [[ $(verdict_line) == MERGED* ]]
  run "$BIN/lane-state" get lanes.x.status; [ "$output" = merged ]
  grep -q "landed lane x PR #12" "$CREWKIT_CAMPAIGN_DIR/journal.md"
}

@test "a precheck hook that hangs is refused after land.precheck_timeout_seconds" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "land.precheck_hook: sleep 30" "land.precheck_timeout_seconds: 1"
  start=$(date +%s)
  run "$BIN/lane-land" x
  [ "$status" -eq 38 ]
  [[ $output == *"timed out"* ]]
  [ $(( $(date +%s) - start )) -lt 15 ]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "merged but the state can't be written: a loud failure, not a warning" {
  approve
  cp "$BIN/lane-state" "$BATS_TEST_TMPDIR/lane-state.real"
  # The PR merges; afterwards every state write fails.
  cp "$BATS_TEST_TMPDIR/stubbin/gh" "$BATS_TEST_TMPDIR/real-stub"
  printf '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\nif [ "$1 $2" = "pr merge" ]; then chmod 500 "%s"; fi\nexit $rc\n' "$BATS_TEST_TMPDIR/real-stub" "$CREWKIT_CAMPAIGN_DIR" > "$BATS_TEST_TMPDIR/stubbin/gh"
  chmod +x "$BATS_TEST_TMPDIR/stubbin/gh"
  run "$BIN/lane-land" x
  chmod 700 "$CREWKIT_CAMPAIGN_DIR"
  [ "$status" -eq 1 ]
  [[ $output == *"MERGED but NOT RECORDED"* ]]
}

@test "the PR author's own verdict comment never counts, even from a listed reviewer" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.author.login = "rev-a" | .comments = [{author: {login: "rev-a"}, createdAt: "2026-10-26T01:00:00Z", body: ("Verdict: MERGE " + $h + " model=opus")}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
}

@test "an unknown review.source is a config error (78), nothing merged" {
  settings "repo: o/r" "review.source: votes" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  run "$BIN/lane-land" x
  [ "$status" -eq 78 ]
  [[ $(verdict_line) == *"review.source must be records or comments, not 'votes'"* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "every lane-land verdict must name review_model: a sonnet record can't land" {
  "$BIN/lane-verdict" record 12 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == NO-VERDICT*review_model* ]]
  none -q '^pr merge' "$STUB/calls.log"
}

@test "review_model applies to comment verdicts too, and an empty review_model opts out" {
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml"
  pr_set 12 --arg h "$HEAD" '.comments = [{author: {login: "rev-a"}, body: ("Verdict: MERGE " + $h)}]'
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == *"review_model needs a model on the verdict line"* ]]
  settings "repo: o/r" "review.source: comments" "review.reviewers: rev-a" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" 'review_model: ""' "ci.workflow: .github/workflows/ci.yml"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "review_model sets the model asked for" {
  "$BIN/lane-verdict" record 12 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "review_model: sonnet" "ci.workflow: .github/workflows/ci.yml"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "CREWKIT_REVIEW_MODEL can't change the model check, to empty or to another model; a settings file can" {
  "$BIN/lane-verdict" record 12 "$HEAD" merge --reviewer rev --implementer impl --model claude-sonnet-5-5 >/dev/null
  CREWKIT_REVIEW_MODEL= run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == NO-VERDICT*review_model* ]]
  CREWKIT_REVIEW_MODEL=claude run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" 'review_model: ""'
  CREWKIT_REVIEW_MODEL= run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
}

@test "settings come from the main checkout: a lane worktree's crewkit.local.md can't weaken lane-land" {
  "$BIN/lane-verdict" record 12 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  git -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/lane-wt" -b lane/wt
  mkdir -p "$BATS_TEST_TMPDIR/lane-wt/.claude" "$BATS_TEST_TMPDIR/lane-wt/sub"
  # The committed settings file is in every worktree; the lane adds its own local one.
  cp "$MAIN/.claude/crewkit.md" "$BATS_TEST_TMPDIR/lane-wt/.claude/crewkit.md"
  printf -- '---\nreview_model: ""\nrepo: evil/other\n---\n' > "$BATS_TEST_TMPDIR/lane-wt/.claude/crewkit.local.md"
  cd "$BATS_TEST_TMPDIR/lane-wt/sub"
  run "$BIN/lane-land" x
  [ "$status" -eq 33 ]
  [[ $(verdict_line) == NO-VERDICT*review_model* ]]
  none -q 'evil/other' "$STUB/calls.log"
  none -q '^pr merge' "$STUB/calls.log"
}

@test "run from a subdirectory of the main checkout, the main checkout's settings apply" {
  approve
  mkdir -p "$MAIN/deep/er"
  cd "$MAIN/deep/er"
  run "$BIN/lane-land" x
  [ "$status" -eq 0 ]
  [[ $(verdict_line) == MERGED* ]]
}

@test "ignored_checks naming the required check is a config error (78), not a wait" {
  approve
  settings "repo: o/r" "review.source: records" "high_risk_areas.confirmed_by: owner" "high_risk_areas.confirmed_on: 2026-10-26" "ci.workflow: .github/workflows/ci.yml" "ignored_checks: deploy-preview, ci-ok"
  run "$BIN/lane-land" x
  [ "$status" -eq 78 ]
  [[ $output == *ignored_checks*ci-ok* ]]
  none -q '^pr merge' "$STUB/calls.log"
}
