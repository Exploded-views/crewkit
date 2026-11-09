# rtk alongside crewkit

[rtk](https://github.com/rtk-ai/rtk) is a CLI proxy that shortens command output before it
reaches the model. `./install.sh --yes --only rtk` installs the pinned release (v1.1.0) and
runs `rtk init -g --auto-patch`; your other hooks are checked afterwards (see
[install.md](install.md)).

rtk rewrites shell commands (for example `git status` to `rtk git status`) through a
`PreToolUse` hook on the `Bash` tool, and filters their output. `rtk gain` shows how
many tokens it has saved you.

## Alongside other `PreToolUse` hooks

- Claude Code runs every matching hook for a tool call, independently. Give rtk its own entry
  with `"matcher": "Bash"`, and keep guard hooks as separate entries rather than chaining them
  in one script.
- Write guard hooks to judge the command as Claude wrote it, not rtk's rewritten form. A deny
  from any hook stops the call. Check the hooks docs for your Claude Code version if you
  depend on ordering.
- Allow `Bash(rtk *)` in your permissions if you use auto mode, so the rewritten commands are
  judged like the originals.
- Use `rtk bypass <cmd>` when you need unfiltered output (`rtk proxy` is its older name and
  still works).
