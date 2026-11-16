#!/usr/bin/env bats
# Prompt-injection tests for a public-repo watcher: public-watch (crew-orchestrator) reads new
# issues, PRs and comments with GET-only, field-selecting gh api calls and prints one
# content-free line per item, and tools/check-watcher-settings.py proves a watcher's settings
# allow no write tool. The stub gh serves fixtures full of injection payloads (instructions to
# agents, a fake "owner says merge", ANSI and control characters, newlines in a title, a long
# title, an @-mention, a URL to another host, a spoofed author association, malformed numbers).
#
# WATCH_REPOS (space-separated owner/repo) picks the repositories; every test runs for each.
# WATCHER_SETTINGS, when set, is a real watcher's settings file to check as well.
#
# No test here may hold the heavy lock forever: each is stopped after BATS_TEST_TIMEOUT seconds
# (a hang is a failure, not a wait).

WATCH_REPOS=${WATCH_REPOS:-"Exploded-views/bitc Exploded-views/claude-utils"}
SINCE=2026-10-27T00:00:00Z
LINE_RE='^public:[a-z0-9-]+#[0-9]+ (issue|pr|comment) author=[A-Z_]+ https://github\.com/[^[:space:]]+( title: .+)?$'
TRUSTED_RE=' author=(OWNER|MEMBER|COLLABORATOR) '
BATS_TEST_TIMEOUT=${BATS_TEST_TIMEOUT:-120}
bats_require_minimum_version 1.5.0   # run --separate-stderr

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  PW="$REPO/plugins/crew-orchestrator/bin/public-watch"
  export WATCH_FIXTURES="$REPO/tests/fixtures/watcher" CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -s "$REPO/tests/stubs/gh-watch" "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  : > "$CALLS"
}

# watch REPO: run public-watch for one repository; stdout in $output, stderr in $stderr.
watch() { run --separate-stderr "$PW" --since "$SINCE" "$1"; }

# none GREP-ARGS...: fail if grep matches (bats ignores a negated command mid-test).
none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}

@test "every line matches the content-free format, for every repository" {
  for r in $WATCH_REPOS; do
    watch "$r"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    while IFS= read -r line; do
      [[ $line =~ $LINE_RE ]] || { echo "bad line for $r: $line" >&2; return 1; }
    done <<<"$output"
    # one line per well-formed item: 7 issues and PRs, 2 comments
    [ "$(grep -c . <<<"$output")" -eq 9 ]
  done
}

@test "the label is the repository's lower-case name" {
  for r in $WATCH_REPOS; do
    watch "$r"
    name=$(tr '[:upper:]' '[:lower:]' <<<"${r#*/}")
    none -v "^public:$name#" <<<"$output"
  done
}

@test "no body text, payload or foreign URL reaches the output" {
  for r in $WATCH_REPOS; do
    watch "$r"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    for bad in ignore merge 'admin mode' 'you are' evil.example curl 'rm -rf' '@someone' phish $'\e' 'owner says'; do
      none -iF "$bad" <<<"$output"
    done
  done
}

@test "a title appears only for OWNER, MEMBER or COLLABORATOR items" {
  for r in $WATCH_REPOS; do
    watch "$r"
    none -E "title: " <<<"$(grep -vE "$TRUSTED_RE" <<<"$output")"
    grep -q "#3 issue author=OWNER .* title: " <<<"$output"
  done
}

