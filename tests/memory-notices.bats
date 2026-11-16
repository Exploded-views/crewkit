#!/usr/bin/env bats
# The memory-notices hooks, run the way Claude Code runs them: each command through a shell
# with the hook's JSON on stdin.

bats_require_minimum_version 1.5.0
load memory-notices-helpers

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export CLAUDE_PLUGIN_ROOT="$REPO/plugins/memory-notices"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  # Only the basics on PATH, so a real claude-memsync on this machine can't leak in.
  BASE_PATH="$STUBS:/usr/bin:/bin"
  # The wrapper keeps its state under XDG_STATE_HOME: never the real one.
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  STATE="$XDG_STATE_HOME/crewkit/memory-notices"
  HOOK="$CLAUDE_PLUGIN_ROOT/bin/changes-hook"
  # Where the stub claude-memsync leaves its pids and logs.
  export STUB_DIR="$BATS_TEST_TMPDIR/stubdir"
  # Nothing of ours goes to the system TMPDIR.
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  mkdir -p "$STUB_DIR"
  # flock is not in the minimal PATH (and is not stock on macOS): link it in when the host has one.
  if command -v flock >/dev/null 2>&1; then ln -s "$(command -v flock)" "$STUBS/flock"; fi
  BG=''
  TS=$(scale_of "${CREWKIT_TEST_TIME_SCALE:-}")
}

