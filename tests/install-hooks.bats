#!/usr/bin/env bats
# tools/install-hooks.sh in a scratch repo: the hook lands where git runs it, from the main
# checkout and from a linked worktree (where .git is a file, not a directory).

setup() {
  # A private HOME: the developer's own global git config (a global core.hooksPath) stays out.
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  T="$BATS_TEST_TMPDIR/main"
  mkdir -p "$T/tools"
  cp "$REPO/tools/install-hooks.sh" "$T/tools/"
  if [[ -e $REPO/tools/lint-markdown.sh ]]; then cp "$REPO/tools/lint-markdown.sh" "$T/tools/"; fi
  # npx stub: records its arguments, and the content of each file it was given (a leading : marks
  # a literal path); NPX_RC sets its exit (a markdownlint finding is 1).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "npx $*" >> "%s/npx-calls"\nfor a; do f=${a#:}; [ -f "$f" ] && cat "$f" >> "%s/npx-linted"; done\nexit "${NPX_RC:-0}"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/npx"
  chmod +x "$BATS_TEST_TMPDIR/bin/npx"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf '#!/bin/sh\necho scrub-ran >> "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$T/tools/scrub.sh"
  printf 'open("%s/ran", "a").write("lint-ran\\n")\n' "$BATS_TEST_TMPDIR" > "$T/tools/lint-skills.py"
  chmod +x "$T/tools/scrub.sh"   # as in the real tree
  git -C "$T" init -q
  git -C "$T" add -A
  git -C "$T" commit -qm init
}

commit_in() { # commit_in DIR: one commit there, so git runs the pre-commit hook
  echo x >> "$1/f"
  git -C "$1" add f
  git -C "$1" commit -qm x
}

@test "from the main checkout: installed, and a commit runs the scrub and the lint" {
  cd "$T"
  run tools/install-hooks.sh
  [ "$status" -eq 0 ]
  commit_in "$T"
  grep -qx scrub-ran "$BATS_TEST_TMPDIR/ran"
  grep -qx lint-ran "$BATS_TEST_TMPDIR/ran"
}

@test "from a linked worktree: installed, and a commit there runs the scrub" {
  git -C "$T" worktree add -q -b wt "$BATS_TEST_TMPDIR/wt"
  cd "$BATS_TEST_TMPDIR/wt"
  run tools/install-hooks.sh
  [ "$status" -eq 0 ]
  commit_in "$BATS_TEST_TMPDIR/wt"
  grep -qx scrub-ran "$BATS_TEST_TMPDIR/ran"
}

@test "installed from a worktree, the hook also runs in the main checkout" {
  git -C "$T" worktree add -q -b wt "$BATS_TEST_TMPDIR/wt"
  cd "$BATS_TEST_TMPDIR/wt"
  run tools/install-hooks.sh
  [ "$status" -eq 0 ]
  commit_in "$T"
  grep -qx scrub-ran "$BATS_TEST_TMPDIR/ran"
}

@test "a local core.hooksPath: refuses, rather than writing a hook git won't run" {
  git -C "$T" config core.hooksPath .githooks
  cd "$T"
  run tools/install-hooks.sh
  [ "$status" -ne 0 ]
  [[ $output == *core.hooksPath* ]]
}

@test "a core.hooksPath from an included file or config.worktree: refuses too" {
  printf '[core]\n\thooksPath = .githooks\n' > "$BATS_TEST_TMPDIR/hp.inc"
  git -C "$T" config include.path "$BATS_TEST_TMPDIR/hp.inc"
  cd "$T"
  run tools/install-hooks.sh
  [ "$status" -ne 0 ]
  [[ $output == *core.hooksPath* ]]
  git -C "$T" config --unset include.path
  git -C "$T" config extensions.worktreeConfig true
  git -C "$T" config --worktree core.hooksPath .githooks
  run tools/install-hooks.sh
  [ "$status" -ne 0 ]
  [[ $output == *core.hooksPath* ]]
}

