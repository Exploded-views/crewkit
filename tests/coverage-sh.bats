#!/usr/bin/env bats
# tools/coverage.sh with a stub docker, in a scratch repo: which suites run under kcov, what it
# covers, and which image it uses. Nothing real is run or touched.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$T/tools" "$T/tests" "$BATS_TEST_TMPDIR/bin"
  cp "$REPO/tools/coverage.sh" "$T/tools/"
  printf '#!/bin/sh\necho "%s/.cache/bats/bin/bats"\n' "$T" > "$T/tools/get-bats.sh"
  chmod +x "$T/tools/get-bats.sh"
  for f in install docs settings lane-new land-batch crew-log; do : > "$T/tests/$f.bats"; done
  cp "$REPO/tools/bats-shards.py" "$T/tools/"
  mkdir -p "$T/plugins/crew-x/bin"
  printf 'echo y\n' > "$T/plugins/crew-x/bin/y"
  # weights chosen so that 2 shards are: {install, crew-log} and {land-batch, lane-new, docs, settings}
  printf '{"install.bats": 50, "land-batch.bats": 40, "lane-new.bats": 10, "crew-log.bats": 5, "docs.bats": 3, "settings.bats": 2}\n' > "$T/tests/bats-times.json"
  git -C "$T" init -q
  # The stub docker logs its arguments and writes the report kcov would. The ps preflight
  # (docker run --entrypoint sh) is logged apart in $PREFLIGHT_ARGS and exits 3 when STUB_NO_PS is
  # set (ps missing) and 125 with a daemon error when STUB_DOCKER_FAIL is set; STUB_SHORT makes the kcov call print bats's short-run warning and fail.
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = --entrypoint ]; then
    printf '%s\n' "$@" > "$PREFLIGHT_ARGS"
    [ -z "${STUB_NO_PS:-}" ] || exit 3
    [ -z "${STUB_DOCKER_FAIL:-}" ] || { echo 'Cannot connect to the Docker daemon' >&2; exit 125; }
    exit 0
  fi
done
printf '%s\n' "$@" > "$DOCKER_ARGS"
for a; do [[ $a == *:/etc/passwd:ro ]] && cp "${a%:/etc/passwd:ro}" "$DOCKER_ARGS.passwd"; done
if [ -n "${STUB_SHORT:-}" ]; then
  echo "# bats warning: Executed 2 instead of expected 3 tests"
  exit 1
fi
if printf '%s\n' "$@" | grep -qx -- '--merge'; then
  out=$(printf '%s\n' "$@" | grep -A1 -x -- '--merge' | tail -1)
  [ -z "${STUB_MERGE_FAIL:-}" ] || { mkdir -p "$TREE/${out#/src/}/kcov-merged"; echo 'kcov: merge failed' >&2; exit 1; }
  mkdir -p "$TREE/${out#/src/}/kcov-merged"
  if [ -n "${STUB_MERGE_TWINS:-}" ]; then
    # kcov credits a file's hits to whichever of several identical files it met first, so after a merge
    # the hits of the identical twins p1, p2 are spread over them (p1: lines 1,2; p2: lines 2,3), while p3
    # has other content and keeps its own
    echo '{"files":[{"file":"/src/plugins/p1/lib/s.sh","percent_covered":"40.00","covered_lines":"2","total_lines":"5"},{"file":"/src/plugins/p2/lib/s.sh","percent_covered":"40.00","covered_lines":"2","total_lines":"5"},{"file":"/src/plugins/p3/lib/s.sh","percent_covered":"20.00","covered_lines":"1","total_lines":"5"},{"file":"/src/plugins/crew-x/bin/y","percent_covered":"94.0","covered_lines":"1","total_lines":"1"}]}' > "$TREE/${out#/src/}/kcov-merged/coverage.json"
    echo '{"coverage":{"plugins/p1/lib/s.sh":{"1":1,"2":1,"3":0,"4":0,"5":0},"plugins/p2/lib/s.sh":{"1":0,"2":1,"3":1,"4":0,"5":0},"plugins/p3/lib/s.sh":{"1":1,"2":0,"3":0,"4":0,"5":0},"plugins/crew-x/bin/y":{"1":1}}}' > "$TREE/${out#/src/}/kcov-merged/codecov.json"
    exit 0
  fi
  [ -n "${STUB_MERGE_NO_JSON:-}" ] || echo '{"files":[{"file":"/src/plugins/crew-x/bin/y","percent_covered":"94.0","covered_lines":"1","total_lines":"1"}]}' > "$TREE/${out#/src/}/kcov-merged/coverage.json"
  { [ -n "${STUB_MERGE_NO_JSON:-}" ] || [ -n "${STUB_MERGE_NO_CODECOV:-}" ]; } || echo '{"coverage":{"plugins/crew-x/bin/y":{"1":1}}}' > "$TREE/${out#/src/}/kcov-merged/codecov.json"
  exit 0
