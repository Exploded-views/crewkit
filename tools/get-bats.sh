#!/usr/bin/env bash
# get-bats.sh: fetch the pinned bats-core release into .cache/bats and print its bin path.
# The archive is checked against the sha256 below before it is unpacked. Bump both together.
set -euo pipefail
tag=v1.14.0
sha=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177  # scrub:pinned-hash
root=$(git rev-parse --show-toplevel)
dest="$root/.cache/bats-$tag"
if [[ ! -x $dest/bin/bats ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/bats.tgz" \
    "https://github.com/bats-core/bats-core/archive/refs/tags/$tag.tar.gz"
  echo "$sha  $tmp/bats.tgz" | sha256sum -c --quiet - >&2
  mkdir -p "$dest"
  tar -xzf "$tmp/bats.tgz" -C "$dest" --strip-components=1
fi
echo "$dest/bin/bats"
