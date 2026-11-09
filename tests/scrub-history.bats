#!/usr/bin/env bats
# tools/scrub.sh --history: the scrub's rules over every commit reachable from any ref, not just
# today's files. Each test plants a canary in one place in a throwaway repo and checks the scan
# finds it, names where (never the matched text), and fails.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$BATS_TEST_TMPDIR/t"
  git init -q -b main "$T"
  cd "$T" || return 1
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
  # The private term, assembled so no test file holds it whole.
  CANARY="zorb""laxian"
  export SCRUB_DENYLIST="$BATS_TEST_TMPDIR/denylist.txt"
  printf '# private terms\n%s\n' "$CANARY" > "$SCRUB_DENYLIST"
  echo "hello" > readme.txt
  git add readme.txt && git commit -qm "first"
}

scrub_history() { run "$REPO/tools/scrub.sh" --history "$@"; }
no_canary() { [[ $output != *"$CANARY"* ]] || { echo "the matched text was printed"; return 1; }; }

@test "a clean history passes" {
  scrub_history
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
}

@test "a term in a file that was later deleted is found" {
  echo "notes about $CANARY" > old.txt; git add old.txt; git commit -qm "add"
  git rm -q old.txt; git commit -qm "remove"
  "$REPO/tools/scrub.sh" >/dev/null   # today's files are clean
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*"history:blob "* ]]
  no_canary
}

@test "an old version of a file still in the tree is found" {
  echo "v1 $CANARY" > readme.txt; git commit -qam "v1"
  echo "v2 clean" > readme.txt; git commit -qam "v2"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *"history:blob "* ]]
  no_canary
}

@test "a secret shape in history is found by its rule" {
  printf 'key = %s%s\n' "AK""IA" "ABCDEFGHIJKLMNOP" > cfg.txt; git add cfg.txt; git commit -qm "cfg"
  git rm -q cfg.txt; git commit -qm "rm"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *aws-key*"history:blob "* ]]
}

@test "a commit on a branch that isn't checked out is scanned" {
  git checkout -q -b side; echo "$CANARY" > side.txt; git add side.txt; git commit -qm "side"
  git checkout -q main
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *"history:blob "* ]]
  no_canary
}

@test "a term in a commit message is found" {
  git commit -q --allow-empty -m "fix for $CANARY"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:messages* ]]
  no_canary
}

@test "a term in an author name or a committer email is found" {
  GIT_AUTHOR_NAME="$CANARY person" git commit -q --allow-empty -m "a"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
  git reset -q --hard HEAD~1
  GIT_COMMITTER_EMAIL="x@$CANARY.example" git commit -q --allow-empty -m "c"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:identities* ]]
}

@test "a term in a branch or tag name is found" {
  git branch "feature/$CANARY-thing"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:refs* ]]
  no_canary
  git branch -q -D "feature/$CANARY-thing"
  git tag "v1-$CANARY"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:refs* ]]
}

@test "a term in an annotated tag's message is found" {
  git tag -a v1 -m "release for $CANARY"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:messages* ]]
  no_canary
}

@test "a pinned sha256 line in pins/*.env stays exempt in history" {
  mkdir pins
  printf 'TOOL_SHA256_linux_amd64=%s\n' "$(printf '0123456789abcdef%.0s' 1 2 3 4)" > pins/tool.env
  git add pins; git commit -qm "pin"
  scrub_history
  [ "$status" -eq 0 ]
}

@test "--require-denylist refuses a history scan with no denylist" {
  SCRUB_DENYLIST="$BATS_TEST_TMPDIR/none.txt" run "$REPO/tools/scrub.sh" --history --require-denylist
  [ "$status" -eq 1 ]
}

@test "the summary says how many commits, refs and files it read" {
  git branch other
  scrub_history
  [[ $output == *"2 refs"* ]]
  [[ $output == *"1 commit"* ]]
}

@test "GitHub's own merge identity (noreply@github.com) is allowed" {
  GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git commit -q --allow-empty -m "Merge pull request #1"
  scrub_history
  [ "$status" -eq 0 ]
  # Only that exact address: a personal one that merely ends the same way is still found.
  GIT_AUTHOR_EMAIL="someone.noreply@""github.com" git commit -q --allow-empty -m "x"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *email*history:identities* ]]
}

@test "a message naming one of this repo's own commits by full SHA is allowed; any other long hex isn't" {
  git commit -q --allow-empty -m "follow-up to $(git rev-parse HEAD)"
  scrub_history
  [ "$status" -eq 0 ]
  git commit -q --allow-empty -m "token $(printf '0123456789abcdef%.0s' 1 2 3)"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*history:messages* ]]
}

# --- From the review of 37a2c54 -----------------------------------------------------------

