#!/usr/bin/env bats
# Run the setup docs' own shell blocks, with placeholders filled, against stubs.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/crewkit"
  # A stub installer that records exactly the arguments it gets, one per line.
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$HOME/args"\n' > "$HOME/crewkit/install.sh"
  chmod +x "$HOME/crewkit/install.sh"
}

# blocks FILE: the page's bash blocks, placeholders filled with test values.
blocks() {
  python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
fill = {"<path to your crewkit clone>": "crewkit", "<name for this machine>": "test host"}
for b in re.findall(r"```bash\n(.*?)```", t, re.S):
    for k, v in fill.items():
        b = b.replace(k, v)
    print(b)
PY
}

@test "install.md: the dry run passes exactly one -- to the installer" {
  run bash -euc "$(blocks "$REPO/docs/install.md" | sed -n '1,/^crewkit_install /p'; echo 'crewkit_install')"
  [ "$status" -eq 0 ]
  [ "$(grep -cx -- '--' "$HOME/args")" -eq 1 ]
  [ "$(tr '\n' ' ' < "$HOME/args")" = "-- --host test host " ]
}

@test "install.md: an extra bootstrap flag added the documented way still gives one --" {
  local script
  script="$(blocks "$REPO/docs/install.md" | grep -v '^crewkit_install ')"
  run bash -euc "$script"$'\nBOOTSTRAP_FLAGS+=(--org acme)\ncrewkit_install --yes'
  [ "$status" -eq 0 ]
  [ "$(grep -cx -- '--' "$HOME/args")" -eq 1 ]
  [ "$(tr '\n' ' ' < "$HOME/args")" = "--yes -- --host test host --org acme " ]
}
