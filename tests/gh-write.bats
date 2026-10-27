#!/usr/bin/env bats
# crew-lanes: gh-write, the one path for GitHub writes (throttled, idempotent, journalled).

load lanes-helpers

setup() {
  setup_lanes
  use_stub_gh
  settings "repo: o/r"
  CREWKIT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  user_setting "state_dir: $CREWKIT_STATE_DIR"
  export CREWKIT_GH_WRITE_MIN_GAP_MS=0 CREWKIT_GH_WRITE_BACKOFF_SECONDS=0
  BODY="$BATS_TEST_TMPDIR/body.md"
  printf 'Looks good.\n' > "$BODY"
}

@test "an issue comment is posted with its header as an H3" {
  run "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY"
  [ "$status" -eq 0 ]
  [[ $output == "posted issue-comment 7 :: Lane fix-login: opened" ]]
  [ "$(head -1 "$STUB/comments/7/1.md")" = "### Lane fix-login: opened" ]
  grep -qx 'Looks good.' "$STUB/comments/7/1.md"
}

@test "posting the same header again is a no-op" {
  "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY" >/dev/null
  run "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY"
  [ "$status" -eq 0 ]
  [[ $output == "exists issue-comment 7 :: Lane fix-login: opened" ]]
  [ "$(ls "$STUB/comments/7" | wc -l)" -eq 1 ]
}

@test "a header that is only a prefix of an existing one still posts" {
  "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened again" "$BODY" >/dev/null
  run "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY"
  [[ $output == posted* ]]
}

@test "a PR review comment is posted and is idempotent" {
  run "$BIN/gh-write" pr-review 12 "Review: round 1" "$BODY"
  [[ $output == "posted pr-review 12 :: Review: round 1" ]]
  run "$BIN/gh-write" pr-review 12 "Review: round 1" "$BODY"
  [[ $output == exists* ]]
  grep -q -- '--comment' "$STUB/calls.log"
}

@test "a body over the cap is posted as a summary with a pointer" {
  { echo "# Review of PR 12"; for i in $(seq 1 200); do echo "line $i of a long review"; done; echo "Verdict: MERGE"; } > "$BODY"
  "$BIN/gh-write" pr-comment 12 "Review: round 2" "$BODY" >/dev/null
  f="$STUB/comments/12/1.md"
  [ "$(wc -c < "$f")" -le 1800 ]
  grep -q '^\*\*Review of PR 12\*\*$' "$f"
  grep -q 'Verdict: MERGE' "$f"
  grep -q 'summary only' "$f"
}

@test "labels are added and removed" {
  "$BIN/gh-write" label 7 lane:in-progress >/dev/null
  run "$BIN/gh-write" label 7 lane:fixed lane:in-progress
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/labels/7")" = lane:fixed ]
}

@test "pr-ready marks the PR ready" {
  run "$BIN/gh-write" pr-ready 12
  [ "$status" -eq 0 ]
  [ -e "$STUB/ready/12" ]
}

@test "every call names the repo" {
  "$BIN/gh-write" issue-comment 7 "h" "$BODY" >/dev/null
  "$BIN/gh-write" label 7 x >/dev/null
  "$BIN/gh-write" pr-ready 12 >/dev/null
  none -v -e '-R o/r' -e '^api repos/o/r/' "$STUB/calls.log"
}

@test "a failing write is retried, then succeeds" {
  echo 2 > "$STUB/fail_next"
  run "$BIN/gh-write" issue-comment 7 "h" "$BODY"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^issue comment' "$STUB/calls.log")" -eq 3 ]
}

@test "a write that keeps failing exits 1 after gh_write.retries tries" {
  echo 99 > "$STUB/fail_next"
  CREWKIT_GH_WRITE_RETRIES=3 run "$BIN/gh-write" issue-comment 7 "h" "$BODY"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^issue comment' "$STUB/calls.log")" -eq 3 ]
}

@test "writes are journalled" {
  "$BIN/gh-write" issue-comment 7 "h" "$BODY" >/dev/null
  "$BIN/gh-write" label 7 x >/dev/null
  [ "$(grep -c 'gh-write' "$CREWKIT_CAMPAIGN_DIR/journal.md")" -eq 2 ]
  grep -q 'gh-write issue-comment 7 rc=0' "$CREWKIT_CAMPAIGN_DIR/journal.md"
}

@test "writes are spaced by gh_write.min_gap_ms" {
  export CREWKIT_GH_WRITE_MIN_GAP_MS=400
  start=$(date +%s%N)
  "$BIN/gh-write" label 7 a >/dev/null
  "$BIN/gh-write" label 7 b >/dev/null
  [ $(( ($(date +%s%N) - start) / 1000000 )) -ge 400 ]
}

@test "a held lock exits 75 (try again later)" {
  mkdir -p "$CREWKIT_STATE_DIR/locks"
  exec 9>"$CREWKIT_STATE_DIR/locks/gh-write.lock"
  flock 9
  CREWKIT_LOCK_WAIT_SECONDS=1 run "$BIN/gh-write" label 7 x
  exec 9>&-
  [ "$status" -eq 75 ]
}

@test "no repo setting exits 78" {
  rm "$MAIN/.claude/crewkit.md"
  run "$BIN/gh-write" label 7 x
  [ "$status" -eq 78 ]
}

@test "unknown kinds and missing arguments exit 2" {
  run "$BIN/gh-write" merge 7
  [ "$status" -eq 64 ]
  run "$BIN/gh-write" issue-comment 7
  [ "$status" -eq 64 ]
}

@test "the duplicate check survives a reader that stops early (no SIGPIPE false negative)" {
  "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY" >/dev/null
  touch "$STUB/api_padding"
  for i in 1 2 3 4 5; do
    run "$BIN/gh-write" issue-comment 7 "Lane fix-login: opened" "$BODY"
    [[ $output == exists* ]]
  done
  [ "$(ls "$STUB/comments/7" | wc -l)" -eq 1 ]
}
