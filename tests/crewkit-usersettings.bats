#!/usr/bin/env bats
# libexec/ck/usersettings.sh: ck_user_set and ck_user_unset write ~/.claude/crewkit.md. Each test
# runs the functions in a fresh bash (usp: with --yes, usd: a dry run) so locks and $$ are real.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

CANARY=canary-9f3e

setup() {
  ck_setup
  F="$HOME/.claude/crewkit.md"
}

# usp ARGS...: run ck_user_set/ck_user_unset ARGS... with CK_YES=1 in a new bash; stdin passes through.
usp() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; shift; CK_YES=1; "$@"' _ "$TREE" "$@"
}
# usd ARGS...: the same as a dry run.
usd() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; shift; "$@"' _ "$TREE" "$@"
}

# seed: a file with comments, other keys, a prefix-twin key and a body.
seed() {
  printf '%s\n' --- '# my notes' 'nodes.a.host: "old@homebox"' 'nodes.a.hostx: "keep"' 'limits.max_sessions: 4' 'plain: yes' --- '' 'Body line one.' '---' 'Body after a rule.' > "$F"
  chmod 600 "$F"
}

@test "set then read back through crew_setting, values with spaces, # and :" {
  usp ck_user_set nodes.a.host 'u@homebox'
  usp ck_user_set nodes.a.machine 'lab box #2: x'
  ck_lib
  [ "$(crew_setting nodes.a.host)" = 'u@homebox' ]
  [ "$(crew_setting nodes.a.machine)" = 'lab box #2: x' ]
  grep -qx 'nodes.a.machine: "lab box #2: x"' "$F"
}

@test "replacing a key keeps other keys, comments and the body byte for byte" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  usp ck_user_set nodes.a.host 'new@homebox'
  sed 's/^nodes.a.host: .*/nodes.a.host: "new@homebox"/' "$BATS_TEST_TMPDIR/before" > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "a new key is appended before the closing --- and the body is untouched" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  usp ck_user_set nodes.b.host 'x@clientspoke'
  awk 'NR > 1 && $0 == "---" && !d { print "nodes.b.host: \"x@clientspoke\""; d = 1 } { print }' "$BATS_TEST_TMPDIR/before" > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "a key that is a prefix of another is not touched" {
  seed
  usp ck_user_set nodes.a.host 'new@homebox'
  grep -qx 'nodes.a.hostx: "keep"' "$F"
  usp ck_user_set nodes.a.hostx 'other'
  grep -qx 'nodes.a.host: "new@homebox"' "$F"
  grep -qx 'nodes.a.hostx: "other"' "$F"
  [ "$(grep -c '^nodes.a.host' "$F")" -eq 2 ]
}

@test "a missing file is created 600 under a 700 ~/.claude" {
  rmdir "$HOME/.claude"
  usp ck_user_set nodes.a.host 'u@homebox'
  [ "$(ls -ld "$HOME/.claude" | cut -c1-10)" = drwx------ ]
  [ "$(ls -l "$F" | cut -c1-10)" = -rw------- ]
  [ "$(cat "$F")" = "$(printf '%s\n' --- 'nodes.a.host: "u@homebox"' ---)" ]
}

@test "an existing ~/.claude keeps its mode" {
  chmod 755 "$HOME/.claude"
  usp ck_user_set k v
  [ "$(ls -ld "$HOME/.claude" | cut -c1-10)" = drwxr-xr-x ]
}

@test "a file without frontmatter gets frontmatter in front, body kept" {
  printf 'just notes\n' > "$F"
  usp ck_user_set k v
  [ "$(cat "$F")" = "$(printf '%s\n' --- 'k: "v"' --- 'just notes')" ]
}

