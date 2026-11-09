#!/usr/bin/env bash
# holder-image-build.sh: build the registry holder image (holder/Dockerfile) from the pins.
#
#   tools/holder-image-build.sh [TAG]       TAG defaults to crewkit-holder:local
#
# The Dockerfile's pin arguments have no defaults, so a bare `docker build` fails closed; this
# is the one build path, and tools/holder-image-test.sh uses it. Run it from anywhere in the repo.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
tag=${1:-crewkit-holder:local}
command -v docker >/dev/null || { echo "holder-image-build: docker is required" >&2; exit 2; }

# pin FILE KEY: read KEY=VALUE from pins/FILE.env the way lint-skills does (no sourcing).
pin() { sed -n "s/^$2=\\([^ ]*\\)\$/\\1/p" "pins/$1.env"; }

args=()
for k in URL TAG SHA256_linux_amd64 SHA256_linux_arm64; do
  args+=(--build-arg "NTFY_$k=$(pin ntfy "NTFY_$k")" --build-arg "TAILSCALE_$k=$(pin tailscale "TAILSCALE_$k")")
done
exec docker build -q -f holder/Dockerfile "${args[@]}" -t "$tag" .
