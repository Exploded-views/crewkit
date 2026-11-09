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

# A bare `wait` also waits on bats's own timeout watchdog, so under BATS_TEST_TIMEOUT it
# hangs until the limit kills the test; so does `wait -n`. Wait on specific pids. bare_waits DIR:
# every *.bats and *.bash under DIR (subdirectories too), a `wait` command with no pid after it
# (the end of the line, ; & |, a redirection or an option, or just (wait)), after dropping a test's name and
# a trailing comment, so prose doesn't count.
bare_waits() {
  local f
  while IFS= read -r f; do
    sed -E 's/^@test "([^"\\]|\\.)*"//; s/(^|[[:space:]])#.*$//' "$f" |
      grep -nE '(^|[;&|({[:space:]])wait([[:space:]]*($|[;&|]|[0-9]*[<>])|[[:space:]]+-[A-Za-z])|\(wait[[:space:]]*\)' | sed "s|^|$f:|"
  done < <(find "$1" -type f \( -name '*.bats' -o -name '*.bash' \) | sort)
  return 0
}

@test "no suite or helper has a bare wait (wait on specific pids)" {
  run bare_waits "$REPO/tests"
  [ -z "$output" ]
}

@test "the bare-wait scan catches every form of a bare wait, and not a wait on pids or prose" {
  local w=wai; w+=t  # spelled out, so this file doesn't trip its own scan
  mkdir -p "$BATS_TEST_TMPDIR/s/sub"
  { printf '%s\n' "  $w" "  $w # c" "  $w 2>/dev/null" "  $w |& cat" "  $w | cat" "  ($w)" "  x=\$($w)" \
      "  $w -n" "  $w -fn" "  true; $w" "  true & $w && true" "  true && $w || true" "  $w>/dev/null"
    printf '@test "one line" { %s; }\n' "$w"; } > "$BATS_TEST_TMPDIR/s/a.bats"
  printf '  %s\n' "$w" > "$BATS_TEST_TMPDIR/s/h.bash"
  printf '  %s\n' "$w" > "$BATS_TEST_TMPDIR/s/sub/b.bats"
  run bare_waits "$BATS_TEST_TMPDIR/s"
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 16 ]
  [[ $output == *"/s/h.bash:1:"* && $output == *"/s/sub/b.bats:1:"* && $output == *"/s/a.bats:14:"* ]]
  printf '%s\n' "  $w \"\$pid\"" "  $w \$p1 \$p2" "  $w \$!" "  $w -- \"\$p\"" "  $w-for-ready" "  ${w}_x" "  $w-n" "  wait_$w" "@test \"a PR that must $w; and $w\" {" \
    "  # we $w; for the lock" "  echo done  # $w" "  await" "  rewait=1" "  sleep 1 &" > "$BATS_TEST_TMPDIR/s/a.bats"
  rm -f "$BATS_TEST_TMPDIR/s/h.bash" "$BATS_TEST_TMPDIR/s/sub/b.bats"
  run bare_waits "$BATS_TEST_TMPDIR/s"
  [ -z "$output" ]
}
