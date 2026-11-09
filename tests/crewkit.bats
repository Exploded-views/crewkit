#!/usr/bin/env bats
# crewkit's dispatcher (bin/crewkit) and shared library (libexec/ck/common.sh). The verbs
# themselves have their own suites. A tree of symlinks (tests/crewkit-helpers.bash) stands in
# for a checkout, and a test that needs verb scripts writes stubs into its own libexec.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

setup() { ck_setup; }

# ---- dispatcher --------------------------------------------------------------------------------

@test "--version prints the VERSION file" {
  run ck --version
  [ "$status" -eq 0 ]
  [ "$output" = "crewkit $(cat "$TREE/libexec/VERSION")" ]
  [ "$output" = "crewkit 0.1.0" ]
}

@test "no verb or an unknown verb is usage (64), on stderr" {
  run ck
  [ "$status" -eq 64 ]
  run ck frobnicate
  [ "$status" -eq 64 ]
  run --separate-stderr ck frobnicate
  [ -z "$output" ]
  [[ $stderr == *usage* ]]
}

@test "a verb with a slash, dots, capitals or an option is usage, never a path" {
  local bad
  for bad in ../../tmp/x /bin/ls 'init/../x' .. Init in_it 'a b' -x -- 'init;ls' '' ; do
    run ck "$bad"
    [ "$status" -eq 64 ] || { echo "verb '$bad' gave $status"; return 1; }
  done
  run ck node ../report
  [ "$status" -eq 64 ]
  run ck node report/..
  [ "$status" -eq 64 ]
  run ck registry move/../../x
  [ "$status" -eq 64 ]
}

@test "traversal in a verb word reaches no file, even where the path would exist" {
  ck_own_libexec
  mkdir -p "$TREE/libexec/crewkit-x" "$TREE/libexec/crewkit-node-report"
  printf '#!/bin/sh\necho PWNED\n' > "$TREE/out"
  chmod +x "$TREE/out"
  run ck 'x/../../out'
  [ "$status" -eq 64 ]
  none -q PWNED <<<"$output"
  run ck node 'report/../../out'
  [ "$status" -eq 64 ]
  none -q PWNED <<<"$output"
}

@test "node-report is not a one-word verb; a group word alone, or an unknown sub, is usage" {
  ck_own_libexec
  printf '#!/bin/sh\necho ran\n' > "$TREE/libexec/crewkit-node-report"
  chmod +x "$TREE/libexec/crewkit-node-report"
  run ck node-report
  [ "$status" -eq 64 ]
  none -q ran <<<"$output"
  run ck node
  [ "$status" -eq 64 ]
  run ck registry
  [ "$status" -eq 64 ]
  run ck node nothing
  [ "$status" -eq 64 ]
  run ck node report
  [ "$output" = ran ]
}

@test "registry move and node report reach their scripts" {
  ck_own_libexec
  local v
  for v in init join status open ask doctor registry-move node-report node-join node-drill node-authorize node-take-registry; do
    printf '#!/bin/sh\necho "%s $*"\n' "$v" > "$TREE/libexec/crewkit-$v"
    chmod +x "$TREE/libexec/crewkit-$v"
  done
  run ck registry move --yes x
  [ "$status" -eq 0 ]
  [ "$output" = "registry-move --yes x" ]
  run ck node report
  [ "$output" = "node-report " ]
  run ck node take-registry a b
  [ "$output" = "node-take-registry a b" ]
  run ck status -v
  [ "$output" = "status -v" ]
}

@test "a verb whose script is missing from the tree is usage (64), saying so" {
  ck_own_libexec
  run --separate-stderr ck doctor
  [ "$status" -eq 64 ]
  [[ $stderr == *"unknown verb"*crewkit-doctor* ]]
}

@test "a verb's exit status is the script's" {
  ck_own_libexec
  printf '#!/bin/sh\nexit 42\n' > "$TREE/libexec/crewkit-node-drill"
  chmod +x "$TREE/libexec/crewkit-node-drill"
  run ck node drill
  [ "$status" -eq 42 ]
}