fi
shardout=$(printf '%s\n' "$@" | grep -x '/src/.cache/coverage-shards/shard-[0-9]*' | head -1)
if [ -n "$shardout" ]; then
  mkdir -p "$TREE/${shardout#/src/}/bats.1"
  [ -n "${STUB_SHARD_NO_DATA:-}" ] || echo '{"files":[{"file":"/src/plugins/crew-x/bin/y","percent_covered":"70.0","covered_lines":"1","total_lines":"1"}]}' > "$TREE/${shardout#/src/}/bats.1/coverage.json"
  # code under test in the container can leave links in the directory it was given
  if [ -n "${STUB_PLANT_LINKS:-}" ]; then
    ln -s "$STUB_PLANT_LINKS" "$TREE/${shardout#/src/}/done.tmp"
    ln -s "$STUB_PLANT_LINKS" "$TREE/${shardout#/src/}/done"
  fi
  [ -n "${STUB_NO_OK:-}" ] || echo "ok 1 x"
  exit 0
fi
mkdir -p "$TREE/.cache/coverage/bats.1"
echo '{"files":[{"file":"/src/plugins/crew-x/bin/y","percent_covered":"88.5","covered_lines":"1","total_lines":"1"}]}' > "$TREE/.cache/coverage/bats.1/coverage.json"
[ -n "${STUB_NO_OK:-}" ] || echo "ok 1 x"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_ARGS="$BATS_TEST_TMPDIR/args" PREFLIGHT_ARGS="$BATS_TEST_TMPDIR/pre" TREE="$T"
  cd "$T"   # coverage.sh finds its repo from the current directory
}

@test "every suite but docs and settings runs under kcov" {
  run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  for s in install lane-new land-batch crew-log; do grep -qx "tests/$s.bats" "$DOCKER_ARGS"; done
  run grep -E '^tests/(docs|settings)\.bats$' "$DOCKER_ARGS"
  [ "$status" -eq 1 ]
}

@test "it covers install.sh, the crewkit CLI, the push gate and the plugins' scripts, with no network" {
  run "$T/tools/coverage.sh"
  grep -qx -- '--include-pattern=/src/install.sh,/src/bin/crewkit,/src/libexec/,/src/plugins/crew-,/src/push-gate/' "$DOCKER_ARGS"
  grep -A1 -x -- '--network' "$DOCKER_ARGS" | grep -qx none
}

@test "KCOV_IMAGE replaces the pinned image; the default is the digest" {
  KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh"
  grep -qx crewkit-kcov "$DOCKER_ARGS"
  run "$T/tools/coverage.sh"
  grep -qx "$("$T/tools/coverage.sh" --pinned-image)" "$DOCKER_ARGS"
}