@test "a quote, control character or padded value is 65; a bad key is 64; nothing written" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  run usp ck_user_set k 'a"b';          [ "$status" -eq 65 ]
  run usp ck_user_set k "a'b";          [ "$status" -eq 65 ]
  run usp ck_user_set k $'a\nb';        [ "$status" -eq 65 ]
  run usp ck_user_set k $'a\tb';        [ "$status" -eq 65 ]
  run usp ck_user_set k ' lead';        [ "$status" -eq 65 ]
  run usp ck_user_set k 'trail ';       [ "$status" -eq 65 ]
  run usp ck_user_set 'Bad Key' v;      [ "$status" -eq 64 ]
  run usp ck_user_set '' v;             [ "$status" -eq 64 ]
  run usp ck_user_set 'a:b' v;          [ "$status" -eq 64 ]
  run usp ck_user_set k;                [ "$status" -eq 64 ]
  run usp ck_user_unset 'Bad Key';      [ "$status" -eq 64 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a world-writable file is refused (78), nothing written" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  chmod 602 "$F"
  run usp ck_user_set k v
  [ "$status" -eq 78 ]
  run usp ck_user_unset k
  [ "$status" -eq 78 ]
  chmod 600 "$F"
  cmp "$F" "$BATS_TEST_TMPDIR/before" || { chmod 602 "$F"; false; }
}

@test "a group-writable file is allowed, like the reader allows it" {
  seed
  chmod 660 "$F"
  usp ck_user_set k v
  grep -qx 'k: "v"' "$F"
  chmod 620 "$F"
  usp ck_user_set k v2
  grep -qx 'k: "v2"' "$F"
}

@test "a ~/.claude writable by others or owned by someone else is refused (78)" {
  chmod 707 "$HOME/.claude"
  run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$HOME/.claude is writable by others"* ]]
  chmod 700 "$HOME/.claude"
  mkdir "$BATS_TEST_TMPDIR/idshim"
  printf '#!/bin/sh\necho 99999\n' > "$BATS_TEST_TMPDIR/idshim/id"
  chmod +x "$BATS_TEST_TMPDIR/idshim/id"
  PATH="$BATS_TEST_TMPDIR/idshim:$PATH" run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$HOME/.claude is not owned"* ]]
  [ ! -e "$F" ]
}

@test "a find that fails makes the checks refuse (78), never pass" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  mkdir "$BATS_TEST_TMPDIR/findshim"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/findshim/find"
  chmod +x "$BATS_TEST_TMPDIR/findshim/find"
  PATH="$BATS_TEST_TMPDIR/findshim:$PATH" run usp ck_user_set k v
  [ "$status" -eq 78 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a crewkit.md owned by someone else is refused (78), naming the file, nothing written" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  # Only $F looks foreign: a find that reports it for the `! -user` test and is the real find otherwise.
  mkdir "$BATS_TEST_TMPDIR/ownshim"
  cat > "$BATS_TEST_TMPDIR/ownshim/find" <<'SH'
#!/bin/sh
foreign=0 neg=0
for a in "$@"; do
  [ "$a" = "-user" ] && foreign=1
  [ "$a" = "!" ] && neg=1
done
if [ "$1" = "$OWN_SHIM_FILE" ] && [ $foreign = 1 ] && [ $neg = 1 ]; then printf '%s\n' "$1"; exit 0; fi
P=
IFS=:
for d in $PATH; do [ "$d" = "$OWN_SHIM_DIR" ] || P=${P:+$P:}$d; done
PATH=$P
exec find "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/ownshim/find"
  export OWN_SHIM_FILE="$F" OWN_SHIM_DIR="$BATS_TEST_TMPDIR/ownshim"
  PATH="$OWN_SHIM_DIR:$PATH" run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is not owned"* ]]
  PATH="$OWN_SHIM_DIR:$PATH" run --separate-stderr usp ck_user_unset nodes.a.host
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is not owned"* ]]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "an id that fails refuses (78); crewkit.md as a directory refuses (78), nothing written" {
  mkdir "$BATS_TEST_TMPDIR/idfail"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/idfail/id"
  chmod +x "$BATS_TEST_TMPDIR/idfail/id"
  PATH="$BATS_TEST_TMPDIR/idfail:$PATH" run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"id -u failed"* ]]
  [ ! -e "$F" ]
  mkdir "$F"
  run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is not a regular file"* ]]
  run --separate-stderr usp ck_user_unset k
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is not a regular file"* ]]
  [ -z "$(ls -A "$F")" ]
}

