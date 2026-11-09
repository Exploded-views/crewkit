#!/usr/bin/env bats
# The v0.1.0 acceptance scenario: one node, offline, stubs only. A fresh empty home gets the
# command from install.sh; then the command reports its version, doctor checks the install, and
# `node report` describes the node's herdr agents without a path, title or hostname. A wrong verb
# is usage. Nothing here reaches a network or another host: ssh and curl are stubs that record
# a call and fail, and the test ends by checking they were never called.
#
# Out of v0.1.0 (their own acceptance comes with their rows): init, join, node join/authorize,
# status, open, ask and --json. outbox, watchline and holder keep their own suites.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

TOKEN=$(printf "a%.0s" {1..64})

pin_tag() { grep -E "^$2_TAG=" "$TREE/pins/$1.env" | head -1 | cut -d= -f2; }
# pin_version TOOL VAR: the version line the real binary prints for the pin: VAR_VERSION when the
# pin sets one (the fork's herdr prints its base version, not its tag), else the tag without its v.
pin_version() {
  local v
  v=$(grep -E "^$2_VERSION=" "$TREE/pins/$1.env" | tail -1 | cut -d= -f2)
  echo "${v:-$(pin_tag "$1" "$2" | sed 's/^v//')}"
}

# stub NAME BODY: an executable NAME on the test PATH.
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BATS_TEST_TMPDIR/bin/$1"; chmod +x "$BATS_TEST_TMPDIR/bin/$1"; }

setup() {
  ck_setup
  # the fresh machine: an empty home that has nothing of crewkit's
  FRESH="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$FRESH"
  export HOME="$FRESH"
  cd "$HOME" || return 1
  NETLOG="$BATS_TEST_TMPDIR/net.log"
  : > "$NETLOG"
  # offline: anything that would talk to a network or another host is recorded, and fails
  stub curl "echo \"curl \$*\" >> \"$NETLOG\"; exit 7"
  rm -f "$BATS_TEST_TMPDIR/bin/ssh"
  stub ssh "echo \"ssh \$*\" >> \"$NETLOG\"; exit 255"
}

# healthy_node: what a node looks like after the owner's own steps, in the fresh home: the tools
# at the versions the pins name, the three plugins, the rtk hook and the SendMessage allow rule.
healthy_node() {
  local rtk bitc memsync
  rtk=$(pin_tag rtk RTK) bitc=$(pin_tag bitc BITC) memsync=$(pin_tag memsync MEMSYNC)
  # shellcheck disable=SC2016  # $1 is for the stub's own shell
  stub herdr "if [ \"\${1:-}\" = --version ]; then echo 'herdr $(pin_version herdr HERDR)'; else exec \"$REPO/tests/stubs/herdr\" \"\$@\"; fi"
  stub rtk "echo 'rtk ${rtk#v}'"
  stub bitc "echo '{\"version\":\"${bitc#v}\",\"release\":true}'"
  stub pgrep 'exit 1'
  stub claude-memsync "echo 'claude-memsync $memsync'"
  export PLUGINS='[{"id":"crew-nodes@crewkit"},{"id":"agent-practice@crewkit"},{"id":"memory-notices@crewkit"}]'
  # shellcheck disable=SC2016
  stub claude 'if [ "$1 $2 $3" = "plugin list --json" ]; then printf "%s\n" "$PLUGINS"; else exit 2; fi'
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]},
 "permissions":{"allow":["SendMessage"]}}
JSON
  chmod 600 "$HOME/.claude/settings.json"
  chmod 700 "$HOME/.claude"
}

# node_state: the state `crewkit node join` writes (a later row), as a fixture.
node_state() {
  mkdir -p "$HOME/.local/state/crewkit/node"
  jq -cn --arg t "$TOKEN" '{schema: 1, node_id: "n-abcdefg234", name: "lab", session: "default", registry_id: "r-abcdefg234",
    join_token_sha256: $t, lead: null, bridge: "bridge", joined_at: "2026-10-27T00:00:00Z"}' > "$HOME/.local/state/crewkit/node/default.json"
}

# fake_hostname: `uname -n` answers a name nothing else in a report could contain; every other
# uname call goes to the real one.
fake_hostname() {
  FAKE_HOSTNAME=acc-host-7f3a91
  local real
  real=$(command -v uname)
  stub uname "if [ \"\${1:-}\" = -n ]; then echo $FAKE_HOSTNAME; else exec \"$real\" \"\$@\"; fi"
}

# installed: the crewkit command as the installer left it, found on the PATH of a fresh shell.
installed() { PATH="$HOME/.local/bin:$PATH" command -v crewkit; }

# no_network: nothing in this test reached curl or ssh.
no_network() { [ ! -s "$NETLOG" ]; }