@test "a term only in a file path, or only in a directory name, is found and never printed" {
  echo x > "notes-$CANARY.txt"; git add -A; git commit -qm a
  git rm -q "notes-$CANARY.txt"; git commit -qm b
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:paths* ]]
  no_canary
  git reset -q --hard HEAD~2
  mkdir "$CANARY-dir"; echo x > "$CANARY-dir/f.txt"; git add -A; git commit -qm c
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

@test "a content hit names the blob by its SHA, never by a path that could hold the term" {
  echo "about $CANARY" > "$CANARY.txt"; git add -A; git commit -qm a
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *"history:blob "* ]]
  no_canary
}

@test "an invalid denylist pattern fails the scan instead of counting zero" {
  printf 'ok-term\n(unclosed\n' > "$SCRUB_DENYLIST"
  scrub_history
  [ "$status" -ne 0 ]
  [[ $output == *"denylist line 2 is not a valid extended regex"* ]]
  run "$REPO/tools/scrub.sh"
  [ "$status" -ne 0 ]
}

@test "a denylist with no patterns (comments only) fails, not passes" {
  printf '# nothing yet\n\n' > "$SCRUB_DENYLIST"
  run "$REPO/tools/scrub.sh" --history --require-denylist
  [ "$status" -ne 0 ]
  run "$REPO/tools/scrub.sh" --require-denylist
  [ "$status" -ne 0 ]
}

@test "binary content is scanned, and a binary later version hides nothing earlier" {
  printf 'key = %s%s\n' "AK""IA" "ABCDEFGHIJKLMNOP" > data.bin; git add data.bin; git commit -qm v1
  printf '\000\001binary\000' > data.bin; git commit -qam v2
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *aws-key* ]]
  git reset -q --hard HEAD~2
  printf '\000\001%s\000' "$CANARY" > other.bin; git add other.bin; git commit -qm bin
  scrub_history
  [ "$status" -eq 1 ]
  no_canary
  # Each secret in a binary blob counts, as in a text one (not one "binary file matches").
  git reset -q --hard HEAD~1
  printf '\000%s%s\n\000%s%s\n' "AK""IA" "ABCDEFGHIJKLMNOP" "AK""IA" "QRSTUVWXYZABCDEF" > two.bin; git add two.bin; git commit -qm two
  scrub_history
  [[ $output =~ aws-key[[:space:]]+history:blob\ [0-9a-f]+[[:space:]]+2 ]]
}

@test "a file named like a stream can't overwrite it: both are scanned" {
  printf 'about %s\n' "$CANARY" > "history:refs"; git add -A; git commit -qm a
  git branch "x-$CANARY"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:refs* ]]
  [[ $output == *denylist*"history:blob "* ]]
  no_canary
}

@test "a historical tools/scrub.sh that isn't a known version is scanned like any file" {
  mkdir -p tools; printf 'key = %s%s\n' "AK""IA" "ABCDEFGHIJKLMNOP" > tools/scrub.sh; git add -A; git commit -qm a
  git rm -q tools/scrub.sh; git commit -qm b
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *aws-key* ]]
}

@test "annotated tags outside refs/tags, and tags of tags, are read" {
  git tag -a inner -m "inner $CANARY"
  git update-ref refs/custom/kept "$(git rev-parse inner)"
  git tag -d inner >/dev/null
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:messages* ]]
  no_canary
  git update-ref -d refs/custom/kept
  git tag -a base -m "inner $CANARY"
  git tag -a outer -m "outer, clean" base
  git tag -d base >/dev/null   # only reachable by following the tag of a tag
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:messages* ]]
}

@test "a blob introduced only by a merge commit is scanned" {
  git checkout -q -b side; git commit -q --allow-empty -m side; git checkout -q main
  git commit -q --allow-empty -m main2
  git merge -q --no-commit side
  echo "$CANARY" > merged.txt; git add merged.txt
  git -c core.editor=true commit -qm "merge"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *"history:blob "* ]]
  no_canary
}

@test "a path that was a file and later a directory doesn't abort the scan or print paths" {
  echo x > a; git add a; git commit -qm f
  git rm -q a; mkdir a; echo y > a/b; git add a; git commit -qm d
  scrub_history
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
}

@test "the noreply allow rules are anchored to the whole address" {
  GIT_AUTHOR_EMAIL="x@""users.noreply.github.com.leak.example" git commit -q --allow-empty -m a
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *email*history:identities* ]]
}

@test "the tree scan reads tracked paths too, and withholds a path that matches the denylist" {
  echo "about $CANARY" > "$CANARY-notes.txt"; git add -A; git commit -qm a
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output == *denylist*tree:paths* ]]
  [[ $output == *"path matches the denylist"* ]]
  no_canary
}

