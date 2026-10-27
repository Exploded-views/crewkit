#!/usr/bin/env bats
# crew-lanes: lane-new creates (or reuses) a lane's worktree and branch.

load lanes-helpers

setup() { setup_lanes; }

@test "creates the worktree and branch from origin/main, commits the lane note, pushes" {
  run "$BIN/lane-new" fix-login
  [ "$status" -eq 0 ]
  wt="$MAIN/.claude/worktrees/fix-login"
  [ -d "$wt" ]
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = lane/fix-login ]
  [ -f "$wt/docs/lanes/fix-login.md" ]
  [ "$(git -C "$wt" log -1 --format=%s)" = "chore(fix-login): open lane" ]
  git -C "$MAIN" ls-remote --exit-code --heads origin lane/fix-login >/dev/null
  [[ $output == "WORKTREE $wt BRANCH lane/fix-login HEAD $(git -C "$wt" rev-parse HEAD)" ]]
}

@test "a second run reuses the worktree and adds no commit" {
  "$BIN/lane-new" fix-login >/dev/null
  head=$(git -C "$MAIN/.claude/worktrees/fix-login" rev-parse HEAD)
  run "$BIN/lane-new" fix-login
  [ "$status" -eq 0 ]
  [ "$(git -C "$MAIN/.claude/worktrees/fix-login" rev-parse HEAD)" = "$head" ]
}

@test "a lane branch that exists only on origin is tracked, not recreated" {
  git -C "$MAIN" branch lane/remote-only
  git -C "$MAIN" push -q origin lane/remote-only
  git -C "$MAIN" branch -q -D lane/remote-only
  run "$BIN/lane-new" remote-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$MAIN/.claude/worktrees/remote-only" rev-parse --abbrev-ref '@{u}')" = origin/lane/remote-only ]
}

@test "the lane name is made safe for paths and branches" {
  run "$BIN/lane-new" "auth: token reuse"
  [ "$status" -eq 0 ]
  [ -d "$MAIN/.claude/worktrees/auth--token-reuse" ]
  [ "$(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads/lane/)" = lane/auth--token-reuse ]
}

@test ".lane/ scratch is ignored through the shared exclude, added once" {
  "$BIN/lane-new" one >/dev/null
  "$BIN/lane-new" two >/dev/null
  "$BIN/lane-new" one >/dev/null
  common=$(git -C "$MAIN" rev-parse --git-common-dir)
  [ "$(grep -cx '.lane/' "$common/info/exclude")" -eq 1 ]
  mkdir -p "$MAIN/.claude/worktrees/one/.lane"; echo x > "$MAIN/.claude/worktrees/one/.lane/log"
  [ -z "$(git -C "$MAIN/.claude/worktrees/one" status --porcelain)" ]
}

@test "the packet's exemptions are written to .lane/exemptions.txt" {
  printf '%s' '{"lane":"fix-login","issues":[{"issue":1,"exemptions":["src/a.ts because x","src/b.ts"]},{"issue":2,"exemptions":["src/a.ts"]}]}' \
    > "$CREWKIT_CAMPAIGN_DIR/lanes/fix-login.json"
  "$BIN/lane-new" fix-login >/dev/null
  [ "$(cat "$MAIN/.claude/worktrees/fix-login/.lane/exemptions.txt")" = "$(printf 'src/a.ts\nsrc/b.ts')" ]
}

@test "lane.setup_hook runs in the new worktree with the lane's details" {
  settings 'lane.setup_hook: echo "$LANE $BRANCH $PWD" > "$WORKTREE/.lane/setup-ran"'
  "$BIN/lane-new" fix-login >/dev/null
  wt="$MAIN/.claude/worktrees/fix-login"
  [ "$(cat "$wt/.lane/setup-ran")" = "fix-login lane/fix-login $wt" ]
}

@test "a failing setup hook fails the command" {
  settings 'lane.setup_hook: exit 3'
  run "$BIN/lane-new" fix-login
  [ "$status" -eq 1 ]
  [[ $output == *"setup hook"* ]]
}

@test "branch_prefix.lane and main_branch are honoured" {
  git -C "$MAIN" checkout -q -b trunk
  git -C "$MAIN" push -q origin trunk
  settings 'branch_prefix.lane: fix/' 'main_branch: trunk'
  run "$BIN/lane-new" x
  [ "$status" -eq 0 ]
  [ "$(git -C "$MAIN/.claude/worktrees/x" rev-parse --abbrev-ref HEAD)" = fix/x ]
}

@test "the repo's own commit hooks don't block the lane note" {
  printf '#!/bin/sh\nexit 1\n' > "$MAIN/.git/hooks/pre-commit"
  chmod +x "$MAIN/.git/hooks/pre-commit"
  run "$BIN/lane-new" fix-login
  [ "$status" -eq 0 ]
}

@test "no lane name is a usage error" {
  run "$BIN/lane-new"
  [ "$status" -eq 64 ]
}

@test "a lane whose worktree was removed is recreated on its existing branch" {
  "$BIN/lane-new" fix-login >/dev/null
  wt="$MAIN/.claude/worktrees/fix-login"
  echo more > "$wt/b.txt"; git -C "$wt" add b.txt; git -C "$wt" commit -qm "local work"
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$MAIN" worktree remove "$wt"
  run "$BIN/lane-new" fix-login
  [ "$status" -eq 0 ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]
}
