#!/usr/bin/env bats
# tools/linux-gate.sh: the CI-equivalent run of a branch in a pinned Linux container, from a
# fresh clone. docker, shellcheck and gitleaks are stubs that record their arguments; the
# "source" checkout is a scratch repository with a stub scrub and a staged bats.

load linux-gate-helpers

setup() { lg_setup; }
teardown() { lg_teardown; }

@test "without the heavy lock it refuses and runs nothing" {
  run "$LG" topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"heavy lock"* ]]
  [ ! -s "$CALLS" ]
}

@test "the container: no network, the caller's uid, the clone at /src, out at /out, the pinned image" {
  gate topic "$OUT" a.json b.json
  [ "$status" -eq 0 ]
  r=$(first_run)
  [[ $r == *" --network none "* ]]
  [[ $r == *" --user $(id -u):$(id -g) "* ]]
  [[ $r != *CREWKIT_HEAVY_LOCK_HELD* ]]   # the dead gate token is gone
  [[ $r == *":/src "* ]]
  [[ $r == *":/out "* && $r != *" -v $OUT:/out "* ]]   # its own out dir: the host writes summary.txt
  [[ $r == *"/run.sh:/run.sh:ro "* ]]
  [[ $r == *" crewkit-ubuntu bash /run.sh a.json b.json" ]]
}

@test "the images are the local builds: --pull never, no IMAGE override, kcov's image checked before coverage.sh" {
  IMAGE=elsewhere gate topic "$OUT"
  [ "$status" -eq 0 ]
  [[ $(first_run) == *" --pull never "*" crewkit-ubuntu bash /run.sh" ]]
  full_src
  : > "$CALLS"
  FULL=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
  grep '^docker run .*crewkit-ubuntu-amd64' "$CALLS" | grep -q -- ' --pull never '
  grep -qx 'docker image inspect crewkit-kcov' "$CALLS"
  : > "$CALLS"
  IMAGE_INSPECT_RC=1 FULL=1 gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: kcov" ]]
  ! grep -q '^coverage.sh' "$CALLS"
}

@test "a relative OUTDIR is taken from the caller's directory: every line lands there, and the gate passes" {
  mkdir -p "$BATS_TEST_TMPDIR/cwd" && cd "$BATS_TEST_TMPDIR/cwd"
  gate topic rel-out
  [ "$status" -eq 0 ]
  grep -q '^head ' rel-out/summary.txt
  grep -q '^gitleaks ' rel-out/summary.txt
  grep -q '^python ' rel-out/summary.txt
}

@test "it gates the named branch from a fresh clone, with origin/main from the source" {
  git -C "$SRC" update-ref refs/remotes/origin/main "$(git -C "$SRC" rev-parse main)"
  echo two > "$SRC/b.txt"; git -C "$SRC" checkout -q topic; git -C "$SRC" add b.txt; git -C "$SRC" commit -qm two
  git -C "$SRC" checkout -q main
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  grep -qx "head *topic $(git -C "$SRC" rev-parse topic)" "$OUT/summary.txt"
}

@test "head is the full SHA the gate cloned, even if the branch moves during the run" {
  before=$(git -C "$SRC" rev-parse topic)
  ON_RUN="git -C '$SRC' checkout -q topic && echo moved > '$SRC/m.txt' && git -C '$SRC' add m.txt && git -C '$SRC' commit -qm moved && git -C '$SRC' checkout -q main" \
    gate topic "$OUT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SRC" rev-parse topic)" != "$before" ]   # the branch did move
  grep -qx "head *topic $before" "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: every step passed (topic $before)" ]]
}

@test "head is the clone's, even when a tag shares the branch's name (rev-parse would take the tag)" {
  want=$(git -C "$SRC" rev-parse refs/heads/topic)
  echo t > "$SRC/t.txt" && git -C "$SRC" add t.txt && git -C "$SRC" commit -qm tagged && git -C "$SRC" tag topic
  [ "$(git -C "$SRC" rev-parse topic 2>/dev/null)" != "$want" ]   # the name alone means the tag
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  grep -qx "head *topic $want" "$OUT/summary.txt"
}

@test "FULL=1 adds kcov, coverage.py (amd64, the wheels read-only, no network) and the floors" {
  full_src
  FULL=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
  grep -q -- '--platform linux/amd64 --network none' "$CALLS"
  grep -q -- "$LINUX_GATE_WHEELS:/wheels:ro" "$CALLS"
  for s in install-mutants kcov coverage-py floors; do grep -qE "^$s +rc=0 " "$OUT/summary.txt"; done
  grep -qx 'floors base {"v": "base"}' "$CALLS"
}

@test "the container and the coverage.py run each mount a passwd entry for the caller's uid (ssh-keygen needs one)" {
  full_src
  FULL=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
  for v in ubuntu amd64; do
    grep -qx 'root:x:0:0:root:/root:/bin/sh' "$CALLS.passwd.$v"
    if (($(id -u) != 0)); then grep -qx "t:x:$(id -u):$(id -g):gate:/home/t:/bin/sh" "$CALLS.passwd.$v"; fi
  done
  grep '^docker run' "$CALLS" | grep -v crewkit-ubuntu-amd64 | grep -q -- ':/etc/passwd:ro '
  grep '^docker run .*crewkit-ubuntu-amd64' "$CALLS" | grep -q -- ':/etc/passwd:ro '
}

@test "FULL=1: a failing kcov, coverage.py or floors fails the gate, and is named" {
  full_src
  for s in KCOV_RC=1:kcov COVPY_RC=1:coverage-py FLOORS_RC=1:floors; do
    env "${s%%:*}" FULL=1 flock "$CREWKIT_HEAVY_LOCK" "$LG" topic "$OUT" > "$BATS_TEST_TMPDIR/o" 2>&1 && { echo "passed with ${s%%:*}" >&2; return 1; }
    grep -qx "linux-gate: failed: ${s#*:}" "$BATS_TEST_TMPDIR/o" || { cat "$BATS_TEST_TMPDIR/o" >&2; return 1; }
  done
}

