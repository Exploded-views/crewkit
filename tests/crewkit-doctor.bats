#!/usr/bin/env bats
# libexec/crewkit-doctor, the local cut (no NODE, no --json): one line per check,
# `ok|warn|FAIL <check>: <detail>`, in a fixed order; exit 1 if any FAIL, else 0.
#
# Every test runs in the temp HOME of ck_setup with stub tools first on PATH: herdr, rtk, bitc and
# claude-memsync report the version their pin names (read from the tree's pins/, so a pin bump does
# not break these), claude lists the three plugins, and the push gate is the fixture. Nothing here
# touches a real host, key or settings file.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

pin_tag() { grep -E "^$2_TAG=" "$TREE/pins/$1.env" | head -1 | cut -d= -f2; }
# pin_version TOOL VAR: the version line the real binary prints for the pin: VAR_VERSION when the
# pin sets one (the fork's herdr prints its base version, not its tag), else the tag without its v.
pin_version() {
  local v
  v=$(grep -E "^$2_VERSION=" "$TREE/pins/$1.env" | tail -1 | cut -d= -f2)
  echo "${v:-$(pin_tag "$1" "$2" | sed 's/^v//')}"
}

# fork_pin [VERSION]: pins/herdr.env in the fork's shape: tag v0.9.5-ev.2, HERDR_VERSION=VERSION
# when given.
fork_pin() {
  { grep -v '^HERDR_\(TAG\|VERSION\)=' "$TREE/pins/herdr.env"; echo "HERDR_TAG=v0.9.5-ev.2"
    [[ $# -eq 0 ]] || echo "HERDR_VERSION=$1"; } > "$BATS_TEST_TMPDIR/herdr.env"
  mv "$BATS_TEST_TMPDIR/herdr.env" "$TREE/pins/herdr.env"
}

# stub NAME BODY: an executable NAME on the test PATH.
# reset: forget what ck_setup built (links and temp dirs only; rm -rf does not follow links).
reset() { rm -rf "$TREE" "$HOME" "$PSTUB" "$SYNC" "${BATS_TEST_TMPDIR:?}/bin"; }

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$BATS_TEST_TMPDIR/bin/$1"; chmod +x "$BATS_TEST_TMPDIR/bin/$1"; }

setup() {
  ck_setup
  local rtk bitc memsync
  rtk=$(pin_tag rtk RTK) bitc=$(pin_tag bitc BITC) memsync=$(pin_tag memsync MEMSYNC)
  stub herdr "echo 'herdr $(pin_version herdr HERDR)'"
  stub rtk "echo 'rtk ${rtk#v}'"
  stub bitc "echo '{\"version\":\"${bitc#v}\",\"release\":true}'"
  stub pgrep 'exit 1'   # no sshd, whatever this machine runs
  stub claude-memsync "echo 'claude-memsync $memsync'"
  export PLUGINS='[{"id":"crew-nodes@crewkit"},{"id":"agent-practice@crewkit"},{"id":"memory-notices@crewkit"}]'
  # shellcheck disable=SC2016  # $1.. are for the stub's own shell
  stub claude 'if [ "$1 $2 $3" = "plugin list --json" ]; then printf "%s\n" "$PLUGINS"; else exit 2; fi'
  mkdir -p "$HOME/.local/bin"
  ln -s "$TREE/bin/crewkit" "$HOME/.local/bin/crewkit"
  F="$HOME/.claude/settings.json"
  cat > "$F" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]},
 "permissions":{"allow":["SendMessage"]}}
JSON
  chmod 600 "$F"
  chmod 700 "$HOME/.claude"
}

doc() { run -"${1:-0}" --separate-stderr ck doctor; }

# without TOOL: a PATH with everything the test PATH has except TOOL.
without() {
  local d="$BATS_TEST_TMPDIR/nopath-$1" p f
  mkdir -p "$d"
  local IFS=:
  for p in $PATH; do
    for f in "$p"/*; do
      [[ -x $f && ! -d $f && ${f##*/} != "$1" && ! -e "$d/${f##*/}" ]] && ln -s "$f" "$d/${f##*/}"
    done
  done
  printf '%s\n' "$d"
}

