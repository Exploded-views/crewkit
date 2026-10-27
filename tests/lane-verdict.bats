#!/usr/bin/env bats
# crew-lanes: lane-verdict writes and checks review verdict records (docs/review-verdicts.md).

load lanes-helpers

setup() {
  setup_lanes
  FX="$BATS_TEST_TMPDIR/fx"
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$FX" > "$BATS_TEST_TMPDIR/cases"
  HEAD=$(awk 'NR==1{print $3}' "$BATS_TEST_TMPDIR/cases")
  CREWKIT_REVIEW_VERDICT_DIR="$BATS_TEST_TMPDIR/verdicts"
  user_setting "review.verdict_dir: $CREWKIT_REVIEW_VERDICT_DIR"
}

@test "every shared fixture case gets its expected answer from check" {
  while read -r case pr head impl expect; do
    user_setting "review.verdict_dir: $FX/$case"
    run "$BIN/lane-verdict" check "$pr" "$head" --implementer "$impl"
    if [ "$expect" = accept ]; then
      [ "$status" -eq 0 ] || { echo "case $case: expected accept, got $status: $output"; return 1; }
    else
      [ "$status" -eq 1 ] || { echo "case $case: expected reject, got $status: $output"; return 1; }
    fi
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "record writes round 1, then round 2 to a new file" {
  run "$BIN/lane-verdict" record 101 "$HEAD" changes --reviewer rev --implementer impl --model opus
  [ "$status" -eq 0 ]
  [ -f "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.json" ]
  run "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus
  [ -f "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.2.json" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["round"]==2 and d["verdict"]=="merge" and d["schema"]==1 and d["reviewedAt"], d' "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.2.json"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 0 ]
}

@test "record refuses a self-review, a short SHA and an unknown verdict" {
  run "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer same --implementer same --model opus
  [ "$status" -eq 65 ]
  run "$BIN/lane-verdict" record 101 abc123 merge --reviewer rev --implementer impl --model opus
  [ "$status" -eq 65 ]
  run "$BIN/lane-verdict" record 101 "$HEAD" lgtm --reviewer rev --implementer impl --model opus
  [ "$status" -eq 65 ]
  [ ! -d "$CREWKIT_REVIEW_VERDICT_DIR/101" ]
}

@test "check refuses a reviewer outside review.reviewers when it is set" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer stranger --implementer impl --model opus >/dev/null
  user_setting "review.reviewers: rev-a, rev-b"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  [[ $output == *review.reviewers* ]]
  user_setting "review.reviewers: rev-a, stranger"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 0 ]
}

@test "check needs the implementer, so a self-review can't slip through" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus >/dev/null
  run "$BIN/lane-verdict" check 101 "$HEAD"
  [ "$status" -eq 64 ]
}

@test "records are written through a temp file and a rename" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus >/dev/null
  [ "$(ls -A "$CREWKIT_REVIEW_VERDICT_DIR/101")" = "$HEAD.json" ]
}

@test "usage errors exit 2" {
  run "$BIN/lane-verdict"
  [ "$status" -eq 64 ]
  run "$BIN/lane-verdict" record 101
  [ "$status" -eq 64 ]
}

@test "a settings value with quotes or \$(...) is never run as shell" {
  user_setting "review.verdict_dir: \"\"" "state_dir: $BATS_TEST_TMPDIR/st'\$(touch $BATS_TEST_TMPDIR/pwned)'x"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "check refuses a record whose implementer isn't the one the caller knows" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer someone-else --model opus >/dev/null
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer lane-impl
  [ "$status" -eq 1 ]
  [[ $output == *implementer* ]]
}

@test "a record whose body round disagrees with its file name makes the head's verdict invalid" {
  d="$CREWKIT_REVIEW_VERDICT_DIR/101"; mkdir -p "$d"
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus >/dev/null
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus >/dev/null
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["round"]=2; d["verdict"]="changes"; json.dump(d,open(p,"w"))' "$d/$HEAD.json"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  [[ $output == *round* ]]
}

@test "check --model refuses a record from another model, and passes the matching one" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl --model opus
  [ "$status" -eq 1 ]
  [[ $output == *review_model* ]]
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl --model ""
  [ "$status" -eq 0 ]
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model claude-opus-5-5 >/dev/null
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl --model opus
  [ "$status" -eq 0 ]
}

@test "record numbers rounds from round files only: another name for the head is skipped" {
  mkdir -p "$CREWKIT_REVIEW_VERDICT_DIR/101"
  echo '{}' > "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.backup.json"
  run "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus
  [ "$status" -eq 0 ]
  [ -f "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.json" ]
}

@test "an unreadable round file still holds its round: record never overwrites it" {
  mkdir -p "$CREWKIT_REVIEW_VERDICT_DIR/101"
  printf '{not json' > "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.json"
  run "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model opus
  [ "$status" -eq 0 ]
  [ "$(cat "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.json")" = '{not json' ]
  [ -f "$CREWKIT_REVIEW_VERDICT_DIR/101/$HEAD.2.json" ]
}

@test "check with no --model asks for review_model (default opus), and an empty review_model opts out" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  [[ $output == *review_model* ]]
  # The environment can't change review_model, to empty or to another model (a lane's session
  # can set its own env); only a settings file can.
  CREWKIT_REVIEW_MODEL=sonnet run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  CREWKIT_REVIEW_MODEL= run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  settings 'review_model: sonnet'
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 0 ]
  settings 'review_model: ""'
  CREWKIT_REVIEW_MODEL= run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 0 ]
}

@test "check reads review_model from the main checkout, never a lane worktree's own settings" {
  "$BIN/lane-verdict" record 101 "$HEAD" merge --reviewer rev --implementer impl --model sonnet >/dev/null
  git -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/lane-wt" -b lane/wt
  mkdir -p "$BATS_TEST_TMPDIR/lane-wt/.claude"
  [ -f "$MAIN/.claude/crewkit.md" ] && cp "$MAIN/.claude/crewkit.md" "$BATS_TEST_TMPDIR/lane-wt/.claude/crewkit.md"
  printf -- '---\nreview_model: ""\n---\n' > "$BATS_TEST_TMPDIR/lane-wt/.claude/crewkit.local.md"
  cd "$BATS_TEST_TMPDIR/lane-wt"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 1 ]
  [[ $output == *review_model* ]]
}

@test "check exits 78 when the repository's main checkout can't be found (a bare repo's worktree)" {
  git init -q --bare -b main "$BATS_TEST_TMPDIR/bare.git"
  git -C "$MAIN" push -q "$BATS_TEST_TMPDIR/bare.git" main
  git -C "$BATS_TEST_TMPDIR/bare.git" worktree add -q "$BATS_TEST_TMPDIR/bare-wt" main
  cd "$BATS_TEST_TMPDIR/bare-wt"
  run "$BIN/lane-verdict" check 101 "$HEAD" --implementer impl
  [ "$status" -eq 78 ]
  [[ $output == *"main checkout"* ]]
}
