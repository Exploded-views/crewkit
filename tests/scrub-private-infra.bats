#!/usr/bin/env bats
# tools/scrub.sh: class tags on denylist lines (a trailing " #class=<name>") and --private-infra,
# which skips only class=crew-host entries and only in a repo whose every remote is on the user's
# private-remote list. Every term here is a made-up fixture assembled at runtime, so this file holds
# no literal the scrub itself would flag.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$BATS_TEST_TMPDIR/t"
  git init -q -b main "$T"
  cd "$T" || return 1
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
  CH="hostzz""alpha"     # tagged crew-host
  OC="hostzz""beta"      # tagged with another class
  UT="hostzz""gamma"     # untagged
  UK="hostzz""delta"     # tagged with a class the scrub doesn't know
  export SCRUB_DENYLIST="$BATS_TEST_TMPDIR/denylist.txt"
  export SCRUB_PRIVATE_REMOTES="$BATS_TEST_TMPDIR/private-remotes.txt"
  RURL="git@example.com:org/private-thing.git"
  printf '%s #class=crew-host\n%s #class=client\n%s\n%s #class=zzz-unknown\n' "$CH" "$OC" "$UT" "$UK" > "$SCRUB_DENYLIST"
  printf '# private remotes\n%s\n' "$RURL" > "$SCRUB_PRIVATE_REMOTES"
  git remote add origin "$RURL"
  echo "x $CH" > ch.txt; echo "x $OC" > oc.txt; echo "x $UT" > ut.txt; echo "x $UK" > uk.txt
  echo hello > readme.txt
  git add -A && git commit -qm first
}

scrub() { run "$REPO/tools/scrub.sh" "$@"; }
no_term() {
  local t
  for t in "$CH" "$OC" "$UT" "$UK"; do
    [[ $output != *"$t"* ]] || { echo "a term was printed"; return 1; }
  done
}

@test "baseline: without the flag every tagged and untagged term is found" {
  scrub
  [ "$status" -eq 1 ]
  for f in ch oc ut uk; do [[ $output == *denylist*"$f.txt"*" 1"* ]]; done
  no_term
}

@test "--private-infra skips a crew-host term and nothing else" {
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output != *"ch.txt"* ]]
  for f in oc ut uk; do [[ $output == *denylist*"$f.txt"*" 1"* ]]; done
  no_term
}

@test "--private-infra passes when only crew-host terms are present" {
  git rm -q oc.txt ut.txt uk.txt; git commit -qm rm
  scrub --private-infra
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
  scrub
  [ "$status" -eq 1 ]
}

@test "an unknown class applies everywhere, with and without the flag" {
  printf '%s #class=zzz-unknown\n' "$UK" > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *denylist*uk.txt* ]]
}

@test "a tag leaves the rest of the line as the pattern (tagged terms still match)" {
  printf '%s #class=client\n' "$OC" > "$SCRUB_DENYLIST"
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *denylist*oc.txt* ]]
}

@test "a malformed class tag fails the scrub, naming the line number only" {
  for bad in 'Bad' '' 'a_b' '-x' "$(printf 'z%.0s' {1..33})" 'ok #class=twice'; do
    printf '%s\n%s #class=%s\n' "$UT" "$CH" "$bad" > "$SCRUB_DENYLIST"
    scrub
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"* ]]
    no_term
    scrub --private-infra
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"* ]]
  done
}

@test "a tag keyword in another case or with spaces around it is malformed, not a whole pattern" {
  local bad
  for bad in ' #CLASS=crew-host' ' #Class=crew-host' ' # class=crew-host' ' #class =crew-host' \
             ' #class= crew-host' $'\t# CLASS = x' $'\t#\tclass\t=\tx' '  #  Class  =  ' $'\xe2\x80\x83#CLASS=crew-host' \
             $' #\vclass=crew-host' $' #\fclass=crew-host' $' #class\v=crew-host' $' #class\f=crew-host' \
             $' #\xc2\xa0class=crew-host' $' #class\xc2\xa0=crew-host' $' #\xe2\x80\x83class=crew-host' \
             $' #class\xe2\x80\x83=crew-host' $' #\xe2\x80\x83Class\xe2\x80\x83=\xe2\x80\x83x' \
             '#CLASS=x' '#class=crew-host'; do
    printf '%s\n%s%s\n' "$UT" "$CH" "$bad" > "$SCRUB_DENYLIST"
    scrub
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"*malformed* ]]
    no_term
    scrub --private-infra
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"*malformed* ]]
  done
}