@test "FULL=1: kcov's suites get the same time limit (BATS_TEST_TIMEOUT to tools/coverage.sh)" {
  full_src
  # An ambient BATS_TEST_TIMEOUT (mutate.py exports one) must not stand in for the gate's value.
  BATS_TEST_TIMEOUT=47 FULL=1 LINUX_GATE_TEST_TIMEOUT=45 gate topic "$OUT"
  grep -qx 'coverage.sh BATS_TEST_TIMEOUT=45' "$CALLS"
}

@test "a step that never ran fails the gate: a container that stopped early, a spec with no mutants line" {
  DROP_STEPS="bats perf-strict perf-ci-headroom mutants-a" gate topic "$OUT" a.json
  [ "$status" -eq 1 ]
  [[ $output == *"failed: "*"bats(missing)"* ]]
  [[ $output == *"mutants-a(missing)"* ]]
  FULL=1 DROP_STEPS=install-mutants gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"install-mutants(missing)"* ]]
}

@test "a container that exits non-zero fails the gate, even with every step line present" {
  DOCKER_RC=137 gate topic "$OUT" a.json
  [ "$status" -eq 1 ]
  [[ $output == *"failed: "*"container(rc=137)"* ]]
  grep -qE '^container +rc=137' "$OUT/summary.txt"
}

@test "the native checks run on the clone: shellcheck, the scrub with the denylist, gitleaks" {
  gate topic "$OUT"
  [ "$(grep -c '^shellcheck ' "$CALLS")" -eq "$(grep -c '^shellcheck --norc ' "$CALLS")" ]   # no call reads the clone's rc file
  grep -q '^shellcheck ' "$CALLS"
  grep -q '^gitleaks git ' "$CALLS"
  grep -q 'scrub: clean' "$OUT/summary.txt"
}

# The files CI's shellcheck job checks: the stub (tests/linux-gate-helpers.bash) needs no real shellcheck, so
# these run, and kill the gate's shellcheck mutants, in the gate's own container too.
sc_fixture() {   # every file the three commands are given, committed on topic; prints nothing
  local f
  git -C "$SRC" checkout -q -B topic main
  mkdir -p "$SRC"/{bin,libexec/ck,push-gate/hooks,tests/mutants,evals,lib,plugins/crew-a/bin}
  echo "# no holds" > "$SRC/tests/mutants/local-gate.txt"   # the gate reads the hold list when tests/ exists
  for f in "${SC_FILES[@]}" plugins/crew-a/bin/tool; do printf '#!/usr/bin/env bash\necho ok\n' > "$SRC/$f"; done
  git -C "$SRC" add -A && git -C "$SRC" commit -qm "shellcheck fixture"
  git -C "$SRC" branch -f scbase topic
}
SC_FILES=(install.sh bin/crewkit tests/run.sh tests/stub-gh evals/e.sh libexec/crewkit-x push-gate/push-gate.sh
          push-gate/hooks/_dispatch push-gate/shim.sh tests/t.bash lib/settings.sh libexec/ck/x.sh)

@test "the shellcheck step runs CI's three commands over CI's files, with CI's flags and --norc" {
  sc_fixture
  : > "$CALLS"
  gate topic "$OUT"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(grep -c '^shellcheck ' "$CALLS")" -eq 3 ]
  grep -Fx 'shellcheck --norc -x install.sh bin/crewkit tools/scrub.sh tests/run.sh tests/stub-gh evals/e.sh plugins/crew-a/bin/tool libexec/crewkit-x push-gate/push-gate.sh push-gate/hooks/_dispatch' "$CALLS"
  grep -Fx 'shellcheck --norc -s sh push-gate/shim.sh' "$CALLS"
  grep -Fx 'shellcheck --norc -s bash tests/t.bash lib/settings.sh libexec/ck/x.sh' "$CALLS"
}

# A marker line in any file of any command fails the step, and all three commands are still called: a gate
# that stopped at the first finding would show one command's findings per 10-minute run.
@test "a finding in a file of any of the three commands fails the step, and the later commands still run" {
  sc_fixture
  for f in "${SC_FILES[@]}" plugins/crew-a/bin/tool; do
    git -C "$SRC" checkout -q -B topic scbase
    echo '# shellcheck-stub: fail' >> "$SRC/$f"
    git -C "$SRC" commit -qam "finding in $f"
    : > "$CALLS"
    gate topic "$OUT"
    [ "$status" -eq 1 ] || { echo "$f: the gate passed a shellcheck finding" >&2; return 1; }
    [[ ${lines[-1]} == "linux-gate: failed: shellcheck" ]] || { echo "$f: ${lines[-1]}" >&2; return 1; }
    [ "$(grep -c '^shellcheck ' "$CALLS")" -eq 3 ] || { echo "$f: not all three commands ran" >&2; return 1; }
  done
}

