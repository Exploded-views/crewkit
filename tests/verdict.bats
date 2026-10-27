#!/usr/bin/env bats
# lib/verdict.py: the one verdict implementation every crewkit lander uses
# (docs/review-verdicts.md). The shared fixture generators define the cases.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  V="$REPO/lib/verdict.py"
}

@test "records: every shared fixture case gets its expected answer" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$BATS_TEST_TMPDIR/fx" > "$BATS_TEST_TMPDIR/cases"
  while read -r case pr head impl expect; do
    run python3 "$V" records --pr "$pr" --head "$head" --dir "$BATS_TEST_TMPDIR/fx/$case" --lane-implementer "$impl"
    want=1; [ "$expect" = accept ] && want=0
    [ "$status" -eq "$want" ] || { echo "case $case: expected $expect, got $status: $output"; return 1; }
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "comments: every shared fixture case gets its expected answer" {
  python3 "$REPO/tests/fixtures/comments/make.py" "$BATS_TEST_TMPDIR/cx" > "$BATS_TEST_TMPDIR/cases"
  while read -r case head author reviewers expect; do
    [ "$reviewers" = - ] && reviewers=""
    run python3 "$V" comments --head "$head" --author "$author" --reviewers "$reviewers" \
      --comments-json "$BATS_TEST_TMPDIR/cx/$case.json" --model ""
    want=1; [ "$expect" = accept ] && want=0
    [ "$status" -eq "$want" ] || { echo "case $case: expected $expect, got $status: $output"; return 1; }
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "records: a PR without a lane needs reviewers" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/fx/valid-merge"
  [ "$status" -eq 1 ]
  [[ $output == *review.reviewers* ]]
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/fx/valid-merge" --reviewers "reviewer-session"
  [ "$status" -eq 0 ]
}

@test "records: an unexpected file name for the head refuses it" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  cp "$BATS_TEST_TMPDIR/fx/valid-merge/101/$head.json" "$BATS_TEST_TMPDIR/fx/valid-merge/101/$head.backup.json"
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/fx/valid-merge" --lane-implementer lane-session
  [ "$status" -eq 1 ]
}

@test "comments: require-sha false accepts a marker line without the SHA" {
  printf '[{"user":{"login":"rev-a"},"created_at":"2026-10-26T01:00:00Z","body":"Verdict: MERGE"}]' > "$BATS_TEST_TMPDIR/c.json"
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" comments --head "$head" --author a --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/c.json" --require-sha false --model ""
  [ "$status" -eq 0 ]
  run python3 "$V" comments --head "$head" --author a --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
}

@test "a head that isn't a full SHA, and unreadable comments, are bad data (65)" {
  run python3 "$V" records --pr 101 --head abc --dir "$BATS_TEST_TMPDIR" --reviewers r
  [ "$status" -eq 65 ]
  printf '{not json' > "$BATS_TEST_TMPDIR/c.json"
  run python3 "$V" comments --head "$(printf 'ab%.0s' {1..20})" --author a --reviewers r --comments-json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 65 ]
}

@test "usage errors exit 64" {
  run python3 "$V"
  [ "$status" -eq 64 ]
  run python3 "$V" records --pr 101
  [ "$status" -eq 64 ]
}

@test "records: a reviewer outside --reviewers is refused" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/fx/valid-merge" --lane-implementer lane-session --reviewers someone-else
  [ "$status" -eq 1 ]
  [[ $output == *"not in review.reviewers"* ]]
}

@test "comments: with no reviewers set, the reason says so" {
  printf '[{"user":{"login":"rev-a"},"created_at":"2026-10-26T01:00:00Z","body":"Verdict: MERGE x"}]' > "$BATS_TEST_TMPDIR/c.json"
  run python3 "$V" comments --head "$(printf 'ab%.0s' {1..20})" --author a --reviewers "" --comments-json "$BATS_TEST_TMPDIR/c.json"
  [ "$status" -eq 1 ]
  [[ $output == *"review.reviewers is not set"* ]]
}

