#!/usr/bin/env bats
# libexec/ck/claudesettings.sh: ck_claude_allow adds a tool to permissions.allow in
# ~/.claude/settings.json, ck_claude_allow_status reads it for doctor. Every test uses the temp HOME
# of ck_setup, never the real one. Each call runs in a fresh bash (caw: with --yes, cad: a dry run,
# cas: the status) so locks and $$ are real.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

setup() {
  ck_setup
  F="$HOME/.claude/settings.json"
  BAK="$F.crewkit-bak"
}

# The zombie test's holder (a sleep this test started), if a failure left it running.
teardown() {
  if [[ -n ${holder-} ]]; then kill "$holder" 2>/dev/null || true; fi
}

caw() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; shift; CK_YES=1; "$@"' _ "$TREE" "$@"
}
cad() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; shift; "$@"' _ "$TREE" "$@"
}
cas() { cad ck_claude_allow_status "$@"; }

# seed JSON: write JSON as the settings file, mode 600.
seed() { printf '%s\n' "$1" > "$F"; chmod 600 "$F"; }

# mode FILE: the octal mode, GNU or BSD stat.
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# mtime FILE: the modification time in seconds.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# keep: save a copy of the settings file to compare against with same (cmp, so a final newline counts).
keep() { cp -p "$F" "$BATS_TEST_TMPDIR/kept"; }
same() { cmp -s "$F" "$BATS_TEST_TMPDIR/kept"; }

OTHERS='{"model":"opus","permissions":{"defaultMode":"plan","allow":["Bash(ls:*)","Read"],"deny":["Bash(rm:*)"]},"env":{"A":"1"}}'

@test "a missing file is created with the entry, mode 600, and ~/.claude mode 700 when it is new" {
  rmdir "$HOME/.claude"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(mode "$HOME/.claude")" = 700 ]
  [ "$(mode "$F")" = 600 ]
  [ "$(cat "$F")" = "$(printf '{\n  "permissions": {\n    "allow": [\n      "SendMessage"\n    ]\n  }\n}')" ]
  [ -z "$(tail -c1 "$F")" ]
  [ ! -e "$BAK" ]
}

@test "an existing ~/.claude keeps its mode" {
  chmod 750 "$HOME/.claude"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(mode "$HOME/.claude")" = 750 ]
  jq -e '.permissions.allow == ["SendMessage"]' "$F"
}

@test "a file without permissions gets it, other keys and their order kept" {
  seed '{"model":"opus","env":{"A":"1"}}'
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  jq -e '.permissions.allow == ["SendMessage"] and .model == "opus" and .env.A == "1"' "$F"
  [ "$(jq -c 'keys_unsorted' "$F")" = '["model","env","permissions"]' ]
}

@test "permissions without allow gets allow, its other keys and their order kept" {
  seed '{"permissions":{"defaultMode":"plan","deny":["X"]},"model":"opus"}'
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions | keys_unsorted' "$F")" = '["defaultMode","deny","allow"]' ]
  [ "$(jq -c '.permissions.deny' "$F")" = '["X"]' ]
  [ "$(jq -c 'keys_unsorted' "$F")" = '["permissions","model"]' ]
}

@test "other allow entries: the tool is appended, every other entry and key kept in order" {
  seed "$OTHERS"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.allow' "$F")" = '["Bash(ls:*)","Read","SendMessage"]' ]
  [ "$(jq -c 'keys_unsorted' "$F")" = '["model","permissions","env"]' ]
  [ "$(jq -c '.permissions | keys_unsorted' "$F")" = '["defaultMode","allow","deny"]' ]
  [ "$(jq -c 'del(.permissions.allow)' "$F")" = "$(jq -c 'del(.permissions.allow)' <<<"$OTHERS")" ]
}

@test "already present: nothing is written, no backup, bytes and mtime unchanged" {
  seed '{"permissions":{"allow":["SendMessage"]}}'
  touch -t 202001010000 "$F"
  m0=$(mtime "$F")
  before=$(cat "$F")
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$output" = "already allowed: SendMessage" ]
  [ "$(cat "$F")" = "$before" ]
  [ "$(mtime "$F")" = "$m0" ]
  [ ! -e "$BAK" ]
  [ -z "$(ls -A "$HOME/.claude" | grep -v '^settings.json$')" ]
}

@test "a second run adds no duplicate" {
  caw ck_claude_allow SendMessage
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(jq -c '.permissions.allow' "$F")" = '["SendMessage"]' ]
}

