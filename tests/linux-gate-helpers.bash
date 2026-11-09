# Shared by tests/linux-gate.bats and tests/linux-gate-holds.bats: the scratch "source" checkout, the
# stubs for docker, shellcheck and gitleaks, the gate's trusted tools, and the helpers that run the gate.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016,SC2034  # bats' $status, $output and $lines; stub scripts are quoted text

lg_setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  LG="$REPO/tools/linux-gate.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  SRC="$BATS_TEST_TMPDIR/src"
  git init -q -b main "$SRC"
  mkdir -p "$SRC/tools"
  # The clone's own scrub.sh is branch code the gate must never run: it records itself and says clean.
  printf '#!/bin/sh\necho clone-scrub >> "$CALLS"\necho "scrub: clean (the clone says so)"\n' > "$SRC/tools/scrub.sh"
  chmod +x "$SRC/tools/scrub.sh"
  echo ".cache/" > "$SRC/.gitignore"   # as in the real repository
  git -C "$SRC" add -A && git -C "$SRC" commit -qm one && git -C "$SRC" branch topic
  mkdir -p "$SRC/.cache/bats-v1.14.0/bin" && printf '#!/bin/sh\n' > "$SRC/.cache/bats-v1.14.0/bin/bats"
  chmod +x "$SRC/.cache/bats-v1.14.0/bin/bats"
  export LINUX_GATE_SRC="$SRC" LINUX_GATE_WORK="$BATS_TEST_TMPDIR/work" LINUX_GATE_WHEELS="$BATS_TEST_TMPDIR/wheels"
  OUT="$BATS_TEST_TMPDIR/out" CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$LINUX_GATE_WORK"
  # docker: records each call; for a run, writes into /out/steps.txt the lines DOCKER_SUMMARY
  # holds, or by default a passing line for every step run.sh runs (one per spec after /run.sh,
  # and install-mutants with FULL=1; only the specs' with MUTANTS_ONLY=1), and a log per step; DROP_STEPS leaves those out; exits
  # DOCKER_RC (default 0).
  # The coverage.py run (crewkit-ubuntu-amd64) prints a line and exits COVPY_RC. DOCKER_SLEEP
  # and COVPY_SLEEP make a run hang (an exec'd sleep, so a signal ends it); `docker kill` is
  # only recorded.
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker' >> "$CALLS"; printf ' %q' "$@" >> "$CALLS"; echo >> "$CALLS"
[[ $1 == image ]] && exit "${IMAGE_INSPECT_RC:-0}"   # docker image inspect: IMAGE_INSPECT_RC=1, no such image
out='' clone='' specs=() after=0 full=0 mo=0
for a; do
  # The passwd file the run mounts, copied now (the work dir is gone after the run): .passwd.ubuntu or .passwd.amd64.
  [[ $a == *:/etc/passwd:ro ]] && cp "${a%:/etc/passwd:ro}" "$CALLS.passwd.$([[ " $* " == *" crewkit-ubuntu-amd64 "* ]] && echo amd64 || echo ubuntu)"
  case $a in *:/out) out=${a%:/out} ;; *:/src) clone=${a%:/src} ;; FULL=1) full=1 ;; MUTANTS_ONLY=1) mo=1 ;; crewkit-ubuntu-amd64) [[ -n ${COVPY_SLEEP:-} ]] && exec sleep "$COVPY_SLEEP" >/dev/null 2>&1
                        echo "coverage-py: done"; exit "${COVPY_RC:-0}" ;; esac
  ((after)) && specs+=("$a")
  [[ $a == /run.sh ]] && after=1
done
if [[ -n $out ]]; then
  if [[ -n ${DOCKER_SUMMARY+x} ]]; then printf "%b" "$DOCKER_SUMMARY" >> "$out/steps.txt"
  else
    steps=(image-locale python lint-skills check-workflows bats perf-strict perf-ci-headroom)
    ((mo)) && steps=()
    for s in ${specs[@]+"${specs[@]}"}; do n=${s/.json@/@}; steps+=("mutants-${n%.json}"); done
    ((full)) && steps+=(install-mutants)
    for s in "${steps[@]}"; do
      [[ " ${DROP_STEPS:-} " == *" $s "* ]] || { printf '%-28s rc=0    1s  OK\n' "$s" >> "$out/steps.txt"; echo "$s log" > "$out/$s.log"; }
    done
  fi
fi
# ON_RUN: a command to run during the container step (a branch moving mid-gate, branch code
# rewriting the clone, mounted at /src: CLONE).
[[ -n $out && -n ${ON_RUN:-} ]] && CLONE=$clone bash -c "$ON_RUN"
[[ -n $out && -n ${DOCKER_SLEEP:-} ]] && exec sleep "$DOCKER_SLEEP" >/dev/null 2>&1
exit "${DOCKER_RC:-0}"
STUB
  # The shellcheck stub: SC_DELAY seconds of work first, per call (a loaded machine's slow native check)
  # The shellcheck stub (deterministic, no real shellcheck needed): records its full argv, SC_DELAY seconds of
  # work first per call, and for each file argument containing the line `# shellcheck-stub: fail` prints a
  # finding and exits 1. Exits SHELLCHECK_RC otherwise. SC_REAL=/path/to/shellcheck also lints each file
  # argument with the real one (the extra test that may skip when none is installed).
  cat > "$BATS_TEST_TMPDIR/bin/shellcheck" <<'STUB'
#!/bin/sh
echo "shellcheck $*" >> "$CALLS"
[ -n "$SC_DELAY" ] && sleep "$SC_DELAY"
rc=${SHELLCHECK_RC:-0}
for a in "$@"; do
  [ -f "$a" ] || continue
  if grep -qx '# shellcheck-stub: fail' "$a"; then echo "$a: shellcheck-stub: finding"; rc=1; fi
  if [ -n "$SC_REAL" ]; then "$SC_REAL" --norc -x "$a" >/dev/null 2>&1 || rc=1; fi