@test "a keyword with no whitespace before it is malformed too, whatever its case" {
  local bad
  for bad in '#CLASS=x' '#class=crew-host' '#Class =x' '#class=' 'x#class=crew-host'; do
    printf '%s\n%s%s\n' "$UT" "$CH" "$bad" > "$SCRUB_DENYLIST"
    scrub
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"*malformed* ]]
    no_term
  done
}

@test "a line that is only a tag is a comment, as before" {
  printf ' #class=crew-host\n%s\n' "$UT" > "$SCRUB_DENYLIST"
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *denylist*ut.txt* ]]
  [[ $output != *"denylist line"* ]]
}

@test "a comment line may mention a tag" {
  printf '# was %s #class=Bad\n%s #class=client\n' "$CH" "$OC" > "$SCRUB_DENYLIST"
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *denylist*oc.txt* ]]
}

@test "--private-infra on a public remote exits 2 with a fixed message" {
  git remote set-url origin "git@example.com:org/open-thing.git"
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output == *"--private-infra"*refus* ]]
  no_term
  [[ $output != *open-thing* && $output != *private-thing* ]]
}

@test "--private-infra refuses when any one of several remotes is not listed" {
  git remote add other "git@example.com:org/open-thing.git"
  scrub --private-infra
  [ "$status" -eq 2 ]
}

@test "--private-infra refuses when the private-remote list is missing" {
  rm "$SCRUB_PRIVATE_REMOTES"
  scrub --private-infra
  [ "$status" -eq 2 ]
}

@test "a trailing .git or slash on the remote is not a way round the list" {
  git remote set-url origin "git@example.com:org/private-thing"
  scrub --private-infra
  [ "$status" -eq 1 ]
  git remote set-url origin "git@example.com:org/private-thing.gitx"
  scrub --private-infra
  [ "$status" -eq 2 ]
}

@test "--private-infra with no remote refuses unless the list says @no-remote" {
  git remote remove origin
  scrub --private-infra
  [ "$status" -eq 2 ]
  printf '@no-remote\n' >> "$SCRUB_PRIVATE_REMOTES"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output != *"ch.txt"* ]]
}

@test "the remote check does not apply without the flag" {
  git remote set-url origin "git@example.com:org/open-thing.git"
  scrub
  [ "$status" -eq 1 ]
}

@test "secret and PII rules still fire under --private-infra" {
  printf 'k = %s\nmail %s@%s.org\n' "ghp_""$(printf 'a%.0s' {1..36})" "someone" "corp-mail" > leak.txt
  git add -A && git commit -qm leak
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *github-token*leak.txt* ]]
  [[ $output == *email*leak.txt* ]]
}

@test "--private-infra with --secrets-only: no denylist, but the remote gate still applies" {
  scrub --secrets-only --private-infra
  [ "$status" -eq 0 ]
  git remote set-url origin "git@example.com:org/open-thing.git"
  scrub --secrets-only --private-infra
  [ "$status" -eq 2 ]
}

@test "--private-infra with --history skips crew-host terms in every version" {
  H="$BATS_TEST_TMPDIR/h"
  git init -q -b main "$H"; cd "$H"
  git remote add origin "$RURL"
  echo "x $CH" > ch.txt; git add -A; git commit -qm first
  scrub --history
  [ "$status" -eq 1 ]
  scrub --history --private-infra
  [ "$status" -eq 0 ]
  git commit -q --allow-empty -m "note $UT"
  scrub --history --private-infra
  [ "$status" -eq 1 ]
  no_term
}

@test "--private-infra with --history refuses a public remote" {
  git remote set-url origin "git@example.com:org/open-thing.git"
  scrub --history --private-infra
  [ "$status" -eq 2 ]
}

@test "--private-infra with --require-denylist: a missing denylist still fails, 1" {
  rm "$SCRUB_DENYLIST"
  scrub --private-infra --require-denylist
  [ "$status" -eq 1 ]
  [[ $output == *"--require-denylist"* ]]
}

@test "--private-infra with --require-denylist passes a present denylist" {
  git rm -q oc.txt ut.txt uk.txt; git commit -qm rm
  scrub --private-infra --require-denylist
  [ "$status" -eq 0 ]
}

@test "--private-infra cannot combine with --self-test" {
  scrub --private-infra --self-test
  [ "$status" -eq 2 ]
}

@test "a path holding a crew-host term is not printed under --private-infra" {
  mkdir d; echo "x $UT" > "d/$CH.txt"; git add -A; git commit -qm p
  scrub --private-infra
  no_term
}

