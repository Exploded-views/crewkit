#!/usr/bin/env bats
# libexec/ck/herdr.sh: herdr discovery per server (sessions, versions, agents), sanitizing of what
# a node's herdr reports, and tagging panes with tokens. herdr is the stub (tests/stubs/herdr) in
# the per-host, per-session mode; every call goes to $PSTUB/herdr.log. Each call runs in a fresh
# bash (hd), so exit codes are real.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

setup() {
  ck_setup
  STATE="$HOME/.local/state/crewkit"
  herdr_session local default 1 1
}

# hd ARGS...: run a herdr.sh function in a new bash.
hd() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/herdr.sh"; shift; "$@"' _ "$TREE" "$@"
}
# hde ARGS...: the same under set -euo pipefail, as the verbs run. It runs a script file, not
# `bash -c`: kcov's trace hook reads BASH_SOURCE, which is unset under `bash -u -c` (see the note
# in tools/coverage.sh), so the set -e tests would fail under coverage.
hde() {
  cat > "$BATS_TEST_TMPDIR/hde.sh" <<'EOS'
set -euo pipefail
source "$1/lib/settings.sh"
source "$1/libexec/ck/common.sh"
source "$1/libexec/ck/herdr.sh"
shift
"$@"
EOS
  bash "$BATS_TEST_TMPDIR/hde.sh" "$TREE" "$@"
}
# no_herdr: no herdr anywhere on PATH (not even a real one), with jq and bash still found.
no_herdr() {
  mkdir -p "$BATS_TEST_TMPDIR/nohd"
  ln -sf "$(command -v jq)" "$BATS_TEST_TMPDIR/nohd/jq"
  ln -sf "$(command -v bash)" "$BATS_TEST_TMPDIR/nohd/bash"
  export PATH="$BATS_TEST_TMPDIR/nohd:/usr/bin:/bin"
}
# nocalls: herdr was not called at all.
nocalls() { [ ! -s "$PSTUB/herdr.log" ]; }
# writes: how many pane report-metadata calls were made.
writes() { grep -c 'report-metadata' "$PSTUB/herdr.log" || true; }
# node_state SESSION JSON
node_state() { mkdir -p "$STATE/node"; printf '%s\n' "$2" > "$STATE/node/$1.json"; }

@test "the minimum herdr version and protocol are constants" {
  run hd eval 'echo "$CK_HERDR_MIN $CK_HERDR_PROTOCOL"'
  [ "$output" = "0.9.1 22" ]
}

@test "bin prefers ~/.local/bin/herdr, then PATH, then nothing" {
  run hd ck_herdr_bin
  [ "$output" = "$BATS_TEST_TMPDIR/bin/herdr" ]
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/herdr"
  chmod +x "$HOME/.local/bin/herdr"
  run hd ck_herdr_bin
  [ "$output" = "$HOME/.local/bin/herdr" ]
  rm "$HOME/.local/bin/herdr"
  no_herdr
  run -1 hd ck_herdr_bin
  [ -z "$output" ]
}

@test "sessions lists each herdr server with default and running" {
  herdr_session local scratch 0 1
  run hd ck_herdr_sessions
  [ "$status" -eq 0 ]
  [ "$output" = $'default\ttrue\ttrue\nscratch\tfalse\ttrue' ]
  herdr_session local scratch 0 0
  run hd ck_herdr_sessions
  [ "$output" = $'default\ttrue\ttrue\nscratch\tfalse\tfalse' ]
}

@test "sessions skips a name that is not a plain session name" {
  herdr_session local 'bad.name' 0 1
  herdr_session local 'two words' 0 1
  herdr_session local '-dash' 0 1
  herdr_session local 'ok_2-b' 0 1
  run hd ck_herdr_sessions
  [ "$output" = $'default\ttrue\ttrue\nok_2-b\tfalse\ttrue' ]
}