@test "malformed JSON is 65, the file is byte for byte unchanged, no backup" {
  printf '{"permissions": {oops' > "$F"
  chmod 600 "$F"
  keep
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 65 ]
  same
  [ ! -e "$BAK" ]
  [ -z "$(ls -A "$HOME/.claude" | grep -v '^settings.json$')" ]
}

@test "each wrong shape is 65 and the file is unchanged" {
  local shape
  for shape in '[]' '"x"' 'null' '{"permissions":[]}' '{"permissions":null}' '{"permissions":"a"}' \
               '{"permissions":{"allow":"SendMessage"}}' '{"permissions":{"allow":{"a":1}}}' \
               '{"permissions":{"allow":["ok",3]}}' '{"permissions":{"allow":null}}' \
               '[] {"permissions":{"allow":["SendMessage"]}}' '{"a":1} {"permissions":{"allow":["SendMessage"]}}' '[] {}' '{} {}' '{} []' ''; do
    seed "$shape"
    keep
    run caw ck_claude_allow SendMessage
    [ "$status" -eq 65 ] || { echo "shape $shape: $status $output"; return 1; }
    same
    [ ! -e "$BAK" ]
  done
}

@test "a symlinked settings.json is 78 and the target is unchanged" {
  printf '{"model":"x"}\n' > "$BATS_TEST_TMPDIR/target.json"
  chmod 600 "$BATS_TEST_TMPDIR/target.json"
  ln -s "$BATS_TEST_TMPDIR/target.json" "$F"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target.json")" = '{"model":"x"}' ]
  [ -L "$F" ]
  [ ! -e "$BAK" ]
}

@test "a symlinked ~/.claude is 78 and its target is untouched" {
  rmdir "$HOME/.claude"
  mkdir -m 700 "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$HOME/.claude"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/real")" ]
}

@test "a symlinked backup path is 78 and nothing is written through it" {
  seed "$OTHERS"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$BAK"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
  [ "$(jq -c .permissions.allow "$F")" = '["Bash(ls:*)","Read"]' ]
}

@test "a world-writable settings.json is 78 and unchanged" {
  seed "$OTHERS"
  chmod 666 "$F"
  before=$(cat "$F")
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [ "$(cat "$F")" = "$before" ]
  [ ! -e "$BAK" ]
}

@test "a world-writable ~/.claude is 78" {
  seed "$OTHERS"
  chmod 777 "$HOME/.claude"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  chmod 700 "$HOME/.claude"
}

@test "settings.json that is a directory is 78" {
  mkdir "$F"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [[ $output == *"not a regular file"* ]]
}

@test "a dry run writes nothing and says what it would do" {
  seed "$OTHERS"
  before=$(cat "$F")
  run cad ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$output" = "would allow SendMessage in ~/.claude/settings.json" ]
  [ "$(cat "$F")" = "$before" ]
  [ -z "$(ls -A "$HOME/.claude" | grep -v '^settings.json$')" ]
  [ ! -e "$HOME/.local" ]
}

@test "a dry run with no file creates neither the file nor the directory" {
  rmdir "$HOME/.claude"
  run cad ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [[ $output == "would allow SendMessage"* ]]
  [ ! -e "$HOME/.claude" ]
}

@test "a dry run with the tool present says already allowed" {
  seed '{"permissions":{"allow":["SendMessage"]}}'
  run cad ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$output" = "already allowed: SendMessage" ]
}

@test "a dry run still refuses malformed JSON (65)" {
  printf 'nope' > "$F"; chmod 600 "$F"
  run cad ck_claude_allow SendMessage
  [ "$status" -eq 65 ]
}

@test "the backup holds the old bytes, mode 600, and an older backup is overwritten" {
  seed "$OTHERS"
  old=$(cat "$F")
  printf 'stale\n' > "$BAK"; chmod 644 "$BAK"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(cat "$BAK")" = "$old" ]
  [ "$(mode "$BAK")" = 600 ]
}

@test "mode rule: the file is 600 afterwards, whatever it was (a looser mode is tightened)" {
  seed "$OTHERS"
  chmod 644 "$F"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(mode "$F")" = 600 ]
  seed '{"model":"x"}'
  chmod 400 "$F"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(mode "$F")" = 600 ]
}

@test "no temp file is left behind after a write" {
  seed "$OTHERS"
  caw ck_claude_allow SendMessage
  [ "$(ls -A "$HOME/.claude" | sort | tr '\n' ' ')" = "settings.json settings.json.crewkit-bak " ]
}

