#!/usr/bin/env bats
# crew-lanes: lane-state reads and writes <campaign_dir>/state.json (docs/campaign-state.md).

load lanes-helpers

setup() {
  setup_lanes
  STATE="$CREWKIT_CAMPAIGN_DIR/state.json"
  FIXTURE="$BATS_TEST_TMPDIR/fixture.json"
  python3 "$REPO/tests/fixtures/campaign-state.py" > "$FIXTURE"
}

@test "the shared fixture is valid against the schema" {
  run "$BIN/lane-state" validate "$FIXTURE"
  [ "$status" -eq 0 ]
}

@test "get reads scalars raw, arrays and objects as JSON" {
  cp "$FIXTURE" "$STATE"
  run "$BIN/lane-state" get ownerPresent;               [ "$output" = false ]
  run "$BIN/lane-state" get lanes.fix-login.status;     [ "$output" = review ]
  run "$BIN/lane-state" get lanes.fix-login.pr;         [ "$output" = 101 ]
  run "$BIN/lane-state" get ownerGatedLanes;            [ "$output" = '["auth-token-reuse"]' ]
}

@test "get of a missing key prints nothing and exits 1" {
  cp "$FIXTURE" "$STATE"
  run "$BIN/lane-state" get lanes.nope.status
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "get with no state file yet gives the schema defaults" {
  run "$BIN/lane-state" get ownerPresent
  [ "$status" -eq 0 ]
  [ "$output" = false ]
  run "$BIN/lane-state" get mergePaused
  [ "$output" = false ]
}

@test "set creates the file and a lane entry, stamping updatedAt" {
  run "$BIN/lane-state" set lanes.fix-login.status open
  [ "$status" -eq 0 ]
  run "$BIN/lane-state" get lanes.fix-login.status; [ "$output" = open ]
  run "$BIN/lane-state" get lanes.fix-login.updatedAt; [[ $output =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]
}

@test "set parses JSON values and keeps other strings as strings" {
  "$BIN/lane-state" set ownerPresent true
  "$BIN/lane-state" set ownerGatedPrs '[5, 6]'
  "$BIN/lane-state" set mergePausedNote 'held for the release'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ownerPresent"] is True and d["ownerGatedPrs"]==[5,6] and d["mergePausedNote"]=="held for the release", d' "$STATE"
}

@test "set keeps keys it doesn't know (an adapter's own flags)" {
  cp "$FIXTURE" "$STATE"
  "$BIN/lane-state" set mergePaused true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["adapterOnlyFlag"] is True and d["mergePaused"] is True' "$STATE"
}

@test "set refuses a value of the wrong type and leaves the file alone" {
  cp "$FIXTURE" "$STATE"
  before=$(sha256sum "$STATE")
  run "$BIN/lane-state" set ownerPresent yes
  [ "$status" -eq 65 ]
  run "$BIN/lane-state" set lanes.fix-login.status shipped
  [ "$status" -eq 65 ]
  run "$BIN/lane-state" set ownerGatedPrs '["x"]'
  [ "$status" -eq 65 ]
  [ "$(sha256sum "$STATE")" = "$before" ]
}

@test "validate fails on a bad type and names the key" {
  printf '{"ownerPresent": "no", "lanes": {}}' > "$BATS_TEST_TMPDIR/bad.json"
  run "$BIN/lane-state" validate "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  [[ $output == *ownerPresent* ]]
}

@test "concurrent writers don't lose updates" {
  for i in $(seq 1 20); do "$BIN/lane-state" set "lanes.l$i.status" open & done
  wait
  run python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["lanes"]))' "$STATE"
  [ "$output" = 20 ]
}

@test "a write goes through a temp file and a rename, never in place" {
  cp "$FIXTURE" "$STATE"
  ino=$(stat -c %i "$STATE")
  "$BIN/lane-state" set mergePaused true
  [ "$(stat -c %i "$STATE")" != "$ino" ]
  none -q . <(ls "$CREWKIT_CAMPAIGN_DIR" | grep -v -e '^state.json$' -e '^state.lock$' -e '^lanes$')
}

@test "a held lock makes set wait, then exit 75 (try again later)" {
  cp "$FIXTURE" "$STATE"
  exec 9>"$CREWKIT_CAMPAIGN_DIR/state.lock"
  flock 9
  CREWKIT_LOCK_WAIT_SECONDS=1 run "$BIN/lane-state" set mergePaused true
  exec 9>&-
  [ "$status" -eq 75 ]
}

@test "usage errors exit 2" {
  run "$BIN/lane-state"
  [ "$status" -eq 64 ]
  run "$BIN/lane-state" set onlykey
  [ "$status" -eq 64 ]
}

@test "a settings value with quotes or \$(...) is never run as shell" {
  user_setting "campaign_dir: $BATS_TEST_TMPDIR/c'\$(touch $BATS_TEST_TMPDIR/pwned)'x"
  run "$BIN/lane-state" get ownerPresent
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a lane's implementer is a string, and the fixture names implementers" {
  run "$BIN/lane-state" set lanes.fix-login.implementer lane-session-1
  [ "$status" -eq 0 ]
  run "$BIN/lane-state" set lanes.fix-login.implementer 42
  [ "$status" -eq 65 ]
  cp "$FIXTURE" "$STATE"
  run "$BIN/lane-state" get lanes.fix-login.implementer
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "lane SHAs must be full 40-hex commits" {
  run "$BIN/lane-state" set lanes.fix-login.headSha abc1234
  [ "$status" -eq 65 ]
  run "$BIN/lane-state" set lanes.fix-login.headSha "$(hex40 a)"
  [ "$status" -eq 0 ]
  run "$BIN/lane-state" set lanes.fix-login.mergedSha abc
  [ "$status" -eq 65 ]
}

@test "the fixture generator prints a valid state with full SHAs" {
  python3 "$REPO/tests/fixtures/campaign-state.py" > "$BATS_TEST_TMPDIR/s.json"
  run "$BIN/lane-state" validate "$BATS_TEST_TMPDIR/s.json"
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys,re; d=json.load(open(sys.argv[1])); assert all(re.fullmatch("[0-9a-f]{40}", l["headSha"]) for l in d["lanes"].values()), d' "$BATS_TEST_TMPDIR/s.json"
}