# --- review follow-ups: legacy remotes, remote loop, one tag parser, push URLs, empty active set ---

OPEN="https://example.com/org/open-thing.git"

@test "a legacy .git/remotes entry is refused, naming the entry and no URL" {
  mkdir -p .git/remotes
  printf 'URL: %s\n' "$OPEN" > .git/remotes/pub
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output == *pub* ]]
  [[ $output != *open-thing* && $output != *private-thing* ]]
  no_term
}

@test "a legacy .git/branches entry is refused" {
  mkdir -p .git/branches
  printf '%s\n' "$OPEN" > .git/branches/pub
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output == *pub* ]]
}

@test "empty legacy remotes and branches directories are fine" {
  mkdir -p .git/remotes .git/branches
  scrub --private-infra
  [ "$status" -eq 1 ]
}

@test "a remote named o* with a public URL is not hidden by a file called origin" {
  git config 'remote.o*.url' "$OPEN"
  rm -f oc.txt   # so the only name o* can expand to is origin
  : > origin
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output != *open-thing* ]]
}

@test "a public push URL is refused" {
  git remote set-url --push origin "$OPEN"
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output != *open-thing* ]]
}

@test "an insteadOf that rewrites a listed URL to a public one is refused" {
  git config "url.https://example.com/org/open-.insteadOf" "git@example.com:org/private-"
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output != *open-thing* ]]
}

@test "a pushInsteadOf that rewrites the push URL to a public one is refused" {
  git config "url.https://example.com/org/open-.pushInsteadOf" "git@example.com:org/private-"
  scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output != *open-thing* ]]
}

@test "a list entry that is empty once normalised exits 2 with a clean message" {
  for e in .git / //; do
    printf '%s\n%s\n' "$RURL" "$e" > "$SCRUB_PRIVATE_REMOTES"
    scrub --private-infra
    [ "$status" -eq 2 ]
    [[ $output == *"--private-infra"* ]]
    [[ $output != *subscript* && $output != *line* ]]
  done
}

@test "a symlinked private-remote list is refused" {
  mv "$SCRUB_PRIVATE_REMOTES" "$BATS_TEST_TMPDIR/real-list"
  ln -s "$BATS_TEST_TMPDIR/real-list" "$SCRUB_PRIVATE_REMOTES"
  scrub --private-infra
  [ "$status" -eq 2 ]
}

@test "a group- or world-writable private-remote list is refused" {
  for m in 664 646 666; do
    chmod "$m" "$SCRUB_PRIVATE_REMOTES"
    scrub --private-infra
    [ "$status" -eq 2 ]
  done
  chmod 644 "$SCRUB_PRIVATE_REMOTES"
  scrub --private-infra
  [ "$status" -eq 1 ]
}

@test "a non-ASCII space before the tag is not a well-formed tag" {
  for sp in '\xe2\x80\x83' '\xe3\x80\x80' '\xe1\x9a\x80' '\xe2\x80\xaf' '\xe2\x80\xa8' '\xc2\xa0'; do
    { printf '%s\n' "$UT"; printf "%s${sp}#class=crew-host\n" "$CH"; } > "$SCRUB_DENYLIST"
    scrub
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"*"malformed"* ]]
    no_term
    scrub --private-infra
    [ "$status" -eq 1 ]
    [[ $output == *"line 2"*"malformed"* ]]
    no_term
  done
}

@test "a tag with no whitespace before it is malformed, not a whole pattern" {
  printf '%s#class=crew-host\n' "$CH" > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *"line 1"*malformed* ]]
  no_term
}

@test "a tab before the tag is a well-formed tag" {
  printf '%s\t#class=crew-host\n%s\n' "$CH" "$UT" > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output != *"ch.txt"* ]]
  [[ $output == *denylist*ut.txt* ]]
}

@test "a denylist of only crew-host lines leaves no active pattern: --require-denylist fails, counts only" {
  printf '%s #class=crew-host\n' "$CH" > "$SCRUB_DENYLIST"
  scrub --private-infra --require-denylist
  [ "$status" -eq 2 ]
  [[ $output == *"active=0 skipped=1"* ]]
  no_term
}

@test "a denylist of only crew-host lines leaves no active pattern: otherwise a warning, counts only" {
  printf '%s #class=crew-host\n' "$CH" > "$SCRUB_DENYLIST"
  git rm -q oc.txt ut.txt uk.txt; git commit -qm rm
  scrub --private-infra
  [ "$status" -eq 0 ]
  [[ $output == *WARNING*"active=0 skipped=1"* ]]
  [[ $output == *clean* ]]
  no_term
}

