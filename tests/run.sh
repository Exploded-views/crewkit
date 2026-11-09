#!/usr/bin/env bash
# run.sh: run the bats suite with the pinned bats-core. Extra arguments go to bats; given any
# existing *.bats file, bats runs those files only, otherwise the whole tests directory.
#
#   tests/run.sh --shard K/N [bats args]   run only shard K of N of tests/*.bats, split by measured
#                                          file time (tools/bats-shards.py); exit 64 on a bad K/N
set -euo pipefail
root=$(git rev-parse --show-toplevel)
args=() shard=""
while (($#)); do
  if [[ $1 == --shard ]]; then
    [[ $# -ge 2 ]] || { echo "run.sh: --shard needs K/N" >&2; exit 64; }
    shard=$2
    shift 2
  else
    args+=("$1")
    shift
  fi
done
shard_files=()
if [[ -n $shard ]]; then
  planned=$(python3 -I "$root/tools/bats-shards.py" --root "$root" files "$shard") || exit $?
  while IFS= read -r f; do [[ -z $f ]] || shard_files+=("$root/tests/$f"); done <<<"$planned"
  ((${#shard_files[@]})) || { echo "run.sh: shard $shard has no bats files" >&2; exit 64; }
fi
bats=$("$root/tools/get-bats.sh")
target=("$root/tests")
for a in ${args[@]+"${args[@]}"}; do
  [[ $a == *.bats && -f $a ]] && target=()
done
if ((${#shard_files[@]})); then
  exec "$bats" ${args[@]+"${args[@]}"} "${shard_files[@]}"
fi
exec "$bats" ${args[@]+"${args[@]}"} ${target[@]+"${target[@]}"}