# Never leave a stub behind, even when a test fails midway: exact pids only.
teardown() {
  local f p
  for f in "$STUB_DIR"/*.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f")
    case $p in '' | *[!0-9]*) continue ;; esac
    kill -KILL "$p" 2>/dev/null || true
  done
  if [ -n "$BG" ]; then kill -KILL "$BG" 2>/dev/null || true; fi
}

# nothing_left: the stub, its grandchild, their group and the wrapper's timer are all gone.
nothing_left() {
  local stub timer
  stub=$(cat "$STUB_DIR/stub.pid")
  timer=$(cat "$STATE/changes-hook.timer.pid")
  gone "$stub"
  gone "$(cat "$STUB_DIR/grandchild.pid")"
  gone "$timer"
  group_empty "$stub"
  group_empty "$timer"
}

# stub_hang: a claude-memsync that prints a partial line, spawns a grandchild, and then waits
# for it (15 s at most, so a failing test ends). Its own pid and the grandchild's are recorded.
stub_hang() {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
echo $$ > "$STUB_DIR/stub.pid"
echo start >> "$STUB_DIR/starts"
echo "partial notice"
sleep 15 &
echo $! > "$STUB_DIR/grandchild.pid"
wait $!
EOF
  chmod +x "$STUBS/claude-memsync"
}

# stub_deaf: like stub_hang, but ignoring TERM (so only KILL stops it); the grandchild inherits that.
stub_deaf() {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
trap '' TERM
echo $$ > "$STUB_DIR/stub.pid"
echo "partial notice"
sleep 15 &
echo $! > "$STUB_DIR/grandchild.pid"
wait $!
EOF
  chmod +x "$STUBS/claude-memsync"
}

# stub_gated: records a start, then waits for $STUB_DIR/go (15 s at most) before printing.
stub_gated() {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
echo start >> "$STUB_DIR/starts"
i=0
while [ ! -e "$STUB_DIR/go" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
echo "notice from $*"
EOF
  chmod +x "$STUBS/claude-memsync"
}

# stub_leaky [deaf]: prints "notice" and exits 0, leaving a sleeping grandchild in its group.
stub_leaky() {
  local trapline=''
  if [ "${1:-}" = deaf ]; then trapline="trap '' TERM"; fi
  cat > "$STUBS/claude-memsync" <<EOF
#!/bin/sh
$trapline
echo \$\$ > "\$STUB_DIR/stub.pid"
sleep 15 &
echo \$! > "\$STUB_DIR/grandchild.pid"
echo notice
EOF
  chmod +x "$STUBS/claude-memsync"
}

# mv_barrier GLOB: a stand-in mv first on PATH. A call whose first argument matches GLOB waits
# (3 s at most) until two such calls have arrived, then does the real mv: two runs are held at
# exactly that step and released together.
mv_barrier() {
  mkdir -p "$BATS_TEST_TMPDIR/barrier"
  cat > "$STUBS/mv" <<EOF
#!/bin/sh
case "\$1" in
  $1)
    : > "$BATS_TEST_TMPDIR/barrier/arrived.\$\$"
    i=0
    while [ \$(( \$(ls "$BATS_TEST_TMPDIR/barrier" | wc -l) + 0 )) -lt 2 ] && [ "\$i" -lt 150 ]; do sleep 0.02; i=\$((i + 1)); done ;;
esac
exec /bin/mv "\$@"
EOF
  chmod +x "$STUBS/mv"
}

# stub_seq: instance 1 (the first to start) prints its notice last; instance 2 prints at once and
# leaves only after instance 1 has printed. Each prints "notice <its pid>" and keeps a pid file.
stub_seq() {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
if mkdir "$STUB_DIR/first" 2>/dev/null; then
  echo $$ > "$STUB_DIR/stub-first.pid"
  echo start >> "$STUB_DIR/starts"
  i=0
  while [ ! -e "$STUB_DIR/second.wrote" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
  echo "notice $$"
  : > "$STUB_DIR/first.wrote"
else
  echo $$ > "$STUB_DIR/stub-second.pid"
  echo "notice $$"
  : > "$STUB_DIR/second.wrote"
  i=0
  while [ ! -e "$STUB_DIR/first.wrote" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
fi
EOF
  chmod +x "$STUBS/claude-memsync"
}

# stub_pidgate: like stub_gated, but prints "notice <its pid>" and keeps a pid file of its own.
stub_pidgate() {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
echo $$ > "$STUB_DIR/stub-$$.pid"
echo start >> "$STUB_DIR/starts"
i=0
while [ ! -e "$STUB_DIR/go" ] && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
echo "notice $$"
EOF
  chmod +x "$STUBS/claude-memsync"
}

# stub_echo: a claude-memsync that prints "run" and returns at once.
stub_echo() {
  printf '#!/bin/sh\necho run\n' > "$STUBS/claude-memsync"
  chmod +x "$STUBS/claude-memsync"
}

# direct [VAR=value ...]: the wrapper, run without bats' `run`. `run` reads the command's output to
# EOF, so it waits for any leftover that still holds the pipe; by the time it returns the leftover
# has exited on its own and a check after it finds nothing. Sets status, output and stderr.
direct() {
  status=0
  env PATH="$BASE_PATH" "$@" "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/direct.out" 2> "$BATS_TEST_TMPDIR/direct.err" || status=$?
  output=$(cat "$BATS_TEST_TMPDIR/direct.out")
  stderr=$(cat "$BATS_TEST_TMPDIR/direct.err")
}

# run_hook [VAR=value ...]: the wrapper, with the hook's JSON on stdin.
run_hook() { run env PATH="$BASE_PATH" "$@" "$HOOK" <<<'{"hook_event_name":"UserPromptSubmit"}'; }

# memsync_commands: every hook command that calls claude-memsync, one per line.
memsync_commands() {
  python3 -c 'import json,sys
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            if "claude-memsync" in h["command"]:
                print(h["command"])' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json"
}

@test "every claude-memsync hook is a silent no-op when claude-memsync isn't installed" {
  local cmd n=0
  while IFS= read -r cmd; do
    n=$((n + 1))
    run env PATH="$BASE_PATH" sh -c "$cmd" <<<'{"hook_event_name":"UserPromptSubmit"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done < <(memsync_commands)
  [ "$n" -ge 2 ]
}

@test "the hooks call claude-memsync changes --hook when it is installed" {
  printf '#!/bin/sh\necho "called $*"\n' > "$STUBS/claude-memsync"
  chmod +x "$STUBS/claude-memsync"
  local cmd
  while IFS= read -r cmd; do
    run env PATH="$BASE_PATH" sh -c "$cmd" <<<'{}'
    [ "$status" -eq 0 ]
    [ "$output" = "called changes --hook" ]
  done < <(memsync_commands)
}

@test "hooks.json: both memsync hooks go through changes-hook, still under the harness's 10 s" {
  local n=0 cmd
  while IFS= read -r cmd; do
    n=$((n + 1))
    [[ $cmd == *'"${CLAUDE_PLUGIN_ROOT}/bin/changes-hook"'* ]]
    [[ $cmd != *'claude-memsync changes'* ]]
  done < <(memsync_commands)
  [ "$n" -eq 2 ]
  python3 - "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json" <<'EOF'
import json, sys
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            assert h["timeout"] == 10, h
EOF
}

@test "changes-hook: memsync absent is a silent exit 0, and leaves no state behind" {
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$XDG_STATE_HOME" ]
}

@test "changes-hook: a normal run passes stdout through exactly, and stdin reaches memsync" {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
printf 'line one\n\n  indented "quoted" $x\nno trailing newline'
cat >> "$STUB_DIR/stdin"
EOF
  chmod +x "$STUBS/claude-memsync"
  env PATH="$BASE_PATH" "$HOOK" <<<'{"hook_event_name":"UserPromptSubmit"}' > "$BATS_TEST_TMPDIR/out"
  printf 'line one\n\n  indented "quoted" $x\nno trailing newline' > "$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/want"
  [ "$(cat "$STUB_DIR/stdin")" = '{"hook_event_name":"UserPromptSubmit"}' ]
}

@test "changes-hook: runs claude-memsync changes --hook" {
  printf '#!/bin/sh\necho "called $*"\n' > "$STUBS/claude-memsync"
  chmod +x "$STUBS/claude-memsync"
  run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "called changes --hook" ]
}

@test "changes-hook: a failing memsync exits 0, its stdout is not injected, and the failure is logged" {
  printf '#!/bin/sh\necho "error text on stdout"\necho "and stderr" >&2\nexit 3\n' > "$STUBS/claude-memsync"
  chmod +x "$STUBS/claude-memsync"
  run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'exited with status 3' "$STATE/changes-hook.log"
}

@test "changes-hook: a normal run is fast, and leaves neither a timer nor anything else behind" {
  stub_leaky
  local t0 t1
  t0=$(now_ms)
  direct CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ "$output" = "notice" ]
  [ $((t1 - t0)) -lt $(ms_bound 500) ]
  nothing_left
}

@test "changes-hook: a grandchild that outlives a normal exit is stopped with the rest of the group" {
  stub_leaky
  direct
  [ "$output" = "notice" ]
  gone "$(cat "$STUB_DIR/grandchild.pid")"
}

@test "changes-hook: a grandchild that ignores TERM is killed too after a normal exit" {
  stub_leaky deaf
  direct
  [ "$output" = "notice" ]
  gone "$(cat "$STUB_DIR/grandchild.pid")"
}

# ms_case VALUE EXPECTED_MS: a hanging stub with that timeout value is stopped, and at EXPECTED_MS.
ms_case() {
  rm -rf "$STATE"
  stub_hang
  local t0 t1
  t0=$(now_ms)
  run env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS="$1" "$HOOK" <<<'{}'
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((t1 - t0)) -ge $(($2 - 50)) ]
  [ $((t1 - t0)) -lt $(ms_bound $(($2 + 1000))) ]
  grep -q "timed out after $2 ms" "$STATE/changes-hook.log"
}

@test "changes-hook: the timeout is read as decimal, clamped to 100..5000, and always fires" {
  ms_case 0800 800
  ms_case 09 100
  ms_case 00 100
  ms_case abc 2000
  ms_case 99999 5000
}

@test "changes-hook: state dir is 0700, the lock 0600, and nothing is logged on a clean run" {
  stub_echo
  run_hook
  [ "$status" -eq 0 ]
  [[ $(ls -ld "$STATE") == drwx------* ]]
  if [ -f "$STATE/changes-hook.lock" ]; then
    [[ $(ls -l "$STATE/changes-hook.lock") == -rw-------* ]]
  fi
  [ ! -s "$STATE/changes-hook.log" ]
}

@test "changes-hook: a child that never returns is stopped at the timeout, silently, and nothing is left behind" {
  stub_hang
  local t0 t1
  t0=$(now_ms)
  direct CREWKIT_CHANGES_HOOK_TIMEOUT_MS=500
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ $((t1 - t0)) -ge 400 ]
  [ $((t1 - t0)) -lt $(ms_bound 1500) ]
  nothing_left
}

@test "changes-hook: a child that ignores TERM is killed 200 ms later, and nothing is left behind" {
  stub_deaf
  local t0 t1
  t0=$(now_ms)
  direct CREWKIT_CHANGES_HOOK_TIMEOUT_MS=300
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((t1 - t0)) -ge 450 ]
  [ $((t1 - t0)) -lt $(ms_bound 1500) ]
  nothing_left
}

@test "changes-hook: the timeout defaults to 2000 ms, and a bad value falls back to it" {
  stub_hang
  local t0 t1
  t0=$(now_ms)
  run env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=soon "$HOOK" <<<'{}'
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((t1 - t0)) -ge 1900 ]
  [ $((t1 - t0)) -lt $(ms_bound 3000) ]
}

# overlap [VAR=value ...]: a second run while the first still holds the lock does nothing, at once.
overlap() {
  stub_gated
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=10000 "$@" "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/first" &
  BG=$!
  local i
  for i in $(seq 1 100); do [ -s "$STUB_DIR/starts" ] && break; sleep 0.05; done
  [ -s "$STUB_DIR/starts" ]
  local t0 t1
  t0=$(now_ms)
  run env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=10000 "$@" "$HOOK" <<<'{}'
  t1=$(now_ms)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ $((t1 - t0)) -lt $(ms_bound 500) ]
  touch "$STUB_DIR/go"
  wait "$BG"
  BG=''
  [ "$(cat "$BATS_TEST_TMPDIR/first")" = "notice from changes --hook" ]
  [ "$(wc -l < "$STUB_DIR/starts" | tr -d ' ')" = 1 ]
}

@test "changes-hook: an overlapping run exits 0 at once and starts no second child (flock)" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  overlap
}

@test "changes-hook: an overlapping run exits 0 at once and starts no second child (mkdir lock)" {
  overlap CREWKIT_CHANGES_HOOK_NO_FLOCK=1
}

@test "changes-hook: the lock is free again after a run (mkdir lock)" {
  stub_echo
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$output" = run ]
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$output" = run ]
}

@test "changes-hook: the lock is free again after a run (flock)" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  stub_echo
  run_hook
  [ "$output" = run ]
  run_hook
  [ "$output" = run ]
}

@test "changes-hook: a mkdir lock left by a dead process is taken over" {
  stub_echo
  mkdir -p "$STATE/changes-hook.lock.d"
  sleep 0 &
  local dead=$!
  wait "$dead"
  echo "$dead" > "$STATE/changes-hook.lock.d/pid"
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$status" -eq 0 ]
  [ "$output" = run ]
}

@test "changes-hook: a mkdir lock held by a live process for too long is taken over" {
  stub_echo
  mkdir -p "$STATE/changes-hook.lock.d"
  sleep 20 &
  BG=$!
  disown "$BG"
  echo "$BG 1" > "$STATE/changes-hook.lock.d/pid"
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$output" = run ]
}

@test "changes-hook: a run removes only a mkdir lock it still owns" {
  stub_gated
  sleep 20 &
  BG=$!
  disown "$BG"
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/first" &
  local run1=$!
  local i
  for i in $(seq 1 100); do [ -s "$STUB_DIR/starts" ] && break; sleep 0.05; done
  # Someone else has taken the lock over (as a stale-lock break would).
  echo "$BG 4000000000" > "$STATE/changes-hook.lock.d/pid"
  touch "$STUB_DIR/go"
  wait "$run1"
  [ "$(cut -d' ' -f1 "$STATE/changes-hook.lock.d/pid")" = "$BG" ]
}

@test "changes-hook: a mkdir lock held by a live process is respected" {
  stub_echo
  mkdir -p "$STATE/changes-hook.lock.d"
  sleep 20 &
  BG=$!
  disown "$BG"
  echo "$BG" > "$STATE/changes-hook.lock.d/pid"
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "changes-hook: a timeout logs one line, and at most one per minute" {
  stub_hang
  local i
  for i in 1 2 3; do
    run env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=200 "$HOOK" <<<'{}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ "$(wc -l < "$STATE/changes-hook.log" | tr -d ' ')" = 1 ]
  grep -q 'timed out after 200 ms' "$STATE/changes-hook.log"
  # A minute later (the stamp says so), the next timeout is logged too.
  echo 0 > "$STATE/changes-hook.log.stamp"
  run env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=200 "$HOOK" <<<'{}'
  [ "$(wc -l < "$STATE/changes-hook.log" | tr -d ' ')" = 2 ]
}

@test "changes-hook: memsync's detached helper does not hold the caller's output pipe open" {
  cat > "$STUBS/claude-memsync" <<'EOF'
#!/bin/sh
# A helper that outlives the hook (its own process group, its own stdio) but inherits any other fd.
python3 -S -c 'import os, sys, time; os.setpgrp(); open(sys.argv[1], "w").close(); time.sleep(4)' "$STUB_DIR/helper.up" </dev/null >/dev/null 2>&1 &
echo $! > "$STUB_DIR/helper.pid"
i=0
while [ ! -e "$STUB_DIR/helper.up" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
echo notice
EOF
  chmod +x "$STUBS/claude-memsync"
  local t0 t1 got
  t0=$(now_ms)
  got=$(env PATH="$BASE_PATH" "$HOOK" <<<'{}' 2>&1)
  t1=$(now_ms)
  [ "$got" = notice ]
  [ $((t1 - t0)) -lt $(ms_bound 500) ]
}

@test "changes-hook: two runs renaming a lock into place at once leave exactly one holder" {
  stub_pidgate
  mv_barrier '*changes-hook.lock.d.new.*'
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  local a=$!
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/b" &
  local b=$!
  sleep 1
  touch "$STUB_DIR/go"
  wait "$a" "$b"
  # Both really were at the rename together.
  [ "$(ls "$BATS_TEST_TMPDIR/barrier" | wc -l | tr -d ' ')" = 2 ]
  [ "$(wc -l < "$STUB_DIR/starts" | tr -d ' ')" = 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" | grep -c '^notice ')" = 1 ]
  [ -z "$(ls "$STATE" | grep 'lock\.d')" ]
}

@test "changes-hook: two runs breaking the same stale mkdir lock leave exactly one holder" {
  stub_pidgate
  mkdir -p "$STATE/changes-hook.lock.d"
  sleep 0 &
  local dead=$!
  wait "$dead"
  echo "$dead 1" > "$STATE/changes-hook.lock.d/pid"
  mv_barrier '*changes-hook.lock.d'
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  local a=$!
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/b" &
  local b=$!
  sleep 1
  touch "$STUB_DIR/go"
  wait "$a" "$b"
  [ "$(ls "$BATS_TEST_TMPDIR/barrier" | wc -l | tr -d ' ')" = 2 ]
  [ "$(wc -l < "$STUB_DIR/starts" | tr -d ' ')" = 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" | grep -c '^notice ')" = 1 ]
  [ -z "$(ls "$STATE" | grep 'lock\.d')" ]
}

@test "changes-hook: a live lock moved by mistake is put back without nesting into a new one" {
  stub_echo
  mkdir -p "$STATE/changes-hook.lock.d"
  sleep 0 &
  local dead=$!
  wait "$dead"
  echo "$dead 1" > "$STATE/changes-hook.lock.d/pid"
  sleep 20 &
  BG=$!
  disown "$BG"
  # The stand-in mv plays the other runs: when the break is about to move the stale lock it swaps
  # in a live one (so the wrong lock is moved), and when the move-back is about to run it makes a
  # new lock (as a third run would).
  cat > "$STUBS/mv" <<EOF
#!/bin/sh
case "\$1" in
  *changes-hook.lock.d)
    /bin/rm -rf "\$1"; /bin/mkdir "\$1"; echo "$BG 4000000000" > "\$1/pid" ;;
  *changes-hook.lock.d.stale.*)
    /bin/mkdir "\$2"; echo "$BG 4000000000" > "\$2/pid" ;;
esac
exec /bin/mv "\$@"
EOF
  chmod +x "$STUBS/mv"
  run_hook CREWKIT_CHANGES_HOOK_NO_FLOCK=1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls "$STATE/changes-hook.lock.d" | grep stale)" ]
  [ -z "$(ls "$STATE" | grep 'lock\.d\.')" ]
}

@test "changes-hook: a run keeps its output in files of its own, and removes them" {
  stub_pidgate
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  BG=$!
  local i
  for i in $(seq 1 100); do [ -s "$STUB_DIR/starts" ] && break; sleep 0.05; done
  ls "$STATE" | grep -q "changes-hook\.[0-9]*\.out"
  touch "$STUB_DIR/go"
  wait "$BG"
  BG=''
  [ -z "$(ls "$STATE" | grep -E 'changes-hook\.[0-9]+\.(out|err|timedout)')" ]
}

@test "changes-hook: after a wrapper is killed with -9, the next run's notice is its own" {
  stub_seq
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  BG=$!
  local i
  for i in $(seq 1 100); do [ -s "$STUB_DIR/starts" ] && break; sleep 0.05; done
  kill -KILL "$BG"
  wait "$BG" 2>/dev/null || true
  BG=''
  direct CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000
  # The orphaned first stub printed after the second one did, and into other files.
  [ -e "$STUB_DIR/first.wrote" ]
  [ "$output" = "notice $(cat "$STUB_DIR/stub-second.pid")" ]
}

@test "changes-hook: a killed wrapper's timer does not hold the caller's stderr pipe" {
  stub_pidgate
  python3 - "$HOOK" "$BASE_PATH" "$STUB_DIR" "$XDG_STATE_HOME" <<'EOF'
import os, subprocess, sys, time
hook, path, stub_dir, state = sys.argv[1:]
env = dict(os.environ, PATH=path, XDG_STATE_HOME=state, CREWKIT_CHANGES_HOOK_NO_FLOCK="1",
           CREWKIT_CHANGES_HOOK_TIMEOUT_MS="5000")
p = subprocess.Popen([hook], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
p.stdin.write(b"{}"); p.stdin.close()
for _ in range(100):
    if os.path.exists(os.path.join(stub_dir, "starts")):
        break
    time.sleep(0.05)
p.kill()
t = time.monotonic()
p.stderr.read()  # EOF once nothing the wrapper started still holds the pipe
took = time.monotonic() - t
open(os.path.join(stub_dir, "go"), "w").close()
sys.exit(0 if took < 1.0 else 1)
EOF
}

@test "changes-hook: a killed wrapper's files are removed by its timer, within the timeout plus a second" {
  stub_pidgate
  env PATH="$BASE_PATH" CREWKIT_CHANGES_HOOK_NO_FLOCK=1 CREWKIT_CHANGES_HOOK_TIMEOUT_MS=1000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  BG=$!
  local i
  for i in $(seq 1 100); do [ -s "$STUB_DIR/starts" ] && break; sleep 0.05; done
  ls "$STATE" | grep -qE 'changes-hook\.[0-9]+\.out'
  kill -KILL "$BG"
  wait "$BG" 2>/dev/null || true
  BG=''
  for i in $(seq 1 60); do
    [ -z "$(ls "$STATE" | grep -E 'changes-hook\.[0-9]+\.(out|err|timedout)')" ] && break
    sleep 0.05
  done
  [ -z "$(ls "$STATE" | grep -E 'changes-hook\.[0-9]+\.(out|err|timedout)')" ]
  gone "$(cat "$STUB_DIR/stub-"*.pid)"
}

@test "changes-hook: the lock is free the moment a timed-out run returns (flock)" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  stub_hang
  local i
  for i in $(seq 1 15); do
    direct CREWKIT_CHANGES_HOOK_TIMEOUT_MS=200
    flock -n "$STATE/changes-hook.lock" true
  done
}

@test "changes-hook: a kill grace sleep left behind by a wrapper killed with -9 does not hold the lock (flock)" {
  command -v flock >/dev/null 2>&1 || skip "no flock on this host"
  local real_sleep barrier i stubpid rc=0
  real_sleep=$(command -v sleep)
  barrier="$BATS_TEST_TMPDIR/barrier"
  mkdir -p "$barrier"
  # A sleep that, for the 0.2 s grace sleep only, records its pid and waits (5 s at most) for a release file.
  cat > "$STUBS/sleep" <<STUBEOF
#!/bin/sh
if [ "\$1" = 0.2 ] && [ -n "\${SLEEP_BARRIER_DIR:-}" ]; then
  echo \$\$ > "\$SLEEP_BARRIER_DIR/marker"
  cp "\$SLEEP_BARRIER_DIR/marker" "\$STUB_DIR/gracesleep.pid"
  i=0
  while [ ! -e "\$SLEEP_BARRIER_DIR/release" ] && [ "\$i" -lt 250 ]; do $real_sleep 0.02; i=\$((i + 1)); done
  exit 0
fi
exec $real_sleep "\$@"
STUBEOF
  chmod +x "$STUBS/sleep"
  stub_deaf
  env PATH="$BASE_PATH" SLEEP_BARRIER_DIR="$barrier" CREWKIT_CHANGES_HOOK_TIMEOUT_MS=5000 "$HOOK" <<<'{}' > "$BATS_TEST_TMPDIR/a" &
  BG=$!
  for i in $(seq 1 100); do [ -s "$STUB_DIR/grandchild.pid" ] && break; sleep 0.05; done
  [ -s "$STUB_DIR/grandchild.pid" ]
  stubpid=$(cat "$STUB_DIR/stub.pid")
  # TERM: the wrapper's on_signal runs stop_group on the child, whose grace sleep blocks on the barrier.
  kill -TERM "$BG"
  for i in $(seq 1 100); do [ -s "$barrier/marker" ] && break; sleep 0.05; done
  [ -s "$barrier/marker" ]
  kill -KILL "$BG"
  wait "$BG" 2>/dev/null || true
  BG=''
  # The grace sleep is still blocked: it must not hold the lock.
  flock -n "$STATE/changes-hook.lock" true || rc=$?
  : > "$barrier/release"
  kill -KILL -- "-$stubpid" 2>/dev/null || true
  kill -KILL "$(cat "$barrier/marker")" 2>/dev/null || true
  [ "$rc" -eq 0 ]
}

# ---- the time scale ----

@test "time scale: scale 1 gives 15 polls and a 500 ms bound, scale 10 gives 150 and 5000" {
  TS=1
  [ "$(polls)" -eq 15 ]
  [ "$(ms_bound 500)" -eq 500 ]
  TS=10
  [ "$(polls)" -eq 150 ]
  [ "$(ms_bound 500)" -eq 5000 ]
}

@test "time scale: a bad value gives 1, and one warning line on stderr" {
  local v
  for v in abc 0 51 -3 1.5 01 '1 0'; do
    [ "$(scale_of "$v")" -eq 1 ]
    run --separate-stderr scale_warn "$v"
    [ -z "$output" ]
    [[ $stderr == *"CREWKIT_TEST_TIME_SCALE='$v' is not a whole number from 1 to 50; using 1" ]]
    [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  done
  [ "$(scale_of '')" -eq 1 ]
  [ "$(scale_of 7)" -eq 7 ]
  [ "$(scale_of 50)" -eq 50 ]
  for v in '' 1 7 50; do
    run --separate-stderr scale_warn "$v"
    [ -z "$stderr" ]
  done
}

# slow_ps: a ps that lists group 4242 for its first 40 calls (about 0.8 s of 20 ms polls), then not.
slow_ps() {
  cat > "$STUBS/ps" <<'EOF'
#!/bin/sh
n=$(cat "$STUB_DIR/ps.count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STUB_DIR/ps.count"
[ "$n" -gt 40 ] || echo "4242 4242"
EOF
  chmod +x "$STUBS/ps"
}

@test "time scale: under a slow ps, group_empty fails at scale 1 and passes at scale 10" {
  slow_ps
  PATH="$STUBS:$PATH"
  TS=1
  run group_empty 4242
  [ "$status" -eq 1 ]
  [ "$(cat "$STUB_DIR/ps.count")" -eq 15 ]
  rm -f "$STUB_DIR/ps.count"
  TS=10
  run group_empty 4242
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ps.count")" -eq 41 ]
}