@test "--pinned-image prints the digest-pinned image and runs nothing" {
  run "$T/tools/coverage.sh" --pinned-image
  [ "$status" -eq 0 ]
  [[ $output =~ ^kcov/kcov@sha256:[0-9a-f]{64}$ ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "it prints each covered file's percentage" {
  run "$T/tools/coverage.sh"
  [[ $output == *"88.5%  plugins/crew-x/bin/y"* ]]
}

@test "BATS_TEST_TIMEOUT, when set, reaches the suites under kcov; unset, nothing is passed" {
  BATS_TEST_TIMEOUT=77 run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  grep -qx 'BATS_TEST_TIMEOUT=77' "$DOCKER_ARGS"
  run env -u BATS_TEST_TIMEOUT "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  none() { ! grep "$@"; }
  none -q BATS_TEST_TIMEOUT "$DOCKER_ARGS"
}

@test "KCOV_NAME, when set, names the kcov container (so tools/linux-gate.sh can kill it); unset, no name" {
  KCOV_NAME=gate-kcov run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  grep -A1 -x -- '--name' "$DOCKER_ARGS" | grep -qx gate-kcov
  run env -u KCOV_NAME "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  none() { ! grep "$@"; }
  none -qx -- '--name' "$DOCKER_ARGS"
}

@test "the kcov container mounts a passwd entry for the caller's uid, home /tmp (ssh-keygen needs one)" {
  run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  grep -q -- ':/etc/passwd:ro$' "$DOCKER_ARGS"
  grep -qx 'root:x:0:0:root:/root:/bin/sh' "$DOCKER_ARGS.passwd"
  if (($(id -u) != 0)); then grep -qx "t:x:$(id -u):$(id -g):gate:/tmp:/bin/sh" "$DOCKER_ARGS.passwd"; fi
}

@test "an image with ps passes the preflight, which runs ps's lookup in that image" {
  KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  grep -qx crewkit-kcov "$PREFLIGHT_ARGS"
  grep -A1 -x -- '--network' "$PREFLIGHT_ARGS" | grep -qx none
  grep -A1 -x -- '--entrypoint' "$PREFLIGHT_ARGS" | grep -qx bash
  grep -qx 'ps -Ao pid,ppid,args >/dev/null || exit 3' "$PREFLIGHT_ARGS"
  [ -e "$DOCKER_ARGS" ]
}

@test "an image without ps is refused before any suite runs" {
  STUB_NO_PS=1 KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"coverage: crewkit-kcov has no ps; bats needs it for BATS_TEST_TIMEOUT (install procps in the kcov image)"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "a docker failure is reported as such, with docker's error, not as a missing ps" {
  STUB_DOCKER_FAIL=1 KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"coverage: could not run crewkit-kcov (docker exit 125)"* ]]
  [[ $output == *"Cannot connect to the Docker daemon"* ]]
  [[ $output != *"has no ps"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "a refused image leaves the previous report alone" {
  mkdir -p "$T/.cache/coverage" && : > "$T/.cache/coverage/old"
  STUB_NO_PS=1 run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [ -e "$T/.cache/coverage/old" ]
}

@test "a short run fails loudly, with bats's warning in the output" {
  STUB_SHORT=1 run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"# bats warning: Executed 2 instead of expected 3 tests"* ]]
  [[ $output == *"the suite failed under kcov"* ]]
}

@test "the kcov run gets an init as PID 1 (--init, before the image), so orphans are reaped" {
  KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  init_line=$(grep -nx -- '--init' "$DOCKER_ARGS" | head -1 | cut -d: -f1)
  image_line=$(grep -nx crewkit-kcov "$DOCKER_ARGS" | head -1 | cut -d: -f1)
  [ -n "$init_line" ]
  [ "$init_line" -lt "$image_line" ]
}

@test "the kcov run passes CREWKIT_TEST_TIME_SCALE=4 into the container, before the image" {
  KCOV_IMAGE=crewkit-kcov run env -u CREWKIT_TEST_TIME_SCALE "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  e_line=$(grep -nx -- 'CREWKIT_TEST_TIME_SCALE=4' "$DOCKER_ARGS" | head -1 | cut -d: -f1)
  image_line=$(grep -nx crewkit-kcov "$DOCKER_ARGS" | head -1 | cut -d: -f1)
  [ -n "$e_line" ]
  [ "$e_line" -lt "$image_line" ]
  [ "$(sed -n "$((e_line - 1))p" "$DOCKER_ARGS")" = -e ]
}

@test "a CREWKIT_TEST_TIME_SCALE already set is the one passed on" {
  CREWKIT_TEST_TIME_SCALE=9 run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  grep -qx -- 'CREWKIT_TEST_TIME_SCALE=9' "$DOCKER_ARGS"
  run grep -x -- 'CREWKIT_TEST_TIME_SCALE=4' "$DOCKER_ARGS"
  [ "$status" -eq 1 ]
}

@test "run from a clone by a copy of its own, it runs its own get-bats.sh and an isolated python: the clone's never run" {
  # tools/linux-gate.sh runs the gate's coverage.sh with the clone as the current directory. The
  # clone's tools/get-bats.sh and a top-level json.py (importable from the current directory by a
  # plain `python3 -`) are branch code and must not run on the host.
  G="$BATS_TEST_TMPDIR/gate"
  mkdir -p "$G"
  cp "$REPO/tools/coverage.sh" "$G/"
  printf '#!/bin/sh\necho "%s/.cache/bats/bin/bats"\n' "$T" > "$G/get-bats.sh"
  chmod +x "$G/get-bats.sh"
  printf '#!/bin/sh\ntouch "%s/get-bats-ran"\n' "$BATS_TEST_TMPDIR" > "$T/tools/get-bats.sh"
  printf 'import pathlib\npathlib.Path("%s/json-ran").touch()\n' "$BATS_TEST_TMPDIR" > "$T/json.py"
  run "$G/coverage.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"88.5%  plugins/crew-x/bin/y"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/get-bats-ran" ]
  [ ! -e "$BATS_TEST_TMPDIR/json-ran" ]
}

@test "a .cache (or .cache/coverage, or the log) that is a symlink is refused before anything is removed or written" {
  mkdir -p "$BATS_TEST_TMPDIR/victim/coverage"
  echo keep > "$BATS_TEST_TMPDIR/victim/coverage/keep"
  # .cache itself a link out of the repository
  ln -s "$BATS_TEST_TMPDIR/victim" "$T/.cache"
  run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  # the resolve check runs first, so a .cache that leads out of the repository is named as such
  [[ $output == *"resolves outside the repository"* ]]
  [ -s "$BATS_TEST_TMPDIR/victim/coverage/keep" ]
  [ ! -e "$DOCKER_ARGS" ]
  rm "$T/.cache"
  # .cache/coverage a link
  mkdir "$T/.cache"; ln -s "$BATS_TEST_TMPDIR/victim/coverage" "$T/.cache/coverage"
  run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [ -s "$BATS_TEST_TMPDIR/victim/coverage/keep" ]
  rm "$T/.cache/coverage"
  # the log a link to a file elsewhere
  echo precious > "$BATS_TEST_TMPDIR/precious"; ln -s "$BATS_TEST_TMPDIR/precious" "$T/.cache/coverage.log"
  run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/precious")" = precious ]
}

@test "a .cache/passwd that is a symlink is refused: the mount file is not written through it" {
  echo precious > "$BATS_TEST_TMPDIR/precious"
  mkdir "$T/.cache"; ln -s "$BATS_TEST_TMPDIR/precious" "$T/.cache/passwd"
  run "$T/tools/coverage.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/precious")" = precious ]
  [ ! -e "$DOCKER_ARGS" ]
}

