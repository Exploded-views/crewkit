#!/usr/bin/env bats
# crewkit node report (libexec/crewkit-node-report): the read-only JSON report a node prints, which
# the hub runs as the forced ssh command. herdr is the stub (tests/stubs/herdr, per-session mode);
# the node state is a fixture, as `crewkit node join` writes it.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

TOKEN=$(printf "a%.0s" {1..64})

setup() {
  ck_setup
  STATE="$HOME/.local/state/crewkit"
  herdr_session local default 1 1
  node_state default "$(good_state)"
}

# good_state [JQ_FILTER]: a valid node state for session default, optionally edited.
good_state() {
  jq -cn --arg t "$TOKEN" '{schema: 1, node_id: "n-abcdefg234", name: "lab", session: "default", registry_id: "r-abcdefg234",
    join_token_sha256: $t, lead: null, bridge: "bridge", joined_at: "2026-10-27T00:00:00Z"} | '"${1:-.}"
}
# node_state SESSION JSON
node_state() { mkdir -p "$STATE/node"; printf '%s\n' "$2" > "$STATE/node/$1.json"; }
nocalls() { [ ! -s "$PSTUB/herdr.log" ]; }
# empty_out: stdout is empty (run --separate-stderr)
rep() { run --separate-stderr ck node report "$@"; }
# tree_with_steps BODY: the libexec of the test tree as a real directory of links, plus ck/steps.sh.
tree_with_steps() {
  local f
  rm -rf "$TREE/libexec"
  mkdir -p "$TREE/libexec/ck"
  for f in "$REPO"/libexec/*; do [ -d "$f" ] || ln -s "$f" "$TREE/libexec/$(basename "$f")"; done
  for f in "$REPO"/libexec/ck/*; do ln -s "$f" "$TREE/libexec/ck/$(basename "$f")"; done
  printf '%s\n' "$1" > "$TREE/libexec/ck/steps.sh"
}
# gate JSON: the push gate of the tree answers `status --json` with JSON.
gate() { printf '#!/bin/sh\necho %s\n' "'$1'" > "$TREE/push-gate/push-gate.sh"; chmod +x "$TREE/push-gate/push-gate.sh"; }

@test "prints one JSON line with the documented keys and nothing else" {
  rep
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  jq -e 'keys == ["agents","at","boot_start","bridge","crewkit","herdr","join_token_sha256","name","node_id","other_sessions","platform","push_gate","schema","session"]' <<<"$output"
  [ -z "$stderr" ]
}

@test "the values: node state, time, versions, platform, and an empty agent list" {
  rep
  jq -e --arg t "$TOKEN" --arg v "$(cat "$REPO/libexec/VERSION")" '.schema == 1 and .node_id == "n-abcdefg234" and .name == "lab"
    and .session == "default" and .at == "2026-10-26T07:33:20Z" and .crewkit == $v and .join_token_sha256 == $t
    and .herdr == {version: "0.9.5", protocol: 22, server_running: true} and .agents == [] and .other_sessions == []
    and .boot_start == "absent" and .push_gate == "absent"
    and .bridge == {name: "bridge", status: "absent"}' <<<"$output"
  jq -e '.platform.os | IN("linux", "darwin")' <<<"$output"
  jq -e '.platform.arch | IN("amd64", "arm64")' <<<"$output"
}

@test "the output's keys stay equal to the registry's CK_REPORT_KEYS" {
  rep
  keys=$(bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/registry.sh"; echo "$CK_REPORT_KEYS"' _ "$TREE")
  [ "$(jq -r 'keys | join(" ")' <<<"$output")" = "$keys" ]
}

@test "roles come from tokens, else from node state" {
  node_state default "$(good_state '.lead = "lead"')"
  herdr_agent local default w1:p1 first working role=worker
  herdr_agent local default w1:p2 lead idle
  herdr_agent local default w1:p3 bridge idle
  herdr_agent local default w1:p4 other idle
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.agents[] | .role]' <<<"$output")" = '["worker","lead","bridge",null]' ]
}

@test "the lead or bridge in node state may be a pane id" {
  node_state default "$(good_state '.lead = "w1:p4" | .bridge = "w1:p3"')"
  herdr_agent local default w1:p3 - idle
  herdr_agent local default w1:p4 - working
  rep
  [ "$(jq -c '[.agents[] | .role]' <<<"$output")" = '["bridge","lead"]' ]
  [ "$(jq -c .bridge <<<"$output")" = '{"name":"w1:p3","status":"idle"}' ]
}

@test "access: the token if exactly reader or writer, else writer for the lead, reader for the bridge, else unknown" {
  node_state default "$(good_state '.lead = "lead"')"
  herdr_agent local default w1:p1 x1 working access=reader
  herdr_agent local default w1:p2 x2 idle access=writer
  herdr_agent local default w1:p3 lead idle
  herdr_agent local default w1:p4 bridge idle
  herdr_agent local default w1:p5 other idle
  herdr_agent local default w1:p6 other2 idle access=admin
  herdr_agent local default w1:p7 other3 idle access=READER
  herdr_agent local default w1:p8 other4 idle role=lead
  rep
  [ "$(jq -c '[.agents[] | .access]' <<<"$output")" = '["reader","writer","writer","reader","unknown","unknown","unknown","writer"]' ]
}

@test "an agent is never guessed to be a reader" {
  herdr_agent local default w1:p1 stranger idle role=reviewer
  rep
  [ "$(jq -r '.agents[0].access' <<<"$output")" = unknown ]
}

@test "the bridge's status is that of its agent" {
  herdr_agent local default w1:p2 bridge blocked
  rep
  [ "$(jq -c .bridge <<<"$output")" = '{"name":"bridge","status":"blocked"}' ]
  node_state default "$(good_state '.bridge = null')"
  rep
  [ "$(jq -c .bridge <<<"$output")" = '{"name":null,"status":null}' ]
}

@test "the report carries no cwd, title or hostname" {
  herdr_agent local default w1:p1 lead working role=lead
  jq -c 'map(. + {cwd: "/home/x/client-repo", title: "secret"})' "$PSTUB/herdr/local/default/panes.json" > "$BATS_TEST_TMPDIR/p.json"
  mv "$BATS_TEST_TMPDIR/p.json" "$PSTUB/herdr/local/default/panes.json"
  rep
  [ "$status" -eq 0 ]
  jq -e '.agents[0].pane_id == "w1:p1"' <<<"$output"
  ! grep -q client-repo <<<"$output"
  ! grep -q secret <<<"$output"
  ! grep -qF "$(uname -n)" <<<"$output"
  jq -e '.agents | all(.[]; keys == ["access","name","pane_id","project","role","status"])' <<<"$output"
}

@test "a hostile agent name or token is null, never passed through" {
  herdr_agent local default w1:p1 'a b;rm' working 'role=x y'
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -c '.agents[0] | [.name, .role]' <<<"$output")" = '[null,null]' ]
}

@test "other running sessions are listed by name only, and not the node's own" {
  herdr_session local scratch 0 1
  herdr_session local idle2 0 0
  herdr_agent local scratch w9:p1 secretagent working
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -c '.other_sessions' <<<"$output")" = '[{"name":"idle2","running":false},{"name":"scratch","running":true}]' ]
  ! grep -q secretagent <<<"$output"
}

@test "--session reports another session, with that session's node state" {
  herdr_session local scratch 0 1
  herdr_agent local scratch w9:p1 solo idle
  node_state scratch "$(good_state '.session = "scratch" | .name = "other"')"
  rep --session scratch
  [ "$status" -eq 0 ]
  jq -e '.session == "scratch" and .name == "other" and (.agents | length) == 1 and (.other_sessions == [{name: "default", running: true}])' <<<"$output"
}

@test "herdr not running: exit 0, server_running false, no agents" {
  herdr_session local default 1 0
  rep
  [ "$status" -eq 0 ]
  jq -e '.herdr.server_running == false and .agents == []' <<<"$output"
}

@test "no herdr at all: exit 0, server_running false, no agents" {
  mkdir -p "$BATS_TEST_TMPDIR/nohd"
  ln -sf "$(command -v jq)" "$BATS_TEST_TMPDIR/nohd/jq"
  ln -sf "$(command -v bash)" "$BATS_TEST_TMPDIR/nohd/bash"
  node_state default "$(good_state)"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nohd:/usr/bin:/bin" "$TREE/bin/crewkit" node report --session default
  [ "$status" -eq 0 ]
  jq -e '.herdr == {version: null, protocol: null, server_running: false} and .agents == [] and .other_sessions == []' <<<"$output"
}

@test "herdr failing on a running server is 1, with nothing on stdout" {
  echo boom > "$PSTUB/herdr/local/default/list_fail"
  rep
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == *boom* ]]
}

@test "writes nothing: a read-only HOME still reports" {
  find "$HOME" | sort > "$BATS_TEST_TMPDIR/before"
  chmod -R a-w "$HOME"
  rep
  chmod -R u+w "$HOME"
  [ "$status" -eq 0 ]
  jq -e .node_id <<<"$output"
  find "$HOME" | sort | diff - "$BATS_TEST_TMPDIR/before"
}

@test "writes nothing: a read-only TMPDIR still reports, and a scratch directory is left behind by none" {
  mkdir "$BATS_TEST_TMPDIR/ro" "$BATS_TEST_TMPDIR/tmp"
  chmod a-w "$BATS_TEST_TMPDIR/ro"
  TMPDIR="$BATS_TEST_TMPDIR/ro" rep
  [ "$status" -eq 0 ]
  jq -e .node_id <<<"$output"
  TMPDIR="$BATS_TEST_TMPDIR/tmp" rep
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
  chmod u+w "$BATS_TEST_TMPDIR/ro"
}

@test "no state is created when there is none: the state directory is not made" {
  rm -rf "$STATE"
  rep
  [ "$status" -eq 78 ]
  [ ! -e "$STATE" ]
}

@test "the state_dir setting is honoured" {
  user_setting 'state_dir: ~/alt'
  mkdir -p "$HOME/alt/node"
  mv "$STATE/node/default.json" "$HOME/alt/node/default.json"
  rep
  [ "$status" -eq 0 ]
  jq -e '.name == "lab"' <<<"$output"
}

@test "the forced command ignores SSH_ORIGINAL_COMMAND" {
  SSH_ORIGINAL_COMMAND='crewkit node join' rep
  [ "$status" -eq 0 ]
  jq -e .node_id <<<"$output"
  SSH_ORIGINAL_COMMAND='; touch /nonexistent/x' rep
  [ "$status" -eq 0 ]
  SSH_ORIGINAL_COMMAND='crewkit node report --session x' rep
  [ "$status" -eq 0 ]
  jq -e '.session == "default"' <<<"$output"
}

@test "any argument but --session S is usage (64), with no herdr call and no read of node state" {
  echo 'not json' > "$STATE/node/default.json"
  : > "$PSTUB/herdr.log"
  for args in "--yes" "--session" "--session default extra" "--session=default" "default" "--session default --yes" "-- --session default" "--session ../x" "--session a.b" "--session -x" "--session ''"; do
    eval "rep $args"
    [ "$status" -eq 64 ] || { echo "$args: $status"; return 1; }
    [ -z "$output" ]
  done
  rep --session ''
  [ "$status" -eq 64 ]
  nocalls
}

@test "no node state is 78, with nothing on stdout" {
  rm "$STATE/node/default.json"
  rep
  [ "$status" -eq 78 ]
  [ -z "$output" ]
  [[ $stderr == *"not a crewkit node"* ]]
  herdr_session local scratch 0 1
  rep --session scratch
  [ "$status" -eq 78 ]
}

@test "node state that fails a check is 65, with nothing on stdout" {
  local n=0 f
  for f in '.schema = 2' '.schema = "1"' '.node_id = "n-ABCDEFG234"' '.node_id = "x-abcdefg234"' '.node_id = "n-abcdefg234\n"' \
    '.registry_id = "n-abcdefg234"' '.registry_id = 7' '.name = "Lab"' '.name = "lab\n"' '.name = ""' '.session = "scratch"' \
    '.join_token_sha256 = "abc"' '.join_token_sha256 = ("A" * 64)' '.join_token_sha256 = ("a" * 63)' '.join_token_sha256 = null' \
    '.lead = "a b"' '.lead = 5' '.lead = ""' '.bridge = "x;y"' '.bridge = ["a"]' '.bridge = ("a" * 65)' 'del(.name)'; do
    node_state default "$(good_state "$f")"
    rep
    [ "$status" -eq 65 ] || { echo "$f: $status"; return 1; }
    [ -z "$output" ]
    n=$((n + 1))
  done
  for f in 'not json' '[]' '"x"' '{}' ''; do
    node_state default "$f"
    rep
    [ "$status" -eq 65 ] || { echo "[$f]: $status"; return 1; }
    [ -z "$output" ]
  done
}

@test "node state: null lead and bridge, and a 64-character pane or name, are valid" {
  node_state default "$(good_state '.lead = null | .bridge = ("a" * 64)')"
  rep
  [ "$status" -eq 0 ]
  node_state default "$(good_state 'del(.lead) | .bridge = null')"
  rep
  [ "$status" -eq 0 ]
}

@test "an oversize node state is 65" {
  node_state default "$(good_state '.junk = ("x" * 70000)')"
  rep
  [ "$status" -eq 65 ]
  [ -z "$output" ]
}

@test "the default session is herdr's default one" {
  herdr_session local default 0 1
  herdr_session local zed 1 1
  node_state zed "$(good_state '.session = "zed"')"
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -r .session <<<"$output")" = zed ]
}

@test "push_gate: installed, installed without the denylist, and absent otherwise" {
  gate '{"installed":true,"denylist":true}'
  rep
  [ "$(jq -r .push_gate <<<"$output")" = installed ]
  gate '{"installed":true,"denylist":false}'
  rep
  [ "$(jq -r .push_gate <<<"$output")" = no-denylist ]
  gate '{"installed":false,"denylist":true}'
  rep
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
  gate 'garbage'
  rep
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
  gate '"installed"'
  rep
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
  printf '#!/bin/sh\necho {\\"installed\\":true,\\"denylist\\":true}\nexit 3\n' > "$TREE/push-gate/push-gate.sh"
  rep
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
  rm "$TREE/push-gate/push-gate.sh"
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
}

@test "push_gate: the fixture dispatcher's own answers" {
  PG_INSTALLED=1 PG_DENYLIST=1 rep
  [ "$(jq -r .push_gate <<<"$output")" = installed ]
  PG_INSTALLED=1 PG_DENYLIST=0 rep
  [ "$(jq -r .push_gate <<<"$output")" = no-denylist ]
  rep
  [ "$(jq -r .push_gate <<<"$output")" = absent ]
}

@test "boot_start comes from ck_boot_status when the tree has it, else absent" {
  rep
  [ "$(jq -r .boot_start <<<"$output")" = absent ]
  tree_with_steps 'ck_boot_status() { echo enabled; }'
  rep
  [ "$(jq -r .boot_start <<<"$output")" = enabled ]
  tree_with_steps 'ck_boot_status() { echo "disabled $1" | cut -d" " -f1; [ "$1" = default ]; }'
  rep
  [ "$(jq -r .boot_start <<<"$output")" = disabled ]
  tree_with_steps 'ck_boot_status() { echo bogus; }'
  rep
  [ "$(jq -r .boot_start <<<"$output")" = absent ]
  tree_with_steps 'ck_boot_status() { echo enabled; return 1; }'
  rep
  [ "$(jq -r .boot_start <<<"$output")" = absent ]
}

@test "a ck_boot_status exported from the environment is not used" {
  ck_boot_status() { echo enabled; }
  export -f ck_boot_status
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -r .boot_start <<<"$output")" = absent ]
}

@test "platform: os and arch are mapped, and anything else is other" {
  local row os arch
  for row in "Linux x86_64 linux amd64" "Darwin arm64 darwin arm64" "Linux aarch64 linux arm64" "Linux amd64 linux amd64" "FreeBSD sparc64 other other" "Linux armv7l linux other"; do
    set -- $row
    fake_host box "$1" "$2"
    PATH="$PSTUB/hosts/box/bin:$PATH" rep
    [ "$status" -eq 0 ]
    [ "$(jq -c '.platform' <<<"$output")" = "{\"os\":\"$3\",\"arch\":\"$4\"}" ] || { echo "$row: $output"; return 1; }
  done
}

# ---- fix round 1 ----

@test "node state: more than one JSON document, or trailing garbage, is 65 whatever the order" {
  local good hostile
  good=$(good_state)
  hostile=$(good_state '.schema = 99 | .session = "elsewhere" | .lead = "ALL" | .join_token_sha256 = "HOSTILE"')
  for body in "$good"$'\n'"$hostile" "$hostile"$'\n'"$good" "$good"$'\n'"$good" "$good junk" "$good"$'\n''{'; do
    node_state default "$body"
    rep
    [ "$status" -eq 65 ] || { echo "[$body]: $status"; return 1; }
    [ -z "$output" ]
  done
}

@test "node state: a NUL byte is 65 with a fixed message and no warning or path on stderr" {
  printf '%s\0\n' "$(good_state)" > "$STATE/node/default.json"
  rep
  [ "$status" -eq 65 ]
  [ -z "$output" ]
  [[ $stderr == "crewkit: node state is invalid" ]]
}

@test "node state: a symlinked state file is 65" {
  mv "$STATE/node/default.json" "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$STATE/node/default.json"
  rep
  [ "$status" -eq 65 ]
  [ -z "$output" ]
}

@test "a name in node state that two agents share matches neither: no role, access unknown" {
  herdr_agent local default w1:p1 bridge idle
  herdr_agent local default w1:p2 bridge idle
  rep
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.agents[] | [.role, .access]]' <<<"$output")" = '[[null,"unknown"],[null,"unknown"]]' ]
  [ "$(jq -c .bridge <<<"$output")" = '{"name":"bridge","status":"unknown"}' ]
}

@test "a pane id in node state wins over names, even when names are shared" {
  node_state default "$(good_state '.bridge = "w1:p2"')"
  herdr_agent local default w1:p1 bridge idle
  herdr_agent local default w1:p2 bridge working
  rep
  [ "$(jq -c '[.agents[] | .role]' <<<"$output")" = '[null,"bridge"]' ]
  [ "$(jq -c .bridge <<<"$output")" = '{"name":"w1:p2","status":"working"}' ]
}

@test "bridge status is null, not absent, when the bridge's agent is there with a status herdr did not name" {
  herdr_agent local default w1:p1 bridge strange
  rep
  [ "$(jq -c .bridge <<<"$output")" = '{"name":"bridge","status":null}' ]
}

@test "steps.sh is sourced silently: what it prints reaches neither stdout nor stderr" {
  tree_with_steps 'echo SOURCED; echo SOURCED-ERR >&2; ck_boot_status() { echo enabled; }'
  rep
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  jq -e '.boot_start == "enabled"' <<<"$output"
  [ -z "$stderr" ]
}

@test "a bad --session is 64 before steps.sh is sourced" {
  tree_with_steps "touch '$BATS_TEST_TMPDIR/sourced'"
  rep --session ../x
  [ "$status" -eq 64 ]
  [ ! -e "$BATS_TEST_TMPDIR/sourced" ]
}

@test "ck_boot_status and herdr get no stdin from the caller" {
  tree_with_steps 'ck_boot_status() { local x=; read -r x || true; if [ -n "$x" ]; then echo disabled; else echo enabled; fi; }'
  run --separate-stderr bash -c 'echo anything | "$0" node report' "$TREE/bin/crewkit"
  [ "$status" -eq 0 ]
  [ "$(jq -r .boot_start <<<"$output")" = enabled ]
}

# ---- fix round 2 ----

@test "a steps.sh that fails to load does not fail the report: boot_start absent, one fixed stderr line" {
  local body
  for body in 'ck_boot_status() { echo enabled; }; false' 'ck_boot_status() { echo enabled; }; if then fi (' 'ck_boot_status() { echo enabled; }; return 3'; do
    tree_with_steps "$body"
    rep
    [ "$status" -eq 0 ] || { echo "[$body]: $status $stderr"; return 1; }
    [ "$(wc -l <<<"$output")" -eq 1 ]
    jq -e '.boot_start == "absent"' <<<"$output"
    [ "$stderr" = "crewkit: steps.sh failed to load" ] || { echo "[$body]: $stderr"; return 1; }
  done
}

@test "node state: a directory or a FIFO in place of the file is not a state (78), and nothing hangs" {
  rm "$STATE/node/default.json"
  mkdir "$STATE/node/default.json"
  rep
  [ "$status" -eq 78 ]
  [ -z "$output" ]
  rmdir "$STATE/node/default.json"
  mkfifo "$STATE/node/default.json"
  run --separate-stderr timeout 20 "$TREE/bin/crewkit" node report
  [ "$status" -eq 78 ]
  [ -z "$output" ]
}

@test "the fallback scratch directory, used when TMPDIR is read-only, is removed" {
  local real
  real=$(command -v mktemp)
  mkdir "$BATS_TEST_TMPDIR/shim" "$BATS_TEST_TMPDIR/ro2"
  printf '#!/bin/sh\nr=$(%s "$@") || exit $?\necho "$r" >> "%s/made"\necho "$r"\n' "$real" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/shim/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/shim/mktemp"
  chmod a-w "$BATS_TEST_TMPDIR/ro2"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" TMPDIR="$BATS_TEST_TMPDIR/ro2" rep
  chmod u+w "$BATS_TEST_TMPDIR/ro2"
  [ "$status" -eq 0 ]
  # the scratch directory is the one mktemp result of the form /tmp/cknr.XXXXXX (herdr.sh's own files are inside it)
  made=$(grep -E '^/tmp/cknr\.[A-Za-z0-9]{6}$' "$BATS_TEST_TMPDIR/made")
  [ "$(wc -l <<<"$made")" -eq 1 ]
  [ ! -e "$made" ]
}
