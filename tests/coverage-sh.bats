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
  git -C "$T" init -q
  # The stub docker logs its arguments and writes the report kcov would.
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DOCKER_ARGS"
mkdir -p "$TREE/.cache/coverage/bats.1"
echo '{"files":[{"file":"/src/plugins/crew-x/bin/y","percent_covered":"88.5","covered_lines":"1","total_lines":"1"}]}' > "$TREE/.cache/coverage/bats.1/coverage.json"
echo "ok 1 x"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_ARGS="$BATS_TEST_TMPDIR/args" TREE="$T"
  cd "$T"   # coverage.sh finds its repo from the current directory
}

@test "every suite but docs and settings runs under kcov" {
  run "$T/tools/coverage.sh"
  [ "$status" -eq 0 ]
  for s in install lane-new land-batch crew-log; do grep -qx "tests/$s.bats" "$DOCKER_ARGS"; done
  run grep -E '^tests/(docs|settings)\.bats$' "$DOCKER_ARGS"
  [ "$status" -eq 1 ]
}

@test "it covers install.sh and the plugins' scripts, with no network" {
  run "$T/tools/coverage.sh"
  grep -qx -- '--include-pattern=/src/install.sh,/src/plugins/crew-' "$DOCKER_ARGS"
  grep -qx -- '--network' "$DOCKER_ARGS"
  grep -qx -- 'none' "$DOCKER_ARGS"
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
