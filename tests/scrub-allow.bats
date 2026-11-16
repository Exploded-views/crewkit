#!/usr/bin/env bats
# tools/scrub.sh and its exact-value allowlist, .scrub-allow at the repo root. A finding is exempt
# only if the sha256 of the exact matched value is listed for that rule; everything else still
# counts. Every value here is a made-up fixture, assembled from pieces so this file holds no
# literal that the scrub itself would flag.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$BATS_TEST_TMPDIR/t"
  git init -q -b main "$T"
  cd "$T" || return 1
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
  CANARY="zorb""laxian"
  export SCRUB_DENYLIST="$BATS_TEST_TMPDIR/denylist.txt"
  printf '%s\n' "$CANARY" > "$SCRUB_DENYLIST"
  ACCT="a1b2c3d4""e5f60718""293a4b5c""6d7e8f90"     # 32 hex
  OTHER="f0e1d2c3""b4a59687""78695a4b""3c2d1e0f"    # 32 hex
  UU="11111111-2222-3333-4444-""555555""555555"
  echo hello > readme.txt
  git add readme.txt && git commit -qm first
}

# hash_of VALUE: the sha256 of the exact value, nothing else on stdout.
hash_of() { printf %s "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
# allow VALUE RULE [REASON]: append one reviewed line to .scrub-allow.
allow() { printf 'sha256:%s  %s  %s\n' "$(hash_of "$1")" "$2" "${3:-made-up fixture}" >> .scrub-allow; }
commit_all() { git add -A && git commit -qm c; }
scrub() { run "$REPO/tools/scrub.sh" "$@"; }
no_value() { # no fixture value, hash line or denylist term in the output
  [[ $output != *"$ACCT"* && $output != *"$OTHER"* && $output != *"$CANARY"* && $output != *"$UU"* ]] \
    || { echo "a value was printed"; return 1; }
}

@test "baseline: an unlisted 32-hex id and a uuid are flagged" {
  printf 'account = %s\nzone %s\n' "$ACCT" "$UU" > cfg.txt; commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
  [[ $output == *uuid*cfg.txt*" 1"* ]]
}

@test "a listed value passes, for each rule it is listed under" {
  printf 'account = %s\nzone %s\n"id": "%s"\n' "$ACCT" "$UU" "$ACCT" > cfg.txt
  allow "$ACCT" long-hex "an account id"; allow "$UU" uuid "a zone id"
  commit_all
  scrub
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
}

@test "the same value listed under a different rule still fails" {
  printf 'account = %s\nzone %s\n' "$ACCT" "$UU" > cfg.txt
  allow "$ACCT" uuid; allow "$UU" long-hex
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
  [[ $output == *uuid*cfg.txt*" 1"* ]]
}

@test "a one-character change to the value fails" {
  printf 'account = %s1\nlonger %s0\nzone %s\n' "${ACCT%?}" "$ACCT" "${UU%?}6" > cfg.txt
  allow "$ACCT" long-hex; allow "$UU" uuid
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 2"* ]]
  [[ $output == *uuid*cfg.txt*" 1"* ]]
}

@test "a one-character change to the listed hash fails" {
  printf 'account = %s\n' "$ACCT" > cfg.txt
  h=$(hash_of "$ACCT"); last=${h: -1}; if [[ $last == 0 ]]; then alt=1; else alt=0; fi
  printf 'sha256:%s%s  long-hex  a near miss\n' "${h%?}" "$alt" > .scrub-allow
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
}

@test "a malformed .scrub-allow line fails closed, names its line, and prints nothing from it" {
  h=$(hash_of "$ACCT"); up=$(printf %s "$h" | tr a-f A-F)
  printf 'account = %s\n' "$ACCT" > cfg.txt
  local i=0 bad
  local -a shapes=(
    "sha1:${h}  long-hex  leakword"
    "sha256:${up}  long-hex  leakword"
    "sha256:${h:1}  long-hex  leakword"
    "sha256:${h}0  long-hex  leakword"
    "sha256:${h}  bogusleakrule  leakword"
    "sha256:${h}  long-hex"
    "sha256:${h}  long-hex  "
    "sha256:${h} long-hex leakword"
    "sha256:${h}   long-hex  leakword"
    "sha256:${h}  long-hex   leakword"
    $'sha256:'"${h}"$'\tlong-hex\tleakword'
    " sha256:${h}  long-hex  leakword"
    "sha256:${h}  Long-Hex  leakword"
    "${h}  long-hex  leakword"
    "sha256:${h}  long-hex  leakword"$'\r'
  )
  for bad in "${shapes[@]}"; do
    i=$((i + 1))
    printf '# reviewed ids\n\n%s\n' "$bad" > .scrub-allow
    commit_all || true
    scrub
    [ "$status" -ne 0 ] || { echo "shape $i passed"; return 1; }
    [[ $output == *".scrub-allow line 3"* ]] || { echo "shape $i: no line number: $output"; return 1; }
    if (( i == 5 )); then want="rule-not-allowed"; else want=malformed; fi
    [[ $output == *"$want"* ]] || { echo "shape $i: wrong refusal: $output"; return 1; }
    [[ $output != *leakword* && $output != *bogusleakrule* && $output != *"$h"* ]] || { echo "shape $i printed its line"; return 1; }
  done
}

@test "a .scrub-allow with a NUL byte fails closed" {
  printf 'account = %s\n' "$ACCT" > cfg.txt
  printf 'sha256:%s  long-hex  ok\0\n' "$(hash_of "$ACCT")" > .scrub-allow
  commit_all
  scrub
  [ "$status" -ne 0 ]
  [[ $output == *".scrub-allow"* ]]
}

@test "a denylist rule line is refused, whatever its hash" {
  printf '# one\nsha256:%s  denylist  not allowed\n' "$(hash_of "$CANARY")" > .scrub-allow
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *".scrub-allow line 2"*denylist* ]]
  no_value
}