# An extra, with the real shellcheck when the machine has one (the gate's images don't): a real finding
# in libexec/ fails the step. No mutant depends on this test alone.
@test "with the real shellcheck, a finding in libexec/ fails the gate's shellcheck step" {
  real=$(PATH=${PATH#"$BATS_TEST_TMPDIR/bin:"} command -v shellcheck) || skip "no shellcheck on this machine"
  git -C "$SRC" checkout -q -B topic main
  mkdir -p "$SRC/libexec"
  printf '#!/usr/bin/env bash\nrm -rf $1/\n' > "$SRC/libexec/crewkit-x"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm "bad libexec"
  SC_REAL=$real gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: shellcheck" ]]
}

@test "the native checks run first, on the clone as cloned: the container can't rewrite the scrub the gate runs" {
  SCRUB_OUT="scrub: 3 finding(s). Replace them" \
    ON_RUN="printf '#!/bin/sh\necho \"scrub: clean\"\n' > \"\$CLONE/tools/scrub.sh\"" gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: scrub" ]]
  first=$(grep -n '^docker run' "$CALLS" | head -1 | cut -d: -f1)
  for c in shellcheck scrub gitleaks; do
    [ "$(grep -n "^$c" "$CALLS" | head -1 | cut -d: -f1)" -lt "$first" ] || { echo "$c ran after the container" >&2; return 1; }
  done
}

@test "FULL=1: kcov runs before the container, and the floors' tool and base are the clone's as cloned, at head" {
  full_src
  echo '{"v": "topic"}' > "$SRC/coverage-floors.json"
  git -C "$SRC" checkout -q topic && git -C "$SRC" commit -qam topic-floors && git -C "$SRC" checkout -q main
  # Branch code in the container: kcov and the floors made to pass, origin/main moved to head.
  rewrite="printf '#!/bin/sh\necho 9 tests passed\n' > \"\$CLONE/tools/coverage.sh\"; printf 'print(\"ok\")\n' > \"\$CLONE/tools/coverage-floors.py\"; git -C \"\$CLONE\" update-ref refs/remotes/origin/main HEAD"
  KCOV_RC=1 FLOORS_RC=1 FULL=1 ON_RUN=$rewrite gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: kcov floors" ]]
  grep -qx 'floors base {"v": "base"}' "$CALLS"
}

@test "the container writes only its own steps' lines: the host writes summary.txt and keeps the head line" {
  DOCKER_SUMMARY='image-locale rc=0 1s OK\npython rc=0 1s OK\nlint-skills rc=0 1s OK\ncheck-workflows rc=0 1s OK\nbats rc=0 1s OK\nperf-strict rc=0 1s OK\nperf-ci-headroom rc=0 1s OK\nhead topic forged\nfloors rc=0 forged\n' \
    gate topic "$OUT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^head ' "$OUT/summary.txt")" -eq 1 ]
  ! grep -q forged "$OUT/summary.txt"
  [ ! -e "$OUT/steps.txt" ]
  gate topic "$OUT"
  grep -qx 'python log' "$OUT/python.log"   # the container's logs are copied out
  ON_RUN="tail -n +2 '$OUT/summary.txt' > '$OUT/s' && mv '$OUT/s' '$OUT/summary.txt'" gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: head" ]]
}

@test "a failing step makes the gate fail (exit 1), and the summary says which" {
  DOCKER_SUMMARY='python rc=0 1s OK\nbats rc=1 9s not ok 3\n' gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"failed: bats"* ]]
  GL_RC=1 gate topic "$OUT"
  [ "$status" -eq 1 ]
  SCRUB_OUT="scrub: 3 finding(s). Replace them" gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"failed: scrub"* ]]
}

@test "the native checks fail the gate on their own: shellcheck's rc, the scrub's rc, a scrub with no verdict" {
  SHELLCHECK_RC=1 gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: shellcheck" ]]
  SCRUB_RC=2 gate topic "$OUT"   # a clean last line, but the scrub failed
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: scrub" ]]
  SCRUB_OUT="denylist: can't read it" gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: scrub" ]]
}

@test "the in-container run checks the image's locale (en_US.UTF-8), so a locale test can't skip silently" {
  gate topic "$OUT"
  grep -q 'step image-locale' "$LINUX_GATE_WORK"/run.sh.last
}

@test "the image recipes take their base by digest (docker/bases.txt) and generate en_US.UTF-8" {
  grep -qE '^ubuntu=ubuntu@sha256:[0-9a-f]{64} ' "$REPO/docker/bases.txt"
  for f in "$REPO"/docker/crewkit-ubuntu.Dockerfile "$REPO"/docker/crewkit-ubuntu-amd64.Dockerfile; do
    grep -qE '^FROM (--platform=[^ ]+ )?\$BASE$' "$f"
  done
  grep -q 'locale-gen' "$REPO/docker/crewkit-ubuntu.Dockerfile"
}

@test "every image recipe installs openssh-client (crewkit doctor FAILs without ssh and ssh-keygen)" {
  for f in "$REPO"/docker/*.Dockerfile; do
    grep -qE 'apt-get( -o [^ ]+)* install .* openssh-client( |$)' "$f" || { echo "no openssh-client in $f"; false; }
  done
}

@test "--build-images builds the three images from the repo's recipes" {
  run flock "$CREWKIT_HEAVY_LOCK" "$LG" --build-images
  [ "$status" -eq 0 ]
  grep -q 'docker build -t crewkit-ubuntu --build-arg BASE=ubuntu@sha256:[0-9a-f]* -f .*/docker/crewkit-ubuntu.Dockerfile' "$CALLS"
  grep -q 'docker build --platform linux/amd64 -t crewkit-ubuntu-amd64 --build-arg BASE=ubuntu@sha256:[0-9a-f]* -f .*/docker/crewkit-ubuntu-amd64.Dockerfile' "$CALLS"
  grep -q 'docker build -t crewkit-kcov --build-arg BASE=kcov/kcov@sha256:.* -f .*/docker/crewkit-kcov.Dockerfile' "$CALLS"
}

@test "usage: no branch or out dir is 64" {
  run flock "$CREWKIT_HEAVY_LOCK" "$LG" topic
  [ "$status" -eq 64 ]
}

@test "every bats test in the container has a time limit (300s; LINUX_GATE_TEST_TIMEOUT), so a hang can't hold the lock" {
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  [[ $(first_run) == *" -e BATS_TEST_TIMEOUT=300 "* ]]
  LINUX_GATE_TEST_TIMEOUT=45 gate topic "$OUT"
  [[ $(grep '^docker run' "$CALLS" | tail -1) == *" -e BATS_TEST_TIMEOUT=45 "* ]]
  for bad in 0 abc ''; do
    : > "$CALLS"
    LINUX_GATE_TEST_TIMEOUT=$bad gate topic "$OUT"
    [ "$status" -eq 64 ] || { echo "accepted: '$bad'" >&2; return 1; }
    [[ $output == *"LINUX_GATE_TEST_TIMEOUT"* ]]
    [ ! -s "$CALLS" ]
  done
}

# The tests that hang one step: LIMIT, the overall time limit, has to cover every step before the hung
# one on a loaded machine (r4's covshard-4 ran out at 4 s before the coverage.py container started),
# so it is generous, and each test checks that the hung step was reached. HANG outlasts LIMIT; the
# gate's kill ends it, so a run takes about LIMIT seconds. Those tests are at the end of this file.
LIMIT=10 HANG=120
name_of() { sed -n 's/.* --name \([^ ]*\) .*/\1/p' <<<"$1"; }

# kills NAME: how many times the gate ran `docker kill NAME`. The exit trap kills all three
# container names on every run that reached docker, so one kill of a name is no proof that the
# timeout path killed it; the timeout path adds a second, before the trap's.
kills() { grep -cx "docker kill $1" "$CALLS" || true; }