@test "a fully installed node is all ok (exit 0), in the fixed order" {
  doc 0
  [[ $output != *FAIL* ]]
  [[ $output != *warn* ]]
  local order
  order=$(sed -E 's/^(ok|warn|FAIL) ([a-z0-9-]+):.*/\2/' <<<"$output" | tr '\n' ' ')
  [[ $order == "bash tools cli pin-herdr pin-rtk pin-bitc pin-memsync plugins hooks push-gate sendmessage-allow hub-inbound " ]]
}

@test "each fault is FAIL on its own check and sets exit 1" {
  local fault check
  for fault in cli:cli pin-herdr:pin-herdr pin-rtk:pin-rtk pin-bitc:pin-bitc pin-memsync:pin-memsync \
    plugins:plugins hooks:hooks sendmessage:sendmessage-allow; do
    reset
    setup
    check=${fault#*:}
    case ${fault%%:*} in
      cli) rm "$HOME/.local/bin/crewkit" ;;
      pin-herdr) stub herdr "echo 'herdr 0.0.1'" ;;
      pin-rtk) stub rtk "echo 'rtk 0.0.1'" ;;
      pin-bitc) stub bitc "echo '{\"version\":\"0.0.1\",\"release\":true}'" ;;
      pin-memsync) stub claude-memsync "echo 'claude-memsync v0.0.1'" ;;
      plugins) export PLUGINS='[{"id":"crew-nodes@crewkit"}]' ;;
      hooks) echo '{"permissions":{"allow":["SendMessage"]}}' > "$F" ;;
      sendmessage) echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"rtk hook claude"}]}]}}' > "$F" ;;
    esac
    run -1 --separate-stderr ck doctor
    [[ $output == *"FAIL $check:"* ]]
    # no other check fails with it
    [ "$(grep -c '^FAIL' <<<"$output")" -eq 1 ]
  done
}

@test "a missing tool is FAIL tools and names the tool" {
  local t
  for t in jq git ssh ssh-keygen; do
    PATH=$(without "$t") run -1 --separate-stderr "$BASH" "$TREE/bin/crewkit" doctor
    [[ $output == *"FAIL tools:"*"$t"* ]]
  done
}

@test "a missing claude is a warn on tools and on plugins, not a FAIL" {
  PATH=$(without claude) run -0 --separate-stderr "$BASH" "$TREE/bin/crewkit" doctor
  [[ $output == *"warn tools:"*claude* ]]
  [[ $output == *"warn plugins:"* ]]
}

@test "a cli link to another tree is FAIL cli" {
  rm "$HOME/.local/bin/crewkit"
  ln -s /nonexistent/bin/crewkit "$HOME/.local/bin/crewkit"
  doc 1
  [[ $output == *"FAIL cli:"* ]]
}

@test "a pin mismatch names the tool, the wanted and the found version, no path" {
  stub herdr "echo 'herdr 0.0.1'"
  doc 1
  local want
  want=$(pin_version herdr HERDR)
  [[ $output == *"FAIL pin-herdr:"*"$want"*"0.0.1"* ]]
  [[ $output != *"$BATS_TEST_TMPDIR"* ]]
}

@test "pin-herdr: the fork pin (tag v0.9.5-ev.2, HERDR_VERSION=0.9.5) is ok for the line the fork binary prints" {
  fork_pin 0.9.5
  stub herdr "echo 'herdr 0.9.5'"
  doc 0
  [[ $output == *"ok pin-herdr: 0.9.5"* ]]
}

@test "pin-herdr: under the fork pin the tag as a version line is a FAIL" {
  fork_pin 0.9.5
  stub herdr "echo 'herdr 0.9.5-ev.2'"
  doc 1
  [[ $output == *"FAIL pin-herdr: the pin wants 0.9.5, found 0.9.5-ev.2"* ]]
}

