#!/usr/bin/env bats
# crew-lanes: lane-hygiene, the deterministic clean-worktree check run after every agent step.
# Fixture tests for each way a worktree can be unclean, plus the JSON contract and exit codes.

load lanes-helpers

setup() {
  setup_lanes
  "$BIN/lane-new" x >/dev/null
  WT="$MAIN/.claude/worktrees/x"
}

hy() { run "$BIN/lane-hygiene" "$WT" lane/x "$@"; }
field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(str(v).lower() if isinstance(v,bool) else v)' "$output" "$1"; }

@test "a clean tree is clean: exit 0, one JSON object" {
  hy
  [ "$status" -eq 0 ]
  [ "$(field clean)" = true ]
  [ "$(field branchOk)" = true ]
  [ "$(field detail)" = clean ]
  [ "$(field headSha)" = "$(git -C "$WT" rev-parse HEAD)" ]
}

@test "another session's stash entry is not dirt" {
  echo b >> "$WT/a.txt"
  git -C "$WT" stash push -q -m "other session WIP"
  hy
  [ "$status" -eq 0 ]
}

@test ".lane/ scratch files are not dirt" {
  mkdir -p "$WT/.lane/cov"; echo log > "$WT/.lane/run.log"; echo x > "$WT/.lane/cov/lcov.info"
  hy
  [ "$status" -eq 0 ]
}

@test "a modified tracked file is dirty: exit 1, named in the detail" {
  echo c >> "$WT/a.txt"
  hy
  [ "$status" -eq 1 ]
  [ "$(field clean)" = false ]
  [[ $(field detail) == *"uncommitted path(s)"*a.txt* ]]
}

@test "an untracked file is dirty" {
  echo new > "$WT/new.txt"
  hy
  [ "$status" -eq 1 ]
  [[ $(field detail) == *new.txt* ]]
}

@test "a .lane patch file is dirty (a cut-off revert or probe left behind)" {
  echo p > "$WT/.lane/cut.patch"
  hy
  [ "$status" -eq 1 ]
  [[ $(field detail) == *".lane patch file"* ]]
}

@test "the wrong branch is dirty" {
  run "$BIN/lane-hygiene" "$WT" lane/y
  [ "$status" -eq 1 ]
  [[ $output == *"expected 'lane/y'"* ]]
  [ "$(field branchOk)" = false ]
}

@test "an operation in progress is dirty" {
  for m in REVERT_HEAD MERGE_HEAD CHERRY_PICK_HEAD; do
    touch "$(git -C "$WT" rev-parse --absolute-git-dir)/$m"
    hy
    [ "$status" -eq 1 ]
    [[ $(field detail) == *"$m"* ]]
    rm "$(git -C "$WT" rev-parse --absolute-git-dir)/$m"
  done
}

@test "a moved main checkout head is dirty when --main-head is given" {
  hy --main-head "$(hex40 0)"
  [ "$status" -eq 1 ]
  [[ $(field detail) == *"main checkout HEAD moved"* ]]
  hy --main-head "$(git -C "$MAIN" rev-parse HEAD)"
  [ "$status" -eq 0 ]
}

@test "the product hash covers the named files at HEAD" {
  hy a.txt
  [ "$status" -eq 0 ]
  [ "$(field productHash)" = "$(git -C "$WT" show HEAD:a.txt | sha256sum | cut -d' ' -f1)" ]
  hy
  [ "$(field productHash)" = n/a ]
}

@test "the last result is kept in .lane/hygiene-last.json" {
  hy
  [ "$(cat "$WT/.lane/hygiene-last.json")" = "$output" ]
}

@test "not a git worktree: exit 1 with a JSON detail" {
  run "$BIN/lane-hygiene" "$BATS_TEST_TMPDIR/nowhere" lane/x
  [ "$status" -eq 1 ]
  [[ $output == *'"clean": false'* || $output == *'"clean":false'* ]]
}

@test "bad usage: exit 2, still one JSON object" {
  run "$BIN/lane-hygiene" "$WT"
  [ "$status" -eq 64 ]
  python3 -c 'import json,sys; json.loads(sys.argv[1])' "$output"
}

@test "it never changes the worktree" {
  echo c >> "$WT/a.txt"
  before=$(git -C "$WT" status --porcelain; git -C "$WT" stash list)
  hy
  [ "$(git -C "$WT" status --porcelain; git -C "$WT" stash list)" = "$before" ]
}

@test "the JSON stays valid for paths with quotes, backslashes and tabs" {
  printf 'x' > "$WT/we\"ird\\name	tab.txt"
  hy
  [ "$status" -eq 1 ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "ird" in d["detail"], d' "$output"
}