@test "a class=firm line is a known class that applies under --private-infra and in a plain run" {
  FT="hostzz""epsilon"
  printf '%s #class=firm\n%s #class=crew-host\n' "$FT" "$CH" > "$SCRUB_DENYLIST"
  echo "x $FT" > ft.txt; git add -A; git commit -qm f
  for flag in "" --private-infra; do
    scrub $flag
    [ "$status" -eq 1 ]
    [[ $output == *denylist*ft.txt* ]]
    [[ $output != *"ch.txt"* || -z $flag ]]
    [[ $output != *"$FT"* ]]
    [[ $output != *malformed* ]]
  done
}

@test "a class=firm tag after a non-ASCII space is malformed, like any other" {
  printf '%s\xe2\x80\x83#class=firm\n' "$UT" > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *"line 1"*malformed* ]]
}

# --- invalid UTF-8 must not hide anything, in the user's UTF-8 locale or in C ---

# The invalid-byte tests run with a grep and sed shim first on PATH that, under a UTF-8 locale, acts
# like BSD's on an invalid byte (see tests/shims/bsd-utf8/shim.py), so they bite on Linux too.
utf8_locale() {
  local l
  for l in en_US.UTF-8 C.UTF-8 C.utf8 $(locale -a 2>/dev/null | grep -i 'utf-\?8' | head -3); do
    if LC_ALL=$l locale charmap 2>/dev/null | grep -qi 'utf-8'; then
      export LC_ALL=$l PATH="$REPO/tests/shims/bsd-utf8:$PATH"
      return 0
    fi
  done
  skip "no UTF-8 locale installed"
}

# bad_byte_case NAME PATH LINES...: PATH holds an invalid byte, then the given content, as
# "same line" (the byte shares the line) or "next line" (the byte sits alone above it).
@test "an invalid UTF-8 byte hides no secret, hex value or denylist term, same line or next" {
  utf8_locale
  tok="ghp_""$(printf 'a%.0s' {1..36})"
  hx="0123456789abcdef""0123456789abcdef""01234567"      # 40 hex, assembled
  mkdir -p pins tools
  missed=""
  for where in same next; do
    if [[ $where == same ]]; then sep=''; else sep='\n'; fi
    git rm -q -r --cached . >/dev/null 2>&1; rm -f ch.txt oc.txt ut.txt uk.txt readme.txt leak.txt hexv.txt pins/x.env tools/scrub-known-versions.txt Cargo.lock lib.txt
    printf "\xff${sep}k = %s\n" "$tok" > leak.txt
    printf "\xff${sep}key %s\n" "$hx" > hexv.txt
    printf "\xff${sep}x %s\n" "$UT" > ut.txt
    printf "A_SHA256_linux_amd64=%s\n\xff${sep}key %s\n" "$(printf '0%.0s' {1..64})" "$hx" > pins/x.env
    printf "%s\n\xff${sep}key %s\n" "$hx" "$hx" > tools/scrub-known-versions.txt
    printf "checksum = \"%s\"\n\xff${sep}key %s\n" "$(printf '0%.0s' {1..64})" "$hx" > Cargo.lock
    printf "\xff${sep}%s scrub:pinned-hash\nkey %s\n" "$(printf '0%.0s' {1..64})" "$hx" > lib.txt
    git add -A && git commit -qm "bad bytes $where"
    for flag in "" --private-infra; do
      scrub $flag
      for want in github-token*leak.txt long-hex*hexv.txt denylist*ut.txt long-hex*pins/x.env \
                  long-hex*tools/scrub-known-versions.txt long-hex*Cargo.lock long-hex*lib.txt; do
        [[ $output == *$want* ]] || missed="$missed [$where ${flag:-plain} $want]"
      done
      no_term
    done
  done
  [ -z "$missed" ] || { echo "missed:$missed"; return 1; }
}

@test "an invalid UTF-8 byte in a denylist comment does not stop the tag parser reading later lines" {
  utf8_locale
  { printf '# note \xff here\n%s\n' "$UT"; printf '%s #class=Bad\n' "$CH"; } > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *"line 3"*malformed* ]]
  printf '# note \xff here\n%s #class=crew-host\n%s\n' "$CH" "$UT" > "$SCRUB_DENYLIST"
  scrub --private-infra
  [ "$status" -eq 1 ]
  [[ $output == *denylist*ut.txt* ]]
  [[ $output != *"ch.txt"* ]]
}

