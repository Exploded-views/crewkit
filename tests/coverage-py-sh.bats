#!/usr/bin/env bats
# tools/coverage-py.sh's guards, with a fake venv: it writes its startup hook only into the
# venv it is given, never into a system site-packages. Its sharding (--shard K/N, --combine N)
# runs in a throwaway repo with a stub bats and a stub python, so no real suite runs.

bats_require_minimum_version 1.5.0

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  V="$BATS_TEST_TMPDIR/venv"
  mkdir -p "$V/bin" "$V/lib/site"
}

fake_python() { # fake_python PURELIB: a venv python that reports PURELIB as its site-packages
  printf '#!/bin/sh\necho %s\n' "$1" > "$V/bin/python"
  chmod +x "$V/bin/python"
}

@test "COVERAGE_VENV is required (exit 2)" {
  run env -u COVERAGE_VENV "$REPO/tools/coverage-py.sh"
  [ "$status" -eq 2 ]
  [[ $output == *COVERAGE_VENV* ]]
}

@test "a venv whose site-packages is outside it is refused, and nothing is written" {
  fake_python "$BATS_TEST_TMPDIR/system-site"
  mkdir -p "$BATS_TEST_TMPDIR/system-site"
  COVERAGE_VENV="$V" run "$REPO/tools/coverage-py.sh"
  [ "$status" -eq 2 ]
  [[ $output == *"not inside"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/system-site")" ]
}

@test "the guards work from a copy that is not in a git checkout (as the mutation runner's temp tree is)" {
  local d="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$d/tools"
  cp "$REPO/tools/coverage-py.sh" "$d/tools/"
  run ! git -C "$d" rev-parse --show-toplevel
  fake_python "$BATS_TEST_TMPDIR/system-site"
  mkdir -p "$BATS_TEST_TMPDIR/system-site"
  cd "$d"
  COVERAGE_VENV="$V" run "$d/tools/coverage-py.sh"
  [ "$status" -eq 2 ]
  [[ $output == *"not inside"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/system-site")" ]
  [ ! -e "$d/.cache" ]
}

@test "--shard and --combine outside a git checkout are refused (exit 2), and nothing is written" {
  local d="$BATS_TEST_TMPDIR/nogit2" a
  mkdir -p "$d/tools" "$d/tests"
  cp "$REPO/tools/coverage-py.sh" "$d/tools/"
  run ! git -C "$d" rev-parse --show-toplevel
  fake_python "$V/lib/site"
  cd "$d"
  for a in "--shard 1/2" "--combine 2"; do
    COVERAGE_VENV="$V" run "$d/tools/coverage-py.sh" $a
    [ "$status" -eq 2 ]
    [[ $output == *"need a git checkout"* ]]
    [ ! -e "$d/.cache" ]
  done
}

# --- sharding: a throwaway repo, a stub bats, a stub python/coverage ---

commit_all() { # commit_all MESSAGE: everything in the throwaway repo, as a new head
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --no-verify -m "$1"
}

shard_repo() { # shard_repo [NAMES...]: a repo with the script's files and these bats files
  R=$(mkdir -p "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo" && pwd -P)
  git init -q "$R"
  mkdir -p "$R/tools" "$R/tests"
  cp "$REPO/tools/coverage-py.sh" "$REPO/tools/coverage-py-report.py" "$R/tools/"
  cp "$REPO/tests/run.sh" "$R/tests/"
  cp "$REPO/tools/bats-shards.py" "$R/tools/"
  local n sep="" json="{"
  for n in ${@:-a b c d e}; do
    : > "$R/tests/$n.bats"
    json+="$sep\"$n.bats\": 1"
    sep=", "
  done
  # equal weights: the planner then deals the sorted files out in turn
  printf '%s}\n' "$json" > "$R/tests/bats-times.json"
  # the pinned-bats fetcher, replaced by a stub that records its arguments in the shard's directory
  cat > "$R/tools/get-bats.sh" <<'SH'
#!/usr/bin/env bash
echo "$(dirname "$0")/fake-bats"
SH
  cat > "$R/tools/fake-bats" <<'SH'
#!/usr/bin/env bash
d=$(dirname "$COVERAGE_PROCESS_START")
: > "$d/bats.args"
for a in "$@"; do printf '%s\n' "$(basename "$a")" >> "$d/bats.args"; done
: > "$d/.coverage.stub$$"
exit "${FAKE_BATS_RC:-0}"
SH
  chmod +x "$R/tools/get-bats.sh" "$R/tools/fake-bats"
  commit_all "first"
}

fake_coverage_python() { # a venv python that answers -c (site), -m unittest and -m coverage
  cat > "$V/bin/python" <<'SH'
#!/bin/sh
case $1 in
  -c) echo "$FAKE_SITE" ;;
  -m)
    case $2 in
      unittest) : > "$(dirname "$COVERAGE_PROCESS_START")/unittest.ran"; exit "${FAKE_UNIT_RC:-0}" ;;
      coverage)
        echo "$*" >> "$FAKE_PYLOG"
        if [ "$3" = json ]; then
          while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
          printf '{"files": {"%s/plugins/p/bin/t": {"summary": {"covered_lines": 3, "num_statements": 4, "percent_covered": 75.0}}}}\n' "$FAKE_ROOT" > "$out"
        fi ;;
    esac ;;
