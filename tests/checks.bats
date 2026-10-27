#!/usr/bin/env bats
# lib/checks.py: the one "required check green on the exact head" implementation every crewkit
# lander uses. The shared fixture generator (tests/fixtures/checks/make.py) defines the cases.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  C="$REPO/lib/checks.py"
  python3 "$REPO/tests/fixtures/checks/make.py" "$BATS_TEST_TMPDIR/fx" > "$BATS_TEST_TMPDIR/cases"
}

check() { # check CASE HEAD [extra args...]
  local d="$BATS_TEST_TMPDIR/fx/$1" head=$2
  shift 2
  run python3 "$C" --head "$head" --required-check ci-ok --workflow .github/workflows/ci.yml --event pull_request \
    --runs-json "$d/runs.json" --jobs-json "$d/jobs.json" --statuses-json "$d/statuses.json" --ignored deploy-preview \
    --noise-step-prefix "Mirror the newest real run" "$@"
}

@test "every shared fixture case gets its expected answer and exit code" {
  while read -r case head expect; do
    check "$case" "$head"
    case $expect in green) want=0 ;; pending) want=30 ;; red) want=31 ;; esac
    [ "$status" -eq "$want" ] || { echo "case $case: expected $expect ($want), got $status: $output"; return 1; }
    [[ $output == "$expect"* ]] || { echo "case $case: output '$output'"; return 1; }
  done < "$BATS_TEST_TMPDIR/cases"
}

@test "red and pending name what is red or pending" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check status-context-red "$head"
  [ "${lines[0]}" = "red: security/scan" ]
  check pending "$head"
  [ "${lines[0]}" = "pending: ci-ok, unit" ]
  check mixed-attempts "$head"
  [ "${lines[0]}" = "pending: run .github/workflows/ci.yml (jobs from more than one attempt)" ]
}

@test "--noise-step-prefix names the mirror step" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check noise-run-ignored "$head"
  [ "$status" -eq 0 ]
  check noise-run-ignored "$head" --noise-step-prefix ""
  [ "$status" -eq 31 ]
}

@test "--min-green 0 lets the required job alone count" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check required-job-alone "$head"
  [ "$status" -eq 30 ]
  check required-job-alone "$head" --min-green 0
  [ "$status" -eq 0 ]
}

@test "an empty --event counts runs from any event" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check push-event-ignored "$head" --event ""
  [ "$status" -eq 0 ]
}

@test "a head that isn't 40 lowercase hex, or unreadable JSON, is bad data (65)" {
  check green abc123
  [ "$status" -eq 65 ]
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  echo '{not json' > "$BATS_TEST_TMPDIR/fx/green/jobs.json"
  check green "$head"
  [ "$status" -eq 65 ]
}

@test "JSON of the wrong shape is bad data (65), not a crash" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  d="$BATS_TEST_TMPDIR/fx/green"
  echo '["not a run"]' > "$d/runs.json"
  check green "$head"
  [ "$status" -eq 65 ]
  python3 "$REPO/tests/fixtures/checks/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  echo '{"state": "success", "total_count": "5", "statuses": []}' > "$d/statuses.json"
  check green "$head"
  [ "$status" -eq 65 ]
  python3 "$REPO/tests/fixtures/checks/make.py" "$BATS_TEST_TMPDIR/fx" > /dev/null
  echo '{"state": "success", "statuses": "x"}' > "$d/statuses.json"
  check green "$head"
  [ "$status" -eq 65 ]
}

@test "--ignored naming the required check is a usage error (64)" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check green "$head" --ignored "deploy-preview, ci-ok"
  [ "$status" -eq 64 ]
  [[ $output == *"required check"* ]]
}

@test "usage errors exit 64" {
  run python3 "$C"
  [ "$status" -eq 64 ]
  run python3 "$C" --head x
  [ "$status" -eq 64 ]
}

@test "when a job decides, a second line names its run attempt" {
  head=$(awk 'NR==1{print $2}' "$BATS_TEST_TMPDIR/cases")
  check newest-attempt-wins "$head"
  [ "${lines[0]}" = green ]
  [ "${lines[1]}" = "attempt: 2" ]
  check required-check-is-a-context "$head"
  [ "${#lines[@]}" -eq 1 ]
}

@test "the invariant holds over every combination of run and status states (tests/checks_invariant.py)" {
  run python3 "$REPO/tests/checks_invariant.py" "$C"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *", 0 wrong" ]]
}