# --- sharding: tools/coverage.sh --shard K/N and --merge N ---

commit_tree() { # a commit in the scratch repo, so HEAD exists
  git -C "$T" add -A
  git -C "$T" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m "${1:-tree}"
}

shard_dir() { echo "$T/.cache/coverage-shards/shard-$1"; }

run_shards() { # run_shards N: every shard 1..N, all expected to pass
  local k
  for k in $(seq 1 "$1"); do
    run "$T/tools/coverage.sh" --shard "$k/$1"
    [ "$status" -eq 0 ] || { echo "shard $k/$1 gave $status: $output"; return 1; }
  done
}

@test "--shard K/N runs that shard's suites only, from the planner, minus docs and settings" {
  commit_tree
  run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 0 ]
  grep -qx 'tests/land-batch.bats' "$DOCKER_ARGS"
  grep -qx 'tests/lane-new.bats' "$DOCKER_ARGS"
  [ -z "$(grep -E '^tests/(install|crew-log|docs|settings)\.bats$' "$DOCKER_ARGS" || true)" ]
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 0 ]
  grep -qx 'tests/install.bats' "$DOCKER_ARGS"
  grep -qx 'tests/crew-log.bats' "$DOCKER_ARGS"
  [ -z "$(grep -E '^tests/(land-batch|lane-new|docs|settings)\.bats$' "$DOCKER_ARGS" || true)" ]
}

