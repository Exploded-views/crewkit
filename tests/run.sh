#!/usr/bin/env bash
# run.sh: run the bats suite with the pinned bats-core. Extra arguments go to bats.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
bats=$("$root/tools/get-bats.sh")
exec "$bats" "$@" "$root/tests"
