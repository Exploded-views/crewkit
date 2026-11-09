#!/usr/bin/env bash
# coverage.sh: run the bats suites under kcov (in its container, as your user, unprivileged,
# with no network and the repo mounted read-only) and write .cache/coverage. Then check the
# floors:
#   tools/coverage-floors.py --report .cache/coverage/bats.*/coverage.json
#
# It covers install.sh, the crewkit CLI (bin/crewkit, libexec/), the push gate (push-gate/) and
# the plugins' bash scripts (plugins/crew-*/bin and lib). The suites need git, jq and ps (procps;
# bats enforces BATS_TEST_TIMEOUT with ps), which the kcov image lacks, so CI builds a derived image
# on the runner and passes it as KCOV_IMAGE (see .github/workflows/ci.yml); locally, set KCOV_IMAGE
# to an image with git, jq and procps added. An image without ps is refused up front.
#
# To split the run (hosted CI does, in a matrix):
#   tools/coverage.sh --shard K/N   run shard K of N (1 <= K <= N <= 16) of the suites under kcov: the
#                                   bats files tools/bats-shards.py gives it, minus docs.bats and
#                                   settings.bats, into .cache/coverage-shards/shard-K, with a `done`
#                                   marker (N, K, the commit, the suites) on success. Only that directory
#                                   is replaced and mounted writable.
#   tools/coverage.sh --merge N     check that shards 1..N are all done, from this commit, and that their
#                                   suites together are exactly tests/*.bats minus the two; merge them with
#                                   `kcov --merge` in the PINNED image (it needs no git, jq or ps, so no
#                                   apt), and write .cache/coverage/bats.merged/coverage.json, where the
#                                   floors look.
# Exit 0 = ok, 1 = a suite or the merge failed or a shard is missing, 2 = usage.
set -euo pipefail
# kcov/kcov "latest" as of 2026-04-02 (kcov v44-pre), pinned by digest. Bump on purpose.
pinned=kcov/kcov@sha256:481289ae32e55e5b733019515acd10948a4f76dfed381765577db909664fc603  # scrub:pinned-hash
# --pinned-image prints the pinned image, so CI derives its image from this one line.
if [[ ${1:-} == --pinned-image ]]; then echo "$pinned"; exit 0; fi
mode=all shard_k=0 shard_n=0
usage() { echo "coverage: usage: tools/coverage.sh [--shard K/N | --merge N]  (1 <= K <= N <= 16)" >&2; exit 2; }
case ${1:-} in
  --shard)
    [[ $# -eq 2 && $2 =~ ^([0-9]{1,2})/([0-9]{1,2})$ ]] || usage
    shard_k=$((10#${BASH_REMATCH[1]})) shard_n=$((10#${BASH_REMATCH[2]}))
    ((shard_k >= 1 && shard_k <= shard_n && shard_n <= 16)) || usage
    mode=shard ;;
  --merge)
    [[ $# -eq 2 && $2 =~ ^[0-9]{1,2}$ ]] || usage
    shard_n=$((10#$2))
    ((shard_n >= 1 && shard_n <= 16)) || usage
    mode=merge ;;
esac
# Every suite except these runs under kcov. kcov's bash trace hook reads BASH_SOURCE, which is
# unset under `bash -u -c`, so suites that run `bash -euc` or `bash -c "set -u ..."` fail under
# it (tests/run.sh still runs every suite normally):
#   docs.bats      runs the setup pages' snippets with bash -euc
#   settings.bats  runs lookups under set -euo pipefail in bash -c (lib/settings.sh is still
#                  covered through the plugin scripts that source it)
skip=" docs.bats settings.bats "
image=${KCOV_IMAGE:-$pinned}

# guard_cache ROOT [EXTRA...]: what this removes and writes (and mounts writable) must be inside the
# repository: refuse a .cache, .cache/coverage, .cache/coverage-shards or log that is a symlink (a
# branch can commit one), or a .cache that resolves outside the root.
guard_cache() {
  local root=$1 d
  # The resolve check first: it is the one that names a .cache leading out of the repository (a symlink, or
  # anything else pwd -P resolves elsewhere); the loop then refuses any remaining link, including one inside.
  if [[ -e $root/.cache && $(cd "$root/.cache" && pwd -P) != "$(cd "$root" && pwd -P)/.cache" ]]; then
    echo "coverage: $root/.cache resolves outside the repository; refusing"; exit 1
  fi
  for d in "$root/.cache" "$root/.cache/coverage" "$root/.cache/coverage-shards" "$root/.cache/coverage.log" "$root/.cache/passwd" "${@:2}"; do
    if [[ -L $d ]]; then echo "coverage: $d is a symlink; refusing to remove or write through it"; exit 1; fi
  done
}

# report_lines FILE: one line per covered file, so a new script's first floor can be read from the log.
report_lines() {
  python3 -I - "$1" <<'PY'
import json, sys
for f in sorted(json.load(open(sys.argv[1]))["files"], key=lambda f: f["file"]):
    print("  %6s%%  %s" % (f["percent_covered"], f["file"].split("/src/", 1)[-1]))
PY
}

# fold_twins MERGED ROOT: write MERGED/coverage.json from kcov's merged report, with the hits of identical
# files put back on one path. kcov credits all the hits of identical files (the three plugins' lib/settings.sh
# are one) to the one it met first in a run, so in one run's report the first has them all and the others have
# none, but in the merge of several runs each run's first is another file and the hits are spread over them.
# An unsharded run and a merged one would then give different numbers for the same path, and the floors are per
# path. So: files of the same content (sha256) form a group; the group's covered lines are the union over its
# members (kcov's codecov.json has the hits per line); the first path by name holds them, the others none.
fold_twins() {
  python3 -I - "$1" "$2" <<'PY'
import hashlib, json, os, sys

merged, root = sys.argv[1], sys.argv[2]
kdir = os.path.join(merged, "kcov-merged")
try:
    report = json.load(open(os.path.join(kdir, "coverage.json")))
except (OSError, ValueError):
    print("coverage: kcov --merge wrote no coverage.json")
    sys.exit(1)
try:
    hits = json.load(open(os.path.join(kdir, "codecov.json")))["coverage"]
except (OSError, ValueError, KeyError):
    print("coverage: kcov --merge wrote no codecov.json (the hits per line)")
    sys.exit(1)

groups = {}
for f in report["files"]:
    rel = f["file"].split("/src/", 1)[-1]
    try:
        with open(os.path.join(root, rel), "rb") as src:
            digest = hashlib.sha256(src.read()).hexdigest()
    except OSError:
        print(f"coverage: {rel} is in the merged report but is not a file of the repository")
        sys.exit(1)
    groups.setdefault(digest, []).append((rel, f))

for members in groups.values():
    if len(members) < 2:
        continue
    members.sort(key=lambda m: m[0])
    union = set()
    for rel, _ in members:
        union |= {int(n) for n, h in hits.get(rel, {}).items() if h > 0}
    for i, (_, f) in enumerate(members):
        covered = len(union) if i == 0 else 0
        total = int(f["total_lines"])
        f["covered_lines"] = str(covered)
        f["percent_covered"] = "%.2f" % (100.0 * covered / total) if total else "0.00"

# (kcov's totals for the whole run are not read by anything: the floors are per file)
with open(os.path.join(merged, "coverage.json"), "w") as out:
    json.dump(report, out)
PY
}

if [[ $mode == merge ]]; then
  root=$(git rev-parse --show-toplevel)
  guard_cache "$root" "$root/.cache/coverage-merge.log"
  shards=$root/.cache/coverage-shards
  head=$(git -C "$root" rev-parse HEAD)
  all=""
  for ((k = 1; k <= shard_n; k++)); do
    d=$shards/shard-$k m=$shards/shard-$k/done
    if [[ ! -f $m ]]; then
      if [[ -d $d ]]; then
        echo "coverage: shard $k did not finish (no ${m#"$root"/}); run --shard $k/$shard_n again"
      else
        echo "coverage: shard $k is missing (${d#"$root"/} does not exist); run --shard $k/$shard_n"
      fi
      exit 1
    fi
    if [[ $(sed -n 's/^n=//p' "$m") != "$shard_n" || $(sed -n 's/^k=//p' "$m") != "$k" ]]; then
      echo "coverage: shard $k was run as shard $(sed -n 's/^k=//p' "$m")/$(sed -n 's/^n=//p' "$m"), not $k/$shard_n; run --shard $k/$shard_n again"
      exit 1
    fi
    if [[ $(sed -n 's/^sha=//p' "$m") != "$head" ]]; then
      echo "coverage: shard $k ran at commit $(sed -n 's/^sha=//p' "$m"), this checkout is at $head; run --shard $k/$shard_n again"
      exit 1
    fi
    # a shard that ran suites left kcov's data: a marker alone would let kcov --merge succeed on nothing
    if [[ -n $(sed -n 's/^file=//p' "$m") ]] && ! ls "$d"/*/coverage.json > /dev/null 2>&1; then
      echo "coverage: shard $k has no kcov data (no ${d#"$root"/}/*/coverage.json); run --shard $k/$shard_n again"
      exit 1
    fi
    all+=$(sed -n 's/^file=//p' "$m")$'\n'
  done
  expected=""
  for f in "$root"/tests/*.bats; do
    [[ -e $f ]] || continue
    [[ $skip == *" ${f##*/} "* ]] || expected+="${f##*/}"$'\n'
  done
  have=$(printf '%s' "$all" | grep . | LC_ALL=C sort || true)
  want=$(printf '%s' "$expected" | grep . | LC_ALL=C sort || true)
  if [[ $have != "$want" ]]; then
    echo "coverage: the shards' suites are not exactly tests/*.bats minus docs and settings (differing: $(diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") | sed -n 's/^[<>] //p' | tr '\n' ' '))"
    exit 1
  fi
  log=$root/.cache/coverage-merge.log
  rm -rf "$root/.cache/coverage"
  mkdir -p "$root/.cache/coverage"
  inputs=()
  for ((k = 1; k <= shard_n; k++)); do inputs+=("/src/.cache/coverage-shards/shard-$k"); done
  if ! docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$root:/src:ro" -v "$root/.cache/coverage:/src/.cache/coverage" -w /src "$pinned" \
    kcov --merge /src/.cache/coverage/bats.merged "${inputs[@]}" >"$log" 2>&1; then
    tail -20 "$log"
    rm -rf "$root/.cache/coverage/bats.merged"
    echo "coverage: kcov --merge failed (full output: ${log#"$root"/})"
    exit 1
  fi
  merged=$root/.cache/coverage/bats.merged
  # (fold_twins also reports a merge that wrote no coverage.json)
  if ! folded=$(fold_twins "$merged" "$root"); then
    rm -rf "$merged"
    echo "$folded"
    exit 1
  fi
  echo "coverage report: .cache/coverage/bats.merged/coverage.json"
  report_lines "$merged/coverage.json"
  exit 0
fi
# bats enforces BATS_TEST_TIMEOUT by running `ps -Ao pid,ppid,args` under bash; without ps every
# test with a timeout errors and the run ends short. Run that call in the image and refuse it
# before anything is wiped or run: exit 3 means ps is missing, any other status is docker or the
# image failing (docker's own message is kept).
set +e
probe_err=$(docker run --rm --network none --entrypoint bash "$image" \
  -c 'ps -Ao pid,ppid,args >/dev/null || exit 3' 2>&1 >/dev/null)
probe=$?
set -e
if [[ $probe -eq 3 ]]; then
  echo "coverage: $image has no ps; bats needs it for BATS_TEST_TIMEOUT (install procps in the kcov image)"
  exit 1
elif [[ $probe -ne 0 ]]; then
  echo "coverage: could not run $image (docker exit $probe)"
  [[ -z $probe_err ]] || echo "$probe_err"
  exit 1
fi
root=$(git rev-parse --show-toplevel)
# This script's own get-bats.sh, never the scanned repo's: when the gate runs it against a clone it
# finds the clone's .cache from the current directory and runs none of the clone's code.
bats=$("$(dirname "${BASH_SOURCE[0]}")/get-bats.sh")
suites=()
if [[ $mode == shard ]]; then
  # This shard's suites, from this script's own planner (never the scanned repo's) and the repo's times table.
  guard_cache "$root" "$root/.cache/coverage-shards/shard-$shard_k.log"
  planned=$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/bats-shards.py" --root "$root" files "$shard_k/$shard_n") || exit 1
  while IFS= read -r f; do
    [[ -z $f || $skip == *" $f "* ]] || suites+=("tests/$f")
  done <<<"$planned"
  out=/src/.cache/coverage-shards/shard-$shard_k
  outdir=$root/.cache/coverage-shards/shard-$shard_k
  mounts=(-v "$outdir:$out")
  log="$root/.cache/coverage-shards/shard-$shard_k.log"
  # Only this shard's own directory is replaced; the other shards' data stays.
  rm -rf "$outdir"
  mkdir -p "$outdir"
else
  log="$root/.cache/coverage.log"
  guard_cache "$root"
  rm -rf "$root/.cache/coverage"
  mkdir -p "$root/.cache/coverage"
  for f in "$root"/tests/*.bats; do
    [[ $skip == *" ${f##*/} "* ]] || suites+=("tests/${f##*/}")
  done
  out=/src/.cache/coverage
  mounts=(-v "$root/.cache/coverage:/src/.cache/coverage")
fi
# kcov's bash tracer echoes traced lines, so the full output goes to a log.
# No network, the repo read-only; only the report directory is writable. A BATS_TEST_TIMEOUT
# that is set (tools/linux-gate.sh sets it) reaches the suites, so a hung test fails here too.
# KCOV_NAME, when set, names the container (tools/linux-gate.sh kills it by name at its time limit).
# kcov's bash tracer makes every step slower and the lane runs beside other heavy jobs, so the
# memory-notices timing windows are widened (CREWKIT_TEST_TIME_SCALE; only the windows, never what
# is asserted). Only the coverage lanes set it; the plain lane gates at scale 1.
# --init puts tini at PID 1 to reap orphans, as a real host's init does; kcov as PID 1 never reaps,
# so killed processes stay zombies and the suites' "nothing left behind" checks (kill -0) fail.
# ssh-keygen needs the uid in passwd, which the image lacks: mount one (root, and the caller as t, home /tmp).
mkdir -p "$root/.cache"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/.cache/passwd"
(($(id -u) == 0)) || printf 't:x:%s:%s:gate:/tmp:/bin/sh\n' "$(id -u)" "$(id -g)" >> "$root/.cache/passwd"
if [[ $mode == shard && ${#suites[@]} -eq 0 ]]; then
  # a share made only of the two suites kcov cannot run: nothing to run, still marked done
  echo "no suites to run under kcov in this shard" > "$log"
elif ! docker run --rm --init --network none --user "$(id -u):$(id -g)" -e HOME=/tmp ${KCOV_NAME:+--name "$KCOV_NAME"} \
  -e CREWKIT_TEST_TIME_SCALE="${CREWKIT_TEST_TIME_SCALE:-4}" \
  ${BATS_TEST_TIMEOUT:+-e "BATS_TEST_TIMEOUT=$BATS_TEST_TIMEOUT"} \
  -v "$root:/src:ro" "${mounts[@]}" -v "$root/.cache/passwd:/etc/passwd:ro" -w /src "$image" \
  kcov --include-pattern=/src/install.sh,/src/bin/crewkit,/src/libexec/,/src/plugins/crew-,/src/push-gate/ "$out" \
  "/src/${bats#"$root"/}" "${suites[@]}" >"$log" 2>&1; then
  grep -E '^(not ok|# )' "$log" || tail -20 "$log"
  echo "coverage: the suite failed under kcov (full output: ${log#"$root"/})"
  exit 1
fi
if ((${#suites[@]})); then
  grep -cE '^ok ' "$log" | sed 's/$/ tests passed under kcov/'   # no passing test at all fails the run (pipefail)
fi
if [[ $mode == shard ]]; then
  # The marker says which run wrote this directory: its N and K, the commit and the suites it ran.
  # --merge checks all of it. The suites ran in a container that could write into $outdir, so the marker is
  # never written there: it is made in a host-only file beside the shard directories and moved in with mv,
  # which replaces a link the suites may have left at the name instead of writing through it.
  marker=$(mktemp "$root/.cache/coverage-shards/.done.XXXXXX")
  {
    echo "n=$shard_n"
    echo "k=$shard_k"
    echo "sha=$(git -C "$root" rev-parse HEAD)"
    for f in ${suites[@]+"${suites[@]}"}; do echo "file=${f#tests/}"; done
  } > "$marker"
  mv -f "$marker" "$outdir/done"
  echo "coverage shard $shard_k/$shard_n: ${outdir#"$root"/}"
  exit 0
fi
report=$(ls "$root"/.cache/coverage/bats.*/coverage.json)
echo "coverage report: ${report#"$root"/}"
report_lines "$report"
