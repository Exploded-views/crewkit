#!/usr/bin/env bats
# tools/coverage-py.sh's guards, with a fake venv: it writes its startup hook only into the
# venv it is given, never into a system site-packages.

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