@test "LINUX_GATE_TIMEOUT must be a whole number of seconds, at least 1 (64, nothing runs)" {
  for bad in 0 abc '' 1.5; do
    : > "$CALLS"
    LINUX_GATE_TIMEOUT=$bad gate topic "$OUT"
    [ "$status" -eq 64 ] || { echo "accepted: '$bad'" >&2; return 1; }
    [[ $output == *"LINUX_GATE_TIMEOUT"* ]]
    [ ! -s "$CALLS" ]
  done
}

# --- LINUX_GATE_MUTANTS_ONLY=1: the container runs only tools/mutate.py, behind a passed base run ---


@test "mutants-only: the container gets the flag and the specs, the head line is first, the native checks stay" {
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" a.json b.json
  [ "$status" -eq 0 ]
  r=$(first_run)
  [[ $r == *" -e MUTANTS_ONLY=1 "* && $r == *" crewkit-ubuntu bash /run.sh a.json b.json" ]]
  [ "$(awk '{ print $1 }' "$OUT/summary.txt" | head -4 | paste -sd' ' -)" = "head mode shellcheck scrub" ]
  # the mode line marks it as not a full run, and binds the base by its hash
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' mode "mutants-only base-sha256=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$BASE/summary.txt")")" ]
  ! grep -q '^mode ' "$BASE/summary.txt"
  grep -q '^gitleaks git ' "$CALLS"
  for s in mutants-a mutants-b; do grep -qE "^$s +rc=0 " "$OUT/summary.txt"; done
  for s in python lint-skills bats perf-strict image-locale; do ! grep -q "^$s " "$OUT/summary.txt"; done
  [[ ${lines[-1]} == "linux-gate: every step passed (topic "* ]]
}

@test "mutants-only: a relative LINUX_GATE_BASE is read as ./NAME, so a name starting with - is no option" {
  base_run
  cd "$BATS_TEST_TMPDIR"
  cp "$BASE/summary.txt" ./-b.txt
  # every use of the path is already option-safe, so the prefix shows only in the arguments: a cp that records them
  printf '#!/bin/sh\necho "cp $*" >> "$CALLS"\nexec /bin/cp "$@"\n' > "$BATS_TEST_TMPDIR/bin/cp"
  chmod +x "$BATS_TEST_TMPDIR/bin/cp"
  LINUX_GATE_BASE=-b.txt mo_gate topic "$OUT" a.json
  [ "$status" -eq 0 ]
  grep -qE '^cp -- \./-b\.txt /' "$CALLS"
  ! grep -qE '^cp -- -b\.txt ' "$CALLS"
  # an absolute path is left as it is
  : > "$CALLS"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/-b.txt mo_gate topic "$OUT" a.json
  [ "$status" -eq 0 ]
  grep -qE "^cp -- $BATS_TEST_TMPDIR/-b\\.txt /" "$CALLS"
}

@test "mutants-only: it needs a SPEC, and refuses FULL=1 (64, nothing runs)" {
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT"
  [ "$status" -eq 64 ]
  [[ $output == *"SPEC"* ]]
  full_src
  : > "$CALLS"
  FULL=1 LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" a.json
  [ "$status" -eq 64 ]
  [[ $output == *"FULL"* ]]
  [ ! -s "$CALLS" ]
}

@test "mutants-only: a spec's step that never ran still fails the gate, and a failing one is named" {
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt DROP_STEPS=mutants-b mo_gate topic "$OUT" a.json b.json
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: mutants-b(missing)" ]]
  LINUX_GATE_BASE=$BASE/summary.txt DOCKER_SUMMARY='mutants-a                    rc=1   9s  baseline failed\nmutants-b                    rc=0   9s  ok\n' mo_gate topic "$OUT" a.json b.json
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: mutants-a" ]]
}

@test "mutants-only: run.sh runs tools/mutate.py for each spec and nothing else; a failing baseline is that step's rc" {
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" a.json b.json
  [ "$status" -eq 0 ]
  # run.sh as the container gets it, with /src and /out pointed at scratch and python3 recorded.
  sb="$BATS_TEST_TMPDIR/sb"; mkdir -p "$sb/src/tools" "$sb/src/tests" "$sb/out" "$sb/bin" "$sb/home"
  sed -e "s|/src|$sb/src|g" -e "s|/out|$sb/out|g" -e "s|/home/t|$sb/home|g" "$LINUX_GATE_WORK/run.sh.last" > "$sb/run.sh"
  printf '#!/bin/sh\necho "python3 $*" >> "$CALLS"\n[ "${MUTATE_RC:-0}" = 0 ] || case "$*" in *a.json*) exit 1;; esac\n' > "$sb/bin/python3"
  chmod +x "$sb/bin/python3"
  : > "$CALLS"
  MUTANTS_ONLY=1 PATH="$sb/bin:$PATH" run bash "$sb/run.sh" a.json b.json
  [ "$(cat "$CALLS")" = "$(printf 'python3 tools/mutate.py tests/mutants/a.json\npython3 tools/mutate.py tests/mutants/b.json')" ]
  [ "$(awk '{ print $1 }' "$sb/out/steps.txt" | paste -sd' ' -)" = "mutants-a mutants-b" ]
  rm -f "$sb/out/steps.txt"; : > "$CALLS"
  MUTATE_RC=1 MUTANTS_ONLY=1 PATH="$sb/bin:$PATH" run bash "$sb/run.sh" a.json b.json
  grep -qE '^mutants-a +rc=1 ' "$sb/out/steps.txt"
  grep -qE '^mutants-b +rc=0 ' "$sb/out/steps.txt"
  # without the flag it runs everything
  rm -f "$sb/out/steps.txt"; : > "$CALLS"
  PATH="$sb/bin:$PATH" run bash "$sb/run.sh" a.json
  grep -q '^python3 tools/perf.py' "$CALLS"
  grep -qE '^bats ' "$sb/out/steps.txt"
}