@test "records: a record copied under another PR's directory doesn't count there" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  mkdir -p "$BATS_TEST_TMPDIR/moved/202"
  cp "$BATS_TEST_TMPDIR/fx/valid-merge/101/$head.json" "$BATS_TEST_TMPDIR/moved/202/"
  run python3 "$V" records --pr 202 --head "$head" --dir "$BATS_TEST_TMPDIR/moved" --reviewers reviewer-session
  [ "$status" -eq 1 ]
}

@test "records: review_model cases (--model) get their expected answer" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" --model-cases "$BATS_TEST_TMPDIR/mx" > "$BATS_TEST_TMPDIR/cases"
  while read -r case pr head impl model expect; do
    run python3 "$V" records --pr "$pr" --head "$head" --dir "$BATS_TEST_TMPDIR/mx/$case" --lane-implementer "$impl" --model "$model"
    want=1; [ "$expect" = accept ] && want=0
    [ "$status" -eq "$want" ] || { echo "case $case: expected $expect, got $status: $output"; return 1; }
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "comments: review_model cases (--model) get their expected answer" {
  python3 "$REPO/tests/fixtures/comments/make.py" --model-cases "$BATS_TEST_TMPDIR/mc" > "$BATS_TEST_TMPDIR/cases"
  while read -r case head author reviewers model expect; do
    run python3 "$V" comments --head "$head" --author "$author" --reviewers "$reviewers" \
      --comments-json "$BATS_TEST_TMPDIR/mc/$case.json" --model "$model"
    want=1; [ "$expect" = accept ] && want=0
    [ "$status" -eq "$want" ] || { echo "case $case: expected $expect, got $status: $output"; return 1; }
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "an empty --model checks no model, on both sources" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" --model-cases "$BATS_TEST_TMPDIR/mx" > /dev/null
  python3 "$REPO/tests/fixtures/comments/make.py" --model-cases "$BATS_TEST_TMPDIR/mc" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/mx/model-sonnet" --lane-implementer lane-session --model ""
  [ "$status" -eq 0 ]
  run python3 "$V" comments --head "$head" --author author --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/mc/model-missing.json" --model ""
  [ "$status" -eq 0 ]
}

@test "review_model refusals say what is missing" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" --model-cases "$BATS_TEST_TMPDIR/mx" > /dev/null
  python3 "$REPO/tests/fixtures/comments/make.py" --model-cases "$BATS_TEST_TMPDIR/mc" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/mx/model-sonnet" --lane-implementer lane-session --model opus
  [[ $output == "not accepted: "*"'sonnet'"*review_model* ]]
  run python3 "$V" comments --head "$head" --author author --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/mc/model-missing.json" --model opus
  [ "$output" = "not accepted: review_model needs a model on the verdict line" ]
}

@test "no --model at all means review_model's default, opus: fail closed, not skipped" {
  python3 "$REPO/tests/fixtures/verdicts/make.py" --model-cases "$BATS_TEST_TMPDIR/mx" > /dev/null
  python3 "$REPO/tests/fixtures/comments/make.py" --model-cases "$BATS_TEST_TMPDIR/mc" > /dev/null
  head=$(printf 'ab%.0s' {1..20})
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/mx/model-sonnet" --lane-implementer lane-session
  [ "$status" -eq 1 ]
  [[ $output == *review_model* ]]
  run python3 "$V" records --pr 101 --head "$head" --dir "$BATS_TEST_TMPDIR/mx/model-full-id" --lane-implementer lane-session
  [ "$status" -eq 0 ]
  run python3 "$V" comments --head "$head" --author author --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/mc/model-missing.json"
  [ "$status" -eq 1 ]
  run python3 "$V" comments --head "$head" --author author --reviewers rev-a --comments-json "$BATS_TEST_TMPDIR/mc/model-opus.json"
  [ "$status" -eq 0 ]
}