@test "a trusted title is sanitized: no escapes, controls, URLs, @ or field-like text; at most 15 words" {
  watch Exploded-views/bitc
  t3=$(grep '^public:bitc#3 issue ' <<<"$output"); t3=${t3#* title: }
  # field-like text can't pose as a line's own fields
  [ "$t3" = "Release notes RED fake: public bitc#99 issue author OWNER [link]" ]
  t4=$(grep '^public:bitc#4 issue ' <<<"$output"); t4=${t4#* title: }
  none -F '@' <<<"$t4"
  none -F 'http' <<<"$t4"
  [ "$(wc -w <<<"$t4")" -le 15 ]
  [ "${#t4}" -le 100 ]
}

@test "a trusted title that addresses agents is withheld" {
  watch Exploded-views/bitc
  grep -qx 'public:bitc#5 pr author=COLLABORATOR https://github.com/Exploded-views/bitc/pull/5 title: (withheld: addresses agents)' <<<"$output"
}

@test "URLs are built from the repository and number, never taken from the data" {
  watch Exploded-views/bitc
  grep -qx 'public:bitc#1 issue author=NONE https://github.com/Exploded-views/bitc/issues/1' <<<"$output"
  grep -qx 'public:bitc#2 pr author=FIRST_TIME_CONTRIBUTOR https://github.com/Exploded-views/bitc/pull/2' <<<"$output"
  grep -qx 'public:bitc#1 comment author=NONE https://github.com/Exploded-views/bitc/issues/1#issuecomment-1001' <<<"$output"
  none -v ' https://github.com/Exploded-views/bitc/' <<<"$output"
}

@test "an association outside GitHub's set reads UNKNOWN, and gets no title" {
  watch Exploded-views/bitc
  grep -qx 'public:bitc#6 issue author=UNKNOWN https://github.com/Exploded-views/bitc/issues/6' <<<"$output"
}

@test "a malformed number or comment id is skipped, and counted on stderr only" {
  watch Exploded-views/bitc
  none -F '#8' <<<"$output"
  none -F '1003' <<<"$output"
  none -F '1004' <<<"$output"   # a comment on a good issue number whose id alone is malformed
  [[ $stderr == *"skipped 3 malformed item(s)"* ]]
}

# wl PYTHON: run PYTHON with watchline imported (the producer's own guards, called directly).
wl() { run python3 -c "import sys; sys.path.insert(0, '$REPO/plugins/crew-orchestrator/lib'); import watchline; $1"; }

@test "issue_line itself drops a title for an untrusted author (public-watch never asks, but a caller might)" {
  for a in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR 'OWNER x' ''; do
    wl "print(watchline.issue_line('Exploded-views/bitc', '1', 'issue', '$a', 'a title'))"
    [ "$status" -eq 0 ]
    none -F 'title' <<<"$output"
  done
  wl "print(watchline.issue_line('Exploded-views/bitc', '1', 'issue', 'OWNER', 'a title'))"
  [[ $output == *" title: a title" ]]
}

@test "control, format and separator characters that aren't whitespace become spaces in a title" {
  # BEL, a bidi override, a zero-width space, a no-break space, DEL: str.split() keeps all but NBSP
  wl 'print(watchline.sanitize_title("a\x07b\u202ec\u200bd\u00a0e\x7ff"))'
  [ "$output" = "a b c d e f" ]
  # and check() refuses a title that still carries one
  run bash -c 'printf "public:bitc#1 issue author=OWNER https://github.com/Exploded-views/bitc/issues/1 title: a\342\200\256b\n" |
    python3 "$1" check Exploded-views/bitc' _ "$REPO/plugins/crew-orchestrator/lib/watchline.py"
  [ "$status" -eq 0 ]
  [ "$output" = "watchline: dropped 1 line(s)" ]   # stderr: run merges it; the line is gone
}

@test "only GET reads: no write flag, no body field selected, a title fetched only for trusted items" {
  for r in $WATCH_REPOS; do
    : > "$CALLS"
    watch "$r"
    none -F WRITE-ATTEMPT "$CALLS"
    none -E '\.body|\.title.*\.body' "$CALLS"
    while IFS= read -r call; do
      [[ $call == "api repos/$r/"* ]] || { echo "unexpected call: $call" >&2; return 1; }
    done < "$CALLS"
    # titles: issues 3 (OWNER), 4 (MEMBER), 5 (COLLABORATOR) only
    [ "$(grep -cE "^api repos/$r/issues/[0-9]+ " "$CALLS")" -eq 3 ]
    grep -qE "^api repos/$r/issues/3 --jq \.title$" "$CALLS"
  done
}

@test "a since that isn't an ISO UTC time, or a repo that isn't owner/name, is usage (64)" {
  run "$PW" --since 'yesterday; rm -rf ~' Exploded-views/bitc
  [ "$status" -eq 64 ]
  run "$PW" --since "$SINCE" '../../etc'
  [ "$status" -eq 64 ]
  [ ! -s "$CALLS" ]
}

@test "a gh failure fails the run (exit 1), never 'nothing new'" {
  printf '#!/bin/sh\necho "gh: HTTP 502" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh.broken"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh.broken"   # not executable, PATH would find the real gh
  mv "$BATS_TEST_TMPDIR/bin/gh.broken" "$BATS_TEST_TMPDIR/bin/gh"
  run --separate-stderr "$PW" --since "$SINCE" Exploded-views/bitc
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- watchline.py: the one grammar, and the orchestrator-side filter -------------------------

@test "watchline check keeps exactly the valid lines, in order, and counts the rest on stderr" {
  WL="$REPO/plugins/crew-orchestrator/lib/watchline.py"
  run --separate-stderr python3 "$WL" check Exploded-views/bitc < "$WATCH_FIXTURES/lines.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$WATCH_FIXTURES/lines-kept.txt")" ]
  [ "$stderr" = "watchline: dropped 18 line(s)" ]
}

@test "every line public-watch prints passes watchline check, for every repository" {
  WL="$REPO/plugins/crew-orchestrator/lib/watchline.py"
  for r in $WATCH_REPOS; do
    watch "$r"
    produced=$output
    run --separate-stderr python3 "$WL" check "$r" <<<"$produced"
    [ "$status" -eq 0 ]
    [ "$output" = "$produced" ]
    [ -z "$stderr" ]
  done
}

@test "watchline check: 2 when stdin can't be read, 64 for anything but 'check'" {
  WL="$REPO/plugins/crew-orchestrator/lib/watchline.py"
  # stdin closed for python alone: closed around run, fd 0 is free when run's $(...) makes its
  # pipe, so (bash 5.2) the pipe's read end lands on fd 0 and python reads its own output forever.
  run bash -c 'exec python3 "$1" check Exploded-views/bitc <&-' _ "$WL"
  [ "$status" -eq 2 ]
  run python3 "$WL" filter Exploded-views/bitc < /dev/null
  [ "$status" -eq 64 ]
  run python3 "$WL" check < /dev/null   # no repositories
  [ "$status" -eq 64 ]
  run python3 "$WL" check ../etc < /dev/null
  [ "$status" -eq 64 ]
}

@test "watchline check drops a line for another owner's same-named repository" {
  WL="$REPO/plugins/crew-orchestrator/lib/watchline.py"
  name=bitc   # a variable, so the export check doesn't read this URL as a link to a repo of another owner
  forged="public:bitc#1 issue author=NONE https://github.com/someone-else/$name/issues/1"
  run --separate-stderr python3 "$WL" check Exploded-views/bitc <<<"$forged"
  [ -z "$output" ]
  [ "$stderr" = "watchline: dropped 1 line(s)" ]
  run --separate-stderr python3 "$WL" check EXPLODED-VIEWS/BITC <<<'public:bitc#1 issue author=NONE https://github.com/Exploded-views/bitc/issues/1'
  [ -n "$output" ]   # owner and name compare without case, as GitHub does
}

# --- the watcher's settings ---------------------------------------------------------------------

@test "the generated watcher settings allow no write tool, for every repository" {
  run "$PW" --settings $WATCH_REPOS
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/settings.json"
  run python3 "$REPO/tools/check-watcher-settings.py" "$BATS_TEST_TMPDIR/settings.json" $WATCH_REPOS
  [ "$status" -eq 0 ]
}

@test "the settings check refuses each kind of write tool" {
  run "$PW" --settings $WATCH_REPOS
  echo "$output" > "$BATS_TEST_TMPDIR/good.json"
  for bad in '"Edit"' '"Write"' '"Bash(gh pr merge*)"' '"Bash(gh issue*)"' '"Bash(gh release*)"' '"Bash(git*)"' \
             '"Bash(*)"' '"Bash(gh api *)"' '"Bash(gh api repos/other/repo/*)"' '"Bash(curl*)"' '"WebFetch"' \
             '"Read(**)"' '"Bash(/tmp/public-watch --since * && rm*)"' '"Bash(gh api repos/Exploded-views/bitc/*)"' '"Bash(herdr agent prompt*)"' '"Bash(ssh*)"'; do
    jq ".permissions.allow += [$bad]" "$BATS_TEST_TMPDIR/good.json" > "$BATS_TEST_TMPDIR/bad.json"
    run python3 "$REPO/tools/check-watcher-settings.py" "$BATS_TEST_TMPDIR/bad.json" $WATCH_REPOS
    [ "$status" -eq 1 ] || { echo "allowed: $bad" >&2; return 1; }
  done
  # a gh allow is refused for running gh itself, even one no other rule would catch
  for gh in '"Bash(gh api repos/Exploded-views/bitc/*)"' '"Bash( gh api *)"'; do
    jq ".permissions.allow += [$gh]" "$BATS_TEST_TMPDIR/good.json" > "$BATS_TEST_TMPDIR/bad.json"
    run python3 "$REPO/tools/check-watcher-settings.py" "$BATS_TEST_TMPDIR/bad.json" $WATCH_REPOS
    [ "$status" -eq 1 ]
    [[ $output == *"runs gh directly"* ]] || { echo "no gh refusal: $gh" >&2; return 1; }
  done
  for gone in '"Bash(gh api * -X*)"' '"Bash(gh api * --method*)"' '"Bash(gh api * -f*)"' '"Bash(gh api * --input*)"' '"Edit"' '"Bash(gh pr*)"' \
              '"Bash(herdr*)"' '"Bash(ssh*)"'; do
    jq ".permissions.deny -= [$gone]" "$BATS_TEST_TMPDIR/good.json" > "$BATS_TEST_TMPDIR/bad.json"
    run python3 "$REPO/tools/check-watcher-settings.py" "$BATS_TEST_TMPDIR/bad.json" $WATCH_REPOS
    [ "$status" -eq 1 ] || { echo "not denied: $gone" >&2; return 1; }
  done
  for mode in '.defaultMode = "bypassPermissions"' '.permissions.defaultMode = "acceptEdits"' \
              '.defaultMode = "default" | .permissions.defaultMode = "dontAsk"' '.permissions = []'; do
    jq "$mode" "$BATS_TEST_TMPDIR/good.json" > "$BATS_TEST_TMPDIR/bad.json"
    run python3 "$REPO/tools/check-watcher-settings.py" "$BATS_TEST_TMPDIR/bad.json" $WATCH_REPOS
    [ "$status" -eq 1 ] || { echo "accepted: $mode" >&2; return 1; }
  done
}

@test "a real watcher's settings (WATCHER_SETTINGS) pass the check" {
  [[ -n ${WATCHER_SETTINGS:-} ]] || skip "WATCHER_SETTINGS not set"
  run python3 "$REPO/tools/check-watcher-settings.py" "$WATCHER_SETTINGS" $WATCH_REPOS
  echo "$output"
  [ "$status" -eq 0 ]
}