@test "the library allows SendMessage only: any other TOOL is 64 and writes nothing" {
  local t
  for t in '' Bash Write WebFetch sendmessage SendMessage2 'Send Message' 'SendMessage;x' $'SendMessage\n' 'mcp__x__y' "$(printf 'A%.0s' {1..65})"; do
    run caw ck_claude_allow "$t"
    [ "$status" -eq 64 ] || { echo "tool '$t': $status"; return 1; }
    [ ! -e "$F" ]
  done
  run caw ck_claude_allow
  [ "$status" -eq 64 ]
  run caw ck_claude_allow SendMessage Bash
  [ "$status" -eq 64 ]
  run cas Bash
  [ "$status" -eq 64 ]
}

@test "two concurrent runs both succeed and leave one entry and a valid file" {
  seed '{"model":"x"}'
  caw ck_claude_allow SendMessage & p1=$!
  caw ck_claude_allow SendMessage & p2=$!
  wait "$p1"; wait "$p2"
  jq -e '.permissions.allow == ["SendMessage"] and .model == "x"' "$F"
}

@test "the lock is released after a run" {
  seed '{}'
  caw ck_claude_allow SendMessage
  [ ! -e "$HOME/.local/state/crewkit/locks/claude-settings.lock" ]
  [ ! -L "$HOME/.local/state/crewkit/locks/claude-settings.lock" ]
}

# hold_lock: take the claude-settings lock as this (live) test process.
hold_lock() {
  mkdir -p "$HOME/.local/state/crewkit/locks"
  ln -s "$$" "$HOME/.local/state/crewkit/locks/claude-settings.lock"
}

@test "a held lock makes the write wait and then give up (75), the file unchanged" {
  seed "$OTHERS"
  before=$(cat "$F")
  hold_lock
  CREWKIT_LOCK_WAIT_SECONDS=1 run caw ck_claude_allow SendMessage
  [ "$status" -eq 75 ]
  [ "$(cat "$F")" = "$before" ]
  [ ! -e "$BAK" ]
}

@test "the check is made again under the lock: an entry added while it waited is not doubled" {
  seed '{"model":"x"}'
  hold_lock
  caw ck_claude_allow SendMessage > "$BATS_TEST_TMPDIR/out" 2>&1 & pid=$!
  sleep 1
  seed '{"permissions":{"allow":["SendMessage"]}}'
  rm "$HOME/.local/state/crewkit/locks/claude-settings.lock"
  wait "$pid"
  [ "$(jq -c '.permissions.allow' "$F")" = '["SendMessage"]' ]
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "already allowed: SendMessage" ]
  [ ! -e "$BAK" ]
}

@test "a symlinked old staging name (settings.json.crewkit-bak.new) is never written through" {
  seed '{"env":{"K":"secret"}}'
  printf 'victim\n' > "$BATS_TEST_TMPDIR/victim"
  chmod 644 "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$BAK.new"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = victim ]
  [ "$(mode "$BATS_TEST_TMPDIR/victim")" = 644 ]
  [ ! -L "$BAK" ]
  [ "$(jq -c .env "$BAK")" = '{"K":"secret"}' ]
}

@test "a backup path that is a directory is 78 and nothing moves into it" {
  seed "$OTHERS"
  keep
  mkdir "$BAK"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  same
  [ -z "$(ls -A "$BAK")" ]
}

@test "a settings.json you cannot read is 78, not a JSON error" {
  seed "$OTHERS"
  chmod 000 "$F"
  run caw ck_claude_allow SendMessage
  chmod 600 "$F"
  [ "$status" -eq 78 ]
  [[ $output == *"cannot be read"* ]]
  [[ $output != *"JSON"* ]]
}

@test "a file or directory owned by someone else is 78 and unchanged" {
  mkdir "$BATS_TEST_TMPDIR/idbin"
  printf '#!/bin/sh\necho 987654\n' > "$BATS_TEST_TMPDIR/idbin/id"
  chmod +x "$BATS_TEST_TMPDIR/idbin/id"
  seed "$OTHERS"
  keep
  PATH="$BATS_TEST_TMPDIR/idbin:$PATH" run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [[ $output == *"not owned by you"* ]]
  same
  [ ! -e "$BAK" ]
}