@test "an invalid byte and a term or secret on the SAME line count exactly once, counts only" {
  utf8_locale
  tok="ghp_""$(printf 'a%.0s' {1..36})"
  git rm -q -r --cached . >/dev/null; rm -f ch.txt oc.txt uk.txt readme.txt ut.txt
  mkdir -p lib
  printf 'lib/caf\xe9 %s\n' "$UT" > lib/same.txt
  printf 'caf\xe9 k = %s\n' "$tok" > leak.txt
  git add -A && git commit -qm same
  for flag in "" --private-infra; do
    scrub $flag
    [ "$status" -eq 1 ]
    grep -Eq '^ +denylist +lib/same.txt +1$' <<<"$output"
    grep -Eq '^ +github-token +leak.txt +1$' <<<"$output"
    no_term
  done
}

@test "a non-ASCII term that folds case only in the user locale is still found" {
  utf8_locale
  printf '\xc3\x89CLAIRZZ\n' > "$SCRUB_DENYLIST"     # E-acute, upper case
  git rm -q -r --cached . >/dev/null; rm -f ch.txt oc.txt uk.txt readme.txt ut.txt
  printf 'x \xc3\xa9clairzz\n' > fold.txt              # e-acute, lower case
  git add -A && git commit -qm fold
  for flag in "" --private-infra; do
    scrub $flag
    [ "$status" -eq 1 ]
    grep -Eq '^ +denylist +fold.txt +1$' <<<"$output"
  done
}

@test "a path holding a non-ASCII term that folds case only in the user locale is withheld" {
  utf8_locale
  printf '\xc3\x89CLAIRZZ\n%s\n' "$UT" > "$SCRUB_DENYLIST"
  git rm -q -r --cached . >/dev/null; rm -f ch.txt oc.txt uk.txt readme.txt ut.txt
  name=$(printf '\xc3\xa9clairzz.txt')
  echo "x $UT" > "$name"
  git add -A && git commit -qm path
  scrub
  [ "$status" -eq 1 ]
  [[ $output == *"path matches the denylist"* ]]
  [[ $output != *clairzz* ]]
}

@test "the self-test hides a path with an invalid byte that only the C view matches" {
  utf8_locale
  run "$REPO/tools/scrub.sh" --self-test
  [ "$status" -eq 0 ]
  [[ $output == *"label: a path with an invalid byte is hidden"* || $output == *"skip  label"* ]]
}

# --- round three: CRLF, ASCII comments, list custody ---

@test "a denylist line ending in a carriage return is refused, not silently ignored" {
  for body in "$UT\r\n" "$CH #class=crew-host\r\n" "$UT\n$OC\r\n"; do
    printf "$body" > "$SCRUB_DENYLIST"
    for flag in "" --private-infra; do
      scrub $flag
      [ "$status" -eq 1 ]
      [[ $output == *"denylist line"*" CR"* ]]
      no_term
    done
  done
}

@test "a space that isn't an ASCII space or tab before # makes a pattern, not a comment" {
  for sep in '\xc2\xa0' '\x0b' '\x0c' '\xe2\x80\x83'; do
    printf "${sep}#%s\n" "$UT" > "$SCRUB_DENYLIST"
    printf "x ${sep}#%s\n" "$UT" > nb.txt
    git add -A; git commit -qm nb
    for flag in "" --private-infra; do
      scrub $flag
      [ "$status" -eq 1 ]
      grep -Eq '^ +denylist +nb.txt +1$' <<<"$output"
      [[ $output != *"ut.txt"* ]]
    done
  done
}

@test "a denylist inside the repository being scanned is refused" {
  mkdir lists
  cp "$SCRUB_DENYLIST" lists/denylist.txt
  SCRUB_DENYLIST="$T/lists/denylist.txt" scrub
  [ "$status" -eq 2 ]
  [[ $output == *"inside the repository"* ]]
  no_term
  ln -s "$T/lists/denylist.txt" "$BATS_TEST_TMPDIR/link.txt"
  SCRUB_DENYLIST="$BATS_TEST_TMPDIR/link.txt" scrub
  [ "$status" -eq 2 ]
}

@test "a private-remote list inside the repository being scanned is refused" {
  mkdir lists
  cp "$SCRUB_PRIVATE_REMOTES" lists/remotes.txt
  SCRUB_PRIVATE_REMOTES="$T/lists/remotes.txt" scrub --private-infra
  [ "$status" -eq 2 ]
  [[ $output == *"inside the repository"* ]]
}