@test "sessions is empty without a herdr" {
  no_herdr
  run hd ck_herdr_sessions
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "default_session names the default one" {
  herdr_session local aaa 0 1
  herdr_session local default 0 1
  herdr_session local zzz 1 1
  run hd ck_herdr_default_session
  [ "$output" = zzz ]
}

@test "versions reads client and server protocol" {
  run hd ck_herdr_versions
  [ "$output" = "0.9.5 22 true 22" ]
}

@test "versions of a stopped server has - for what it can't know; with no herdr, all -" {
  herdr_session local default 1 0
  run hd ck_herdr_versions
  [ "$output" = "0.9.5 22 false -" ]
  no_herdr
  run hd ck_herdr_versions
  [ "$status" -eq 0 ]
  [ "$output" = "- - - -" ]
}

@test "versions of another session; a bad session name is 65 and calls nothing" {
  herdr_session local scratch 0 0
  run hd ck_herdr_versions scratch
  [ "$output" = "0.9.5 22 false -" ]
  : > "$PSTUB/herdr.log"
  run hd ck_herdr_versions '../x'
  [ "$status" -eq 65 ]
  nocalls
}

@test "agents keeps only pane_id, name, status, role and project" {
  herdr_agent local default w1:p1 lead working role=lead project=acme other=x
  herdr_agent local default w1:p2 - idle
  run hd ck_herdr_agents default
  [ "$status" -eq 0 ]
  jq -e 'all(.[]; keys == ["name","pane_id","project","role","status"])' <<<"$output"
  ! grep -q cwd <<<"$output"
  ! grep -q tokens <<<"$output"
  [ "$(jq -c '.[0]' <<<"$output")" = '{"pane_id":"w1:p1","name":"lead","status":"working","role":"lead","project":"acme"}' ]
  [ "$(jq -c '.[1]' <<<"$output")" = '{"pane_id":"w1:p2","name":null,"status":"idle","role":null,"project":null}' ]
}

@test "agents --access adds the access token, only if it is exactly reader or writer" {
  herdr_agent local default w1:p1 a idle access=reader
  herdr_agent local default w1:p2 b idle access=writer
  herdr_agent local default w1:p3 c idle access=admin
  herdr_agent local default w1:p4 d idle
  run hd ck_herdr_agents default --access
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | .access]' <<<"$output")" = '["reader","writer",null,null]' ]
  jq -e 'all(.[]; keys == ["access","name","pane_id","project","role","status"])' <<<"$output"
}

@test "agents of a session is read with that session" {
  herdr_session local scratch 0 1
  herdr_agent local scratch w4:p1 other idle
  run hd ck_herdr_agents scratch
  [ "$(jq -r '.[0].pane_id' <<<"$output")" = w4:p1 ]
  grep -q '^\[local/scratch\] agent list$' "$PSTUB/herdr.log"
}

@test "agents of a stopped session is an empty list, not an error" {
  herdr_session local scratch 0 0
  run hd ck_herdr_agents scratch
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "agents: a hostile name, role, project, status or pane id is null, built by jq and never run" {
  canary="$BATS_TEST_TMPDIR/canary"
  herdr_agent local default w1:p1 "\$(touch $canary)" 'weird' "role=a"$'\n'"b" 'project=x"y' 'extra=$(touch '"$canary"')'
  herdr_agent local default 'w1:p2;x' ok idle role=lead "project=$(printf 'p%.0s' $(seq 81))"
  run hd ck_herdr_agents default
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0]' <<<"$output")" = '{"pane_id":"w1:p1","name":null,"status":null,"role":null,"project":null}' ]
  [ "$(jq -c '.[1]' <<<"$output")" = '{"pane_id":null,"name":"ok","status":"idle","role":"lead","project":null}' ]
  [ ! -e "$canary" ]
}

@test "agents keeps only the statuses of herdr's schema" {
  grep -q 'CK_HERDR_STATUSES' "$TREE/libexec/ck/herdr.sh"
  run hd eval 'echo "$CK_HERDR_STATUSES"'
  [ "$output" = "$(jq -r '.AgentStatus | join(" ")' "$REPO/tests/fixtures/herdr/agent-schema.json")" ]
}