@test "a denylist search that fails for any other reason fails the scan" {
  # A grep that fails the denylist count (exit 2), as an I/O or memory error would.
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  real=$(command -v grep)
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -aEic ] && exit 2; done\nexec %s "$@"\n' "$real" > "$BATS_TEST_TMPDIR/shim/grep"
  chmod +x "$BATS_TEST_TMPDIR/shim/grep"
  PATH="$BATS_TEST_TMPDIR/shim:$PATH" run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"the denylist search failed"* ]]
}

@test "tools/scrub-known-versions.txt may list blob SHAs; any other long hex in it is found" {
  mkdir -p tools
  printf '# reviewed versions\n%s\n' "$(printf '0123456789abcdef%.0s' 1 2 3 | cut -c1-40)" > tools/scrub-known-versions.txt
  git add -A; git commit -qm known
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 0 ]
  scrub_history
  [ "$status" -eq 0 ]
  printf 'note %s\n' "$(printf 'fedcba9876543210%.0s' 1 2 3)" >> tools/scrub-known-versions.txt
  git commit -qam more
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output == *long-hex* ]]
}

# --- From the review of 3dad719 -----------------------------------------------------------

@test "a term only in a file's old name (renamed later) is found" {
  echo "plan" > "$CANARY-plan.md"; git add -A; git commit -qm a
  git mv "$CANARY-plan.md" plan.md; git commit -qm rename
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:paths* ]]
  no_canary
}

@test "a term in a path whose content is shared with another path is found" {
  : > .gitkeep; git add .gitkeep; git commit -qm keep
  : > "$CANARY-notes.txt"; git add -A; git commit -qm same
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

@test "a term in a directory that copies another directory's content is found" {
  mkdir a; echo same > a/f; git add a; git commit -qm a
  mkdir "$CANARY"; echo same > "$CANARY/f"; git add -A; git commit -qm copy
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

@test "a submodule (gitlink) entry's name is scanned" {
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),vendor/$CANARY"
  git commit -qm gitlink
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

@test "a path with a newline in it is scanned whole" {
  mkdir q; printf 'x\n' > "q/ok
$CANARY"; git add -A; git commit -qm nl
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

# The long-hex rule exempts a pinned sha256 line only in a pins/*.env file. A path that holds a
# newline must not lend a blob that context, by being cut at the newline or by faking an
# ls-tree entry after it.
@test "a newline in a path can't give a blob a pins/ context (truncated path)" {
  pin=$(printf 'A_SHA256_linux_amd64=%s' "$(printf '0%.0s' {1..64})")
  mkdir pins; printf '%s\n' "$pin" > "pins/x.env
z"; git add -A; git commit -qm nlpin
  sha=$(printf '%s\n' "$pin" | git hash-object --stdin)
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob ${sha:0:12}"* ]]
  no_canary
}

# The blob is reachable only through a tag, so a forged entry in a tree path would be its only
# path context. The match is on the blob's own line: the forged name itself, sha included, also
# lands in history:paths, so a bare long-hex match would pass even with the blob exempt.
@test "a newline in a path can't give a blob a pins/ context (forged tree entry, blob only under a tag)" {
  pin=$(printf 'A_SHA256_linux_amd64=%s' "$(printf '0%.0s' {1..64})")
  sha=$(printf '%s\n' "$pin" | git hash-object -w --stdin)
  git tag pinblob "$sha"
  other=$(printf 'other\n' | git hash-object -w --stdin)
  git update-index --add --cacheinfo "100644,$other,d/a
100644 blob $sha	pins/x.env"
  git commit -qm forge
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*"history:blob ${sha:0:12}"* ]]
  no_canary
}

@test "a tab in a path is kept whole: a term before the tab is found" {
  printf 'x\n' > "$CANARY"$'\tb'; git add -A; git commit -qm tab
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
  no_canary
}

@test "commit headers are scanned: a mergetag's tagger and message" {
  tree=$(git rev-parse HEAD^{tree}); parent=$(git rev-parse HEAD)
  obj=$(printf 'tree %s\nparent %s\nauthor dev <dev@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nmergetag object %s\n type commit\n tag v9\n tagger %s person <t@example.com> 1700000000 +0000\n \n note %s\n\nmerge\n' \
    "$tree" "$parent" "$parent" "$CANARY" "$CANARY" | git hash-object -t commit -w --stdin)
  git update-ref refs/heads/main "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *"history:commits"* ]]
  no_canary
}

@test "the tree scan reads files with non-ASCII or quoted names" {
  printf 'about %s\n' "$CANARY" > "résumé.txt"; git add -A; git commit -qm u
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"scanning 2 files"* ]]
  no_canary
}