@test "pin-herdr: a pin without HERDR_VERSION wants the tag without its v" {
  fork_pin
  stub herdr "echo 'herdr 0.9.5-ev.2'"
  doc 0
  [[ $output == *"ok pin-herdr: 0.9.5-ev.2"* ]]
  stub herdr "echo 'herdr 0.9.5'"
  doc 1
  [[ $output == *"FAIL pin-herdr: the pin wants 0.9.5-ev.2, found 0.9.5"* ]]
}

@test "pin-herdr: a malformed HERDR_VERSION is a FAIL naming the pin file, not a crash" {
  local bad
  for bad in "0.9" "v0.9.5" "0.9.5-" "0.9.5 x" "0.9.5+meta" "'0.9.5'"; do
    fork_pin "$bad"
    doc 1
    [[ $output == *"FAIL pin-herdr:"*"pins/herdr.env"* ]] || { echo "$bad: $output"; return 1; }
    [ "$(grep -c '^FAIL' <<<"$output")" -eq 1 ]
    [[ $output == *"ok pin-rtk:"* ]]
  done
}

@test "a broken settings.json is FAIL hooks and FAIL sendmessage-allow, never a crash" {
  echo '{not json' > "$F"
  doc 1
  [[ $output == *"FAIL hooks:"* ]]
  [[ $output == *"FAIL sendmessage-allow:"* ]]
}

@test "doctor writes nothing: settings.json is byte for byte as it was" {
  cp -p "$F" "$BATS_TEST_TMPDIR/before"
  doc 0
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$F.crewkit-bak" ]
}

@test "the push gate's lines are folded in, and its FAIL is ours" {
  PG_DOCTOR_FAIL=dispatcher doc 1
  [[ $output == *"FAIL push-gate:"*dispatcher* ]]
}

@test "a push gate that errors (exit 2) is FAIL push-gate" {
  # an ok line on stdout must not hide the error exit
  printf '#!/bin/sh\necho "global-gate ok fine"\necho oops >&2\nexit 2\n' > "$TREE/push-gate/push-gate.sh"
  chmod +x "$TREE/push-gate/push-gate.sh"
  doc 1
  [[ $output == *"FAIL push-gate:"*"exit 2"* ]]
}

@test "a gate that prints nothing and exits 0 is FAIL, not zero checks ok" {
  printf '#!/bin/sh\nexit 0\n' > "$TREE/push-gate/push-gate.sh"
  doc 1
  [[ $output == *"FAIL push-gate:"* ]]
}

@test "a path in a gate's detail is shown under ~, and no other absolute path survives" {
  printf '#!/bin/sh\necho "repo FAIL %s/code/x and /etc/other"\nexit 1\n' "$HOME" > "$TREE/push-gate/push-gate.sh"
  doc 1
  [[ $output == *"FAIL push-gate:"*"~/code/x"* ]]
  [[ $output != *"$HOME"* ]]
  [[ $output != *"/etc/other"* ]]
}

@test "no push gate in the tree is a warn, not a FAIL" {
  rm "$TREE/push-gate/push-gate.sh"
  doc 0
  [[ $output == *"warn push-gate:"* ]]
}

@test "arguments are refused: --json and NODE are not in this cut (64, nothing on stdout)" {
  run -64 --separate-stderr ck doctor --json
  [ -z "$output" ]
  run -64 --separate-stderr ck doctor homebox
  [ -z "$output" ]
}

# --- hub-inbound -------------------------------------------------------------------------------