@test "a symlinked crewkit.md or ~/.claude is refused (78), naming it, and not written through" {
  printf '%s\n' --- 'a: "1"' --- > "$BATS_TEST_TMPDIR/target"
  cp "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/target.before"
  ln -s "$BATS_TEST_TMPDIR/target" "$F"
  run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F"* ]]
  [[ $stderr == *"$F is a symlink"* ]]
  run --separate-stderr usp ck_user_unset a
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is a symlink"* ]]
  run --separate-stderr usd ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$F is a symlink"* ]]
  cmp "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/target.before"
  rm "$F"
  rmdir "$HOME/.claude"
  mkdir "$BATS_TEST_TMPDIR/realclaude"
  ln -s "$BATS_TEST_TMPDIR/realclaude" "$HOME/.claude"
  run --separate-stderr usp ck_user_set k v
  [ "$status" -eq 78 ]
  [[ $stderr == *"$HOME/.claude is a symlink"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/realclaude")" ]
}

@test "dry run prints and writes nothing" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  run usd ck_user_set nodes.a.host 'new@homebox'
  [ "$status" -eq 0 ]
  [ "$output" = 'set nodes.a.host: "new@homebox" in ~/.claude/crewkit.md' ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  run usd ck_user_unset nodes.a.host
  [ "$status" -eq 0 ]
  [ "$output" = 'unset nodes.a.host in ~/.claude/crewkit.md' ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  rm "$F"
  usd ck_user_set k v
  [ ! -e "$F" ]
}

@test "CK_YES from the environment does not turn a dry run into a write" {
  CK_YES=1 run usd ck_user_set k v
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
}

@test "unset removes only that key" {
  seed
  usp ck_user_unset nodes.a.host
  grep -qx 'nodes.a.hostx: "keep"' "$F"
  none -q '^nodes.a.host:' "$F"
  [ "$(grep -c . "$F")" -eq 9 ]
  grep -qx 'Body after a rule.' "$F"
}

@test "unset of a key or file that is not there succeeds and changes nothing" {
  run usp ck_user_unset nope
  [ "$status" -eq 0 ]
  [ ! -e "$F" ]
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  usp ck_user_unset nope
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a key only in the body is not replaced or removed" {
  seed
  printf 'nodes.a.host: "bodyline"\n' >> "$F"
  usp ck_user_set nodes.a.host 'new@homebox'
  usp ck_user_unset limits.max_sessions
  [ "$(tail -n 1 "$F")" = 'nodes.a.host: "bodyline"' ]
}

@test "8 concurrent writers on different keys all land" {
  local i pids=() pid
  for i in 1 2 3 4 5 6 7 8; do
    usp ck_user_set "k$i" "v$i" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  for i in 1 2 3 4 5 6 7 8; do grep -qx "k$i: \"v$i\"" "$F"; done
  [ "$(grep -c '^k' "$F")" -eq 8 ]
}

@test "the lock is held during the write and released on success and on a refusal" {
  local lock="$HOME/.local/state/crewkit/locks/user-settings.lock"
  usp ck_user_set k v
  [ ! -e "$lock" ]
  [ ! -L "$lock" ]
  chmod 602 "$F"
  run usp ck_user_set k v2
  [ "$status" -eq 78 ]
  [ ! -L "$lock" ]
  chmod 600 "$F"
  # A live holder blocks the writer until the wait runs out (75).
  mkdir -p "$HOME/.local/state/crewkit/locks"
  sleep 30 >/dev/null 2>&1 3>&- & local holder=$!
  ln -s "$holder" "$lock"
  CREWKIT_LOCK_WAIT_SECONDS=1 run usp ck_user_set k v3
  kill "$holder"
  [ "$status" -eq 75 ]
  grep -qx 'k: "v"' "$F"
}

# ---- --secret ----------------------------------------------------------------------------------

@test "--secret reads the value from stdin, one line, and reads back" {
  printf '%s\nignored second line\n' "$CANARY" | usp ck_user_set --secret nodes.a.token
  grep -qx "nodes.a.token: \"$CANARY\"" "$F"
  ck_lib
  [ "$(crew_setting nodes.a.token)" = "$CANARY" ]
}

@test "--secret takes no value argument, and needs a value on stdin" {
  run usp ck_user_set --secret k "$CANARY" < /dev/null
  [ "$status" -eq 64 ]
  run usp ck_user_set --secret k < /dev/null
  [ "$status" -eq 65 ]
  [ ! -e "$F" ]
}

@test "the canary never appears in stdout or stderr: write, dry run, refusal" {
  run --separate-stderr bash -c 'printf "%s\n" "$2" | "${@:3}"' _ x "$CANARY" bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; CK_YES=1; ck_user_set --secret k' _ "$TREE"
  [ "$status" -eq 0 ]
  none -q "$CANARY" <<<"$output$stderr"
  run --separate-stderr bash -c 'printf "%s\n" "$1" | "${@:2}"' _ "$CANARY" bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; ck_user_set --secret k' _ "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = 'set k: <secret> in ~/.claude/crewkit.md' ]
  none -q "$CANARY" <<<"$stderr"
  run --separate-stderr bash -c 'printf "%s\n" "$1" | "${@:2}"' _ "$CANARY\"x" bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; CK_YES=1; ck_user_set --secret k' _ "$TREE"
  [ "$status" -eq 65 ]
  none -q "$CANARY" <<<"$output$stderr"
  # And the refused symlink path.
  rm "$F"; ln -s /nonexistent "$F"
  run --separate-stderr bash -c 'printf "%s\n" "$1" | "${@:2}"' _ "$CANARY" bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; CK_YES=1; ck_user_set --secret k' _ "$TREE"
  [ "$status" -eq 78 ]
  none -q "$CANARY" <<<"$output$stderr"
}

@test "the value is in no external command's argv, and the temp file is created 600 (never chmodded)" {
  local shims="$BATS_TEST_TMPDIR/shims" cmd
  mkdir "$shims"
  cat > "$shims/shim" <<'SH'
#!/usr/bin/env bash
name=${0##*/}
printf '%s' "$name" >> "$SHIM_LOG"
printf ' %s' "$@" >> "$SHIM_LOG"
printf '\n' >> "$SHIM_LOG"
if [[ $name == mv ]]; then ls -l "$1" | cut -c1-10 >> "$SHIM_LOG.mode"; fi
PATH=${PATH#"$SHIM_DIR":}
exec "$(command -v "$name")" "$@"
SH
  chmod +x "$shims/shim"
  for cmd in mv mktemp chmod awk find mkdir ln rm cat sed grep cp ls cut stat; do ln -s shim "$shims/$cmd"; done
  export SHIM_LOG="$BATS_TEST_TMPDIR/argv.log" SHIM_DIR="$shims"
  : > "$SHIM_LOG"
  seed
  ( umask 000; printf '%s\n' "$CANARY" | PATH="$shims:$PATH" usp ck_user_set --secret nodes.a.token )
  grep -qx "nodes.a.token: \"$CANARY\"" "$F"
  [ -s "$SHIM_LOG" ]
  grep -q '^mv ' "$SHIM_LOG"
  none -q "$CANARY" "$SHIM_LOG"
  none -q '^chmod .*crewkit\.md' "$SHIM_LOG"
  [ "$(cat "$SHIM_LOG.mode")" = -rw------- ]
  [ "$(ls -l "$F" | cut -c1-10)" = -rw------- ]
  # The plain (argv) form leaves its value in no shim argv either: values only ever go through the environment.
  : > "$SHIM_LOG"
  PATH="$shims:$PATH" usp ck_user_set plain2 "$CANARY"
  none -q "$CANARY" "$SHIM_LOG"
}

@test "no temp file is left behind" {
  seed
  usp ck_user_set k v
  run usp ck_user_set k 'a"b'
  chmod 602 "$F"
  run usp ck_user_set k v
  chmod 600 "$F"
  [ "$(ls -A "$HOME/.claude")" = crewkit.md ]
}

# ---- the check before the rename ----------------------------------------------------------------

# awkshim PIPELINE: a PATH shim dir ($AWKSHIM) whose awk runs the real awk and passes its output through
# the awk program PIPELINE (a post-filter that damages it).
awkshim() {
  AWKSHIM="$BATS_TEST_TMPDIR/awkshim"
  mkdir -p "$AWKSHIM"
  {
    printf '#!/bin/sh\n'
    printf 'D=%s\n' "$AWKSHIM"
    printf 'P=\nIFS=:\nfor d in $PATH; do [ "$d" = "$D" ] || P=${P:+$P:}$d; done\nPATH=$P\n'
    printf 'awk "$@" | awk %s\n' "'$1'"
  } > "$AWKSHIM/awk"
  chmod +x "$AWKSHIM/awk"
}

@test "an awk that writes only part of the output (stops after the frontmatter): set and unset fail closed" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  awkshim '{ print } /^---$/ && ++c == 2 { exit }'
  PATH="$AWKSHIM:$PATH" run usp ck_user_set nodes.b.host 'x@y'
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  PATH="$AWKSHIM:$PATH" run usp ck_user_set nodes.a.host 'x@y'
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  PATH="$AWKSHIM:$PATH" run usp ck_user_unset limits.max_sessions
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$HOME/.local/state/crewkit/locks/user-settings.lock" ]
  [ "$(ls -A "$HOME/.claude")" = crewkit.md ]
}

@test "an awk that replaces the last line with another one fails closed (the body's end must survive)" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  # Changing an existing key keeps the line count; the shim swaps the last line, so only the end differs.
  awkshim '{ l[NR] = $0 } END { for (i = 1; i < NR; i++) print l[i]; print "damaged" }'
  PATH="$AWKSHIM:$PATH" run usp ck_user_set nodes.a.host 'x@y'
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a body line equal to the wanted line does not stand in for a frontmatter write that failed" {
  seed
  printf 'nodes.b.host: "x@y"\n' >> "$F"
  cp "$F" "$BATS_TEST_TMPDIR/before"
  # The frontmatter line gets another value: the count and the last line are right, the key is not in the frontmatter.
  awkshim '$0 == "nodes.b.host: \"x@y\"" && !d { print "nodes.b.host: \"other\""; d = 1; next } { print }'
  PATH="$AWKSHIM:$PATH" run usp ck_user_set nodes.b.host 'x@y'
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "an awk that leaves the key in the frontmatter on an unset (and loses a body line instead) fails closed" {
  seed
  cp "$F" "$BATS_TEST_TMPDIR/before"
  # The line count, the last line and the body's end are right; the key is still in the frontmatter.
  awkshim '$0 == "Body line one." { next } $0 == "---" && ++c == 2 { print "limits.max_sessions: 4" } { print }'
  PATH="$AWKSHIM:$PATH" run usp ck_user_unset limits.max_sessions
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a frontmatter-only file whose closing fence is cut to -- is not renamed into place" {
  printf '%s\n' --- 'a: 1' --- > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/before"
  awkshim '$0 == "---" && ++c == 2 { print "--"; next } { print }'
  PATH="$AWKSHIM:$PATH" run usp ck_user_set k v
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  printf '%s\n' --- 'a: 1' 'k: "v"' --- > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/before"
  PATH="$AWKSHIM:$PATH" run usp ck_user_unset k
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "duplicate keys in the frontmatter: set keeps the first place and drops the twin, unset drops both" {
  printf '%s\n' --- 'k: "1"' 'other: 2' 'k: "3"' --- 'body' > "$F"
  usp ck_user_set k v
  [ "$(cat "$F")" = "$(printf '%s\n' --- 'k: "v"' 'other: 2' --- 'body')" ]
  printf '%s\n' --- 'k: "1"' 'other: 2' 'k: "3"' --- 'body' > "$F"
  usp ck_user_unset k
  [ "$(cat "$F")" = "$(printf '%s\n' --- 'other: 2' --- 'body')" ]
}

@test "--secret leaves no copy of the value in the caller's shell variables (unclosed frontmatter puts it on the last line)" {
  printf '%s\n' --- 'a: 1' > "$F"
  printf '%s\n' "$CANARY" > "$BATS_TEST_TMPDIR/secret"
  run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/usersettings.sh"; CK_YES=1; ck_user_set --secret k < "$2"; declare -p' _ "$TREE" "$BATS_TEST_TMPDIR/secret"
  [ "$status" -eq 0 ]
  grep -qx "k: \"$CANARY\"" "$F"
  none -q "$CANARY" <<<"$output"
}