@test "a denylist hit is never exempt, even if its hash is listed under another rule" {
  printf 'notes about %s\n' "$CANARY" > notes.txt
  allow "$CANARY" long-hex; allow "$CANARY" uuid
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *denylist*notes.txt*" 1"* ]]
  no_value
}

@test "--require-denylist still fails with no denylist, allowlist or not" {
  printf 'account = %s\n' "$ACCT" > cfg.txt; allow "$ACCT" long-hex; commit_all
  SCRUB_DENYLIST="$BATS_TEST_TMPDIR/absent.txt" scrub --require-denylist
  [ "$status" -eq 1 ]
  [[ $output == *"--require-denylist"* ]]
}

@test "a line with one allowed and one other match of the same rule still counts the other" {
  printf 'a %s b %s\nc %s d %s\n' "$ACCT" "$OTHER" "$OTHER" "$ACCT" > cfg.txt
  allow "$ACCT" long-hex
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 2"* ]]
  no_value
}

@test "counting is per match: two other matches count two, two allowed matches count none" {
  printf 'a %s %s\n' "$OTHER" "${OTHER%?}1" > cfg.txt
  printf 'b %s %s\n' "$ACCT" "$ACCT" > ok.txt
  allow "$ACCT" long-hex
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 2"* ]]
  [[ $output != *ok.txt* ]]
}

@test ".scrub-allow itself: valid lines pass" {
  allow "$ACCT" long-hex "an account id"; allow "$UU" uuid
  printf '# a comment\n\n' >> .scrub-allow
  printf 'account = %s\nzone %s\n' "$ACCT" "$UU" > cfg.txt
  commit_all
  scrub
  [ "$status" -eq 0 ]
}

@test ".scrub-allow itself: other hex in it trips, wherever it sits" {
  allow "$ACCT" long-hex "an account id"
  printf 'account = %s\n' "$ACCT" > cfg.txt
  local extra i=0
  for extra in "# $OTHER" "# $(hash_of x)" \
               "sha256:$(hash_of y)  long-hex  see $OTHER" \
               "sha256:$(hash_of y)  long-hex  and $(hash_of x)"; do
    i=$((i + 1))
    cp .scrub-allow "$BATS_TEST_TMPDIR/keep"
    printf '%s\n' "$extra" >> .scrub-allow
    commit_all
    scrub
    [ "$status" -eq 1 ] || { echo "case $i: status $status: $output"; return 1; }
    [[ $output == *long-hex*.scrub-allow*" 1"* ]] || { echo "case $i not counted: $output"; return 1; }
    cp "$BATS_TEST_TMPDIR/keep" .scrub-allow
  done
}

@test ".scrub-allow itself: a bare hash line is malformed" {
  allow "$ACCT" long-hex
  hash_of x >> .scrub-allow
  commit_all
  scrub
  [ "$status" -ne 0 ]
  [[ $output == *".scrub-allow line 2"* ]]
}

@test "other rules still apply inside .scrub-allow" {
  allow "$ACCT" long-hex "contact bob@""corp-mail.test"
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *email*.scrub-allow*" 1"* ]]
}

