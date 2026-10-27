#!/usr/bin/env bash
# coverage.sh: run the bats suites under kcov (in its container, as your user, unprivileged,
# with no network and the repo mounted read-only) and write .cache/coverage. Then check the
# floors:
#   tools/coverage-floors.py --report .cache/coverage/bats.*/coverage.json
#
# It covers install.sh and the plugins' bash scripts (plugins/crew-*/bin and lib). The suites
# need git and jq, which the kcov image lacks, so CI builds a derived image on the runner and
# passes it as KCOV_IMAGE (see .github/workflows/ci.yml); locally, set KCOV_IMAGE to an image
# with git and jq added, or the plugin suites fail.
set -euo pipefail
# kcov/kcov "latest" as of 2026-04-02 (kcov v44-pre), pinned by digest. Bump on purpose.
pinned=kcov/kcov@sha256:481289ae32e55e5b733019515acd10948a4f76dfed381765577db909664fc603  # scrub:pinned-hash
# --pinned-image prints the pinned image, so CI derives its image from this one line.
if [[ ${1:-} == --pinned-image ]]; then echo "$pinned"; exit 0; fi
image=${KCOV_IMAGE:-$pinned}
root=$(git rev-parse --show-toplevel)
bats=$("$root/tools/get-bats.sh")
rm -rf "$root/.cache/coverage"
mkdir -p "$root/.cache/coverage"
log="$root/.cache/coverage.log"
# Every suite except these runs under kcov. kcov's bash trace hook reads BASH_SOURCE, which is
# unset under `bash -u -c`, so suites that run `bash -euc` or `bash -c "set -u ..."` fail under
# it (tests/run.sh still runs every suite normally):
#   docs.bats      runs the setup pages' snippets with bash -euc
#   settings.bats  runs lookups under set -euo pipefail in bash -c (lib/settings.sh is still
#                  covered through the plugin scripts that source it)
skip=" docs.bats settings.bats "
suites=()
for f in "$root"/tests/*.bats; do
  [[ $skip == *" ${f##*/} "* ]] || suites+=("tests/${f##*/}")
done
# kcov's bash tracer echoes traced lines, so the full output goes to a log.
# No network, the repo read-only; only the report directory is writable.
if ! docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$root:/src:ro" -v "$root/.cache/coverage:/src/.cache/coverage" -w /src "$image" \
  kcov --include-pattern=/src/install.sh,/src/plugins/crew- /src/.cache/coverage \
  "/src/${bats#"$root"/}" "${suites[@]}" >"$log" 2>&1; then
  grep -E '^(not ok|# )' "$log" || tail -20 "$log"
  echo "coverage: the suite failed under kcov (full output: ${log#"$root"/})"
  exit 1
fi
grep -cE '^ok ' "$log" | sed 's/$/ tests passed under kcov/'
report=$(ls "$root"/.cache/coverage/bats.*/coverage.json)
echo "coverage report: ${report#"$root"/}"
# One line per covered file, so a new script's first floor can be read from the log.
python3 - "$report" <<'PY'
import json, sys
for f in sorted(json.load(open(sys.argv[1]))["files"], key=lambda f: f["file"]):
    print("  %6s%%  %s" % (f["percent_covered"], f["file"].split("/src/", 1)[-1]))
PY