esac
SH
  chmod +x "$V/bin/python"
  export FAKE_SITE="$V/lib/site" FAKE_PYLOG="$BATS_TEST_TMPDIR/py.log" FAKE_ROOT="$R"
}

shard() { # shard ARGS...: the script, from inside the throwaway repo
  cd "$R" && COVERAGE_VENV="$V" run "$R/tools/coverage-py.sh" "$@"
}

setup_shards() { shard_repo "$@"; fake_coverage_python; }

@test "--shard rejects 0/2, 3/2, 1/0, 17/17 and junk with exit 2 and a usage line" {
  setup_shards
  local bad
  for bad in 0/2 3/2 1/0 17/17 2/1 x 1 1/ /2 1/2/3 a/b -1/2 1/-2 "1 /2" 001/002 ""; do
    shard --shard "$bad"
    [ "$status" -eq 2 ] || { echo "--shard '$bad' gave $status"; return 1; }
    [[ $output == *"--shard"* ]]
  done
  shard --shard
  [ "$status" -eq 2 ]
  shard --combine 0
  [ "$status" -eq 2 ]
  shard --combine 17
  [ "$status" -eq 2 ]
  shard --combine x
  [ "$status" -eq 2 ]
  shard --frobnicate
  [ "$status" -eq 2 ]
  [ ! -e "$R/.cache" ]
}

@test "--shard accepts 1/1 and 16/16" {
  setup_shards
  shard --shard 1/1
  [ "$status" -eq 0 ]
  [ -f "$R/.cache/coverage-py/shard-1/done" ]
  shard --shard 16/16
  [ "$status" -eq 0 ]
  [ -f "$R/.cache/coverage-py/shard-16/done" ]
}

@test "the shards' bats files cover every file exactly once, in sorted order, i % N == K-1" {
  setup_shards a b c d e f g
  local k all=""
  for k in 1 2 3; do
    shard --shard "$k/3"
    [ "$status" -eq 0 ]
    all+=$(tr '\n' ' ' < "$R/.cache/coverage-py/shard-$k/bats.args")$'\n'
  done
  [ "$(sed -n 1p <<<"$all")" = "a.bats d.bats g.bats " ]
  [ "$(sed -n 2p <<<"$all")" = "b.bats e.bats " ]
  [ "$(sed -n 3p <<<"$all")" = "c.bats f.bats " ]
}

@test "the shards come from tools/bats-shards.py: a heavy file in tests/bats-times.json has a shard to itself" {
  setup_shards a b c d
  printf '{"a.bats": 100, "b.bats": 1, "c.bats": 1, "d.bats": 1}\n' > "$R/tests/bats-times.json"
  commit_all "times"
  shard --shard 1/2
  [ "$status" -eq 0 ]
  [ "$(cat "$R/.cache/coverage-py/shard-1/bats.args")" = "a.bats" ]
  shard --shard 2/2
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$R/.cache/coverage-py/shard-2/bats.args")" = "b.bats c.bats d.bats " ]
}

