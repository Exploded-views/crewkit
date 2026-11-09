#!/usr/bin/env bash
# coverage-py.sh: line coverage of the plugins' Python tools (plugins/*/bin/*) under coverage.py,
# measured while the bats suites and the Python unit tests run them as subprocesses. Writes
# .cache/coverage-py/report.json in the shape tools/coverage-floors.py reads.
#
#   COVERAGE_VENV=<venv with coverage installed> tools/coverage-py.sh
#
# To split the run across machines (a slot's time cap): run `tools/coverage-py.sh --shard K/N` for
# each K in 1..N (1 <= K <= N <= 16), on any machines, then `tools/coverage-py.sh --combine N` with
# every shard's directory .cache/coverage-py/shard-K/ in place. A shard runs its share of the bats files
# (tests/*.bats split by measured file time: tools/bats-shards.py) and, in shard 1, the Python unit tests; it
# writes its data and logs under shard-K/ and a `done` marker on success, and no report. --combine
# refuses (exit 1) a missing, unfinished or stale shard (the marker records N, K, the commit, the bats
# files and the data files of the run) and writes report.json as the unsharded run does.
#
# CI makes the venv and installs coverage.py from tools/requirements-coverage.txt (pinned by
# sha256, --require-hashes) on the hosted runner. The script adds a startup hook (a .pth file) to
# that venv's site-packages, so every Python the suites start from the venv is measured; it
# refuses a venv whose site-packages lies outside it, so it never writes to a system Python.
# The repo root is taken from this script's own place (tools/..), not from git, so the guards
# also work in a copy that has no .git (the mutation runner's temp tree); sharding needs a checkout.
# Exit 0 = report written (or, for a shard, its suites passed), 1 = the suites failed or a shard
# is missing, 2 = usage.
set -euo pipefail
mode=all shard_k=0 shard_n=0
usage() { echo "coverage-py: usage: tools/coverage-py.sh [--shard K/N | --combine N]  (1 <= K <= N <= 16)" >&2; exit 2; }
case ${1:-} in
  "") [[ $# -eq 0 ]] || usage ;;
  --shard)
    [[ $# -eq 2 && $2 =~ ^([0-9]{1,2})/([0-9]{1,2})$ ]] || usage
    shard_k=$((10#${BASH_REMATCH[1]})) shard_n=$((10#${BASH_REMATCH[2]}))
    ((shard_k >= 1 && shard_k <= shard_n && shard_n <= 16)) || usage
    mode=shard ;;
  --combine)
    [[ $# -eq 2 && $2 =~ ^[0-9]{1,2}$ ]] || usage
    shard_n=$((10#$2))
    ((shard_n >= 1 && shard_n <= 16)) || usage
    mode=combine ;;
  *) usage ;;
esac
venv=${COVERAGE_VENV:-}
[[ -n $venv && -x $venv/bin/python ]] ||
  { echo "coverage-py: set COVERAGE_VENV to a venv with coverage installed (tools/requirements-coverage.txt)" >&2; exit 2; }
venv=$(cd "$venv" && pwd -P)
root=$(cd "$(dirname "$0")/.." && pwd -P)
if [[ $mode != all ]]; then
  git -C "$root" rev-parse HEAD > /dev/null 2>&1 ||
    { echo "coverage-py: --shard/--combine need a git checkout" >&2; exit 2; }
fi
site=$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
site=$(cd "$site" 2>/dev/null && pwd -P) || site=""
[[ -n $site && $site == "$venv"/* ]] ||
  { echo "coverage-py: the venv's site-packages (${site:-unknown}) is not inside $venv; refusing to add a startup hook there" >&2; exit 2; }

out=$root/.cache/coverage-py
rc_text() { # rc_text DATA_FILE
  printf '[run]\nparallel = True\ndata_file = %s\ninclude = %s\n' "$1" "$root/plugins/*/bin/*"
}

# bats_list: the tests/*.bats names, in byte order (the same on every machine).
bats_list() {
  local f
  for f in "$root"/tests/*.bats; do if [[ -e $f ]]; then echo "${f##*/}"; fi; done | LC_ALL=C sort
}

# data_files DIR: the coverage data files in DIR (.coverage*), by name, in byte order.
data_files() {
  local f
  for f in "$1"/.coverage*; do if [[ -e $f ]]; then echo "${f##*/}"; fi; done | LC_ALL=C sort
}

die() { echo "coverage-py: $*" >&2; exit 1; }

# marker_field MARKER KEY: the values of KEY= lines in a shard's done marker.
marker_field() { sed -n "s/^$2=//p" "$1"; }

# check_shards: every shard 1..N has a done marker from a run of this N, at this commit, whose
# data files are exactly the ones in its directory; and the shards' bats files, together, are
# exactly tests/*.bats, each once. Dies (exit 1) naming what is wrong.
check_shards() {
  local k d m head listed actual all dup expected
  head=$(git -C "$root" rev-parse HEAD)
  all=""
  for ((k = 1; k <= shard_n; k++)); do
    d=$out/shard-$k m=$out/shard-$k/done
    if [[ ! -f $m ]]; then
      if [[ -d $d ]]; then
        die "shard $k did not finish (no ${m#"$root"/}); run --shard $k/$shard_n again"
      fi
      die "shard $k is missing (${d#"$root"/} does not exist); run --shard $k/$shard_n"
    fi
    [[ $(marker_field "$m" n) == "$shard_n" && $(marker_field "$m" k) == "$k" ]] ||
      die "shard $k was run as shard $(marker_field "$m" k)/$(marker_field "$m" n), not $k/$shard_n (an older run's N?); run --shard $k/$shard_n again"
    [[ $(marker_field "$m" sha) == "$head" ]] ||
      die "shard $k ran at commit $(marker_field "$m" sha), this checkout is at $head; run --shard $k/$shard_n again"
    listed=$(marker_field "$m" data | LC_ALL=C sort)
    actual=$(data_files "$d")
    [[ $listed == "$actual" ]] ||
      die "shard $k's data files are not the ones its run wrote (marker lists: $(tr '\n' ' ' <<<"$listed"); directory has: $(tr '\n' ' ' <<<"$actual")); run --shard $k/$shard_n again into a clean directory"
    all+=$(marker_field "$m" file)$'\n'
  done
  dup=$(printf '%s' "$all" | grep . | LC_ALL=C sort | uniq -d | head -3 | tr '\n' ' ') || true
  [[ -z $dup ]] || die "bats files run by more than one shard: $dup"
  expected=$(bats_list)
  [[ $(printf '%s' "$all" | grep . | LC_ALL=C sort || true) == "$expected" ]] ||
    die "the shards' bats files are not tests/*.bats of this checkout (differing: $(diff <(printf '%s' "$all" | grep . | LC_ALL=C sort || true) <(echo "$expected") | sed -n 's/^[<>] //p' | tr '\n' ' '))"
}

# report: combine the data under $out into $out/report.json and print the per-file lines. The
# shards' directories are kept (--keep), so a combine can be run again.
report() {
  "$venv/bin/python" -m coverage combine --rcfile "$out/coveragerc" -q "$@"
  "$venv/bin/python" -m coverage json --rcfile "$out/coveragerc" -o "$out/coverage-py.json" -q
  python3 "$root/tools/coverage-py-report.py" "$out/coverage-py.json" "$out/report.json" "$root"
  echo "coverage-py report: ${out#"$root"/}/report.json"
  python3 - "$out/report.json" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print("  %6s%%  %s" % (f["percent_covered"], f["file"]))
PY
}

if [[ $mode == combine ]]; then
  check_shards
  mkdir -p "$out"
  rm -f "$out"/.coverage "$out"/.coverage.* "$out/report.json" "$out/coverage-py.json"
  rc_text "$out/.coverage" > "$out/coveragerc"
  # The files the markers list, no more (check_shards saw the directories hold nothing else).
  data=()
  for ((k = 1; k <= shard_n; k++)); do
    while IFS= read -r f; do data+=("$out/shard-$k/$f"); done < <(marker_field "$out/shard-$k/done" data)
  done
  report --keep ${data[@]+"${data[@]}"}
  exit 0
fi

printf 'import coverage; coverage.process_startup()\n' > "$site/crewkit-coverage.pth"
if [[ $mode == shard ]]; then
  # Only this shard's own directory is replaced; the others' data stays.
  dir=$out/shard-$shard_k
  rm -rf "$dir"
  mkdir -p "$dir"
  # This shard's bats files, split by measured file time (tools/bats-shards.py, tests/bats-times.json;
  # the same on every machine).
  bats_files=()
  planned=$(python3 -I "$root/tools/bats-shards.py" --root "$root" files "$shard_k/$shard_n") ||
    die "cannot plan the bats shards (tools/bats-shards.py)"
  while IFS= read -r f; do
    [[ -z $f ]] || bats_files+=("$root/tests/$f")
  done <<<"$planned"
else
  dir=$out
  rm -rf "$out"
  mkdir -p "$out"
fi
rc_text "$dir/.coverage" > "$dir/coveragerc"
export COVERAGE_PROCESS_START=$dir/coveragerc
# This lane runs the suites with a startup hook in every Python (and emulated, linux/amd64 on an arm host, in the local gate)
# Python, so the memory-notices timing windows need room: CREWKIT_TEST_TIME_SCALE widens only the
# windows (see tests/memory-notices-helpers.bash), never what is asserted. Only the coverage lanes set it.
export CREWKIT_TEST_TIME_SCALE=${CREWKIT_TEST_TIME_SCALE:-10}
# The tools' shebang is `#!/usr/bin/env python3`, so the venv first on PATH runs them.
if [[ $mode == shard && ${#bats_files[@]} -eq 0 ]]; then
  echo "no bats files in this shard" > "$dir/bats.log"
elif ! PATH="$venv/bin:$PATH" "$root/tests/run.sh" ${bats_files[@]+"${bats_files[@]}"} >"$dir/bats.log" 2>&1; then
  grep -E '^(not ok|# )' "$dir/bats.log" | head -40 || tail -20 "$dir/bats.log"
  echo "coverage-py: the suites failed (full output: ${dir#"$root"/}/bats.log)"
  exit 1
fi
# The Python unit tests start some tools themselves (shared-index, with sys.executable), so they
# run with the venv's Python too. A sharded run does them once, in shard 1.
if [[ $mode == all || $shard_k -eq 1 ]]; then
  if ! (cd "$root" && "$venv/bin/python" -m unittest discover -s tests -p 'test_*.py') >"$dir/unittest.log" 2>&1; then
    tail -20 "$dir/unittest.log"
    echo "coverage-py: the unit tests failed (full output: ${dir#"$root"/}/unittest.log)"
    exit 1
  fi
fi
if [[ $mode == shard ]]; then
  # The marker says which run wrote this directory: its N and K, the commit, the run id, the
  # bats files it ran and the data files it wrote. --combine checks all of it.
  {
    echo "n=$shard_n"
    echo "k=$shard_k"
    echo "sha=$(git -C "$root" rev-parse HEAD)"
    echo "run=$(date +%s)-$$-$RANDOM"
    for f in ${bats_files[@]+"${bats_files[@]}"}; do echo "file=${f##*/}"; done
    data_files "$dir" | sed 's/^/data=/'
  } > "$dir/done.tmp"
  mv "$dir/done.tmp" "$dir/done"
  echo "coverage-py: shard $shard_k/$shard_n done (${#bats_files[@]} bats files): ${dir#"$root"/}"
  exit 0
fi
report