@test "CK_ROOT is the tree as reached, also through a link to the command" {
  ck_own_libexec
  printf '#!/bin/sh\necho "$CK_ROOT"\n' > "$TREE/libexec/crewkit-status"
  chmod +x "$TREE/libexec/crewkit-status"
  run ck status
  [ "$output" = "$TREE" ]
  ln -s "$TREE/bin/crewkit" "$BATS_TEST_TMPDIR/bin/crewkit"
  run crewkit status
  [ "$output" = "$TREE" ]
}

@test "verbs run from HOME: a project's settings file never applies" {
  ck_own_libexec
  cat > "$TREE/libexec/crewkit-node-report" <<'EOS'
#!/usr/bin/env bash
. "$CK_ROOT/lib/settings.sh"
pwd
crew_setting state_dir unset
EOS
  chmod +x "$TREE/libexec/crewkit-node-report"
  mkdir -p "$BATS_TEST_TMPDIR/p/.claude"
  printf -- '---\nstate_dir: /nope\n---\n' > "$BATS_TEST_TMPDIR/p/.claude/crewkit.md"
  cd "$BATS_TEST_TMPDIR/p"
  run ck node report
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME" ] || { echo "got: $output"; return 1; }
  [ "${lines[1]}" = unset ]
  none -q /nope <<<"$output"
}

@test "bash below 4.4 exits 78 naming bash 4.4 before anything else runs" {
  ck_own_libexec
  printf '#!/bin/sh\necho ran\n' > "$TREE/libexec/crewkit-status"
  chmod +x "$TREE/libexec/crewkit-status"
  local v
  for v in 3.2 4.3 4.0; do
    CK_BASH_VERSION=$v run --separate-stderr ck --version
    [ "$status" -eq 78 ] || { echo "$v gave $status"; return 1; }
    [[ $stderr == *"bash 4.4"* ]]
    [[ $stderr == *"brew install bash"* ]]
    [ -z "$output" ]
    CK_BASH_VERSION=$v run ck status
    [ "$status" -eq 78 ]
  done
  CK_BASH_VERSION=4.4 run ck --version
  [ "$status" -eq 0 ]
  CK_BASH_VERSION=5.2 run ck --version
  [ "$status" -eq 0 ]
  # It can only make the check stricter: anything but MAJOR.MINOR, or a version at least as new
  # as the running bash, is ignored.
  for v in junk 4 4. .4 3.2.57 99.0 "3.2; true" ''; do
    CK_BASH_VERSION=$v run ck --version
    [ "$status" -eq 0 ] || { echo "'$v' gave $status"; return 1; }
  done
}

@test "CK_BASH_VERSION can't loosen the check under the real bash 3.2" {
  [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ] || skip "/bin/bash is not 3.2 here"
  CK_BASH_VERSION=5.0 run /bin/bash "$TREE/bin/crewkit" --version
  [ "$status" -eq 78 ]
  CK_BASH_VERSION=5.0 run /bin/bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; echo defined' _ "$TREE"
  [ "$status" -eq 78 ]
  none -q defined <<<"$output"
}

@test "CK_YES from the environment never turns a dry run into a real one" {
  CK_YES=1 run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; ck_run touch x' _ "$TREE"
  [ "$status" -eq 0 ]
  [ ! -e x ]
  ck_own_libexec
  printf '#!/usr/bin/env bash\necho "CK_YES=${CK_YES-unset}"\n' > "$TREE/libexec/crewkit-status"
  chmod +x "$TREE/libexec/crewkit-status"
  CK_YES=1 run ck status
  [ "$output" = "CK_YES=unset" ]
}

@test "a verb runs under the bash that passed the check, not whichever bash is first on PATH" {
  ck_own_libexec
  printf '#!/usr/bin/env bash\necho "$BASH_VERSION"\n' > "$TREE/libexec/crewkit-status"
  chmod +x "$TREE/libexec/crewkit-status"
  mkdir "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/bin/sh\necho FAKE\n' > "$BATS_TEST_TMPDIR/fakebin/bash"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/bash"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run "$BASH" "$TREE/bin/crewkit" status
  [ "$output" = "$BASH_VERSION" ]
}