@test "--shard K/N writes kcov's output into its own directory and mounts only that directory writable" {
  commit_tree
  run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 0 ]
  grep -qx '/src/.cache/coverage-shards/shard-2' "$DOCKER_ARGS"
  # (the host side of a mount is the repository's real path, which may differ from $T by a symlink)
  grep -q -e '/.cache/coverage-shards/shard-2:/src/.cache/coverage-shards/shard-2$' "$DOCKER_ARGS"
  [ -z "$(grep -e ':/src/.cache/coverage$' "$DOCKER_ARGS" || true)" ]
  [ -d "$(shard_dir 2)/bats.1" ]
}

@test "--shard K/N keeps the unsharded options: no network, the same include pattern, KCOV_IMAGE, the timeout, the passwd entry" {
  commit_tree
  KCOV_IMAGE=crewkit-kcov BATS_TEST_TIMEOUT=77 run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 0 ]
  grep -qx -- '--include-pattern=/src/install.sh,/src/bin/crewkit,/src/libexec/,/src/plugins/crew-,/src/push-gate/' "$DOCKER_ARGS"
  grep -A1 -x -- '--network' "$DOCKER_ARGS" | grep -qx none
  grep -qx crewkit-kcov "$DOCKER_ARGS"
  grep -qx 'BATS_TEST_TIMEOUT=77' "$DOCKER_ARGS"
  grep -q -- ':/etc/passwd:ro$' "$DOCKER_ARGS"
  grep -qx -- '--init' "$DOCKER_ARGS"
  # and it is the shard's run, not the whole suite
  grep -qx '/src/.cache/coverage-shards/shard-1' "$DOCKER_ARGS"
  [ -z "$(grep -x 'tests/land-batch.bats' "$DOCKER_ARGS" || true)" ]
}

@test "a finished shard leaves a done marker with N, K, the commit and the suites it ran" {
  commit_tree
  run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 0 ]
  local m; m="$(shard_dir 2)/done"
  [ -f "$m" ]
  grep -qx 'n=2' "$m"
  grep -qx 'k=2' "$m"
  grep -qx "sha=$(git -C "$T" rev-parse HEAD)" "$m"
  [ "$(grep '^file=' "$m" | LC_ALL=C sort | tr '\n' ' ')" = "file=land-batch.bats file=lane-new.bats " ]
}

@test "--shard rejects 0/2, 3/2, 1/0, 1/17, x, 1/2/3 and a missing value with exit 2, and runs nothing" {
  commit_tree
  local bad
  for bad in 0/2 3/2 1/0 1/17 x 1/2/3 -1/2; do
    run "$T/tools/coverage.sh" --shard "$bad"
    [ "$status" -eq 2 ] || { echo "'$bad' gave $status"; return 1; }
    [[ $output == *"--shard"* ]]
  done
  run "$T/tools/coverage.sh" --shard
  [ "$status" -eq 2 ]
  [ ! -e "$DOCKER_ARGS" ]
  [ ! -e "$T/.cache/coverage-shards" ]
}

@test "only the shard's own directory is replaced; the other shards' data stays" {
  commit_tree
  mkdir -p "$(shard_dir 1)" "$(shard_dir 2)"
  : > "$(shard_dir 1)/keep"
  : > "$(shard_dir 2)/old"
  run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 0 ]
  [ -e "$(shard_dir 1)/keep" ]
  [ ! -e "$(shard_dir 2)/old" ]
}

