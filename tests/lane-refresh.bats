#!/usr/bin/env bats
# crew-lanes: lane-refresh merges main into a PR's head in a temporary worktree, checks the diff
# against main is still exactly the PR's own change, and pushes without force.

load lanes-helpers

setup() {
  setup_lanes
  use_stub_gh
  settings "repo: o/r"
  commit_on lane/x feature.txt "the lane's change"
  stub_pr 12 lane/x main
}

remote() { git -C "$MAIN" ls-remote origin "refs/heads/$1" | cut -f1; }
patch_id() { git -C "$MAIN" diff "$1" "$2" | git patch-id --stable | cut -d' ' -f1; }

@test "a PR that already contains main is left alone" {
  before=$(remote lane/x)
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 0 ]
  [[ $output == *"already contains main"* ]]
  [ "$(remote lane/x)" = "$before" ]
}

@test "main is merged in, pushed without force, and the PR's diff is unchanged" {
  old=$(remote lane/x)
  own=$(patch_id main "$old")
  commit_on main other.txt "someone else landed"
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 0 ]
  [[ $output == *refreshed* ]]
  git -C "$MAIN" fetch -q origin
  new=$(remote lane/x)
  [ "$new" != "$old" ]
  git -C "$MAIN" merge-base --is-ancestor "$old" "$new"
  git -C "$MAIN" merge-base --is-ancestor origin/main "$new"
  [ "$(patch_id origin/main "$new")" = "$own" ]
}

@test "a conflict lists the files, pushes nothing and exits 3" {
  commit_on lane/x shared.txt "lane side"
  commit_on main shared.txt "main side"
  before=$(remote lane/x)
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 3 ]
  [[ $output == *shared.txt* ]]
  [ "$(remote lane/x)" = "$before" ]
}

@test "a merge that silently changes the PR's diff is not pushed (exit 4)" {
  # A different message, or this commit would be byte-identical to the lane's (same parent,
  # tree, message and second) and main would simply contain the lane's head.
  commit_on main feature.txt "the lane's change" "the same change, landed separately"
  commit_on main more.txt "and more"
  before=$(remote lane/x)
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 4 ]
  [[ $output == *"differs from the PR's own change"* ]]
  [ "$(remote lane/x)" = "$before" ]
}

@test "a stacked PR whose parent isn't merged is refused (exit 6)" {
  commit_on lane/child child.txt "child change"
  stub_pr 13 lane/child lane/x
  run "$BIN/lane-refresh" 13
  [ "$status" -eq 6 ]
  [[ $output == *"not merged"* ]]
}

@test "a stacked PR whose parent was squash-merged gets its own change on main, retargeted first" {
  git -C "$MAIN" checkout -q -b lane/child origin/lane/x
  printf 'child change\n' > "$MAIN/child.txt"
  git -C "$MAIN" add child.txt; git -C "$MAIN" commit -qm child; git -C "$MAIN" push -q origin lane/child
  git -C "$MAIN" checkout -q main
  own=$(patch_id origin/lane/x origin/lane/child)
  git -C "$MAIN" merge -q --squash origin/lane/x; git -C "$MAIN" commit -qm "squash of lane/x"; git -C "$MAIN" push -q origin main
  stub_pr 12 lane/x main MERGED
  stub_pr 13 lane/child lane/x
  run "$BIN/lane-refresh" 13
  [ "$status" -eq 0 ]
  [ "$(jq -r .baseRefName "$STUB/pr/13.json")" = main ]
  edit_line=$(grep -n '^pr edit 13' "$STUB/calls.log" | cut -d: -f1)
  [ -n "$edit_line" ]
  git -C "$MAIN" fetch -q origin
  [ "$(patch_id origin/main origin/lane/child)" = "$own" ]
}

@test "a push that doesn't land on the remote exits 5" {
  commit_on main other.txt "someone else landed"
  printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/lane/x ] && git update-ref "$ref" "$old"; done\nexit 0\n' > "$ORIGIN/hooks/post-receive"
  chmod +x "$ORIGIN/hooks/post-receive"
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 5 ]
}

@test "the lane's own worktree is never touched, and the temp worktree is removed" {
  "$BIN/lane-new" x >/dev/null
  wt="$MAIN/.claude/worktrees/x"
  echo "work in progress" > "$wt/wip.txt"
  commit_on main other.txt "someone else landed"
  "$BIN/lane-refresh" 12 >/dev/null
  [ -f "$wt/wip.txt" ]
  none -q 'lane-refresh/12' <(git -C "$MAIN" worktree list)
}

@test "it never force-pushes" {
  commit_on main other.txt "someone else landed"
  export GIT_TRACE=1
  run "$BIN/lane-refresh" 12
  [ "$status" -eq 0 ]
  none -qE -- 'push.*(--force|-f |\+refs|\+HEAD)' <<<"$output"
}

@test "usage errors exit 2" {
  run "$BIN/lane-refresh"
  [ "$status" -eq 64 ]
  run "$BIN/lane-refresh" abc
  [ "$status" -eq 64 ]
}