@test "an empty or relative HOME is usage (64); nothing runs" {
  ck_own_libexec
  printf '#!/bin/sh\necho ran\n' > "$TREE/libexec/crewkit-status"
  chmod +x "$TREE/libexec/crewkit-status"
  HOME= run ck status
  [ "$status" -eq 64 ]
  HOME=rel run ck status
  [ "$status" -eq 64 ]
  none -q ran <<<"$output"
}

@test "ck_age refuses anything but an integer and never evaluates it (64)" {
  ck_lib
  local bad
  for bad in 'a[$(touch pwned)]' 1e3 '' ' 5' 1.5 --5 x; do
    run ck_age "$bad"
    [ "$status" -eq 64 ] || { echo "'$bad' gave $status"; return 1; }
  done
  [ ! -e pwned ]
  [ "$(ck_age 08)" = 8s ]
}

@test "ck_state_dir leaves an existing directory's mode alone, and expands only ~ and ~/" {
  ck_lib
  mkdir -m 755 "$BATS_TEST_TMPDIR/pub"
  user_setting "state_dir: $BATS_TEST_TMPDIR/pub"
  ck_state_dir >/dev/null
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/pub" 2>/dev/null || stat -f %Lp "$BATS_TEST_TMPDIR/pub")" = 755 ]
  user_setting "state_dir: ~"
  [ "$(ck_state_dir)" = "$HOME" ]
  user_setting "state_dir: ~bob/x"
  run ck_state_dir
  [ "$status" -eq 78 ]
  [ ! -e "$HOME"bob ]
}

@test "ck_new_id gives up (1) instead of looping when random bytes can't be read" {
  ck_lib
  mkdir "$BATS_TEST_TMPDIR/nohead"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/nohead/head"
  chmod +x "$BATS_TEST_TMPDIR/nohead/head"
  PATH="$BATS_TEST_TMPDIR/nohead:$PATH" run timeout 20 bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; ck_new_id n' _ "$TREE"
  [ "$status" -eq 1 ]
}



@test "the real stock bash 3.2, when there is one, exits 78 with the message" {
  [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ] || skip "/bin/bash is not 3.2 here"
  run --separate-stderr /bin/bash "$TREE/bin/crewkit" --version
  [ "$status" -eq 78 ]
  [[ $stderr == *"bash 4.4"* ]]
}

# ---- common.sh ---------------------------------------------------------------------------------

@test "ck_bash_ok 3 2 exits 78 naming bash 4.4; 4 4 and 5 0 pass" {
  ck_lib
  run ck_bash_ok 3 2
  [ "$status" -eq 78 ]
  [[ $output == *"bash 4.4"* ]]
  run ck_bash_ok 4 3
  [ "$status" -eq 78 ]
  run ck_bash_ok 4 4
  [ "$status" -eq 0 ]
  run ck_bash_ok 5 0
  [ "$status" -eq 0 ]
  run ck_bash_ok 4 10
  [ "$status" -eq 0 ]
}

@test "ck_die prints crewkit: MSG on stderr and exits with CODE" {
  ck_lib
  run --separate-stderr ck_die 65 "bad value x"
  [ "$status" -eq 65 ]
  [ -z "$output" ]
  [ "$stderr" = "crewkit: bad value x" ]
}

@test "ck_age: -5 -> 0s, 0 -> 0s, 59 -> 59s, 60 -> 1m, 3599 -> 59m, 3600 -> 1h, 7200 -> 2h, 172799 -> 47h, 172800 -> 2d" {
  ck_lib
  local pair
  for pair in -5:0s 0:0s 59:59s 60:1m 3599:59m 3600:1h 7200:2h 172799:47h 172800:2d 864000:10d; do
    [ "$(ck_age "${pair%%:*}")" = "${pair#*:}" ] || { echo "ck_age ${pair%%:*} gave $(ck_age "${pair%%:*}")"; return 1; }
  done
}

@test "ck_now is CK_NOW when set, else the clock; ck_iso formats epoch seconds in UTC" {
  ck_lib
  [ "$(ck_now)" = 1793000000 ]
  unset CK_NOW
  [ "$(ck_now)" -gt 1790000000 ]
  [ "$(ck_iso 0)" = 1970-01-01T00:00:00Z ]
  [ "$(ck_iso 1793000000)" = 2026-10-26T07:33:20Z ]
  run ck_iso notanumber
  [ "$status" -ne 0 ]
}