@test "a shard passes its files only: not the whole tests directory" {
  setup_shards a b c
  shard --shard 2/2
  [ "$status" -eq 0 ]
  [ "$(cat "$R/.cache/coverage-py/shard-2/bats.args")" = "b.bats" ]
}

@test "the bats files are sorted bytewise, not by the locale" {
  setup_shards B a
  LC_ALL=en_US.UTF-8 shard --shard 1/2
  [ "$status" -eq 0 ]
  [ "$(cat "$R/.cache/coverage-py/shard-1/bats.args")" = "B.bats" ]
}

@test "a shard with no bats files runs none, still passes and is marked complete" {
  setup_shards a
  shard --shard 3/4
  [ "$status" -eq 0 ]
  [ ! -e "$R/.cache/coverage-py/shard-3/bats.args" ]
  [ -f "$R/.cache/coverage-py/shard-3/done" ]
}

@test "the Python unit tests run in shard 1 only" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; [ "$status" -eq 0 ]; done
  [ -f "$R/.cache/coverage-py/shard-1/unittest.ran" ]
  [ ! -e "$R/.cache/coverage-py/shard-2/unittest.ran" ]
  [ ! -e "$R/.cache/coverage-py/shard-3/unittest.ran" ]
}

@test "a shard has its own coveragerc and data file, writes no report, and installs the hook" {
  setup_shards
  shard --shard 2/3
  [ "$status" -eq 0 ]
  local d=$R/.cache/coverage-py/shard-2
  grep -qxF "data_file = $d/.coverage" "$d/coveragerc"
  grep -qxF "include = $R/plugins/*/bin/*" "$d/coveragerc"
  [ -f "$d/bats.log" ]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
  [ ! -e "$R/.cache/coverage-py/coveragerc" ]
  [ "$(cat "$V/lib/site/crewkit-coverage.pth")" = "import coverage; coverage.process_startup()" ]
  [ ! -e "$BATS_TEST_TMPDIR/py.log" ]
}

@test "a shard leaves the other shards' directories alone, and replaces only its own" {
  setup_shards a b
  mkdir -p "$R/.cache/coverage-py/shard-2" "$R/.cache/coverage-py/shard-1"
  : > "$R/.cache/coverage-py/shard-2/done"
  : > "$R/.cache/coverage-py/shard-2/.coverage.keep"
  : > "$R/.cache/coverage-py/shard-1/.coverage.stale"
  shard --shard 1/3
  [ "$status" -eq 0 ]
  [ -f "$R/.cache/coverage-py/shard-2/done" ]
  [ -f "$R/.cache/coverage-py/shard-2/.coverage.keep" ]
  [ ! -e "$R/.cache/coverage-py/shard-1/.coverage.stale" ]
}

@test "a failing shard exits 1, names its log, and leaves no completion marker" {
  setup_shards a b
  shard --shard 1/2
  [ -f "$R/.cache/coverage-py/shard-1/done" ]
  FAKE_BATS_RC=1 shard --shard 1/2
  [ "$status" -eq 1 ]
  [[ $output == *"shard-1/bats.log"* ]]
  [ ! -e "$R/.cache/coverage-py/shard-1/done" ]
  FAKE_UNIT_RC=1 shard --shard 1/2
  [ "$status" -eq 1 ]
  [[ $output == *"shard-1/unittest.log"* ]]
  [ ! -e "$R/.cache/coverage-py/shard-1/done" ]
}