@test "mutants-only: it refuses to start without a passed base run of this head (1, nothing runs, no summary)" {
  base_run
  good=$BASE/summary.txt
  refuse() { # refuse WHY-FRAGMENT: the gate was run with the current LINUX_GATE_BASE setting
    [ "$status" -eq 1 ] || { echo "status $status: $output" >&2; return 1; }
    [[ $output == *"$1"* ]] || { echo "no '$1' in: $output" >&2; return 1; }
    [ ! -s "$CALLS" ] && [ ! -e "$OUT/summary.txt" ]
  }
  mo_gate topic "$OUT" a.json;                              refuse "needs LINUX_GATE_BASE"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/none mo_gate topic "$OUT" a.json;  refuse "no such file"
  # the same branch at another SHA, another branch at this SHA
  sed "1s/ [0-9a-f]\{40\}\$/ $(printf '0%.0s' {1..40})/" "$good" > "$BATS_TEST_TMPDIR/b1"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b1 mo_gate topic "$OUT" a.json;    refuse "head line"
  git -C "$SRC" branch other topic
  sed "1s/ topic / other /" "$good" > "$BATS_TEST_TMPDIR/b2"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b2 mo_gate topic "$OUT" a.json;    refuse "head line"
  # a head line with a different spacing is not the exact line
  sed "1s/^head  */head /" "$good" > "$BATS_TEST_TMPDIR/b3"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b3 mo_gate topic "$OUT" a.json;    refuse "head line"
  sed "1s/\$/ x/" "$good" > "$BATS_TEST_TMPDIR/b3b"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b3b mo_gate topic "$OUT" a.json;   refuse "head line"
  # a failed step (rc), a step that never ran, a timeout, a verdict line
  sed 's/^\(bats  *\)rc=0/\1rc=1/' "$good" > "$BATS_TEST_TMPDIR/b4"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b4 mo_gate topic "$OUT" a.json;    refuse "bats"
  grep -v '^perf-strict ' "$good" > "$BATS_TEST_TMPDIR/b5"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b5 mo_gate topic "$OUT" a.json;    refuse "perf-strict(missing)"
  { cat "$good"; echo "linux-gate: failed: bats"; } > "$BATS_TEST_TMPDIR/b6"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b6 mo_gate topic "$OUT" a.json;    refuse "records a failed base run: verdict"
  { cat "$good"; echo "timeout                      bats (LINUX_GATE_TIMEOUT=9s)"; } > "$BATS_TEST_TMPDIR/b7"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b7 mo_gate topic "$OUT" a.json;    refuse "timeout(bats)"
  # a failed native check
  sed 's/^\(gitleaks  *\)rc=0/\1rc=1/' "$good" > "$BATS_TEST_TMPDIR/b8"
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b8 mo_gate topic "$OUT" a.json;    refuse "gitleaks"
  # and it prints nothing of the file but its head line
  LINUX_GATE_BASE=$BATS_TEST_TMPDIR/b4 mo_gate topic "$OUT" a.json
  [[ $output != *"perf-strict"* && $output != *"rc=0"* ]]
}

@test "mutants-only: a summary with a mode line is not a full run, so it is no base" {
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" a.json
  [ "$status" -eq 0 ]
  : > "$CALLS"
  LINUX_GATE_BASE=$OUT/summary.txt mo_gate topic "$BATS_TEST_TMPDIR/out2" a.json
  [ "$status" -eq 1 ]
  [[ $output == *"records a failed base run"*"mode(mutants-only)"* ]]
  [ ! -s "$CALLS" ]
}

@test "mutants-only: the base can't be this run's own summary.txt (by resolved path), which would be overwritten" {
  base_run
  ln -s "$BASE" "$BATS_TEST_TMPDIR/alias"
  for b in "$BASE/summary.txt" "$BATS_TEST_TMPDIR/alias/summary.txt" "$BASE/../base/summary.txt"; do
    LINUX_GATE_BASE=$b mo_gate topic "$BASE" a.json
    [ "$status" -eq 1 ] || { echo "accepted: $b" >&2; return 1; }
    [[ $output == *"this run's own summary.txt"* ]]
    [ ! -s "$CALLS" ]
  done
  grep -q '^bats ' "$BASE/summary.txt"   # untouched
}

@test "mutants-only: a base path starting with - or holding = is a path, not an option" {
  base_run
  cd "$BATS_TEST_TMPDIR"
  cp "$BASE/summary.txt" ./-base.txt; cp "$BASE/summary.txt" ./a=b.txt
  for b in -base.txt a=b.txt; do
    LINUX_GATE_BASE=$b mo_gate topic "$OUT" a.json
    [ "$status" -eq 0 ] || { echo "refused: $b: $output" >&2; return 1; }
  done
}

@test "mutants-only: the base is read once, into a copy: a base changed after the copy can't split the checks" {
  base_run
  want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$BASE/summary.txt")
  # a cp that, after copying a summary.txt (cp -- SRC DST), overwrites the source
  printf '#!/bin/sh\n/bin/cp "$@" || exit\n[ "$1" = -- ] && [ $# -eq 3 ] && case $2 in *summary.txt) echo changed > "$2" ;; esac\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/cp"
  chmod +x "$BATS_TEST_TMPDIR/bin/cp"
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" a.json
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qx changed "$BASE/summary.txt"   # the gate did copy it (and the stub then changed the original)
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' mode "mutants-only base-sha256=$want")" ]
}

# --- the launcher starts the gate container only under a heavy hold (a scratch crew dir) ---