@test "ck_new_id n is n- plus 10 base32 characters, and two differ" {
  ck_lib
  local a b
  a=$(ck_new_id n)
  b=$(ck_new_id n)
  [[ $a =~ ^n-[a-z2-7]{10}$ ]]
  [[ $b =~ ^n-[a-z2-7]{10}$ ]]
  [ "$a" != "$b" ]
  [[ $(ck_new_id reg) =~ ^reg-[a-z2-7]{10}$ ]]
}

@test "ck_sq quotes for a POSIX shell, quotes and spaces and newlines included" {
  ck_lib
  [ "$(ck_sq "a b")" = "'a b'" ]
  [ "$(ck_sq "it's")" = "'it'\\''s'" ]
  [ "$(ck_sq '')" = "''" ]
  local evil
  evil=$'x; touch pwned\n$(touch pwned) `touch pwned`'
  [ "$(sh -c "printf %s $(ck_sq "$evil")")" = "$evil" ]
  [ ! -e pwned ]
}

@test "ck_run prints and does nothing without --yes" {
  ck_lib
  CK_YES=0
  run ck_run touch x
  [ "$status" -eq 0 ]
  [ ! -e x ]
  [[ $output == "  touch x" ]]
  unset CK_YES
  run ck_run touch x
  [ ! -e x ]
  CK_YES=true run ck_run touch x
  [ ! -e x ]
  CK_YES=11 run ck_run touch x
  [ ! -e x ]
}

@test "ck_run with CK_YES=1 prints the command and runs it, passing its status on" {
  ck_lib
  CK_YES=1
  run ck_run touch "a file"
  [ "$status" -eq 0 ]
  [ -e "a file" ]
  [[ $output == "  touch a file" ]]
  run ck_run false
  [ "$status" -eq 1 ]
}

@test "ck_state_dir expands ~, creates the directory with mode 700 and prints it" {
  ck_lib
  user_setting "state_dir: ~/st/deep"
  run ck_state_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/st/deep" ]
  [ -d "$HOME/st/deep" ]
  [ "$(stat -c %a "$HOME/st/deep" 2>/dev/null || stat -f %Lp "$HOME/st/deep")" = 700 ]
}

@test "ck_state_dir defaults to ~/.local/state/crewkit, and refuses a relative path (78)" {
  ck_lib
  [ "$(ck_state_dir)" = "$HOME/.local/state/crewkit" ]
  user_setting "state_dir: rel/dir"
  run ck_state_dir
  [ "$status" -eq 78 ]
}

@test "ck_lock takes a free lock as a link to our pid, ck_unlock releases only our own" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state"
  user_setting "state_dir: $s"
  ck_lock reg
  [ "$(readlink "$s/locks/reg.lock")" = "$$" ]
  ck_unlock reg
  [ ! -e "$s/locks/reg.lock" ] && [ ! -L "$s/locks/reg.lock" ]
  ln -s 1 "$s/locks/reg.lock"
  ck_unlock reg
  [ "$(readlink "$s/locks/reg.lock")" = 1 ]
}

@test "ck_lock waits then exits 75; a dead holder's lock is taken over" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state" holder dead
  user_setting "state_dir: $s" "lock_wait_seconds: 1"
  mkdir -p "$s/locks"
  sleep 60 &
  holder=$!
  ln -s "$holder" "$s/locks/x.lock"
  run ck_lock x
  kill "$holder"
  [ "$status" -eq 75 ]
  [[ $output == *"x"* ]]
  [ "$(readlink "$s/locks/x.lock")" = "$holder" ]
  rm "$s/locks/x.lock"
  sleep 0 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$s/locks/x.lock"
  run ck_lock x
  [ "$status" -eq 0 ]
  [ "$(readlink "$s/locks/x.lock")" = "$$" ]
}