@test "the tree scan withholds a path that looks like a secret" {
  name="AK""IAABCDEFGHIJKLMNOP.txt"
  echo "mail someone@corp-""mail.test" > "$name"; git add -A; git commit -qm s
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output != *"$name"* ]]
}

@test "scrub:pinned-hash exempts a sha256-length hash only, not any long hex" {
  printf 'X=%s  # scrub:pinned-hash\n' "$(printf '0123456789abcdef%.0s' 1 2 3 4)" > pin.txt
  git add -A; git commit -qm pin
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 0 ]
  printf 'GH_TOKEN=%s # scrub:pinned-hash\n' "$(printf '0123456789abcdef%.0s' 1 2 3 | cut -c1-40)" >> pin.txt
  git commit -qam token
  run "$REPO/tools/scrub.sh"
  [ "$status" -eq 1 ]
  [[ $output == *long-hex* ]]
}

@test "a git command that fails mid-scan exits 1, not git's own code" {
  mkdir -p "$BATS_TEST_TMPDIR/gshim"
  real=$(command -v git)
  printf '#!/bin/sh\n[ "$1" = cat-file ] && [ "$2" = commit ] && exit 128\nexec %s "$@"\n' "$real" > "$BATS_TEST_TMPDIR/gshim/git"
  chmod +x "$BATS_TEST_TMPDIR/gshim/git"
  PATH="$BATS_TEST_TMPDIR/gshim:$PATH" run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
}

@test "a pin-shaped line is exempt only if every path the blob ever had is a pin file" {
  mkdir pins
  printf 'TOOL_SHA256_linux_amd64=%s\n' "$(printf '0123456789abcdef%.0s' 1 2 3 4)" > pins/tool.env
  cp pins/tool.env zz-notes.env   # sorts after the pin file, so the pin path is the first one seen
  git add -A; git commit -qm both
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *long-hex* ]]
}

@test "a tag object's own name is scanned even when its ref is named otherwise" {
  obj=$(printf 'object %s\ntype commit\ntag v1-%s\ntagger dev <dev@example.com> 1700000000 +0000\n\nrelease\n' \
    "$(git rev-parse HEAD)" "$CANARY" | git mktag)
  git update-ref refs/tags/clean "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:refs* ]]
  no_canary
}

@test "a commit message only on a branch that isn't checked out is read" {
  git checkout -q -b side; git commit -q --allow-empty -m "side note $CANARY"; git checkout -q main
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:messages* ]]
  no_canary
}

# --- From the review of 4a53d6a -----------------------------------------------------------

@test "paths in a tree that a tag or ref points at directly are read" {
  mkdir t; echo x > "t/$CANARY.txt"; git add t
  tree=$(git write-tree); git reset -q --hard
  git tag -a -m rel treetag "$tree"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:paths* ]]
  no_canary
  git tag -d treetag >/dev/null
  git update-ref refs/trees/raw "$tree"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *history:paths* ]]
}

@test "unknown tag headers are scanned" {
  obj=$(printf 'object %s\ntype commit\ntag v2\ntagger dev <dev@example.com> 1700000000 +0000\nx-note %s\n\nrelease\n' \
    "$(git rev-parse HEAD)" "$CANARY" | git hash-object -t tag -w --literally --stdin)
  git update-ref refs/tags/v2 "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:commits* ]]
  no_canary
}

