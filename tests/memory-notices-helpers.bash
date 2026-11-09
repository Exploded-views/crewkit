# Sourced by tests/memory-notices.bats and tests/push-gate.bats (load memory-notices-helpers): its time scale and its bounded
# polls. A file of its own, not inside the .bats, so tools/mutate.py can check a mutant with bash -n
# (a .bats file is not bash) and tests/mutants/memory-notices-time-scale.json can target it.
# shellcheck shell=bash

# CREWKIT_TEST_TIME_SCALE (a whole number from 1 to 50, default 1) widens the timing windows of
# these tests for the slow lanes (kcov traces bash; coverage-py runs emulated). It scales the poll
# count in alive/group_empty and the upper speed bounds, never what is asserted: every leftover
# must still be gone and every timing check still runs. Only tools/coverage*.sh set it.
# scale_of VALUE: VALUE if it is a whole number from 1 to 50, else 1.
scale_of() { if [[ $1 =~ ^[1-9][0-9]?$ ]] && [ "$1" -le 50 ]; then echo "$1"; else echo 1; fi; }
# scale_warn VALUE: one line on stderr when VALUE is set but unusable.
scale_warn() {
  if [ -n "$1" ] && [ "$(scale_of "$1")" != "$1" ]; then
    echo "${BATS_TEST_FILENAME##*/}: CREWKIT_TEST_TIME_SCALE='$1' is not a whole number from 1 to 50; using 1" >&2
  fi
}
# Once per file, not once per test.
setup_file() { scale_warn "${CREWKIT_TEST_TIME_SCALE:-}"; }
# polls: how many 20 ms polls alive/group_empty make. ms_bound MS: an upper speed bound, scaled.
polls() { echo $((15 * ${TS:-1})); }
ms_bound() { echo $(($1 * ${TS:-1})); }

# -S: no site import, so a coverage .pth startup hook cannot slow the start inside a timing window.
now_ms() { python3 -S -c 'import time; print(int(time.time() * 1000))'; }

# alive PID: true if the process still exists after a bounded poll (300 ms at scale 1) (init needs a moment to
# reap an orphan that was killed). The wrapper has already exited, so nothing is given more time.
alive() {
  local _
  for _ in $(seq 1 "$(polls)"); do
    kill -0 "$1" 2>/dev/null || return 1
    sleep 0.02
  done
  return 0
}

# gone PID: fails the test when the process is still there. (A bare `! alive` mid-test asserts
# nothing: bats ignores a negated command unless it is the test's last line.)
gone() { if alive "$1"; then return 1; fi; }

# group_empty PGID: no process is left in that process group (read from ps; nothing is signalled).
group_empty() {
  local _ n
  for _ in $(seq 1 "$(polls)"); do
    n=$(ps -A -o pid=,pgid= | awk -v g="$1" '$2 == g || $1 == g' | wc -l)
    [ "$n" -eq 0 ] && return 0
    sleep 0.02
  done
  return 1
}