# jqwrap BODY: a jq first on PATH. BODY runs, with $real the real jq and "$@" the call's arguments,
# when the call is crewkit's edit (the one with `.allow = ` in its filter); every other call is the real jq.
jqwrap() {
  local real
  real=$(command -v jq)
  mkdir -p "$BATS_TEST_TMPDIR/wrapbin"
  {
    printf '#!/bin/bash\nreal=%q\n' "$real"
    printf 'case "$*" in *".allow = "*) %s ;; esac\n' "$1"
    printf 'exec "$real" "$@"\n'
  } > "$BATS_TEST_TMPDIR/wrapbin/jq"
  chmod +x "$BATS_TEST_TMPDIR/wrapbin/jq"
  PATH="$BATS_TEST_TMPDIR/wrapbin:$PATH"
}

@test "a rewrite of settings.json during the run is refused (75) and the other writer's bytes stay" {
  seed "$OTHERS"
  (jqwrap "printf '%s\n' '{\"permissions\":{\"allow\":[\"Bash(npm test)\"]},\"theirs\":1}' > \"$F\""
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 75 ] || { echo "$status $output"; exit 1; }
   [[ $output == *"changed while crewkit was editing it; run again"* ]])
  [ "$(jq -c . "$F")" = '{"permissions":{"allow":["Bash(npm test)"]},"theirs":1}' ]
  [ ! -e "$BAK" ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "a settings.json that appears during the run (there was none) is refused (75), not overwritten" {
  rm -f "$F"
  (jqwrap "printf '%s\n' '{\"theirs\":1}' > \"$F\""
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 75 ] || { echo "$status $output"; exit 1; })
  [ "$(jq -c . "$F")" = '{"theirs":1}' ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "the file's content never appears in any process argument" {
  seed '{"env":{"SOME_VAR":"canary-4417"},"permissions":{"allow":["Read"]}}'
  (jqwrap_all='1'
   real=$(command -v jq)
   mkdir -p "$BATS_TEST_TMPDIR/spybin"
   printf '#!/bin/bash\nreal=%q\nfor a in "$@"; do case "$a" in *canary-4417*) echo "SECRET IN ARGV" >&2; exit 99;; esac; done\nexec "$real" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/spybin/jq"
   chmod +x "$BATS_TEST_TMPDIR/spybin/jq"
   PATH="$BATS_TEST_TMPDIR/spybin:$PATH"
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 0 ] || { echo "$status $output"; exit 1; })
  jq -e '.permissions.allow == ["Read","SendMessage"] and .env.SOME_VAR == "canary-4417"' "$F"
}

# waitfor CMD...: run CMD every 0.05s until it succeeds, for at most 30s (then fail).
waitfor() {
  local _
  for _ in $(seq 600); do "$@" && return 0; sleep 0.05; done
  return 1
}
# gone PID: no process PID (the end condition of an orphaned write subshell).
gone() { ! kill -0 "$1" 2>/dev/null; }

@test "SIGTERM mid-run leaves no temp file behind, the settings untouched, and the caller's EXIT trap runs" {
  seed "$OTHERS"
  keep
  # jq's parent is the write subshell: record it, so the test waits for it to end, not for the caller.
  jqwrap "echo \$PPID > \"$BATS_TEST_TMPDIR/subpid\"; echo \$\$ > \"$BATS_TEST_TMPDIR/jqpid\"; exec sleep 30"
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap "echo ran > \"\$HOME/caller-trap-ran\"" EXIT; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE" &
  pid=$!
  waitfor test -s "$BATS_TEST_TMPDIR/jqpid"
  sub=$(cat "$BATS_TEST_TMPDIR/subpid")
  kill -TERM "$pid"
  kill "$(cat "$BATS_TEST_TMPDIR/jqpid")" 2>/dev/null || true
  wait "$pid" || true
  waitfor gone "$sub"
  same
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
  [ -e "$HOME/caller-trap-ran" ]
}

@test "the caller's own EXIT trap still runs after a run" {
  seed '{}'
  run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap "echo caller-trap" EXIT; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE"
  [ "$status" -eq 0 ]
  [[ $output == *caller-trap* ]]
  run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap "echo caller-trap" EXIT; printf nope > "$HOME/.claude/settings.json"; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE"
  [ "$status" -eq 65 ]
  [[ $output == *caller-trap* ]]
}

@test "a deny entry for the tool makes status unreadable (it would not take effect)" {
  seed '{"permissions":{"allow":["SendMessage"],"deny":["SendMessage"]}}'
  run cas SendMessage
  [ "$status" -eq 2 ]
  [ "$output" = unreadable ]
}

@test "a caller's EXIT trap sees the real status when TERM lands mid-write (143, not 0)" {
  seed "$OTHERS"
  keep
  jqwrap "echo \$\$ > \"$BATS_TEST_TMPDIR/jqpid\"; exec sleep 30"
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap "exit 143" TERM; trap "echo \$? > \"\$HOME/caller-rc\"" EXIT; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE" &
  pid=$!
  for _ in $(seq 100); do [ -s "$BATS_TEST_TMPDIR/jqpid" ] && break; sleep 0.1; done
  [ -s "$BATS_TEST_TMPDIR/jqpid" ]
  kill -TERM "$pid"
  kill "$(cat "$BATS_TEST_TMPDIR/jqpid")" 2>/dev/null || true
  wait "$pid" || true
  [ "$(cat "$HOME/caller-rc")" = 143 ]
  same
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "the caller's EXIT trap is the same one after a normal run and after a refusal" {
  seed '{}'
  run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap "echo caller-trap" EXIT; a=$(trap -p EXIT); CK_YES=1; ck_claude_allow SendMessage >/dev/null; [[ $(trap -p EXIT) == "$a" ]] && echo same-trap' _ "$TREE"
  [ "$status" -eq 0 ]
  [[ $output == *same-trap* ]]
  # A refusal exits the caller's process: its EXIT trap records the trap it runs under, to compare
  # with the one set before the call.
  printf nope > "$F"
  run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; trap '\''trap -p EXIT > "$HOME/trap-at-exit"'\'' EXIT; trap -p EXIT > "$HOME/trap-before"; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE"
  [ "$status" -eq 65 ]
  [ -s "$HOME/trap-before" ]
  cmp "$HOME/trap-before" "$HOME/trap-at-exit"
}

# pausewrap TOOL PATTERN [after]: a TOOL first on PATH. A call whose arguments match the case PATTERN
# records its parent (the write subshell) in $BATS_TEST_TMPDIR/subpid, then waits (at most 30s) for the
# file $BATS_TEST_TMPDIR/go; with `after` the real TOOL runs first. Every other call is the real TOOL.
pausewrap() {
  local real
  real=$(command -v "$1")
  mkdir -p "$BATS_TEST_TMPDIR/pausebin"
  {
    printf '#!/bin/bash\nreal=%q t=%q\n' "$real" "$BATS_TEST_TMPDIR"
    printf 'pause() { echo "$PPID" > "$t/subpid"; for _ in $(seq 600); do [ -e "$t/go" ] && return; sleep 0.05; done; }\n'
    if [[ ${3-} == after ]]; then
      printf 'case "$*" in %s) "$real" "$@"; rc=$?; pause; exit "$rc" ;; esac\n' "$2"
    else
      printf 'case "$*" in %s) pause ;; esac\n' "$2"
    fi
    printf 'exec "$real" "$@"\n'
  } > "$BATS_TEST_TMPDIR/pausebin/$1"
  chmod +x "$BATS_TEST_TMPDIR/pausebin/$1"
  PATH="$BATS_TEST_TMPDIR/pausebin:$PATH"
}

# orphan_run: start ck_claude_allow --yes in a caller with no TERM trap, wait until the write subshell
# is paused (pausewrap), TERM the caller and wait for it to die, let the subshell go on, and wait for it
# to end. Only then is the outcome checked: no race with the orphan.
orphan_run() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE" 2> "$BATS_TEST_TMPDIR/err" &
  pid=$!
  waitfor test -s "$BATS_TEST_TMPDIR/subpid"
  sub=$(cat "$BATS_TEST_TMPDIR/subpid")
  kill -TERM "$pid"
  wait "$pid" || true
  touch "$BATS_TEST_TMPDIR/go"
  waitfor gone "$sub"
}

@test "TERM to a caller with no TERM trap, mid-edit: the orphaned write never lands, no temp file is left" {
  seed "$OTHERS"
  keep
  pausewrap jq '*".allow = "*'
  orphan_run
  same
  [ ! -e "$BAK" ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "the caller gone while the file is compared: the older backup is not replaced, settings.json unchanged" {
  seed "$OTHERS"
  keep
  printf 'older\n' > "$BAK"
  chmod 600 "$BAK"
  pausewrap cmp '*'
  orphan_run
  same
  [ "$(cat "$BAK")" = older ]
  [ "$(ls -A "$HOME/.claude" | sort | tr '\n' ' ')" = "settings.json settings.json.crewkit-bak " ]
}

@test "the caller gone after the backup rename: settings.json is still not replaced" {
  seed "$OTHERS"
  keep
  pausewrap mv '*/.settings.json.snap.*' after
  orphan_run
  same
  [ "$(ls -A "$HOME/.claude" | sort | tr '\n' ' ')" = "settings.json settings.json.crewkit-bak " ]
}

# zombie PID: PID is a zombie (killed, not yet reaped by its parent). BSD and procps ps both show Z first.
zombie() { [[ $(ps -o stat= -p "$1" 2>/dev/null) =~ ^[[:space:]]*Z ]]; }

@test "TERM to a caller its own parent does not reap (a zombie): the orphaned write still never lands" {
  seed "$OTHERS"
  keep
  pausewrap jq '*".allow = "*'
  printf 'source %q/lib/settings.sh; source %q/libexec/ck/common.sh; source %q/libexec/ck/claudesettings.sh; CK_YES=1; ck_claude_allow SendMessage\n' \
    "$TREE" "$TREE" "$TREE" > "$BATS_TEST_TMPDIR/caller.sh"
  # The holder starts the caller, then becomes sleep, which never waits: a dead caller stays a zombie,
  # as under a supervisor that kills first and reaps later.
  bash -c 'bash "$1" 2> "$2" & echo $! > "$3"; exec sleep 60' _ "$BATS_TEST_TMPDIR/caller.sh" "$BATS_TEST_TMPDIR/err" "$BATS_TEST_TMPDIR/callerpid" > /dev/null 3>&- &
  holder=$!
  waitfor test -s "$BATS_TEST_TMPDIR/subpid"
  caller=$(cat "$BATS_TEST_TMPDIR/callerpid")
  sub=$(cat "$BATS_TEST_TMPDIR/subpid")
  kill -TERM "$caller"
  waitfor zombie "$caller"
  touch "$BATS_TEST_TMPDIR/go"
  waitfor gone "$sub"
  # Still unreaped while the subshell made its checks.
  zombie "$caller"
  kill "$holder"
  wait "$holder" || true
  same
  [ ! -e "$BAK" ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "a lock taken over mid-edit (the caller still alive) is refused (75), settings.json unchanged" {
  seed "$OTHERS"
  keep
  pausewrap jq '*".allow = "*'
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/claudesettings.sh"; CK_YES=1; ck_claude_allow SendMessage' _ "$TREE" 2> "$BATS_TEST_TMPDIR/err" &
  pid=$!
  waitfor test -s "$BATS_TEST_TMPDIR/subpid"
  lock=$HOME/.local/state/crewkit/locks/claude-settings.lock
  [ "$(readlink "$lock")" = "$pid" ]
  # Another live process (this test) now holds it, as after a wrongful takeover.
  ln -sfn "$$" "$lock"
  touch "$BATS_TEST_TMPDIR/go"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 75 ] || { echo "rc $rc: $(cat "$BATS_TEST_TMPDIR/err")"; return 1; }
  grep -q "lost its lock" "$BATS_TEST_TMPDIR/err"
  same
  [ ! -e "$BAK" ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
  [ "$(readlink "$lock")" = "$$" ]
}

# gidstub: an id first on PATH whose -g says a group the directory is not in, with the names pinned
# to a user-private pair (ckuser:ckuser) so only the gid can refuse; id -u stays real. The names are
# pinned so the result does not depend on the name of the user running the suite.
gidstub() {
  mkdir -p "$BATS_TEST_TMPDIR/gidbin"
  printf '#!/bin/sh\ncase "$1" in -g) echo 987654 ;; -gn|-un) echo ckuser ;; *) exec %s "$@" ;; esac\n' "$(command -v id)" > "$BATS_TEST_TMPDIR/gidbin/id"
  chmod +x "$BATS_TEST_TMPDIR/gidbin/id"
  PATH="$BATS_TEST_TMPDIR/gidbin:$PATH"
}

# gnstub NAME: an id first on PATH whose -gn says NAME (the primary group's name) and whose -un says
# ckuser (pinned, as in gidstub); the rest is the real id.
gnstub() {
  mkdir -p "$BATS_TEST_TMPDIR/gnbin"
  printf '#!/bin/sh\ncase "$1" in -gn) echo %s ;; -un) echo ckuser ;; *) exec %s "$@" ;; esac\n' "$1" "$(command -v id)" > "$BATS_TEST_TMPDIR/gnbin/id"
  chmod +x "$BATS_TEST_TMPDIR/gnbin/id"
  PATH="$BATS_TEST_TMPDIR/gnbin:$PATH"
}

@test "a group-writable ~/.claude of the user's own primary group is allowed (user-private groups)" {
  seed "$OTHERS"
  chgrp "$(id -g)" "$HOME/.claude"
  chmod 775 "$HOME/.claude"
  # A user-private group is named after the user (Debian, Raspberry Pi OS): ckuser:ckuser.
  (gnstub ckuser
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 0 ] || { echo "$status $output"; exit 1; })
  jq -e '.permissions.allow | index("SendMessage")' "$F"
}

@test "a group-writable ~/.claude of a shared primary group (staff) is 78 and unchanged" {
  seed "$OTHERS"
  keep
  chgrp "$(id -g)" "$HOME/.claude"
  chmod 770 "$HOME/.claude"
  (gnstub staff
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 78 ] || { echo "$status $output"; exit 1; }
   [[ $output == *"writable by a group that is not yours"* ]])
  same
  [ ! -e "$BAK" ]
}

@test "a group-writable ~/.claude of another group is 78 and unchanged (id -g stubbed to a foreign gid)" {
  seed "$OTHERS"
  keep
  chmod 770 "$HOME/.claude"
  (gidstub
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 78 ] || { echo "$status $output"; exit 1; }
   [[ $output == *"writable by a group that is not yours"* ]])
  same
  [ ! -e "$BAK" ]
}

@test "a ~/.claude of another group that the group cannot write (750) is fine" {
  seed "$OTHERS"
  chmod 750 "$HOME/.claude"
  (gidstub
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 0 ] || { echo "$status $output"; exit 1; })
  jq -e '.permissions.allow | index("SendMessage")' "$F"
}

# namefailstub: an id first on PATH whose -gn and -un fail the way GNU id does for a gid or uid with no
# name (the number, exit 1); the rest is the real id.
namefailstub() {
  mkdir -p "$BATS_TEST_TMPDIR/nfbin"
  printf '#!/bin/sh\ncase "$1" in -gn|-un) echo 4242; echo "id: cannot find name for ID 4242" >&2; exit 1 ;; *) exec %s "$@" ;; esac\n' "$(command -v id)" > "$BATS_TEST_TMPDIR/nfbin/id"
  chmod +x "$BATS_TEST_TMPDIR/nfbin/id"
  PATH="$BATS_TEST_TMPDIR/nfbin:$PATH"
}

@test "a ~/.claude no group can write (700) is fine when the user or group name cannot be looked up" {
  seed "$OTHERS"
  chmod 700 "$HOME/.claude"
  (namefailstub
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 0 ] || { echo "$status $output"; exit 1; })
  jq -e '.permissions.allow | index("SendMessage")' "$F"
}

