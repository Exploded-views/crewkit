#!/usr/bin/env bats
# The memory-notices hooks, run the way Claude Code runs them: each command through a shell
# with the hook's JSON on stdin.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export CLAUDE_PLUGIN_ROOT="$REPO/plugins/memory-notices"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  # Only the basics on PATH, so a real claude-memsync on this machine can't leak in.
  BASE_PATH="$STUBS:/usr/bin:/bin"
}

# memsync_commands: every hook command that calls claude-memsync, one per line.
memsync_commands() {
  python3 -c 'import json,sys
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            if "claude-memsync" in h["command"]:
                print(h["command"])' "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json"
}

@test "every claude-memsync hook is a silent no-op when claude-memsync isn't installed" {
  local cmd n=0
  while IFS= read -r cmd; do
    n=$((n + 1))
    run env PATH="$BASE_PATH" sh -c "$cmd" <<<'{"hook_event_name":"UserPromptSubmit"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done < <(memsync_commands)
  [ "$n" -ge 2 ]
}

@test "the hooks call claude-memsync changes --hook when it is installed" {
  printf '#!/bin/sh\necho "called $*"\n' > "$STUBS/claude-memsync"
  chmod +x "$STUBS/claude-memsync"
  local cmd
  while IFS= read -r cmd; do
    run env PATH="$BASE_PATH" sh -c "$cmd" <<<'{}'
    [ "$status" -eq 0 ]
    [ "$output" = "called changes --hook" ]
  done < <(memsync_commands)
}