heavy_dir() {
  HD="$BATS_TEST_TMPDIR/crew"
  mkdir -p "$HD"
  export CREW_HEAVY_DIR="$HD" CREWKIT_HEAVY_LOCK="$HD/heavy.lock"
}
need_crew_heavy() {
  CH=${CREW_HEAVY_BIN:-$(command -v crew-heavy || true)}
  [[ -n $CH && -x $CH ]] || skip "crew-heavy is not installed (set CREW_HEAVY_BIN)"
}
# sibling: another `crew-heavy run` holding a slot until teardown.
sibling() {
  local n=${1:-1} i
  "$CH" run 120 sleep 120 > /dev/null 2> "$BATS_TEST_TMPDIR/sib$n.err" 3>&- &
  SIB="${SIB:-} $!"
  for i in $(seq 100); do grep -q 'start mode=run' "$BATS_TEST_TMPDIR/sib$n.err" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
reached_docker() { grep -q '^docker run' "$CALLS"; }
no_docker() { ! grep -q '^docker' "$CALLS" 2>/dev/null; }

@test "under crew-heavy run, with the other slot held by a sibling, it passes the lock check and reaches docker" {
  need_crew_heavy
  heavy_dir
  sibling
  run "$CH" run 120 "$LG" topic "$OUT"
  [ "$status" -eq 0 ]
  [[ $output == *"slot="* ]]
  reached_docker
}

@test "under crew-heavy run in slot 3, with slots 1 and 2 held by sibling runs, it passes and reaches docker" {
  need_crew_heavy
  heavy_dir
  sibling 1
  sibling 2
  run "$CH" run 120 "$LG" topic "$OUT"
  [ "$status" -eq 0 ]
  [[ $output == *"slot=3"* ]]
  reached_docker
}

@test "under crew-heavy run with both slots free it passes too" {
  need_crew_heavy
  heavy_dir
  run "$CH" run 120 "$LG" topic "$OUT"
  [ "$status" -eq 0 ]
  reached_docker
}

@test "under crew-heavy bench it passes and reaches docker" {
  need_crew_heavy
  heavy_dir
  run "$CH" bench 120 "$LG" topic "$OUT"
  [ "$status" -eq 0 ]
  reached_docker
}

@test "under a legacy raw flock on heavy.lock it passes and reaches docker" {
  heavy_dir
  : > "$CREWKIT_HEAVY_LOCK"
  run flock "$CREWKIT_HEAVY_LOCK" "$LG" topic "$OUT"
  [ "$status" -eq 0 ]
  reached_docker
}

@test "a run hold made by hand (shared lock fd plus an exclusive slot fd) passes" {
  heavy_dir
  run bash -c 'exec 7>>"$CREWKIT_HEAVY_LOCK" 6>>"$CREW_HEAVY_DIR/heavy.slot1"; flock -s 7; flock -n 6; exec "$0" topic "$1"' "$LG" "$OUT"
  [ "$status" -eq 0 ]
  reached_docker
}

@test "with no lock at all it refuses with status 1 and docker is never called" {
  heavy_dir
  : > "$CREWKIT_HEAVY_LOCK"
  run "$LG" topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"heavy lock"* ]]
  no_docker
}

@test "a shared heavy.lock fd with no slot fd is refused and docker is never called" {
  heavy_dir
  run bash -c 'exec 7>>"$CREWKIT_HEAVY_LOCK"; flock -s 7; exec "$0" topic "$1"' "$LG" "$OUT"
  [ "$status" -eq 1 ]
  no_docker
}

@test "a slot fd with no heavy.lock fd is refused and docker is never called" {
  heavy_dir
  : > "$CREWKIT_HEAVY_LOCK"
  run bash -c 'exec 6>>"$CREW_HEAVY_DIR/heavy.slot1"; flock -n 6; exec "$0" topic "$1"' "$LG" "$OUT"
  [ "$status" -eq 1 ]
  no_docker
}

@test "a slot fd from another directory does not make a shared hold" {
  heavy_dir
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run bash -c 'exec 7>>"$CREWKIT_HEAVY_LOCK" 6>>"$BATS_TEST_TMPDIR/elsewhere/heavy.slot1"; flock -s 7; flock -n 6; exec "$0" topic "$1"' "$LG" "$OUT"
  [ "$status" -eq 1 ]
  no_docker
}

@test "after a refused check under a shared hold, the shared lock is still held" {
  heavy_dir
  run bash -c 'exec 7>>"$CREWKIT_HEAVY_LOCK"; flock -s 7
    "$0" topic "$1" > /dev/null 2>&1; echo "gate=$?"
    flock -x -n "$CREWKIT_HEAVY_LOCK" true; echo "outside=$?"
    flock -s -n "$CREWKIT_HEAVY_LOCK" true; echo "shared=$?"' "$LG" "$OUT"
  [[ $output == *"gate=1"* ]]
  [[ $output == *"outside=1"* ]]   # a raw exclusive flock still can't get it
  [[ $output == *"shared=0"* ]]
  no_docker
}

@test "a hostile PYTHONPATH cannot make the launcher's guard call pass" {
  heavy_dir
  : > "$CREWKIT_HEAVY_LOCK"
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  printf 'import sys\nsys.exit(0)\n' > "$BATS_TEST_TMPDIR/evil/subprocess.py"
  PYTHONPATH="$BATS_TEST_TMPDIR/evil" run "$LG" topic "$OUT"
  [ "$status" -eq 1 ]
  no_docker
  PYTHONPATH="$BATS_TEST_TMPDIR/evil" run "$LG" --build-images
  [ "$status" -eq 1 ]
  no_docker
}