mkkey() { ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$BATS_TEST_TMPDIR/k-$1"; }
fp() { ssh-keygen -lf "$BATS_TEST_TMPDIR/k-$1.pub" | awk '{print $2}'; }
authorize() { mkdir -p "$HOME/.ssh"; cat >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"; }

hub() { user_setting 'nodes.me.this_host: true' 'nodes.me.role: hub' "$@"; }

@test "hub-inbound is ok (not a hub) with no this_host node, a spoke, or no role" {
  doc 0
  [[ $output == *"ok hub-inbound: not a hub"* ]]
  user_setting 'nodes.me.this_host: true' 'nodes.me.role: spoke'
  doc 0
  [[ $output == *"ok hub-inbound: not a hub"* ]]
  rm "$HOME/.claude/crewkit.md"
  user_setting 'nodes.me.this_host: true'
  doc 0
  [[ $output == *"ok hub-inbound: not a hub"* ]]
}

@test "any other role value is FAIL hub-inbound bad-role" {
  user_setting 'nodes.me.this_host: true' 'nodes.me.role: boss'
  doc 1
  [[ $output == *"FAIL hub-inbound:"*bad-role* ]]
}

@test "a hub with no authorized_keys file, or an empty one, is ok" {
  hub
  doc 0
  [[ $output == *"ok hub-inbound:"* ]]
  mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/authorized_keys"
  doc 0
}

@test "a hub whose only keys are the owner's pinned ones is ok" {
  mkkey owner
  authorize < "$BATS_TEST_TMPDIR/k-owner.pub"
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 0
  [[ $output == *"ok hub-inbound:"* ]]
}

@test "keys present with no allowlist is FAIL hub-inbound no-allowlist" {
  mkkey owner
  authorize < "$BATS_TEST_TMPDIR/k-owner.pub"
  hub
  doc 1
  [[ $output == *"FAIL hub-inbound:"*no-allowlist* ]]
}

@test "a plain key that is not in the allowlist is FAIL, naming file, line and fingerprint, never the key" {
  mkkey owner; mkkey agent
  { cat "$BATS_TEST_TMPDIR/k-owner.pub"; cat "$BATS_TEST_TMPDIR/k-agent.pub"; } | authorize
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 1
  [[ $output == *"FAIL hub-inbound:"*authorized_keys*":2"*"$(fp agent)"* ]]
  [[ $output != *"$(awk '{print $2}' "$BATS_TEST_TMPDIR/k-agent.pub")"* ]]
}

@test "the allowlist may hold several fingerprints, comma separated" {
  mkkey a; mkkey b
  { cat "$BATS_TEST_TMPDIR/k-a.pub"; cat "$BATS_TEST_TMPDIR/k-b.pub"; } | authorize
  hub "nodes.me.owner_keys: $(fp a),$(fp b)"
  doc 0
}

@test "a crewkit marker or a command naming crewkit fails whatever the fingerprint" {
  mkkey owner
  printf 'command="crewkit node gate --from n-1",restrict %s\n' "$(cut -d' ' -f1-2 "$BATS_TEST_TMPDIR/k-owner.pub") crewkit-n-1" | authorize
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 1
  [[ $output == *"FAIL hub-inbound:"*crewkit* ]]
}

@test "option names are matched whatever their case, as sshd does" {
  mkkey owner
  local k opt
  k=$(cat "$BATS_TEST_TMPDIR/k-owner.pub")
  for opt in 'CERT-AUTHORITY' 'Cert-Authority,principals="x"' 'COMMAND="crewkit node gate"' 'Command="CrewKit node gate"'; do
    printf '%s %s\n' "$opt" "$k" > "$HOME/.ssh/authorized_keys" 2>/dev/null || { mkdir -p "$HOME/.ssh"; printf '%s %s\n' "$opt" "$k" > "$HOME/.ssh/authorized_keys"; }
    chmod 600 "$HOME/.ssh/authorized_keys"
    hub "nodes.me.owner_keys: $(fp owner)"
    doc 1
    [[ $output == *"FAIL hub-inbound:"* ]]
  done
}

@test "a ~/.ssh that is a link to a directory doctor cannot search is FAIL" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  mkdir -p "$BATS_TEST_TMPDIR/locked/ssh"
  ln -s "$BATS_TEST_TMPDIR/locked/ssh" "$HOME/.ssh"
  chmod 000 "$BATS_TEST_TMPDIR/locked"
  hub "nodes.me.owner_keys: SHA256:none"
  doc 1
  chmod 700 "$BATS_TEST_TMPDIR/locked"
  [[ $output == *"FAIL hub-inbound:"*"cannot be searched"* ]]
}

@test "a line that cannot be read as a key fails closed" {
  mkkey owner
  { cat "$BATS_TEST_TMPDIR/k-owner.pub"; echo 'ssh-ed25519 not-a-key junk'; } | authorize
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 1
  [[ $output == *"FAIL hub-inbound:"*":2 cannot be read as a key"* ]]
}

@test "comments and blank lines are skipped, even a comment holding a key" {
  mkkey owner; mkkey agent
  { echo '# the owner'; echo; echo "# $(cat "$BATS_TEST_TMPDIR/k-agent.pub")"; cat "$BATS_TEST_TMPDIR/k-owner.pub"; } | authorize
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 0
  [[ $output == *"ok hub-inbound:"* ]]
}

@test "authorized_keys2 is read too" {
  mkkey owner; mkkey agent
  authorize < "$BATS_TEST_TMPDIR/k-owner.pub"
  cat "$BATS_TEST_TMPDIR/k-agent.pub" > "$HOME/.ssh/authorized_keys2"
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 1
  [[ $output == *"authorized_keys2"* ]]
}

@test "a cert-authority line is FAIL: it admits any certificate its key signs" {
  mkkey owner
  printf 'cert-authority %s\n' "$(cat "$BATS_TEST_TMPDIR/k-owner.pub")" | authorize
  hub "nodes.me.owner_keys: $(fp owner)"
  doc 1
  [[ $output == *"FAIL hub-inbound:"*cert-authority* ]]
}

@test "an authorized_keys doctor cannot read is FAIL, not a clean hub" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  mkkey agent
  authorize < "$BATS_TEST_TMPDIR/k-agent.pub"
  hub "nodes.me.owner_keys: SHA256:none"
  chmod 000 "$HOME/.ssh/authorized_keys"
  doc 1
  chmod 600 "$HOME/.ssh/authorized_keys"
  [[ $output == *"FAIL hub-inbound:"*"cannot be read"* ]]
}