@test "a malformed author line is still scanned" {
  obj=$(printf 'tree %s\nauthor %s person <a@example.com>\ncommitter dev <dev@example.com> 1700000000 +0000\n\nm\n' \
    "$(git rev-parse HEAD^{tree})" "$CANARY" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/odd "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  no_canary
}

@test "an empty repository (no commits) is clean, not a failed search" {
  e="$BATS_TEST_TMPDIR/empty"; git init -q "$e"; cd "$e"
  scrub_history
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
}

# --- From the review of 4789c3c -----------------------------------------------------------

@test "identities and headers that aren't valid UTF-8 are read under a UTF-8 locale" {
  obj=$(printf 'tree %s\nauthor %s Ren\351 <a@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nencoding ISO-8859-1\n\nm\n' \
    "$(git rev-parse HEAD^{tree})" "$CANARY" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/latin "$obj"
  LC_ALL=C.UTF-8 run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
  git update-ref -d refs/heads/latin
  tree=$(git rev-parse HEAD^{tree}); parent=$(git rev-parse HEAD)
  obj=$(printf 'tree %s\nparent %s\nauthor dev <dev@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nmergetag object %s\n type commit\n tag v9\n tagger dev <dev@example.com> 1700000000 +0000\n \n %s caf\351\n\nmerge\n' \
    "$tree" "$parent" "$parent" "$CANARY" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/main "$obj"
  LC_ALL=C.UTF-8 run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:commits* ]]
}

@test "an identity or tagger with bytes that aren't UTF-8, and no encoding header, is read under a UTF-8 locale" {
  # No encoding header, so nothing re-encodes the bytes (#28): only LC_ALL=C lets GNU sed's "."
  # match \351. (The test above carries ISO-8859-1, which git now shows as valid UTF-8.)
  obj=$(printf 'tree %s\nauthor %s Ren\351 <a@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\n\nm\n' \
    "$(git rev-parse HEAD^{tree})" "$CANARY" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/raw "$obj"
  LC_ALL=C.UTF-8 run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
  git update-ref -d refs/heads/raw
  obj=$(printf 'object %s\ntype commit\ntag v4\ntagger %s Ren\351 <a@example.com> 1700000000 +0000\n\nrelease\n' \
    "$(git rev-parse HEAD)" "$CANARY" | git hash-object -t tag -w --literally --stdin)
  git update-ref refs/tags/v4 "$obj"
  LC_ALL=C.UTF-8 run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
}

# --- From the mutation run of the locale fix ----------------------------------------------

@test "a header with a NUL byte is still scanned (grep -a), in commits and tags" {
  obj=$(printf 'tree %s\nauthor dev <dev@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nx-bin \000 %s\n\nm\n' \
    "$(git rev-parse HEAD^{tree})" "$CANARY" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/nul "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:commits* ]]
  no_canary
  git update-ref -d refs/heads/nul
  obj=$(printf 'object %s\ntype commit\ntag v3\ntagger dev <dev@example.com> 1700000000 +0000\nx-bin \000 %s\n\nrelease\n' \
    "$(git rev-parse HEAD)" "$CANARY" | git hash-object -t tag -w --literally --stdin)
  git update-ref refs/tags/v3 "$obj"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:commits* ]]
  no_canary
}

# Cargo.lock: `checksum = "<64 lowercase hex>"` lines are exempt from long-hex, in a file named
# Cargo.lock only; every other line and every other rule still applies there.
hex64() { printf '0123456789abcdef%.0s' 1 2 3 4; }
tree_scan() { git add -A; git commit -qm "t" --allow-empty; run "$REPO/tools/scrub.sh"; }

@test "Cargo.lock: checksum lines are exempt from long-hex (tree and history)" {
  mkdir -p src-tauri
  { for i in 1 2 3; do printf '[[package]]\nname = "p%s"\nchecksum = "%s"\n' "$i" "$(hex64)"; done; } > src-tauri/Cargo.lock
  tree_scan
  [ "$status" -eq 0 ]
  scrub_history
  [ "$status" -eq 0 ]
}

@test "Cargo.lock: the exemption is for the file name Cargo.lock only" {
  printf 'checksum = "%s"\n' "$(hex64)" > Cargo.lock.bak
  printf 'checksum = "%s"\n' "$(hex64)" > notes.txt
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*Cargo.lock.bak* ]]
  [[ $output == *long-hex*notes.txt* ]]
}

@test "Cargo.lock: only the whole checksum line is exempt, and the other lines still count" {
  printf 'checksum = "%s"\n' "$(hex64)" > Cargo.lock
  printf 'checksum = "%s" x\n' "$(hex64)" >> Cargo.lock
  printf 'source = "%s"\n' "$(hex64)" >> Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *"long-hex"*"Cargo.lock"*" 2"* ]]
}

@test "Cargo.lock: a checksum that is not 64 lowercase hex is flagged" {
  h=$(hex64)
  printf 'checksum = "%s"\n' "${h:0:40}" > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]; [[ $output == *long-hex*Cargo.lock*" 1"* ]]
  printf 'checksum = "%s"\n' "${h:0:63}" > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]; [[ $output == *long-hex*Cargo.lock*" 1"* ]]
  printf 'checksum = "%s"\n' "$(printf %s "$h" | tr a-f A-F)" > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]; [[ $output == *long-hex*Cargo.lock*" 1"* ]]
}

@test "Cargo.lock: the denylist still applies inside it" {
  { printf 'checksum = "%s"\n' "$(hex64)"; echo "name = \"$CANARY\""; } > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *denylist*Cargo.lock* ]]
  [[ $output != *long-hex* ]]
  no_canary
}

@test "Cargo.lock: a name that only ends in Cargo.lock, and a line that only contains a checksum, are flagged" {
  h=$(hex64)
  printf 'checksum = "%s"\n' "$h" > fooCargo.lock
  printf '# checksum = "%s"\nxchecksum = "%s"\n' "$h" "$h" > Cargo.lock
  printf 'checksum = "%s"\n' "$h" > CargoXlock
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*fooCargo.lock*" 1"* ]]
  [[ $output == *long-hex*" Cargo.lock"*" 2"* ]]
  [[ $output == *long-hex*CargoXlock*" 1"* ]]
}