@test "ck_lock: a junk link target counts as dead; a stale reap mutex is cleared; a fresh one waits" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state" dead
  user_setting "state_dir: $s" "lock_wait_seconds: 1"
  mkdir -p "$s/locks"
  ln -s "not a pid" "$s/locks/z.lock"
  run ck_lock z
  [ "$status" -eq 0 ]
  sleep 0 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$s/locks/y.lock"
  mkdir "$s/locks/y.reap"
  touch -t 202001010000 "$s/locks/y.reap"
  run ck_lock y
  [ "$status" -eq 0 ]
  ln -s "$dead" "$s/locks/w.lock"
  mkdir "$s/locks/w.reap"
  run ck_lock w
  [ "$status" -eq 75 ]
}

# race_rounds N ROUNDS: N background workers take the lock x per round, log "in"/"out" around a
# critical section, and either unlock or crash holding it (so the next round starts on a dead
# holder's lock). Fails if a round shows two holders at once, or a worker never got the lock.
race_rounds() {
  local log="$BATS_TEST_TMPDIR/race.log" round n=$1 i mode
  cat > "$BATS_TEST_TMPDIR/worker.sh" <<'EOS'
source "$1/lib/settings.sh"
source "$1/libexec/ck/common.sh"
ck_lock x || exit 1
echo "in $$" >> "$2"
sleep 0.05
echo "out $$" >> "$2"
# "crash" leaves the lock behind for the next one to take over
[[ $3 == crash ]] || ck_unlock x
EOS
  for ((round = 1; round <= $2; round++)); do
    : > "$log"
    # Rounds 1, 2, 4 and 5: every holder crashes; rounds 3 and 6 unlock. So rounds 2, 3, 5 and 6
    # start on a dead holder's lock, left by the round before; rounds 1 and 4 start clean.
    mode=clean
    ((round % 3 == 0)) || mode=crash
    pids=()
    for ((i = 0; i < n; i++)); do
      bash "$BATS_TEST_TMPDIR/worker.sh" "$TREE" "$log" "$mode" &
      pids+=($!)
    done
    wait "${pids[@]}"
    [ "$(grep -c '^in ' "$log")" -eq "$n" ] || { echo "round $round ($mode): not every worker got the lock"; cat "$log"; return 1; }
    awk '/^in /{ if (held) bad = 1; held = 1 } /^out /{ held = 0 } END { exit bad }' "$log" \
      || { echo "round $round ($mode): two holders at once"; cat "$log"; return 1; }
  done
}

@test "ck_lock under a race: never two holders at once, with dead holders to take over" {
  user_setting "state_dir: $BATS_TEST_TMPDIR/state" "lock_wait_seconds: 60"
  race_rounds 8 6
}

@test "ck_lock under a race with a slow rm (the window the reap mutex closes)" {
  user_setting "state_dir: $BATS_TEST_TMPDIR/state" "lock_wait_seconds: 60"
  mkdir "$BATS_TEST_TMPDIR/slowrm"
  printf '#!/bin/sh\nsleep 0.15\nexec /bin/rm "$@"\n' > "$BATS_TEST_TMPDIR/slowrm/rm"
  chmod +x "$BATS_TEST_TMPDIR/slowrm/rm"
  # Four rounds: the mutex mutant fails in round 1 or 2 (task 3's second re-review), in half the time.
  PATH="$BATS_TEST_TMPDIR/slowrm:$PATH" race_rounds 12 4
}

@test "ck_lock refuses a directory at the lock path and creates nothing inside it" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state"
  user_setting "state_dir: $s"
  mkdir -p "$s/locks/x.lock"
  run ck_lock x
  [ "$status" -ne 0 ]
  [[ $output == *"$s/locks/x.lock"* ]]
  [ -z "$(ls -A "$s/locks/x.lock")" ]
}

@test "ck_lock never follows a symlink to a directory at the lock path" {
  # ln -s would create the link inside the directory and report success to every caller.
  ck_lib
  local s="$BATS_TEST_TMPDIR/state"
  user_setting "state_dir: $s" "lock_wait_seconds: 2"
  mkdir -p "$s/locks/target"
  ln -s target "$s/locks/x.lock"
  run ck_lock x
  [ -z "$(ls -A "$s/locks/target")" ]
  [ "$(readlink "$s/locks/x.lock")" != target ]
}