@test "a group-writable ~/.claude of your own gid is 78 when the names cannot be looked up (user-private unconfirmed)" {
  seed "$OTHERS"
  keep
  chgrp "$(id -g)" "$HOME/.claude"
  chmod 770 "$HOME/.claude"
  (namefailstub
   run caw ck_claude_allow SendMessage
   [ "$status" -eq 78 ] || { echo "$status $output"; exit 1; }
   [[ $output == *"name cannot be looked up"* ]] || { echo "$output"; exit 1; })
  same
  [ ! -e "$BAK" ]
}

@test "a settings.json with a second hard link is 78 and unchanged" {
  seed "$OTHERS"
  keep
  ln "$F" "$BATS_TEST_TMPDIR/other-name"
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 78 ]
  [[ $output == *"hard link"* ]]
  same
  [ ! -e "$BAK" ]
}

# cmpwrap PLANT: a cmp first on PATH; once the real cmp says the file is unchanged, PLANT runs (the window
# between the check and the rename) and the real status is returned.
cmpwrap() {
  local real
  real=$(command -v cmp)
  mkdir -p "$BATS_TEST_TMPDIR/cmpbin"
  printf '#!/bin/bash\n%q "$@"; rc=$?\n[ "$rc" -eq 0 ] && { %s; }\nexit "$rc"\n' "$real" "$1" > "$BATS_TEST_TMPDIR/cmpbin/cmp"
  chmod +x "$BATS_TEST_TMPDIR/cmpbin/cmp"
  PATH="$BATS_TEST_TMPDIR/cmpbin:$PATH"
}

