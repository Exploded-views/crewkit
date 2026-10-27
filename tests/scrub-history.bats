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