@test "ck_lock: a link to pid 0, to 007 or to a negative number counts as dead" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state" t
  user_setting "state_dir: $s" "lock_wait_seconds: 2"
  mkdir -p "$s/locks"
  for t in 0 007 -1; do
    ln -s -- "$t" "$s/locks/p.lock"
    run ck_lock p
    [ "$status" -eq 0 ] || { echo "target $t gave $status"; return 1; }
    ck_unlock p
  done
}

@test "ck_unlock checks its name like ck_lock (64), and a stale reap clears quietly" {
  ck_lib
  local s="$BATS_TEST_TMPDIR/state" dead
  user_setting "state_dir: $s" "lock_wait_seconds: 2"
  run ck_unlock ../../foo
  [ "$status" -eq 64 ]
  mkdir -p "$s/locks"
  sleep 0 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$s/locks/q.lock"
  mkdir "$s/locks/q.reap"
  touch -t 202001010000 "$s/locks/q.reap"
  run --separate-stderr ck_lock q
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "ck_lock with an unusable state_dir stops, and creates nothing at /locks or in the cwd" {
  ck_lib
  cd "$BATS_TEST_TMPDIR"
  user_setting "state_dir: rel/dir"
  run ck_lock x
  [ "$status" -eq 78 ]
  run ck_unlock x
  [ "$status" -eq 78 ]
  [ ! -e locks ] && [ ! -e rel ] && [ ! -e /locks ]
  : > "$BATS_TEST_TMPDIR/afile"
  user_setting "state_dir: $BATS_TEST_TMPDIR/afile"
  run ck_lock x
  [ "$status" -ne 0 ]
  [ ! -e locks ] && [ ! -e /locks ] && [ -f "$BATS_TEST_TMPDIR/afile" ]
}

@test "ck_lock refuses a name that is not a plain word (64)" {
  ck_lib
  user_setting "state_dir: $BATS_TEST_TMPDIR/state"
  local n
  for n in ../x a/b '' .hidden 'a b'; do
    run ck_lock "$n"
    [ "$status" -eq 64 ] || { echo "lock '$n' gave $status"; return 1; }
  done
  [ ! -e "$BATS_TEST_TMPDIR/x.lock" ]
}

@test "ck_name_ok takes codenames only" {
  ck_lib
  local n
  for n in a laptop homebox clientspoke a1 a-b x0123456789012345678901234567890; do
    ck_name_ok "$n" || { echo "refused $n"; return 1; }
  done
  for n in '' 1a -a A a_b 'a b' a.b a/b x01234567890123456789012345678901 'a
b'; do
    ! ck_name_ok "$n" || { echo "accepted '$n'"; return 1; }
  done
}

@test "ck_label_ok takes KEY=VALUE with a dot-free key (herdr rejects dotted keys)" {
  ck_lib
  local n
  for n in role=lead project=crewkit a_b=x.y:z-1 k=A; do
    ck_label_ok "$n" || { echo "refused $n"; return 1; }
  done
  for n in a.b=x role= =x role 'role=a b' 'role=a/b' Role=x 1a=x 'role=x;y' "role=$(printf 'x%.0s' {1..65})" 'ro
le=x'; do
    ! ck_label_ok "$n" || { echo "accepted '$n'"; return 1; }
  done
}

@test "ck_owner_steps_done returns 3 with steps, 0 without" {
  ck_lib
  run ck_owner_steps_done
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ck_owner_step "run: tailscale up"
  ck_owner_step "trust the folder: claude"
  local rc=0 out
  out=$(ck_owner_steps_done) || rc=$?
  [ "$rc" -eq 3 ]
  [ "${out%%$'\n'*}" = "Owner-only steps (crewkit never runs these):" ]
  [[ $out == *$'\n'"  1. run: tailscale up"* ]]
  [[ $out == *$'\n'"  2. trust the folder: claude" ]]
}

@test "sourcing common.sh under an old bash exits 78 before it defines anything" {
  CK_BASH_VERSION=3.2 run bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; echo defined' _ "$TREE"
  [ "$status" -eq 78 ]
  none -q defined <<<"$output"
}
