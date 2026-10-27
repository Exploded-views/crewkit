#!/usr/bin/env bats
# lib/landing.sh on its own: what it hands lib/verdict.py (the lane's implementer, the reviewers),
# and its own guards. verdict.py's rules are tested once, in tests/verdict.bats.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  FX="$BATS_TEST_TMPDIR/fx"
  python3 "$REPO/tests/fixtures/verdicts/make.py" "$FX" > "$BATS_TEST_TMPDIR/cases"
}

verdict_in() { # verdict_in DIR PR SHA [REVIEWERS]: has_verdict with review.source records
  bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    SOURCE=records VDIR=$2 REVIEWERS=$5 R=OWNER/REPO CAMPAIGN=${CAMPAIGN:-/nonexistent}; has_verdict "$3" "$4"' \
    _ "$REPO" "$1" "$2" "$3" "${4:-}"
}

@test "records: review.reviewers narrows the accepted fixture to its reviewer" {
  read -r _ pr head _ _ < <(grep '^valid-merge ' "$BATS_TEST_TMPDIR/cases")
  run verdict_in "$FX/valid-merge" "$pr" "$head"
  [ "$status" -ne 0 ]   # no lane and no review.reviewers: nobody is known to be allowed
  run verdict_in "$FX/valid-merge" "$pr" "$head" someone-else
  [ "$status" -ne 0 ]
  run verdict_in "$FX/valid-merge" "$pr" "$head" "someone-else, reviewer-session"
  [ "$status" -eq 0 ]
}

@test "records with the campaign state: the lane's implementer must match the record's" {
  read -r _ pr head impl _ < <(grep '^valid-merge ' "$BATS_TEST_TMPDIR/cases")
  export CAMPAIGN="$BATS_TEST_TMPDIR/state.json"
  python3 "$REPO/tests/fixtures/campaign-state.py" > "$CAMPAIGN"
  [ "$(jq -r --argjson pr "$pr" '.lanes[] | select(.pr == $pr) | .implementer' "$CAMPAIGN")" = "$impl" ]
  run verdict_in "$FX/valid-merge" "$pr" "$head"
  [ "$status" -eq 0 ]
  jq '.lanes["fix-login"].implementer = "another-session"' "$CAMPAIGN" > "$CAMPAIGN.new" && mv "$CAMPAIGN.new" "$CAMPAIGN"
  run verdict_in "$FX/valid-merge" "$pr" "$head"
  [ "$status" -ne 0 ]
  jq '.lanes["fix-login"].implementer = "reviewer-session"' "$CAMPAIGN" > "$CAMPAIGN.new" && mv "$CAMPAIGN.new" "$CAMPAIGN"
  run verdict_in "$FX/valid-merge" "$pr" "$head"
  [ "$status" -ne 0 ]
}

@test "review C: the landers need bash 4.4 or later" {
  run bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    crew_land_bash_ok 4 3' _ "$REPO"
  [ "$status" -eq 78 ]
  [[ $output == *"bash 4.4"* ]]
  run bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    crew_land_bash_ok 3 2' _ "$REPO"
  [ "$status" -eq 78 ]
  run bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    crew_land_bash_ok 4 4 && crew_land_bash_ok 5 0 && echo fine' _ "$REPO"
  [ "$output" = fine ]
}

@test "review C: a failed read of the changed files is not 'no high-risk files'" {
  run bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    mapfile() { return 1; }; AREAS=(x); printf "src/billing/a\0" | risk_area' _ "$REPO"
  [ "$status" -ne 0 ]
}


@test "a lander that can't find the main checkout to read settings from stops as config (78)" {
  run bash -c 'source "$1/plugins/crew-orchestrator/lib/settings.sh"; source "$1/plugins/crew-orchestrator/lib/landing.sh"
    crew_cd_main_checkout() { return 1; }; crew_land_init land-batch' _ "$REPO"
  [ "$status" -eq 78 ]
  [[ $output == *"main checkout"* ]]
}