@test "without the test override, a run with no hold: refused where the crew state dir exists, else the guard's verdict" {
  # The default dir and the heavy_lock setting come from the password database's home, which a
  # test can't create, so this follows the host. Where ~/.local/state/crew exists the answer is
  # fixed whatever the guard says (a refusal, docker never called); on a host without it, the
  # guard's own verdict (a configured-only lock refuses, neither passes unguarded) must match.
  unset CREWKIT_HEAVY_LOCK CREWKIT_HEAVY_LOCK_TEST
  # The home the guard uses: the password database's. In the gate's container that is /home/t,
  # which has no crew state dir, so the guard's verdict decides.
  pwhome=$(python3 -c 'import os, pwd
try: print(pwd.getpwuid(os.getuid()).pw_dir)
except KeyError: pass')
  verdict=0
  python3 -I "$REPO/tools/heavy_lock.py" probe > /dev/null 2>&1 || verdict=1
  run "$LG" topic "$OUT"
  if [[ -n $pwhome && -d $pwhome/.local/state/crew ]]; then
    [ "$verdict" -eq 1 ]
    [ "$status" -eq 1 ]
    no_docker
  elif [ "$verdict" -eq 1 ]; then
    [ "$status" -eq 1 ]
    no_docker
  else
    [ "$status" -eq 0 ]
    reached_docker
  fi
  [[ -n $pwhome ]] || [ "$verdict" -eq 0 ]   # no passwd entry: nothing to guard, so no refusal
}

# --- the gate's own trusted tools run against the clone; the branch can't switch a check off ---

# A token built at run time, so this file holds none.
token() { printf 'ghp_%s' "q7Rk2Lm9Xw4Tz8Bn3Vc6Hj1Pd5Fs0Ga7Ye2U"; }

@test "the secrets step runs the gate's own secrets-scan.sh with the pinned gitleaks and the hardened flags" {
  GITLEAKS_CONFIG_TOML=/branch/evil.toml GITLEAKS_CONFIG=/branch/evil.toml GITLEAKS_ANYTHING=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q '^UNPINNED' "$CALLS"                       # never a gitleaks from PATH
  line=$(grep '^gitleaks git ' "$CALLS")
  [[ $line == *"--ignore-gitleaks-allow"* ]]
  [[ $line == *"--log-opts=--all -m --text --no-textconv --no-ext-diff"* ]]
  [[ $line == *"--gitleaks-ignore-path"* ]]
  cfg=$(sed -n 's/^gitleaks-config //p' "$CALLS")
  [[ -n $cfg && $cfg != "$LINUX_GATE_WORK"/* ]]        # the gate's config, not the clone's
  ! grep -q '^gitleaks-env' "$CALLS"                   # no GITLEAKS_* reached it
  grep -q '^gitleaks  *rc=0' "$OUT/summary.txt"
}

@test "a clone that commits a token and its own allowlisting .gitleaks.toml fails the secrets step" {
  git -C "$SRC" checkout -q topic
  echo "t=$(token)" > "$SRC/leak.txt"
  printf '[extend]\nuseDefault = true\n[allowlist]\npaths = ["leak.txt"]\n' > "$SRC/.gitleaks.toml"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm leak && git -C "$SRC" checkout -q main
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == *"failed: "*gitleaks* ]]
  grep -qE '^gitleaks +rc=1' "$OUT/summary.txt"
}

@test "a token that is in history but gone from the tip fails the secrets step" {
  git -C "$SRC" checkout -q topic
  echo "t=$(token)" > "$SRC/leak.txt"; git -C "$SRC" add -A; git -C "$SRC" commit -qm leak
  git -C "$SRC" rm -q leak.txt; git -C "$SRC" commit -qm gone; git -C "$SRC" checkout -q main
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^gitleaks +rc=1' "$OUT/summary.txt"
}

@test "a token introduced only by a merge's resolution fails the secrets step" {
  git -C "$SRC" checkout -q topic
  echo base > "$SRC/f"; git -C "$SRC" add -A; git -C "$SRC" commit -qm base
  git -C "$SRC" checkout -q -b side; echo side > "$SRC/f"; git -C "$SRC" commit -qam side
  git -C "$SRC" checkout -q topic; echo topic > "$SRC/f"; git -C "$SRC" commit -qam topic
  git -C "$SRC" merge -q side > /dev/null 2>&1 || true
  echo "t=$(token)" > "$SRC/f"; git -C "$SRC" add -A; git -C "$SRC" commit -qm "merge side"
  git -C "$SRC" checkout -q main
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^gitleaks +rc=1' "$OUT/summary.txt"
}

@test "the clone's own scrub.sh is never run: its 'clean' doesn't stand in for the gate's scrub" {
  run env -u LINUX_GATE_TOOLS flock "$CREWKIT_HEAVY_LOCK" "$LG" topic "$OUT"
  [ "$status" -eq 1 ]
  ! grep -q '^clone-scrub' "$CALLS"
  ! grep -q 'the clone says so' "$OUT/summary.txt"
  [[ ${lines[-1]} == *"failed: "*scrub* ]]
}

@test "TERM to a running gate kills its named containers before the work directory goes" {
  # docker is a stub that records a kill and whether the work directory still existed then.
  mv "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/docker.real"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == kill ]]; then
  echo "docker-kill $2" >> "$CALLS"
  find "$LINUX_GATE_WORK" -maxdepth 1 -type d -name 'run.*' | grep -q . && echo "work-present-at-kill $2" >> "$CALLS"
  exit 0
fi
exec "$(dirname "$0")/docker.real" "$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  # The lock held on fd 7 and the gate exec'd in place, so $! is the gate itself (flock(1) can fork).
  ( exec 7>> "$CREWKIT_HEAVY_LOCK"; flock -x 7; exec env DOCKER_SLEEP=60 "$LG" topic "$OUT" ) > "$BATS_TEST_TMPDIR/gate.log" 2>&1 3>&- &
  pid=$!
  for i in $(seq 100); do grep -q '^docker run' "$CALLS" 2>/dev/null && break; sleep 0.1; done
  grep -q '^docker run' "$CALLS"
  kill -TERM "$pid"
  st=0; wait "$pid" || st=$?
  [ "$st" -ne 0 ]   # an interrupted gate never exits 0
  grep -q '^docker-kill crewkit-linux-gate-' "$CALLS"
  grep -q '^work-present-at-kill crewkit-linux-gate-' "$CALLS"
  grep -q '^docker-kill crewkit-linux-gate-.*-kcov' "$CALLS"
  grep -q '^docker-kill crewkit-linux-gate-.*-covpy' "$CALLS"
  [ -z "$(find "$LINUX_GATE_WORK" -maxdepth 1 -type d -name 'run.*')" ]   # and the work directory is gone
}

@test "a relative LINUX_GATE_TOOLS is refused with a failing line: it would be read from the clone" {
  LINUX_GATE_TOOLS=tools gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^tools +rc=1' "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: failed: "*tools* ]]
  ! grep -q '^clone-scrub' "$CALLS"
  ! grep -q '^docker run' "$CALLS"
}

@test "a container killed from outside (rc 137) is docker-killed by name anyway, and the gate fails" {
  DOCKER_RC=137 gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^container +rc=137' "$OUT/summary.txt"
  grep -q '^docker kill crewkit-linux-gate-' "$CALLS"
}

@test "a committed .cache symlink pointing outside the work directory is refused before any step, and the target is untouched" {
  mkdir -p "$BATS_TEST_TMPDIR/victim/coverage"
  echo keep > "$BATS_TEST_TMPDIR/victim/coverage/keep"
  git -C "$SRC" checkout -q topic
  ln -s "$BATS_TEST_TMPDIR/victim" "$SRC/.cache.link" && rm -rf "$SRC/.cache" && mv "$SRC/.cache.link" "$SRC/.cache"
  git -C "$SRC" add -f .cache && git -C "$SRC" commit -qm "a cache link"
  git -C "$SRC" checkout -q main
  mkdir -p "$SRC/.cache/bats-v1.14.0/bin" && printf '#!/bin/sh\n' > "$SRC/.cache/bats-v1.14.0/bin/bats" && chmod +x "$SRC/.cache/bats-v1.14.0/bin/bats"
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^cache +rc=1' "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: failed: cache" ]]
  no_docker
  [ -s "$BATS_TEST_TMPDIR/victim/coverage/keep" ]
  [ ! -e "$BATS_TEST_TMPDIR/victim/bats-v1.14.0" ]
}

@test "a committed regular .cache directory is refused too" {
  git -C "$SRC" checkout -q topic
  mkdir -p "$SRC/.cache/bats-v1.14.0/bin"
  printf '#!/bin/sh\necho fake\n' > "$SRC/.cache/bats-v1.14.0/bin/bats"; chmod +x "$SRC/.cache/bats-v1.14.0/bin/bats"
  git -C "$SRC" add -f .cache && git -C "$SRC" commit -qm "a tracked cache"
  git -C "$SRC" checkout -q main
  mkdir -p "$SRC/.cache/bats-v1.14.0/bin" && printf '#!/bin/sh\n' > "$SRC/.cache/bats-v1.14.0/bin/bats" && chmod +x "$SRC/.cache/bats-v1.14.0/bin/bats"
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -qE '^cache +rc=1' "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: failed: cache" ]]
  no_docker
}

# --- the hung-step tests (LIMIT, HANG) last: each takes about LIMIT seconds, and a mutant run
# (bats --abort) only reaches them if no faster test killed it ---

@test "an overall time limit (LINUX_GATE_TIMEOUT): a hung container is killed by its name, a timeout line, the gate fails" {
  DOCKER_SLEEP=$HANG LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(name_of "$(first_run)")
  [[ $name == crewkit-linux-gate-* ]]
  grep -qx "docker kill $name" "$CALLS"   # (the exit trap also kills it: the next test counts the kills)
  grep -qE '^timeout +container ' "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: failed: timeout(container)"* ]]
  [ "$(head -1 "$OUT/summary.txt" | awk '{ print $1 }')" = head ]
}

@test "the time limit covers the native checks: a hung gitleaks stops the gate, and nothing after it starts" {
  full_src
  GL_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -q '^gitleaks ' "$CALLS"   # the hung step was reached
  grep -qE '^timeout +gitleaks ' "$OUT/summary.txt"
  [[ ${lines[-1]} == "linux-gate: failed: timeout(gitleaks) "* ]]
  for s in gitleaks kcov python install-mutants coverage-py floors; do [[ ${lines[-1]} == *" $s(missing)"* ]]; done
  ! grep -q '^docker run' "$CALLS"
  ! grep -q '^coverage.sh' "$CALLS"
}

@test "FULL=1: the time limit covers kcov: its container is named and killed, and nothing after it starts" {
  full_src
  KCOV_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(sed -n 's/^coverage.sh KCOV_NAME=//p' "$CALLS")
  [[ $name == crewkit-linux-gate-* ]]
  grep -qx "docker kill $name" "$CALLS"
  [[ ${lines[-1]} == "linux-gate: failed: timeout(kcov) "* ]]
  for s in kcov python coverage-py floors; do [[ ${lines[-1]} == *" $s(missing)"* ]]; done
}

@test "FULL=1: the time limit covers coverage.py: its container is killed" {
  full_src
  COVPY_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(name_of "$(grep '^docker run .*crewkit-ubuntu-amd64' "$CALLS")")
  [ -n "$name" ]
  grep -qx "docker kill $name" "$CALLS"
  [[ ${lines[-1]} == "linux-gate: failed: timeout(coverage-py) coverage-py(missing) floors(missing)" ]]
}

@test "FULL=1: the time limit covers the floors" {
  full_src
  FLOORS_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  grep -q '^floors base ' "$CALLS"   # the hung step was reached
  [[ ${lines[-1]} == "linux-gate: failed: timeout(floors) floors(missing)" ]]
}

@test "a timed-out container is killed by the timeout path itself, not only by the exit trap" {
  DOCKER_SLEEP=$HANG LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(name_of "$(first_run)")
  [ "$(kills "$name")" -eq 2 ]
  # the two others are killed by the trap alone
  [ "$(kills "$name-kcov")" -eq 1 ]
  [ "$(kills "$name-covpy")" -eq 1 ]
}

@test "FULL=1: a timed-out kcov container is killed by the timeout path itself" {
  full_src
  KCOV_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(sed -n 's/^coverage.sh KCOV_NAME=//p' "$CALLS")
  [[ $name == crewkit-linux-gate-*-kcov ]]
  [ "$(kills "$name")" -eq 2 ]
}

@test "FULL=1: a timed-out coverage.py container is killed by the timeout path itself" {
  full_src
  COVPY_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"
  [ "$status" -eq 1 ]
  name=$(name_of "$(grep '^docker run .*crewkit-ubuntu-amd64' "$CALLS")")
  [[ $name == crewkit-linux-gate-*-covpy ]]
  [ "$(kills "$name")" -eq 2 ]
}

@test "a slow step before the hung one still leaves the hung step reached, timed out and killed (covshard-4, r4)" {
  full_src
  SC_DELAY=2 COVPY_SLEEP=$HANG FULL=1 LINUX_GATE_TIMEOUT=$LIMIT gate topic "$OUT"   # 6 s: the gate calls shellcheck three times
  [ "$status" -eq 1 ]
  name=$(name_of "$(grep '^docker run .*crewkit-ubuntu-amd64' "$CALLS")")
  [[ $name == crewkit-linux-gate-*-covpy ]]
  [ "$(kills "$name")" -eq 2 ]
  [[ ${lines[-1]} == "linux-gate: failed: timeout(coverage-py) coverage-py(missing) floors(missing)" ]]
}