@test "a .scrub-allow in a subdirectory gives no exemption, and its hash lines trip" {
  printf 'account = %s\n' "$ACCT" > cfg.txt
  mkdir sub; printf 'sha256:%s  long-hex  a subdirectory copy\n' "$(hash_of "$ACCT")" > sub/.scrub-allow
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
  [[ $output == *long-hex*sub/.scrub-allow*" 1"* ]]
}

@test "a file with another name gives no exemption" {
  printf 'account = %s\n' "$ACCT" > cfg.txt
  for n in scrub-allow .scrub-allow.txt .scrub-allow.bak .SCRUB-ALLOW .scrub_allow; do
    printf 'sha256:%s  long-hex  wrong name\n' "$(hash_of "$ACCT")" > "$n"
  done
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
}

@test "an untracked .scrub-allow gives no exemption (it is read from the index)" {
  printf 'account = %s\n' "$ACCT" > cfg.txt; git add cfg.txt; git commit -qm cfg
  allow "$ACCT" long-hex
  scrub --all
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
}

@test "--secrets-only honours the allowlist too, and still validates it" {
  printf 'account = %s\n' "$ACCT" > cfg.txt; allow "$ACCT" long-hex; commit_all
  scrub --secrets-only
  [ "$status" -eq 0 ]
  printf 'bad line\n' >> .scrub-allow; commit_all
  scrub --secrets-only
  [ "$status" -ne 0 ]
  [[ $output == *".scrub-allow line 2"* ]]
}

@test "--history honours the current .scrub-allow for old content, per rule and exact value" {
  printf 'account = %s\nother %s\n' "$ACCT" "$OTHER" > old.txt; git add old.txt; git commit -qm old
  git rm -q old.txt; git commit -qm rm
  scrub --history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob "*" 2"* ]]
  allow "$ACCT" long-hex; commit_all
  scrub --history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob "*" 1"* ]]
  allow "$OTHER" uuid; commit_all
  scrub --history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob "*" 1"* ]]
  allow "$OTHER" long-hex; commit_all
  scrub --history
  [ "$status" -eq 0 ]
}

@test "--history fails closed on a malformed .scrub-allow" {
  printf 'junk\n' > .scrub-allow; commit_all
  scrub --history
  [ "$status" -ne 0 ]
  [[ $output == *".scrub-allow line 1"* ]]
}

@test "--self-test passes and reports the allowlist cases" {
  scrub --self-test
  [ "$status" -eq 0 ]
  [[ $output == *"ok    allow: listed value"* ]]
  [[ $output == *"ok    allow: denylist refused"* ]]
}

@test "only long-hex and uuid can be allowlisted: other rules are refused with a reason code" {
  local tok="gh""p_""ABCDEFGHIJKLMNOP""ABCDEFGHIJKLMNOP""abcd"
  local -a pairs=("github-token|$tok" "phone|(555) 234-""5678" "private-ip|192.168.""1.20" "email|someone@""corp-mail.test"
                  "llm-api-key|s""k-ant-ABCDEFGHIJKLMNOPQRSTUV" "home-path|/home/""alice/x")
  local pair rule val
  for pair in "${pairs[@]}"; do
    rule=${pair%%|*}; val=${pair#*|}
    printf 'value: %s\n' "$val" > cfg.txt
    rm -f .scrub-allow; allow "$val" "$rule"
    commit_all || true
    scrub
    [ "$status" -ne 0 ] || { echo "$rule: passed"; return 1; }
    [[ $output == *".scrub-allow line 1"*"rule-not-allowed"* ]] || { echo "$rule: wrong refusal: $output"; return 1; }
    [[ $output != *"$val"* && $output != *"$rule "* ]] || { echo "$rule: printed"; return 1; }
    # and with the line removed the value is flagged
    rm .scrub-allow; commit_all || true
    scrub
    [ "$status" -eq 1 ]
    [[ $output == *"cfg.txt"* ]]
  done
}

@test "--history: one old blob per bad shape each count their hex" {
  local old
  for old in "phone  refused rule" "anyword  x" "long-hex"; do
    printf 'sha256:%s  %s\n' "$(hash_of "$old")" "$old" > .scrub-allow; commit_all
  done
  rm .scrub-allow; commit_all
  scrub --history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob "*" 1"*"history:blob "*" 1"*"history:blob "*" 1"* ]]
}

@test "--history reads HEAD's .scrub-allow, not the index; the tree scan reads the index" {
  printf 'account = %s\n' "$ACCT" > cfg.txt; commit_all
  allow "$ACCT" long-hex; git add .scrub-allow          # staged only
  scrub --history
  [ "$status" -eq 1 ]                                    # history: HEAD has no allowlist
  scrub
  [ "$status" -eq 0 ]                                    # tree / pre-commit: the index counts
  git commit -qm allow
  git rm -q --cached .scrub-allow                        # now removed from the index only
  scrub --history
  [ "$status" -eq 0 ]
  scrub
  [ "$status" -eq 1 ]
  git reset -q; git add .scrub-allow
  printf 'junk\n' > .scrub-allow; git add .scrub-allow  # a bad staged edit
  scrub --history
  [ "$status" -eq 0 ]                                    # HEAD's valid file is used
  scrub
  [ "$status" -ne 0 ]
}

@test "a symlinked .scrub-allow is refused, and an uppercased listed value is still flagged" {
  printf 'account = %s\n' "$ACCT" > cfg.txt
  printf 'target\n' > elsewhere; ln -s elsewhere .scrub-allow; commit_all
  scrub
  [ "$status" -ne 0 ]
  [[ $output == *".scrub-allow line 1"* ]]
  rm .scrub-allow; allow "$ACCT" long-hex
  printf 'account = %s\n' "$(printf %s "$ACCT" | tr a-f A-F)" > cfg.txt; commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*cfg.txt*" 1"* ]]
}