@test "a bad session name is 65 and calls nothing (agents, tag, retag)" {
  local s
  for s in '../x' 'a b' 'a.b' '-x' '' 'a/b' "$(printf 'a%.0s' $(seq 65))"; do
    run hd ck_herdr_agents "$s"
    [ "$status" -eq 65 ]
    run hd ck_herdr_tag "$s" w1:p1 role lead
    [ "$status" -eq 65 ]
    run hd ck_herdr_retag "$s"
    [ "$status" -eq 65 ]
  done
  nocalls
  [ ! -e "$STATE/node" ]
}

@test "tag writes one report-metadata call and is idempotent" {
  herdr_agent local default w1:p1 lead idle
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
  grep -q 'pane report-metadata --source crewkit --token role=lead w1:p1' "$PSTUB/herdr.log"
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
  run hd ck_herdr_tag default w1:p1 role scout
  [ "$(writes)" -eq 2 ]
  [ "$(hd ck_herdr_agents default | jq -r '.[0].role')" = scout ]
}

@test "tag refuses a bad pane, key or value (65) and makes no call" {
  herdr_agent local default w1:p1 lead idle
  : > "$PSTUB/herdr.log"
  run hd ck_herdr_tag default 'w1:p1;x' role lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default '-p1' role lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default '' role lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 'a.b' lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 'Role' lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 '' lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role 'a b'; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role $'a\nb'; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role '$(id)'; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role ''; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role "$(printf 'v%.0s' $(seq 81))"; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default w1:p1 role $'lead\n'; [ "$status" -eq 65 ]
  run hd ck_herdr_tag $'default\n' w1:p1 role lead; [ "$status" -eq 65 ]
  run hd ck_herdr_tag default $'w1:p1\n' role lead; [ "$status" -eq 65 ]
  nocalls
}

@test "tag takes a value of exactly 80 characters" {
  herdr_agent local default w1:p1 lead idle
  run hd ck_herdr_tag default w1:p1 role "$(printf 'v%.0s' $(seq 80))"
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
}

@test "tag: a pane with 32 tokens takes no new key (65, no write) but a changed value" {
  local i toks=()
  for i in $(seq 32); do toks+=("k$i=v"); done
  herdr_agent local default w1:p1 lead idle "${toks[@]}"
  run hd ck_herdr_tag default w1:p1 extra v
  [ "$status" -eq 65 ]
  [ "$(writes)" -eq 0 ]
  run hd ck_herdr_tag default w1:p1 k7 changed
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
}

@test "tag on a pane in a stopped session fails (1) and says so" {
  herdr_session local scratch 0 0
  run hd ck_herdr_tag scratch w1:p1 role lead
  [ "$status" -eq 1 ]
  [[ $output == *scratch* ]]
}

# retag

@test "retag in a session with no node state does nothing" {
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  nocalls
}

@test "retag: node state that is not JSON, or whose tags is not an object, is 65 with no calls" {
  mkdir -p "$STATE/node"
  echo '{not json' > "$STATE/node/default.json"
  run hd ck_herdr_retag default
  [ "$status" -eq 65 ]
  node_state default '{"tags":[1,2]}'
  run hd ck_herdr_retag default
  [ "$status" -eq 65 ]
  node_state default '{"other":1}'
  run hd ck_herdr_retag default
  [ "$status" -eq 65 ]
  nocalls
}

@test "retag re-applies the recorded tokens to a pane that still runs the recorded agent" {
  herdr_agent local default w1:p1 lead idle
  node_state default '{"schema":1,"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead","project":"acme"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 2 ]
  [ "$(hd ck_herdr_agents default | jq -c '.[0] | [.role, .project]')" = '["lead","acme"]' ]
}

@test "retag skips a pane that is gone" {
  herdr_agent local default w1:p1 lead idle
  node_state default '{"tags":{"w9:p9":{"agent":"lead","tokens":{"role":"lead"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 0 ]
}

@test "retag skips a pane whose agent changed" {
  herdr_agent local default w1:p1 other idle
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 0 ]
}

@test "retag skips a pane that runs no agent at all when the state recorded one" {
  herdr_agent local default w1:p1 lead idle
  jq '.[0].agent = null | .[0].name = null' "$PSTUB/herdr/local/default/panes.json" > "$BATS_TEST_TMPDIR/p" && mv "$BATS_TEST_TMPDIR/p" "$PSTUB/herdr/local/default/panes.json"
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 0 ]
}

