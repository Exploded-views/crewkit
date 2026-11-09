#!/usr/bin/env bats
# tests/stub-reaper.bash: stub daemons that outlive an aborted bats run are found by the next run
# and stopped. A stub registers itself (its pid, the pid of the bats run that owns it, its start
# time); reap_stale_stubs stops the entries whose run is dead and whose process is still the one
# that registered, and keeps the entries of runs that are alive.
#
# Every process these tests start is stopped again by teardown, whatever the test did.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  HELPER="$REPO/tests/stub-reaper.bash"
  REG="$BATS_TEST_TMPDIR/registry"
  STARTED="$BATS_TEST_TMPDIR/started"
  : > "$STARTED"
  # shellcheck source=tests/stub-reaper.bash
  source "$HELPER"
}

teardown() {
  local pid
  [[ -f $STARTED ]] || return 0
  while read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done < "$STARTED"
}

# daemon OWNER: a background process that ignores TERM, registered with the run OWNER; its pid is
# in $DPID. It holds none of the test's pipes.
daemon() {
  bash -c 'source "$1"; stub_register "$2" "$3"; trap "" TERM; exec >/dev/null 2>&1 </dev/null; while :; do sleep 1; done' _ \
    "$HELPER" "$REG" "$1" > /dev/null 2>&1 < /dev/null &
  DPID=$!
  echo "$DPID" >> "$STARTED"
  local n
  for n in $(seq 50); do
    [[ -s $REG ]] && grep -q "^$DPID " "$REG" && return 0
    /bin/sleep 0.1
  done
  return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
gone() { local n; for n in $(seq 50); do alive "$1" || return 0; /bin/sleep 0.1; done; return 1; }

# a pid that is not running: that of a short-lived process that has been waited for.
dead_pid() { /bin/sleep 0.1 & local p=$!; wait "$p"; echo "$p"; }

@test "a stub registers its pid, its run's pid and its start time" {
  daemon "$$"
  [ "$(wc -l < "$REG" | tr -d ' ')" -eq 1 ]
  read -r pid owner start < "$REG"
  [ "$pid" = "$DPID" ]
  [ "$owner" = "$$" ]
  [[ $start =~ ^[A-Za-z0-9_:]+$ ]]
}

@test "a stub of a run that is dead is stopped, and its entry goes" {
  daemon "$(dead_pid)"
  alive "$DPID"
  reap_stale_stubs "$REG"
  gone "$DPID"
  [ ! -s "$REG" ]
}

@test "a stub of a run that is still alive is left running, and its entry stays" {
  daemon "$$"
  reap_stale_stubs "$REG"
  alive "$DPID"
  grep -q "^$DPID " "$REG"
}

@test "a process that merely has the pid of an old stub is not stopped: the start time must match" {
  /bin/sleep 120 > /dev/null 2>&1 < /dev/null &
  local other=$!
  echo "$other" >> "$STARTED"
  printf '%s %s %s\n' "$other" "$(dead_pid)" "Mon_Jan_1_00:00:00_2001" > "$REG"
  reap_stale_stubs "$REG"
  alive "$other"
  [ ! -s "$REG" ]
}

@test "an entry whose process is already gone is dropped without an error" {
  printf '%s %s %s\n' "$(dead_pid)" "$(dead_pid)" "Mon_Jan_1_00:00:00_2001" > "$REG"
  run reap_stale_stubs "$REG"
  [ "$status" -eq 0 ]
  [ ! -s "$REG" ]
}

@test "live and dead entries together: only the dead run's stub is stopped" {
  daemon "$$"
  local live=$DPID
  daemon "$(dead_pid)"
  local stale=$DPID
  reap_stale_stubs "$REG"
  gone "$stale"
  alive "$live"
  [ "$(wc -l < "$REG" | tr -d ' ')" -eq 1 ]
  grep -q "^$live " "$REG"
}

@test "no registry file is fine" {
  run reap_stale_stubs "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 0 ]
  # and it makes no file, neither the registry nor a temporary one
  [ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep '^none')" ]
}

@test "a line that is not an entry is dropped and stops nothing" {
  printf 'garbage\n\n1 x\n' > "$REG"
  run reap_stale_stubs "$REG"
  [ "$status" -eq 0 ]
  [ ! -s "$REG" ]
}

@test "an entry whose owner is 0 or 1 is not a dead run: nothing is stopped, the entry goes" {
  # kill -0 1 fails for a user who is not root, so an owner of 1 would look dead; a file with such
  # a line must not be able to get a process of this user stopped.
  local o
  for o in 0 1; do
    : > "$REG"
    daemon "$o"
    reap_stale_stubs "$REG"
    alive "$DPID"
    [ ! -s "$REG" ]
  done
}

@test "an entry for pid 0 or 1 is dropped without a signal and without an error" {
  printf '%s %s %s\n' 1 "$(dead_pid)" "$(_stub_start 1)" > "$REG"
  printf '%s %s %s\n' 0 "$(dead_pid)" "Mon_Jan_1_00:00:00_2001" >> "$REG"
  run reap_stale_stubs "$REG"
  [ "$status" -eq 0 ]
  [ ! -s "$REG" ]
}

@test "a registry that is a symbolic link is ignored: its stubs are not stopped and its target is not rewritten" {
  daemon "$(dead_pid)"
  local victim=$DPID
  mv "$REG" "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$REG"
  local before
  before=$(cat "$BATS_TEST_TMPDIR/real")
  reap_stale_stubs "$REG"
  alive "$victim"
  [ "$(cat "$BATS_TEST_TMPDIR/real")" = "$before" ]
  [ -L "$REG" ]
}

@test "a stub does not register through a symbolic link" {
  : > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$REG"
  bash -c 'source "$1"; stub_register "$2" 4242' _ "$HELPER" "$REG"
  [ ! -s "$BATS_TEST_TMPDIR/target" ]
}

@test "after a bats run is killed mid-run, the next run's reaper stops the stub it left behind" {
  local bats nested
  # the bats that is running this test (tools/get-bats.sh needs a git checkout, which a copy of the tree lacks)
  bats="$BATS_LIBEXEC/bats"
  nested="$BATS_TEST_TMPDIR/nested.bats"
  cat > "$nested" <<EOF
#!/usr/bin/env bats
@test "start a stub, then be killed" {
  bash -c 'source "$HELPER"; stub_register "$REG" "\$BATS_ROOT_PID"; trap "" TERM; exec >/dev/null 2>&1 </dev/null; while :; do sleep 1; done' &
  /bin/sleep 60
}
EOF
  # the nested run in a session of its own, so that killing its root leaves the rest of it behind
  local root
  root=$(python3 -I -c '
import subprocess, sys
p = subprocess.Popen([sys.argv[1], sys.argv[2]], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(p.pid)' "$bats" "$nested")
  echo "$root" >> "$STARTED"
  local n
  for n in $(seq 100); do [[ -s $REG ]] && break; /bin/sleep 0.1; done
  [ -s "$REG" ]
  read -r dpid owner _ < "$REG"
  echo "$dpid" >> "$STARTED"
  [ "$owner" = "$root" ]
  kill -9 "$root"
  gone "$root"
  # the stub is still there: that is the leak
  alive "$dpid"
  reap_stale_stubs "$REG"
  gone "$dpid"
  [ ! -s "$REG" ]
  # the rest of the aborted run (its own session) goes with the test
  kill -9 -- "-$root" 2>/dev/null || true
}

@test "stub_exec registers the process and becomes the command, which the reaper then stops" {
  local owner
  owner=$(dead_pid)
  bash -c 'source "$1"; stub_exec "$2" "$3" /bin/sleep 120' _ "$HELPER" "$REG" "$owner" > /dev/null 2>&1 < /dev/null &
  local p=$!
  echo "$p" >> "$STARTED"
  local n
  for n in $(seq 50); do grep -q "^$p " "$REG" 2> /dev/null && break; /bin/sleep 0.1; done
  grep -q "^$p $owner " "$REG"
  # the shell has become the command: same pid, now sleep
  [[ $(ps -o comm= -p "$p") == *sleep ]]
  reap_stale_stubs "$REG"
  gone "$p"
}

@test "crewkit-holder.bats registers its stubs and the holder itself, and reaps in setup_file" {
  grep -q '^setup_file()' "$REPO/tests/crewkit-holder.bats"
  grep -q 'reap_stale_stubs' "$REPO/tests/crewkit-holder.bats"
  grep -q 'stub_register' "$REPO/tests/crewkit-holder.bats"
  # the holder is started in one place only, and that place goes through stub_exec
  local lines
  lines=$(grep -v '^[[:space:]]*#' "$REPO/tests/crewkit-holder.bats" | grep 'libexec/crewkit-holder-run')
  [ "$(wc -l <<< "$lines" | tr -d ' ')" -eq 1 ]
  [[ $lines == *stub_exec* ]]
}