@test "a directory, or a symlink to one, planted at the backup path after the check fails the run (1), settings.json untouched" {
  local plant
  for plant in "mkdir \"$BAK\"" "mkdir \"$BATS_TEST_TMPDIR/vdir\"; ln -s \"$BATS_TEST_TMPDIR/vdir\" \"$BAK\""; do
    rm -rf "$BAK" "$BATS_TEST_TMPDIR/vdir"
    seed "$OTHERS"
    keep
    (cmpwrap "$plant"
     run caw ck_claude_allow SendMessage
     [ "$status" -eq 1 ] || { echo "plant $plant: $status $output"; exit 1; })
    same
  done
}

@test "a deny entry beside the allow warns on stderr and changes no exit code" {
  seed '{"permissions":{"allow":["SendMessage"],"deny":["SendMessage"]}}'
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [[ $output == *"also in permissions.deny"* ]]
  seed '{"permissions":{"deny":["SendMessage"]}}'
  run caw ck_claude_allow SendMessage
  [ "$status" -eq 0 ]
  [[ $output == *"also in permissions.deny"* ]]
  jq -e '.permissions.allow == ["SendMessage"]' "$F"
}

# badjq MODE: a jq first on PATH that damages what the edit writes, to show the check before the mv
# refuses it (1) and leaves the source, no backup and no temp file behind.
badjq() {
  local real
  real=$(command -v jq)
  mkdir -p "$BATS_TEST_TMPDIR/badbin"
  cat > "$BATS_TEST_TMPDIR/badbin/jq" <<STUB
#!/bin/bash
out=\$("$real" "\$@") || exit
if [[ "\$*" == *'.allow = '* ]]; then "$real" '$1' <<<"\$out"; else printf '%s\n' "\$out"; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/badbin/jq"
  PATH="$BATS_TEST_TMPDIR/badbin:$PATH"
}