# A NUL byte must not end the line for the exemption: BSD grep treats NUL as the end of a
# line for `$`, so an exempt line followed by NUL and a secret hid the secret.
@test "NUL: hex after an exempt Cargo.lock checksum line, on the same line, is still counted" {
  printf 'checksum = "%s"\0key %s%s\n' "$(hex64)" "$(hex64)" "$(hex64)" > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*Cargo.lock*" 1"* ]]
}

@test "NUL: hex after an exempt pins/*.env sha256 line is still counted" {
  mkdir pins
  printf 'TOOL_SHA256_linux_amd64=%s\0key %s%s\n' "$(hex64)" "$(hex64)" "$(hex64)" > pins/tool.env
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*pins/tool.env*" 1"* ]]
}

@test "NUL: hex after an exempt tools/scrub-known-versions.txt blob line is still counted" {
  mkdir tools
  printf '%s\0key %s%s\n' "$(hex64 | cut -c1-40)" "$(hex64)" "$(hex64)" > tools/scrub-known-versions.txt
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*scrub-known-versions.txt*" 1"* ]]
}

# The NUL split comes before the scrub:pinned-hash sed: a marked line, a NUL and then a
# secret is two lines, and the marker must not strip the secret on the far side of the NUL.
@test "NUL: a secret hex after a scrub:pinned-hash line and a NUL is counted (plain file)" {
  printf 'x # scrub:pinned-hash\0%s\n' "$(hex64)" > notes.txt
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*notes.txt*" 1"* ]]
}

@test "NUL: a secret hex after a scrub:pinned-hash line and a NUL is counted (Cargo.lock)" {
  printf 'x # scrub:pinned-hash\0%s\n' "$(hex64)" > Cargo.lock
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*" Cargo.lock"*" 1"* ]]
}

@test "NUL: a secret hex after a scrub:pinned-hash line and a NUL is counted (pins/*.env)" {
  mkdir pins
  printf 'x # scrub:pinned-hash\0%s\n' "$(hex64)" > pins/tool.env
  tree_scan
  [ "$status" -eq 1 ]
  [[ $output == *long-hex*pins/tool.env*" 1"* ]]
}

# --- #28: a commit stored in another encoding ---------------------------------------------

@test "a non-ASCII term in a commit stored as ISO-8859-1 is found, as git shows it (UTF-8)" {
  term=$(printf 'zorbl\303\251x')   # the term in UTF-8, as a denylist holds it
  printf '%s\n' "$term" > "$SCRUB_DENYLIST"
  for loc in C.UTF-8 C; do
    obj=$(printf 'tree %s\nauthor Zorbl\351x Smith <a@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nencoding ISO-8859-1\n\nm\n' \
      "$(git rev-parse HEAD^{tree})" | git hash-object -t commit -w --literally --stdin)
    git update-ref refs/heads/latin "$obj"
    LC_ALL=$loc run "$REPO/tools/scrub.sh" --history
    [ "$status" -eq 1 ]
    [[ $output == *denylist*history:identities* ]]
    [[ $output != *"$term"* ]]
    obj=$(printf 'tree %s\nauthor dev <dev@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nencoding ISO-8859-1\n\nabout zorbl\351x\n' \
      "$(git rev-parse HEAD^{tree})" | git hash-object -t commit -w --literally --stdin)
    git update-ref refs/heads/latin "$obj"
    LC_ALL=$loc run "$REPO/tools/scrub.sh" --history
    [ "$status" -eq 1 ]
    [[ $output == *denylist*history:messages* ]]
    [[ $output != *"$term"* ]]
  done
}

@test "a commit in another encoding still passes when it holds no term" {
  obj=$(printf 'tree %s\nauthor Ren\351 <a@example.com> 1700000000 +0000\ncommitter dev <dev@example.com> 1700000000 +0000\nencoding ISO-8859-1\n\ncaf\351\n' \
    "$(git rev-parse HEAD^{tree})" | git hash-object -t commit -w --literally --stdin)
  git update-ref refs/heads/latin "$obj"
  scrub_history
  [ "$status" -eq 0 ]
  [[ $output == *clean* ]]
}

# --- GNU-only forms: BSD sed (macOS) dropped every identity (2026-10-27) ------------------

# bsd_like_sed: a sed first on PATH that refuses GNU extensions in basic expressions (\|, \+,
# \?), as BSD sed does: GNU sed in --posix mode, or the system sed when it isn't GNU.
bsd_like_sed() {
  local real; real=$(command -v sed)
  mkdir -p "$BATS_TEST_TMPDIR/bsd"
  if "$real" --version >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec "%s" --posix "$@" 2>/dev/null\n' "$real" > "$BATS_TEST_TMPDIR/bsd/sed"
  else
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/bsd/sed"
  fi
  chmod +x "$BATS_TEST_TMPDIR/bsd/sed"
  PATH="$BATS_TEST_TMPDIR/bsd:$PATH"
}