done
exit $rc
STUB
  # A gitleaks on PATH is not the pinned one: the gate must never call it.
  printf '#!/bin/sh\necho "UNPINNED gitleaks $*" >> "$CALLS"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/gitleaks"
  # The gate's trusted tools (LINUX_GATE_TOOLS): stubs for the scrub and kcov/floors, the real secrets-scan.sh.
  TT="$BATS_TEST_TMPDIR/trusted"
  mkdir -p "$TT"
  printf '#!/bin/sh\necho scrub >> "$CALLS"\necho "${SCRUB_OUT:-scrub: clean (1 files, 2 denylist patterns)}"\nexit ${SCRUB_RC:-0}\n' > "$TT/scrub.sh"
  cp "$REPO/tools/secrets-scan.sh" "$TT/secrets-scan.sh"
  chmod +x "$TT"/*.sh
  export LINUX_GATE_TOOLS="$TT"
  # The pinned gitleaks (what secrets-scan.sh runs): records its call and the GITLEAKS_* it sees,
  # hangs for GL_SLEEP, exits GL_RC, and flags a GitHub token shape in
  # `git log -p <its --log-opts>` (the clone is the current directory).
  export HOME="$BATS_TEST_TMPDIR/home"
  G="$HOME/.local/share/crewkit/gitleaks/gitleaks"
  mkdir -p "${G%/*}"
  cat > "$G" <<'GL'
#!/usr/bin/env bash
echo "gitleaks $*" >> "$CALLS"
env | grep '^GITLEAKS_' | sed 's/^/gitleaks-env /' >> "$CALLS"
opts=--all
while (($#)); do
  case $1 in
    --log-opts=*) opts=${1#--log-opts=} ;;
    --config) echo "gitleaks-config $2" >> "$CALLS"; shift ;;
  esac
  shift
done
[ -n "${GL_SLEEP:-}" ] && exec sleep "$GL_SLEEP" >/dev/null 2>&1
[ -n "${GL_RC:-}" ] && exit "$GL_RC"
# shellcheck disable=SC2086
git log -p $opts | grep -Eq 'ghp_[A-Za-z0-9]{36}' && { echo "Finding: REDACTED"; exit 1; }
exit 0
GL
  chmod +x "$G"
  if command -v sha256sum >/dev/null; then sha256sum "$G" | cut -d' ' -f1 > "$G.sha256"; else shasum -a 256 "$G" | cut -d' ' -f1 > "$G.sha256"; fi
  chmod +x "$BATS_TEST_TMPDIR/bin"/*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Every test here runs under the test override; the default-dir and setting logic is in
  # tests/test_heavy_lock.py, and one test below runs without the override.
  export CREWKIT_HEAVY_LOCK="$BATS_TEST_TMPDIR/heavy.lock" CREWKIT_HEAVY_LOCK_TEST=1
  : > "$CREWKIT_HEAVY_LOCK"
  unset CI GITHUB_ACTIONS FULL
}

lg_teardown() {
  local p
  for p in ${SIB:-}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  return 0
}

gate() { run flock "$CREWKIT_HEAVY_LOCK" "$LG" "$@"; }
# FULL=1's host tools, the gate's trusted copies (LINUX_GATE_TOOLS), with origin/main at main: coverage.sh
# (records BATS_TEST_TIMEOUT and KCOV_NAME, hangs for KCOV_SLEEP, prints a kcov tally, exits
# KCOV_RC) and coverage-floors.py (records its --base-floors file, hangs for FLOORS_SLEEP,
# exits FLOORS_RC).
full_src() {
  printf '#!/bin/sh\necho "coverage.sh BATS_TEST_TIMEOUT=$BATS_TEST_TIMEOUT" >> "$CALLS"\necho "coverage.sh KCOV_NAME=$KCOV_NAME" >> "$CALLS"\n[ -n "$KCOV_SLEEP" ] && exec sleep "$KCOV_SLEEP" >/dev/null 2>&1\necho "3 tests passed under kcov"\nexit ${KCOV_RC:-0}\n' > "$TT/coverage.sh"
  cat > "$TT/coverage-floors.py" <<'PY'
import os, sys
base = sys.argv[sys.argv.index("--base-floors") + 1]
with open(os.environ["CALLS"], "a") as f:
    f.write("floors base " + open(base).read().strip() + "\n")
if os.environ.get("FLOORS_SLEEP"):
    os.execvp("sleep", ["sleep", os.environ["FLOORS_SLEEP"]])
print("coverage floors: " + ("ok" if os.environ.get("FLOORS_RC", "0") == "0" else "1 below its floor"))
sys.exit(int(os.environ.get("FLOORS_RC", "0")))
PY
  echo '{"v": "base"}' > "$SRC/coverage-floors.json"
  chmod +x "$TT/coverage.sh"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm full && git -C "$SRC" branch -f topic main
  git -C "$SRC" update-ref refs/remotes/origin/main "$(git -C "$SRC" rev-parse main)"
}
first_run() { grep -m1 '^docker run' "$CALLS"; }

# base_run [ARGS...]: a plain gate run of topic into $BASE (no specs, unless given), its summary the base claim.
base_run() { BASE="$BATS_TEST_TMPDIR/base"; run flock "$CREWKIT_HEAVY_LOCK" "$LG" topic "$BASE" "$@"; [ "$status" -eq 0 ]; : > "$CALLS"; }
mo_gate() { LINUX_GATE_MUTANTS_ONLY=1 gate "$@"; }