@test "a shard that fails under kcov exits 1 with the log named, and leaves no done marker (an older one is removed)" {
  commit_tree
  mkdir -p "$(shard_dir 2)"
  printf 'n=2\nk=2\n' > "$(shard_dir 2)/done"
  STUB_SHORT=1 run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 1 ]
  [[ $output == *"the suite failed under kcov"* ]]
  [[ $output == *"# bats warning: Executed 2 instead of expected 3 tests"* ]]
  [ ! -e "$(shard_dir 2)/done" ]
}

@test "--shard checks the image for ps first, as the unsharded run does, and touches nothing when it is missing" {
  commit_tree
  mkdir -p "$(shard_dir 2)" && : > "$(shard_dir 2)/old"
  STUB_NO_PS=1 KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 1 ]
  [[ $output == *"has no ps"* ]]
  [ -e "$(shard_dir 2)/old" ]
  [ ! -e "$DOCKER_ARGS" ]
  # with an image that has ps, the same call runs the shard (and only then replaces its directory)
  KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -eq 0 ]
  [ ! -e "$(shard_dir 2)/old" ]
  [ -d "$(shard_dir 2)/bats.1" ]
}

@test "--shard refuses a .cache/coverage-shards that is a symbolic link" {
  commit_tree
  mkdir -p "$T/.cache" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$T/.cache/coverage-shards"
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 1 ]
  [[ $output == *"symlink"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

@test "--shard stops when the times table is broken, instead of running everything" {
  commit_tree
  printf 'not json\n' > "$T/tests/bats-times.json"
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -ne 0 ]
  [[ $output == *"bats-times.json"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge N merges the N shard directories in the pinned image, with no network and no apt, and writes the report where the floors look" {
  commit_tree
  run_shards 2
  KCOV_IMAGE=crewkit-kcov run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 0 ]
  grep -qx -- '--merge' "$DOCKER_ARGS"
  grep -A1 -x -- '--merge' "$DOCKER_ARGS" | grep -qx '/src/.cache/coverage/bats.merged'
  [ "$(grep -x '/src/.cache/coverage-shards/shard-[0-9]*' "$DOCKER_ARGS" | tr '\n' ' ')" = "/src/.cache/coverage-shards/shard-1 /src/.cache/coverage-shards/shard-2 " ]
  grep -qx "$("$T/tools/coverage.sh" --pinned-image)" "$DOCKER_ARGS"
  [ -z "$(grep -x crewkit-kcov "$DOCKER_ARGS" || true)" ]
  grep -A1 -x -- '--network' "$DOCKER_ARGS" | grep -qx none
  [ -f "$T/.cache/coverage/bats.merged/coverage.json" ]
  [[ $output == *"coverage report: .cache/coverage/bats.merged/coverage.json"* ]]
  [[ $output == *"94.0%  plugins/crew-x/bin/y"* ]]
  [ "$(ls "$T"/.cache/coverage/bats.*/coverage.json | wc -l | tr -d ' ')" -eq 1 ]
}

@test "--merge replaces an older report, and a failed merge leaves none" {
  commit_tree
  run_shards 2
  mkdir -p "$T/.cache/coverage/bats.old"
  echo '{"files":[]}' > "$T/.cache/coverage/bats.old/coverage.json"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 0 ]
  [ ! -e "$T/.cache/coverage/bats.old" ]
  STUB_MERGE_FAIL=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"merge"* ]]
  [ -z "$(ls "$T"/.cache/coverage/bats.*/coverage.json 2>/dev/null || true)" ]
  [ ! -e "$T/.cache/coverage/bats.merged" ]
}

@test "--merge fails when kcov wrote no coverage.json" {
  commit_tree
  run_shards 2
  STUB_MERGE_NO_JSON=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"coverage: kcov --merge wrote no coverage.json"* ]]
  [ ! -e "$T/.cache/coverage/bats.merged" ]
}