@test "a damaged edit is refused before the mv (1): a dropped key, a lost entry, a wrong order" {
  local damage
  for damage in 'del(.env)' '.permissions.allow |= map(select(. != "Read"))' '.permissions.allow += ["Extra"]' \
                'to_entries | reverse | from_entries' '.permissions |= (to_entries | reverse | from_entries)' '.permissions.deny = []'; do
    seed "$OTHERS"
    before=$(cat "$F")
    (badjq "$damage"; run caw ck_claude_allow SendMessage
     [ "$status" -eq 1 ] || { echo "damage $damage: $status $output"; exit 1; }
     [[ $output == *"not written as expected"* ]])
    [ "$(cat "$F")" = "$before" ]
    [ ! -e "$BAK" ]
    [ "$(ls -A "$HOME/.claude")" = settings.json ]
  done
}

@test "status: ok and 0 when present" {
  seed "$OTHERS"; caw ck_claude_allow SendMessage
  run cas SendMessage
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "status: missing and 1 for no file, no permissions, no allow, no entry" {
  rm -f "$F"
  run cas SendMessage; [ "$status" -eq 1 ]; [ "$output" = missing ]
  seed '{"model":"x"}'
  run cas SendMessage; [ "$status" -eq 1 ]; [ "$output" = missing ]
  seed '{"permissions":{}}'
  run cas SendMessage; [ "$status" -eq 1 ]; [ "$output" = missing ]
  seed "$OTHERS"
  run cas SendMessage; [ "$status" -eq 1 ]; [ "$output" = missing ]
}

@test "status: unreadable and 2 for malformed JSON and each wrong shape" {
  local s
  printf 'nope' > "$F"
  run cas SendMessage; [ "$status" -eq 2 ]; [ "$output" = unreadable ]
  for s in '[]' '{"permissions":[]}' '{"permissions":{"allow":"SendMessage"}}' '{"permissions":{"allow":[1]}}' \
            '[] {"permissions":{"allow":["SendMessage"]}}' '{} {}' ''; do
    seed "$s"
    run cas SendMessage
    [ "$status" -eq 2 ] || { echo "shape $s: $status $output"; return 1; }
    [ "$output" = unreadable ]
  done
}

@test "status writes nothing and takes no lock file" {
  seed "$OTHERS"
  before=$(cat "$F")
  cas SendMessage || true
  [ "$(cat "$F")" = "$before" ]
  [ "$(ls -A "$HOME/.claude")" = settings.json ]
}

@test "status: a bad TOOL is 64" {
  run cas 'a b'
  [ "$status" -eq 64 ]
}