@test "with a BSD-like sed, a term in an author name or a committer email is still found" {
  bsd_like_sed
  GIT_AUTHOR_NAME="Ann $CANARY" git commit -q --allow-empty -m "a"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
  git reset -q --hard HEAD~1
  GIT_COMMITTER_EMAIL="$CANARY@example.com" git commit -q --allow-empty -m "c"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  no_canary
}

@test "with a BSD-like sed, a tagger and a tree path are still found" {
  bsd_like_sed
  GIT_COMMITTER_NAME="Tag $CANARY" git tag -a -m "release" v1
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:identities* ]]
  git tag -d v1 >/dev/null
  mkdir d; echo x > "d/$CANARY.txt"; git add d; git commit -qm "p"
  scrub_history
  [ "$status" -eq 1 ]
  [[ $output == *denylist*history:paths* ]]
  no_canary
}

@test "fails closed: --history refuses to run when its extraction finds no tagger" {
  mkdir -p "$BATS_TEST_TMPDIR/broken"
  # A sed that prints nothing for a tagger line, as a GNU-only form on BSD sed would.
  real=$(command -v sed)
  printf '#!/bin/sh\ncase "$*" in *tagger*) exit 0 ;; esac\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/broken/sed"
  chmod +x "$BATS_TEST_TMPDIR/broken/sed"
  PATH="$BATS_TEST_TMPDIR/broken:$PATH" run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *tagger*"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

@test "fails closed: --history refuses to run when its extraction finds no known identity" {
  mkdir -p "$BATS_TEST_TMPDIR/broken"
  # A sed that prints nothing for the probe's author line, as a GNU-only form on BSD sed did.
  real=$(command -v sed)
  printf '#!/bin/sh\ncase "$*" in *author*) exit 0 ;; esac\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/broken/sed"
  chmod +x "$BATS_TEST_TMPDIR/broken/sed"
  PATH="$BATS_TEST_TMPDIR/broken:$PATH" run "$REPO/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

@test "the self-test plants a history canary and finds it in the identities" {
  run "$REPO/tools/scrub.sh" --self-test
  [ "$status" -eq 0 ]
  [[ $output == *"ok    history identities"* ]]
}

@test "the self-test's history canary runs a copy without the exec bit, as bash FILE does" {
  # A vendored copy is often run as `bash scrub.sh` with mode 0644; re-running it as "$0" was exit 126.
  mkdir -p "$BATS_TEST_TMPDIR/vendored"
  cp "$REPO/tools/scrub.sh" "$BATS_TEST_TMPDIR/vendored/scrub.sh"
  chmod 644 "$BATS_TEST_TMPDIR/vendored/scrub.sh"
  run bash "$BATS_TEST_TMPDIR/vendored/scrub.sh" --self-test
  [ "$status" -eq 0 ]
  [[ $output == *"ok    history identities"* ]]
}

@test "the self-test fails when the history scan misses an identity" {
  mkdir -p "$BATS_TEST_TMPDIR/broken"
  real=$(command -v sed)
  printf '#!/bin/sh\ncase "$*" in *author*) exit 0 ;; esac\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/broken/sed"
  chmod +x "$BATS_TEST_TMPDIR/broken/sed"
  PATH="$BATS_TEST_TMPDIR/broken:$PATH" run "$REPO/tools/scrub.sh" --self-test
  [ "$status" -eq 1 ]
  [[ $output == *"MISS  history identities"* ]]
}

# --- the self-test must not touch the caller's repository (review of #81) -------------------

# A hook, a linked worktree or a --git-dir caller exports GIT_DIR; the self-test's own git work
# (a temp repo, update-ref) then ran in THAT repository and moved its main to a canary commit.
victim_state() {
  { git -C "$VICTIM" for-each-ref; git -C "$VICTIM" symbolic-ref HEAD; git -C "$VICTIM" rev-parse HEAD
    git -C "$VICTIM" cat-file --batch-all-objects --batch-check; } 2>&1
}

make_victim() {
  VICTIM="$BATS_TEST_TMPDIR/victim"
  git init -q -b main "$VICTIM"
  git -C "$VICTIM" commit -q --allow-empty -m "real work"
}

@test "the self-test leaves a repository named by GIT_DIR untouched" {
  make_victim
  before=$(victim_state)
  cd "$BATS_TEST_TMPDIR"
  GIT_DIR="$VICTIM/.git" run "$REPO/tools/scrub.sh" --self-test
  [ "$status" -eq 0 ]
  [[ $output == *"ok    history identities"* ]]
  [ "$(victim_state)" = "$before" ]
}

@test "the self-test leaves a repository named by GIT_DIR and GIT_WORK_TREE untouched" {
  make_victim
  before=$(victim_state)
  cd "$BATS_TEST_TMPDIR"
  GIT_DIR="$VICTIM/.git" GIT_WORK_TREE="$VICTIM" GIT_INDEX_FILE="$VICTIM/.git/index" \
    run "$REPO/tools/scrub.sh" --self-test
  [ "$status" -eq 0 ]
  [ "$(victim_state)" = "$before" ]
}

# --- the probe holds a non-UTF-8 byte, so losing the C locale fails closed (review nit) ------

@test "the extraction probe fails closed when the C locale is lost" {
  locale -a 2>/dev/null | grep -qix 'en_US.UTF-8\|en_US.utf8\|C.UTF-8\|C.utf8' || skip "no UTF-8 locale installed"
  loc=$(locale -a | grep -ix 'en_US.UTF-8\|en_US.utf8\|C.UTF-8\|C.utf8' | head -1)
  cp "$REPO/tools/scrub.sh" "$BATS_TEST_TMPDIR/scrub-nolc.sh"
  python3 - "$BATS_TEST_TMPDIR/scrub-nolc.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  export LC_ALL=C\n  set -E"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, "  set -E"))
PY
  mkdir -p "$BATS_TEST_TMPDIR/tools"
  mv "$BATS_TEST_TMPDIR/scrub-nolc.sh" "$BATS_TEST_TMPDIR/tools/scrub.sh"
  cp "$REPO/tools/scrub-known-versions.txt" "$BATS_TEST_TMPDIR/tools/"
  chmod +x "$BATS_TEST_TMPDIR/tools/scrub.sh"
  LC_ALL=$loc run "$BATS_TEST_TMPDIR/tools/scrub.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

# broken_sed PATTERN: a sed first on PATH that prints nothing when its arguments match PATTERN
# (a shell case pattern), as a GNU-only form on BSD sed does; every other call is the real sed.
broken_sed() {
  mkdir -p "$BATS_TEST_TMPDIR/broken"
  printf '#!/bin/sh\ncase "$*" in %s) exit 0 ;; esac\nexec "%s" "$@"\n' "$1" "$(command -v sed)" \
    > "$BATS_TEST_TMPDIR/broken/sed"
  chmod +x "$BATS_TEST_TMPDIR/broken/sed"
  PATH="$BATS_TEST_TMPDIR/broken:$PATH"
}

# broken_copy SED-SCRIPT: a copy of the scrub with one edit that breaks an extraction in the
# tree reader (bash itself now, no sed or tr); the edit must have changed the file.
broken_copy() {
  sed "$1" "$REPO/tools/scrub.sh" > "$BATS_TEST_TMPDIR/scrub-broken.sh"
  if cmp -s "$REPO/tools/scrub.sh" "$BATS_TEST_TMPDIR/scrub-broken.sh"; then echo "broken_copy: the edit did not apply"; return 1; fi
  chmod +x "$BATS_TEST_TMPDIR/scrub-broken.sh"
}

@test "fails closed: --history refuses to run when its extraction finds no blob path" {
  broken_copy 's/sha=\${meta##\* }/sha=zz/'
  run "$BATS_TEST_TMPDIR/scrub-broken.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"history's blob-paths"*"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

@test "fails closed: --history refuses to run when its extraction finds no tree path" {
  broken_copy 's/"\${rec#\*\$.\\t.}"/"$rec"/'
  run "$BATS_TEST_TMPDIR/scrub-broken.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"history's paths;"*"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

# Only the blob-paths probe's own record is changed (its type), so the paths and newline probes
# stay green and the refusal must name blob-paths and nothing else.
@test "fails closed: the blob-paths probe alone refuses, naming blob-paths" {
  broken_copy 's/100644 blob 0a1b\\tdir\/probe/100644 tree 0a1b\\tdir\/probe/'
  run "$BATS_TEST_TMPDIR/scrub-broken.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"history's blob-paths;"*"refusing to scan"* ]]
  [[ $output != *clean* ]]
}

@test "fails closed: --history refuses to run when a path with a newline can forge a blob pair" {
  broken_copy "s/if \\[\\[ \$path == \\*\\\$'\\\\n'\\* \\]\\]; then path=.*; fi/:/"
  run "$BATS_TEST_TMPDIR/scrub-broken.sh" --history
  [ "$status" -eq 1 ]
  [[ $output == *"blob-paths-newline"*"refusing to scan"* ]]
  [[ $output != *clean* ]]
}