@test "retag with the agent recorded as null tags the pane whatever runs there, agent or not" {
  herdr_agent local default w1:p1 other idle
  "$REPO/tests/stubs/herdr" workspace create --label x --cwd /w --no-focus > /dev/null
  node_state default '{"tags":{"w1:p1":{"agent":null,"tokens":{"role":"lead"}},"w2:p1":{"agent":null,"tokens":{"project":"acme"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 2 ]
}

@test "retag makes no call for a token that is already set" {
  herdr_agent local default w1:p1 lead idle role=lead
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead","project":"acme"}}}}'
  run hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
  grep -q 'token project=acme' "$PSTUB/herdr.log"
  ! grep -q 'token role=lead' "$PSTUB/herdr.log"
}

@test "retag skips a bad entry with a stderr line and still applies the rest" {
  herdr_agent local default w1:p1 lead idle
  herdr_agent local default w1:p2 scout idle
  node_state default '{"tags":{"bad;pane":{"agent":null,"tokens":{"role":"x"}},"w1:p1":{"agent":"lead","tokens":{"Bad.Key":"x","role":"a b","project":"acme"}},"w1:p2":{"agent":"scout","tokens":{"role":"scout"}}}}'
  run --separate-stderr hd ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 2 ]
  grep -q 'token project=acme w1:p1' "$PSTUB/herdr.log"
  grep -q 'token role=scout w1:p2' "$PSTUB/herdr.log"
  [[ $stderr == *bad*pane* ]]
  [[ $stderr == *"Bad.Key"* ]]
  [[ $stderr == *"role"* ]]
}

# herdr failing (fix round 1)

@test "sessions: a herdr whose session list fails is 1, with its words" {
  : > "$PSTUB/herdr/local/session_list_fail"
  run --separate-stderr hd ck_herdr_sessions
  [ "$status" -eq 1 ]
  [[ $stderr == *"session list failed"* ]]
}

@test "agents: a running session whose agent list fails is 1 with herdr's stderr, not []" {
  : > "$PSTUB/herdr/local/default/list_fail"
  run --separate-stderr hd ck_herdr_agents default
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == *"agent list failed in session default"* ]]
  [[ $stderr == *internal* ]]
}

@test "agents: when session list itself fails, it is 1 (can't tell stopped from broken)" {
  herdr_session local scratch 0 0
  : > "$PSTUB/herdr/local/session_list_fail"
  run hd ck_herdr_agents scratch
  [ "$status" -eq 1 ]
}

@test "agents: a session herdr doesn't list is []" {
  run hd ck_herdr_agents nosuch
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tag and retag with a failing read: 1 and no write" {
  herdr_agent local default w1:p1 lead idle
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead"}}}}'
  : > "$PSTUB/herdr/local/default/list_fail"
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 1 ]
  run hd ck_herdr_retag default
  [ "$status" -eq 1 ]
  [ "$(writes)" -eq 0 ]
  rm "$PSTUB/herdr/local/default/list_fail"
  : > "$PSTUB/herdr/local/session_list_fail"
  : > "$PSTUB/herdr/local/default/list_fail"
  run hd ck_herdr_retag default
  [ "$status" -eq 1 ]
  [ "$(writes)" -eq 0 ]
}

# panes with no agent

plain_pane() { "$REPO/tests/stubs/herdr" workspace create --label x --cwd /w --no-focus > /dev/null; }

@test "tag on a pane with no agent is idempotent too" {
  plain_pane
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
}

@test "tag on a pane with no agent: 32 tokens is the cap (65, no write), a present key may change" {
  plain_pane
  local i
  for i in $(seq 32); do "$REPO/tests/stubs/herdr" pane report-metadata --source x --token "k$i=v" w1:p1 > /dev/null; done
  : > "$PSTUB/herdr.log"
  run hd ck_herdr_tag default w1:p1 extra v
  [ "$status" -eq 65 ]
  [ "$(writes)" -eq 0 ]
  run hd ck_herdr_tag default w1:p1 k3 changed
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
}