@test "--merge refuses a missing shard, naming it, and runs nothing" {
  commit_tree
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 0 ]
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses a shard without its done marker" {
  commit_tree
  run_shards 2
  rm "$(shard_dir 2)/done"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2"* && $output == *"did not finish"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses shards from a run with another N" {
  commit_tree
  run_shards 2
  sed -i.bak 's/^n=2$/n=3/' "$(shard_dir 1)/done"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 1"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses shards that ran at another commit than this checkout's" {
  commit_tree
  run_shards 2
  : > "$T/tests/extra-change"
  commit_tree second
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"commit"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses when the shards' suites are not exactly tests/*.bats minus docs and settings" {
  commit_tree
  run_shards 2
  printf 'file=ghost.bats\n' >> "$(shard_dir 1)/done"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"ghost.bats"* ]]
  [ ! -e "$DOCKER_ARGS" ]
  # and a suite that ran in no shard
  run_shards 2
  sed -i.bak '/^file=crew-log.bats$/d' "$(shard_dir 1)/done"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"crew-log.bats"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge rejects 0, 17, x and a missing N with exit 2" {
  commit_tree
  local bad
  for bad in 0 17 x -1 1/2; do
    run "$T/tools/coverage.sh" --merge "$bad"
    [ "$status" -eq 2 ] || { echo "'$bad' gave $status"; return 1; }
  done
  run "$T/tools/coverage.sh" --merge
  [ "$status" -eq 2 ]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "the kcov image recipe gives apt retries and a timeout for each fetch, on update and on install" {
  local f="$REPO/docker/crewkit-kcov.Dockerfile"
  [ "$(grep -c 'apt-get .*Acquire::Retries=[1-9]' "$f")" -eq 2 ]
  [ "$(grep -c 'apt-get .*Acquire::http::Timeout=[1-9]' "$f")" -eq 2 ]
  grep -q 'apt-get .*update' "$f"
  grep -q 'apt-get .*install' "$f"
}

@test "a shard made only of docs.bats and settings.bats runs no kcov, and is still marked done with no suites" {
  commit_tree
  printf '{"docs.bats": 100, "settings.bats": 90, "install.bats": 1, "land-batch.bats": 1, "lane-new.bats": 1, "crew-log.bats": 1}\n' > "$T/tests/bats-times.json"
  commit_tree weights
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 0 ]
  [ ! -e "$DOCKER_ARGS" ]
  local m; m="$(shard_dir 1)/done"
  grep -qx 'n=2' "$m"
  grep -qx 'k=1' "$m"
  [ -z "$(grep '^file=' "$m" || true)" ]
}