@test "--combine refuses a missing shard, naming it, and writes no report" {
  setup_shards a b c
  shard --shard 1/3; shard --shard 3/3
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2 is missing"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses a shard without its completion marker" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; done
  rm "$R/.cache/coverage-py/shard-2/done"
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2 did not finish"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses when no shard has run" {
  setup_shards
  shard --combine 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard-1"* ]]
}

@test "--combine merges every shard's data and writes report.json as an unsharded run does" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; [ "$status" -eq 0 ]; done
  shard --combine 3
  [ "$status" -eq 0 ]
  [[ $output == *"coverage-py report: .cache/coverage-py/report.json"* ]]
  [[ $output == *"  75.00%  plugins/p/bin/t"* ]]
  python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["files"]; assert [x["file"] for x in f]==["plugins/p/bin/t"]' \
    "$R/.cache/coverage-py/report.json"
  grep -F -- "combine" "$BATS_TEST_TMPDIR/py.log" | grep -q -- "--keep"
  local c; c=$(grep -F -- "combine" "$BATS_TEST_TMPDIR/py.log")
  for k in 1 2 3; do [[ $c == *"shard-$k"* ]]; done
  grep -qxF "include = $R/plugins/*/bin/*" "$R/.cache/coverage-py/coveragerc"
  # the shards' data is kept, so a combine can be run again
  [ -f "$R/.cache/coverage-py/shard-1/done" ]
  ls -A "$R/.cache/coverage-py/shard-2" | grep -q '^.coverage.stub'
}

@test "--combine compares the shards' files with tests/*.bats bytewise: B and a, in a locale that sorts them the other way" {
  setup_shards B a
  local k
  for k in 1 2; do shard --shard "$k/2"; [ "$status" -eq 0 ]; done
  LC_ALL=en_US.UTF-8 shard --combine 2
  [ "$status" -eq 0 ]
}

@test "--combine needs only the shards it names" {
  setup_shards a b
  shard --shard 1/2; shard --shard 2/2
  mkdir "$R/.cache/coverage-py/shard-3"
  shard --combine 2
  [ "$status" -eq 0 ]
}

@test "no arguments: the unsharded run is unchanged (one directory, every suite, a report)" {
  setup_shards a b
  mkdir -p "$R/.cache/coverage-py/shard-1"
  shard
  [ "$status" -eq 0 ]
  [[ $output == *"  75.00%  plugins/p/bin/t"* ]]
  [ ! -e "$R/.cache/coverage-py/shard-1" ]
  [ -f "$R/.cache/coverage-py/report.json" ]
  [ -f "$R/.cache/coverage-py/bats.log" ]
  [ -f "$R/.cache/coverage-py/unittest.log" ]
  grep -qxF "data_file = $R/.cache/coverage-py/.coverage" "$R/.cache/coverage-py/coveragerc"
  # every suite: bats got the tests directory, not a list of files
  [ "$(cat "$R/.cache/coverage-py/bats.args")" = "tests" ]
  [ -f "$R/.cache/coverage-py/unittest.ran" ]
}