# set -e

@test "retag under set -e: a malformed entry first is skipped with a stderr line and the rest apply" {
  herdr_agent local default w1:p1 lead idle
  herdr_agent local default w1:p2 scout idle
  node_state default '{"tags":{"a1":5,"a2":"x","a3":null,"a4":[1],"w1:p1":{"agent":"lead","tokens":{"role":"lead","bad":7}},"w1:p2":{"agent":{"x":1},"tokens":{"role":"scout"}}}}'
  run --separate-stderr hde ck_herdr_retag default
  [ "$status" -eq 0 ]
  grep -q 'token role=lead w1:p1' "$PSTUB/herdr.log"
  [ "$(writes)" -eq 1 ]
  [[ $stderr == *"entry is not an object"* ]]
  [[ $stderr != *"jq: error"* ]]
}

@test "the whole retag and tag paths work under set -euo pipefail" {
  herdr_agent local default w1:p1 lead idle
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":{"role":"lead"}},"w9:p9":{"agent":null,"tokens":{"role":"x"}}}}'
  run hde ck_herdr_retag default
  [ "$status" -eq 0 ]
  run hde ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  run hde ck_herdr_agents default
  [ "$status" -eq 0 ]
}

# fix round 2

@test "herdr's stderr is shown as printable ASCII only, at most 300 bytes: no ESC, no OSC 52, no screen clear" {
  printf '\033]52;c;ZXZpbA==\a\033[2Jpwned\n%0400d\n' 0 > "$PSTUB/herdr/local/default/list_fail"
  run --separate-stderr hd ck_herdr_agents default
  [ "$status" -eq 1 ]
  ! grep -q "$(printf '\033')" <<<"$stderr"
  ! grep -q "$(printf '\007')" <<<"$stderr"
  [[ $stderr == *"pwned"* ]]
  # the reason after the fixed prefix is exactly the cap (the input is longer)
  msg=${stderr#*"in session default: "}
  [ "$(printf '%s' "$msg" | wc -c)" -eq 300 ]
}

@test "8-bit bytes in herdr's stderr, in a UTF-8 locale, don't cut the reason or add a tr error" {
  printf 'boom \377\376 secret-after \033[2J end\n' > "$PSTUB/herdr/local/default/list_fail"
  LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 run --separate-stderr hd ck_herdr_agents default
  [ "$status" -eq 1 ]
  [[ $stderr == *"boom"*"secret-after"*"end"* ]]
  [[ $stderr != *"tr:"* ]]
  [[ $stderr != *$'\033'* ]]
}

@test "a session-list failure's stderr is sanitized the same way" {
  printf '\033[31mred\033]0;t\a' > "$PSTUB/herdr/local/session_list_fail"
  run --separate-stderr hd ck_herdr_sessions
  [ "$status" -eq 1 ]
  [[ $stderr != *$'\033'* ]]
  [[ $stderr == *red* ]]
}

@test "tag compares in jq: a token of \"lead\\n\" is not \"lead\"" {
  herdr_agent local default w1:p1 lead idle "role=lead"$'\n'
  run hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
}

@test "retag: tokens that are not an object are skipped with a stderr line, the rest applied" {
  herdr_agent local default w1:p1 lead idle
  herdr_agent local default w1:p2 scout idle
  node_state default '{"tags":{"w1:p1":{"agent":"lead","tokens":"x"},"w1:p2":{"agent":"scout","tokens":{"role":"scout"}}}}'
  run --separate-stderr hde ck_herdr_retag default
  [ "$status" -eq 0 ]
  [ "$(writes)" -eq 1 ]
  [[ $stderr == *"w1:p1"*"not an object"* ]]
}

@test "no herdr installed says so, apart from a failure" {
  no_herdr
  run --separate-stderr hd ck_herdr_agents default
  [ "$status" -eq 1 ]
  [[ $stderr == *"herdr not installed"* ]]
  [[ $stderr != *"failed"* ]]
  run --separate-stderr hd ck_herdr_tag default w1:p1 role lead
  [ "$status" -eq 1 ]
  [[ $stderr == *"herdr not installed"* ]]
}