@test "a tools/scrub.sh in the scanned tree that isn't this script gets no self-exemption" {
  # The path alone must not exempt a file: the gate runs its own scrub against a clone, and the
  # clone decides what is at tools/scrub.sh. Home path, private IP and credentialed URL are all found.
  mkdir tools
  scheme="https:/""/"; colon=":"
  printf 'p=%s\nip=%s\nu=%s\n' "/hom""e/al""ice/x" "10.1.""2.3" "${scheme}user${colon}pass@example.com/x" > tools/scrub.sh
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *home-path*tools/scrub.sh* ]]
  [[ $output == *private-ip*tools/scrub.sh* ]]
  [[ $output == *url-credentials*tools/scrub.sh* ]]
}

@test "a tools/scrub.sh that is byte-identical to the running script is still exempt" {
  mkdir tools
  cp "$REPO/tools/scrub.sh" tools/scrub.sh
  commit_all
  scrub
  [ "$status" -eq 0 ]
}

@test "the known-versions list is read from the running script's directory, never the scanned tree" {
  mkdir tools
  printf 'p=%s\n' "/hom""e/al""ice/x" > tools/scrub.sh
  git add -A; git commit -qm c
  sha=$(git hash-object tools/scrub.sh)
  printf '%s  a version the tree vouches for itself\n' "$sha" > tools/scrub-known-versions.txt
  commit_all
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *home-path*tools/scrub.sh* ]]
}

@test "run by a relative path from a subdirectory, an identical tools/scrub.sh is still exempt" {
  mkdir tools sub
  cp "$REPO/tools/scrub.sh" tools/scrub.sh
  cp "$REPO/tools/scrub-known-versions.txt" tools/ 2>/dev/null || true
  commit_all
  cd sub
  run ../tools/scrub.sh
  [ "$status" -eq 0 ]
}

@test "the known-version check hashes the file as it is, with no gitattributes conversion" {
  # A copy of the scrub with a known-versions list of its own, naming a fixture's blob. The scanned
  # tree's tools/scrub.sh holds a home path, and a clean filter maps it to the fixture on hashing:
  # the scrub must hash the bytes on disk, not what the tree's attributes turn them into.
  mkdir "$BATS_TEST_TMPDIR/s"
  cp "$REPO/tools/scrub.sh" "$BATS_TEST_TMPDIR/s/scrub.sh"
  echo "a reviewed version" > "$BATS_TEST_TMPDIR/s/fixture"
  git hash-object "$BATS_TEST_TMPDIR/s/fixture" > "$BATS_TEST_TMPDIR/s/scrub-known-versions.txt"
  mkdir tools
  printf 'p=%s\n' "/hom""e/al""ice/x" > tools/scrub.sh
  git config filter.fake.clean "cat '$BATS_TEST_TMPDIR/s/fixture'"
  printf 'tools/scrub.sh filter=fake\n' > .gitattributes
  commit_all
  run "$BATS_TEST_TMPDIR/s/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output == *home-path*tools/scrub.sh* ]]
}