@test "tests/run.sh: bats files given as arguments replace the tests directory, flags do not" {
  setup_shards a b
  local bin=$BATS_TEST_TMPDIR/args
  cat > "$R/tools/fake-bats" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$bin"
SH
  cd "$R"
  run tests/run.sh --abort "$R/tests/a.bats"
  [ "$status" -eq 0 ]
  [ "$(cat "$bin")" = "--abort
$R/tests/a.bats" ]
  run tests/run.sh --abort
  [ "$status" -eq 0 ]
  [ "$(cat "$bin")" = "--abort
$R/tests" ]
}

@test "--combine refuses shards left from a run with a different N" {
  setup_shards a b c d e
  local k
  for k in 1 2; do shard --shard "$k/2"; done
  shard --shard 1/3; shard --shard 3/3
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2"* ]]
  [[ $output == *"N"* || $output == *"shards"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses shards from different commits" {
  setup_shards a b c
  shard --shard 1/3; shard --shard 2/3
  : > "$R/tests/zz.txt"; commit_all "second"
  shard --shard 3/3
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"commit"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses shards that all ran at an older commit than this checkout" {
  setup_shards a b
  shard --shard 1/2; shard --shard 2/2
  : > "$R/tests/zz.txt"; commit_all "second"
  shard --combine 2
  [ "$status" -eq 1 ]
  [[ $output == *"commit"* ]]
}

@test "--combine refuses when a bats file ran in no shard" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; done
  : > "$R/tests/f.bats"
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"f.bats"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses when a shard ran a file this checkout does not have" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; done
  rm "$R/tests/c.bats"
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"c.bats"* ]]
}

@test "--combine refuses a bats file that ran in two shards" {
  setup_shards a b c
  local k
  for k in 1 2 3; do shard --shard "$k/3"; done
  echo "file=a.bats" >> "$R/.cache/coverage-py/shard-2/done"
  shard --combine 3
  [ "$status" -eq 1 ]
  [[ $output == *"a.bats"* ]]
}

@test "--combine refuses a shard directory holding data from another run" {
  setup_shards a b
  shard --shard 1/2; shard --shard 2/2
  : > "$R/.cache/coverage-py/shard-2/.coverage.old-run"
  shard --combine 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 2"* && $output == *".coverage.old-run"* ]]
  [ ! -e "$R/.cache/coverage-py/report.json" ]
}

@test "--combine refuses a shard whose recorded data file is gone" {
  setup_shards a b
  shard --shard 1/2; shard --shard 2/2
  rm "$R/.cache/coverage-py/shard-1"/.coverage.stub*
  shard --combine 2
  [ "$status" -eq 1 ]
  [[ $output == *"shard 1"* ]]
}

@test "the partition covers every file once for every N, at several file counts" {
  local count n k
  for count in 0 1 5 17; do
    rm -rf "$BATS_TEST_TMPDIR/repo"
    local names="" i
    for ((i = 0; i < count; i++)); do names+=$(printf 'f%02d ' "$i"); done
    shard_repo $names
    [ "$count" -gt 0 ] || rm -f "$R"/tests/*.bats
    fake_coverage_python
    for n in 1 2 3 7 16; do
      rm -rf "$R/.cache"
      local seen=""
      for ((k = 1; k <= n; k++)); do
        shard --shard "$k/$n"
        [ "$status" -eq 0 ]
        [ ! -e "$R/.cache/coverage-py/shard-$k/bats.args" ] || seen+=$(cat "$R/.cache/coverage-py/shard-$k/bats.args")$'\n'
      done
      [ "$(printf '%s' "$seen" | grep -c .)" -eq "$count" ]
      [ "$(printf '%s' "$seen" | grep . | sort -u | wc -l | tr -d ' ')" -eq "$count" ]
      shard --combine "$n"
      [ "$status" -eq 0 ]
    done
  done
}

@test "tests/run.sh: a flag value ending in .bats is not a file" {
  setup_shards a
  local bin=$BATS_TEST_TMPDIR/args
  cat > "$R/tools/fake-bats" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$bin"
SH
  cd "$R"
  run tests/run.sh --filter nothing.bats
  [ "$status" -eq 0 ]
  [ "$(cat "$bin")" = "--filter
nothing.bats
$R/tests" ]
}

# scale_repo: a scratch repo with the real script and a tests/run.sh that records the scale it sees.
scale_repo() {
  T="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$T/tools" "$T/tests"
  cp "$REPO/tools/coverage-py.sh" "$T/tools/"
  printf '#!/bin/sh\nprintf "%%s\\n" "${CREWKIT_TEST_TIME_SCALE-unset}" > "%s/seen"\n' "$BATS_TEST_TMPDIR" > "$T/tests/run.sh"
  chmod +x "$T/tests/run.sh"
  git -C "$T" init -q
  fake_python "$V/lib/site"
}

@test "the suites run with CREWKIT_TEST_TIME_SCALE=10 (the coverage lane), unless one is set" {
  scale_repo
  cd "$T"
  env -u CREWKIT_TEST_TIME_SCALE COVERAGE_VENV="$V" "$T/tools/coverage-py.sh" || true
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = 10 ]
  CREWKIT_TEST_TIME_SCALE=3 COVERAGE_VENV="$V" "$T/tools/coverage-py.sh" || true
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = 3 ]
}

@test "the plain lane sets no time scale: neither tests/run.sh nor the workflow mention it" {
  run grep -n CREWKIT_TEST_TIME_SCALE "$REPO/tests/run.sh" "$REPO/.github/workflows/ci.yml"
  [ "$status" -eq 1 ]
}