@test "phase 1, one node: install, version, doctor and node report on a fresh empty home" {
  [ -z "$(ls -A "$HOME")" ]
  # 1. install.sh gives the empty home the command
  run "$TREE/install.sh" --yes --only cli
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/crewkit")" = "$TREE/bin/crewkit" ]
  [ "$(installed)" = "$HOME/.local/bin/crewkit" ]
  # 2. the version it prints is the VERSION file's
  run crewkit_installed --version
  [ "$status" -eq 0 ]
  [ "$output" = "crewkit $(cat "$TREE/libexec/VERSION")" ]
  # 3. doctor on the healthy node: exit 0, one line per check, none a FAIL
  healthy_node
  run --separate-stderr crewkit_installed doctor
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -z "$(grep '^FAIL' <<<"$output")" ]
  [ -z "$(grep -vE '^(ok|warn) [a-z0-9-]+: ' <<<"$output")" ]
  [ "$(awk '{print $2}' <<<"$output" | tr '\n' ' ')" = "bash: tools: cli: pin-herdr: pin-rtk: pin-bitc: pin-memsync: plugins: hooks: push-gate: sendmessage-allow: hub-inbound: " ]
  # 4. node report: the agents, and nothing of where they are
  node_state
  fake_hostname
  herdr_session local default 1 1
  herdr_agent local default w1:p1 lead working role=lead
  jq -c 'map(. + {cwd: "/work/client-repo", title: "secret title"})' "$PSTUB/herdr/local/default/panes.json" > "$BATS_TEST_TMPDIR/p.json"
  mv "$BATS_TEST_TMPDIR/p.json" "$PSTUB/herdr/local/default/panes.json"
  run --separate-stderr crewkit_installed node report
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jq -e '.agents | length == 1 and .[0].pane_id == "w1:p1" and .[0].role == "lead"' <<<"$output"
  jq -e '.agents[0] | keys == ["access","name","pane_id","project","role","status"]' <<<"$output"
  [[ $output != *client-repo* ]]
  [[ $output != *"secret title"* ]]
  [[ $output != *"$FAKE_HOSTNAME"* ]]
  # 5. a wrong verb is usage
  run crewkit_installed frobnicate
  [ "$status" -eq 64 ]
  # and all of it was offline
  no_network
}

# crewkit_installed ARGS...: run the command by the link the installer made.
crewkit_installed() { "$HOME/.local/bin/crewkit" "$@"; }

@test "install.sh twice: the second run changes nothing and exits 0" {
  run "$TREE/install.sh" --yes --only cli
  [ "$status" -eq 0 ]
  before=$(find "$HOME" -print | sort | tr '\n' ' ')
  run "$TREE/install.sh" --yes --only cli
  [ "$status" -eq 0 ]
  [ "$(find "$HOME" -print | sort | tr '\n' ' ')" = "$before" ]
}

@test "install.sh as a dry run changes nothing in the empty home" {
  run "$TREE/install.sh" --only cli
  [ "$status" -eq 0 ]
  [[ $output == *"Dry run"* ]]
  [ -z "$(ls -A "$HOME")" ]
}

@test "install.sh leaves another crewkit at the link's place alone (exit 1)" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho mine\n' > "$HOME/.local/bin/crewkit"
  chmod +x "$HOME/.local/bin/crewkit"
  run "$TREE/install.sh" --yes --only cli
  [ "$status" -eq 1 ]
  [ "$("$HOME/.local/bin/crewkit")" = mine ]
}

@test "doctor fails (exit 1) when the install is not there: no link, no plugins" {
  healthy_node
  PLUGINS='[]'
  run --separate-stderr crewkit_installed_or_tree doctor
  [ "$status" -eq 1 ]
  grep -q '^FAIL cli: ' <<<"$output"
  grep -q '^FAIL plugins: ' <<<"$output"
}

# crewkit_installed_or_tree ARGS...: the tree's command, for a home with no link.
crewkit_installed_or_tree() { "$TREE/bin/crewkit" "$@"; }

@test "node report writes nothing: the home is the same before and after" {
  healthy_node
  node_state
  herdr_session local default 1 1
  herdr_agent local default w1:p1 lead working role=lead
  before=$(find "$HOME" -type f -exec cksum {} + | sort | tr '\n' ' ')
  run --separate-stderr ck node report
  [ "$status" -eq 0 ]
  [ "$(find "$HOME" -type f -exec cksum {} + | sort | tr '\n' ' ')" = "$before" ]
}

@test "the unknown verb and node-report as one word are usage (64) on stderr, with an empty stdout" {
  local v
  for v in frobnicate node-report; do
    run --separate-stderr ck "$v"
    [ "$status" -eq 64 ]
    [ -z "$output" ]
    [[ $stderr == *usage* ]]
  done
  run --separate-stderr ck node
  [ "$status" -eq 64 ]
}

@test "nothing in the acceptance scenario's verbs reaches curl or ssh" {
  healthy_node
  node_state
  herdr_session local default 1 1
  ck --version
  ck doctor || true
  ck node report
  no_network
}