@test "a ~/.ssh doctor cannot search is FAIL, not a clean hub" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  mkkey agent
  authorize < "$BATS_TEST_TMPDIR/k-agent.pub"
  hub "nodes.me.owner_keys: SHA256:none"
  chmod 000 "$HOME/.ssh"
  doc 1
  chmod 700 "$HOME/.ssh"
  [[ $output == *"FAIL hub-inbound:"*"cannot be searched"* ]]
}

@test "with two hub nodes the allowlist is the union of both" {
  mkkey a; mkkey b
  { cat "$BATS_TEST_TMPDIR/k-a.pub"; cat "$BATS_TEST_TMPDIR/k-b.pub"; } | authorize
  user_setting 'nodes.one.this_host: true' 'nodes.one.role: hub' "nodes.one.owner_keys: $(fp a)" \
    'nodes.two.this_host: true' 'nodes.two.role: hub' "nodes.two.owner_keys: $(fp b)"
  doc 0
}

@test "a hub that is ok says sshd's state is unknown, never that it is off" {
  hub
  doc 0
  [[ $output == *"ok hub-inbound:"*unknown* ]]
}

@test "a running sshd on a hub is a warn, not a FAIL" {
  stub pgrep 'exit 0'
  hub
  doc 0
  [[ $output == *"warn hub-inbound:"*sshd* ]]
}

@test "owner_keys and role are read from the user file only" {
  mkkey owner; mkkey agent
  { cat "$BATS_TEST_TMPDIR/k-owner.pub"; cat "$BATS_TEST_TMPDIR/k-agent.pub"; } | authorize
  mkdir -p "$BATS_TEST_TMPDIR/proj/.claude"
  printf -- '---\nnodes.me.this_host: true\nnodes.me.role: hub\nnodes.me.owner_keys: %s,%s\n---\n' "$(fp owner)" "$(fp agent)" > "$BATS_TEST_TMPDIR/proj/.claude/crewkit.md"
  cd "$BATS_TEST_TMPDIR/proj"
  doc 0
  [[ $output == *"ok hub-inbound: not a hub"* ]]
}