@test "a core.hooksPath from an includeIf in the global config: refuses" {
  printf '[core]\n\thooksPath = %s\n' "$BATS_TEST_TMPDIR/client-hooks" > "$BATS_TEST_TMPDIR/hp.inc"
  git config --global "includeIf.gitdir:$T/.path" "$BATS_TEST_TMPDIR/hp.inc"
  cd "$T"
  run tools/install-hooks.sh
  [ "$status" -ne 0 ]
  [[ $output == *core.hooksPath* ]]
}

@test "a global core.hooksPath (the push-gate dispatcher) doesn't stop it: the dispatcher chains to the hook" {
  mkdir -p "$BATS_TEST_TMPDIR/global-hooks"
  printf '#!/bin/sh\nown="$(git rev-parse --git-common-dir)/hooks/pre-commit"\n[ -x "$own" ] && exec "$own" "$@"\nexit 0\n' \
    > "$BATS_TEST_TMPDIR/global-hooks/pre-commit"
  chmod +x "$BATS_TEST_TMPDIR/global-hooks/pre-commit"
  git config --global core.hooksPath "$BATS_TEST_TMPDIR/global-hooks"
  cd "$T"
  run tools/install-hooks.sh
  [ "$status" -eq 0 ]
  commit_in "$T"
  grep -qx scrub-ran "$BATS_TEST_TMPDIR/ran"
}

# --- markdownlint on staged Markdown (tools/lint-markdown.sh) ---------------------------------

md_commit() { # md_commit FILE...: stage the files (Markdown or not) and commit in $T
  local f
  for f; do echo "# x" > "$T/$f"; git -C "$T" add "$f"; done
  git -C "$T" commit -qm md
}

@test "a staged Markdown file runs the pinned markdownlint-cli2 on it" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  md_commit "a doc.md" b.txt
  grep -qx 'npx -y markdownlint-cli2@0.18.1 :a doc.md' "$BATS_TEST_TMPDIR/npx-calls"
}

@test "the staged copy is linted, not the working tree" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  echo "# staged" > "$T/a.md"; git -C "$T" add a.md
  echo "# working tree" > "$T/a.md"
  git -C "$T" commit -qm md
  grep -qx '# staged' "$BATS_TEST_TMPDIR/npx-linted"
  ! grep -q 'working tree' "$BATS_TEST_TMPDIR/npx-linted" || false
}

@test "a staged path that looks like a glob or a negation is passed literally" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  md_commit '!x.md' '[a].md'
  grep -qx 'npx -y markdownlint-cli2@0.18.1 :!x.md :\[a\].md' "$BATS_TEST_TMPDIR/npx-calls"
  [ "$(grep -c '^# x$' "$BATS_TEST_TMPDIR/npx-linted")" -eq 2 ]
}

@test "a markdownlint finding refuses the commit" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  head=$(git -C "$T" rev-parse HEAD)
  NPX_RC=1 run md_commit a.md
  [ "$status" -ne 0 ]
  [ "$(git -C "$T" rev-parse HEAD)" = "$head" ]
}

@test "staged Markdown and no npx: the commit is refused, saying what to install" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  rm "$BATS_TEST_TMPDIR/bin/npx"
  # Drop every PATH directory that has an npx (git, sh and the rest stay).
  local d keep=()
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do [[ -x $d/npx ]] || keep+=("$d"); done
  PATH=$(IFS=:; echo "${keep[*]}")
  [ -z "$(command -v npx)" ]
  head=$(git -C "$T" rev-parse HEAD)
  run md_commit a.md
  [ "$status" -ne 0 ]
  [[ $output == *npx*Node.js* ]]
  [ "$(git -C "$T" rev-parse HEAD)" = "$head" ]
}

@test "no staged Markdown: markdownlint doesn't run, and npx isn't needed" {
  cd "$T"; run tools/install-hooks.sh; [ "$status" -eq 0 ]
  rm "$BATS_TEST_TMPDIR/bin/npx"
  md_commit b.txt
  [ ! -e "$BATS_TEST_TMPDIR/npx-calls" ]
}