@test "--merge refuses a .cache/coverage-shards that is a symbolic link, and runs nothing" {
  commit_tree
  run_shards 2
  mv "$T/.cache/coverage-shards" "$BATS_TEST_TMPDIR/real-shards"
  ln -s "$BATS_TEST_TMPDIR/real-shards" "$T/.cache/coverage-shards"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"symlink"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "the shard's log is not written through a symbolic link" {
  commit_tree
  mkdir -p "$T/.cache/coverage-shards"
  : > "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$T/.cache/coverage-shards/shard-1.log"
  run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 1 ]
  [[ $output == *"symlink"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/victim" ]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "the merge log is not written through a symbolic link" {
  commit_tree
  run_shards 2
  : > "$BATS_TEST_TMPDIR/victim"
  echo keep > "$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$T/.cache/coverage-merge.log"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"symlink"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses a shard marked as another K, even when N and the suites are right" {
  commit_tree
  run_shards 2
  sed -i.bak 's/^k=1$/k=2/' "$(shard_dir 1)/done"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 1"* && $output == *"shard 2/2"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "--merge refuses a shard that has a done marker but no kcov data" {
  commit_tree
  run_shards 2
  rm -r "$(shard_dir 2)/bats.1"
  rm -f "$DOCKER_ARGS"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2"* && $output == *"no kcov data"* ]]
  [ ! -e "$DOCKER_ARGS" ]
}

@test "a shard whose kcov run printed no passing test is a failure, as the unsharded run is" {
  commit_tree
  STUB_NO_OK=1 run "$T/tools/coverage.sh" --shard 2/2
  [ "$status" -ne 0 ]
  [ ! -e "$(shard_dir 2)/done" ]
  STUB_NO_OK=1 run "$T/tools/coverage.sh"
  [ "$status" -ne 0 ]
}

@test "a link left in the shard directory by the suites is not written through when the done marker is made" {
  commit_tree
  echo keep > "$BATS_TEST_TMPDIR/victim"
  STUB_PLANT_LINKS="$BATS_TEST_TMPDIR/victim" run "$T/tools/coverage.sh" --shard 1/2
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = keep ]
  [ -f "$(shard_dir 1)/done" ] && [ ! -L "$(shard_dir 1)/done" ]
  grep -qx 'n=2' "$(shard_dir 1)/done"
  grep -qx 'k=1' "$(shard_dir 1)/done"
}

# identical files: kcov credits all of their hits to the one it met first in a run, so the report of one
# run and the merge of several differ in which path holds the hits; --merge puts them back on one path

twin_tree() { # three scripts: p1 and p2 identical, p3 different
  mkdir -p "$T/plugins/p1/lib" "$T/plugins/p2/lib" "$T/plugins/p3/lib"
  printf 'a\nb\nc\nd\ne\n' > "$T/plugins/p1/lib/s.sh"
  cp "$T/plugins/p1/lib/s.sh" "$T/plugins/p2/lib/s.sh"
  printf 'v\nw\nx\ny\nz\n' > "$T/plugins/p3/lib/s.sh"
  commit_tree twins
}

report_of() { # report_of FILE: "covered/total percent" for that file in the merged report
  python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    if f["file"] == "/src/" + sys.argv[2]:
        print(f["covered_lines"] + "/" + f["total_lines"], f["percent_covered"])
' "$T/.cache/coverage/bats.merged/coverage.json" "$1"
}

@test "--merge puts the hits of identical files back on one path, the first by name, as one kcov run reports them" {
  twin_tree
  run_shards 2
  STUB_MERGE_TWINS=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 0 ]
  [ "$(report_of plugins/p1/lib/s.sh)" = "3/5 60.00" ]
  [ "$(report_of plugins/p2/lib/s.sh)" = "0/5 0.00" ]
}

@test "--merge leaves a file of other content, and a file with no twin, as kcov merged them" {
  twin_tree
  run_shards 2
  STUB_MERGE_TWINS=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 0 ]
  [ "$(report_of plugins/p3/lib/s.sh)" = "1/5 20.00" ]
  [ "$(report_of plugins/crew-x/bin/y)" = "1/1 94.0" ]
}

@test "the printed per-file lines show the folded numbers" {
  twin_tree
  run_shards 2
  STUB_MERGE_TWINS=1 run "$T/tools/coverage.sh" --merge 2
  [[ $output == *"60.00%  plugins/p1/lib/s.sh"* ]]
  [[ $output == *"0.00%  plugins/p2/lib/s.sh"* ]]
}

@test "--merge fails when kcov's merged output has no codecov.json (the per-line hits)" {
  twin_tree
  run_shards 2
  STUB_MERGE_NO_CODECOV=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"codecov.json"* ]]
  [ ! -e "$T/.cache/coverage/bats.merged/coverage.json" ]
}

@test "--merge fails, naming the file, when a path in the report is not a file of the repository" {
  twin_tree
  run_shards 2
  rm "$T/plugins/p2/lib/s.sh"
  STUB_MERGE_TWINS=1 run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 1 ]
  [[ $output == *"plugins/p2/lib/s.sh"* ]]
  [ ! -e "$T/.cache/coverage/bats.merged/coverage.json" ]
}

@test "--merge runs its python isolated: a json.py or hashlib.py in the repository is never imported" {
  commit_tree
  run_shards 2
  printf 'import pathlib\npathlib.Path("%s/json-ran").touch()\n' "$BATS_TEST_TMPDIR" > "$T/json.py"
  printf 'import pathlib\npathlib.Path("%s/hashlib-ran").touch()\n' "$BATS_TEST_TMPDIR" > "$T/hashlib.py"
  run "$T/tools/coverage.sh" --merge 2
  [ "$status" -eq 0 ]
  [[ $output == *"94.0%  plugins/crew-x/bin/y"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/json-ran" ]
  [ ! -e "$BATS_TEST_TMPDIR/hashlib-ran" ]
}
