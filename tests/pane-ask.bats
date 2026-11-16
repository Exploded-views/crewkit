#!/usr/bin/env bats
# crew-nodes: pane-ask, one message to an agent session in herdr on another node and its reply,
# as a thin wrapper over `herdr agent prompt --wait` and `herdr agent read`. ssh and herdr are
# stubs (tests/stubs/ssh, tests/stubs/herdr): ssh runs the remote command with sh -c in a fake
# remote home, where herdr sits at ~/.local/bin/herdr and is not on PATH. For a saved herdr
# machine (`--machine`), the stub herdr is the local one. No real host is ever called.
# Every nodes.* setting is file-only, so the tests write the test HOME's settings file.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  BIN="$REPO/plugins/crew-nodes/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  export PSTUB="$BATS_TEST_TMPDIR/pstub"
  mkdir -p "$HOME/.claude" "$PSTUB/remote/.local/bin" "$BATS_TEST_TMPDIR/bin"
  while IFS= read -r v; do unset "$v"; done < <(compgen -v | grep '^CREWKIT_' || true)
  ln -s "$REPO/tests/stubs/ssh" "$BATS_TEST_TMPDIR/bin/ssh"
  ln -s "$REPO/tests/stubs/herdr" "$PSTUB/remote/.local/bin/herdr"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  : > "$PSTUB/ssh.log"
  : > "$PSTUB/herdr.log"
  printf 'earlier work\nolder output\n' > "$PSTUB/screen"
  printf 'reply line 1\nreply line 2\n' > "$PSTUB/reply"
  statuses idle
  cd "$BATS_TEST_TMPDIR" || return 1
  # This host is "home", its bridge is "homebridge" and the caller is that bridge; the node
  # "lab" is another host whose bridge is wX:pY (the target most tests use).
  export HERDR_PANE_ID=homebridge
  unset HERDR_SESSION
  user_setting "nodes.default: lab" "nodes.lab.host: agent-host" "nodes.prefix: lead" \
    "nodes.home.this_host: true" "nodes.home.bridge: homebridge" "nodes.lab.bridge: wX:pY" \
    "nodes.local_herdr: $BATS_TEST_TMPDIR/no-herdr"
}

# statuses S...: what `herdr agent get` and `agent wait` see, one per call; the last repeats.
statuses() { printf '%s\n' "$@" > "$PSTUB/status"; }

# user_setting KEY: VALUE...: set keys in the test HOME's ~/.claude/crewkit.md, replacing any
# earlier value of the same key.
user_setting() {
  local f="$HOME/.claude/crewkit.md" kv keys=()
  for kv in "$@"; do keys+=("${kv%%:*}"); done
  {
    echo ---
    [[ -f $f ]] && awk -v drop=" ${keys[*]} " 'NR > 1 && $0 != "---" { k = $0; sub(/:.*/, "", k); if (index(drop, " " k " ") == 0) print }' "$f"
    printf '%s\n' "$@"
    echo ---
  } > "$f.new" && mv "$f.new" "$f"
}

# local_herdr: the stub herdr as the local herdr (a saved machine profile, a caller lookup, a local
# node). Without it, nodes.local_herdr is a path that doesn't exist: no test reaches a real herdr.
local_herdr() {
  ln -s "$REPO/tests/stubs/herdr" "$BATS_TEST_TMPDIR/bin/herdr"
  user_setting "nodes.local_herdr: $BATS_TEST_TMPDIR/bin/herdr"
}

none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}

# ---- usage and settings ----------------------------------------------------------------------

@test "no arguments is a usage error" {
  run "$BIN/pane-ask"
  [ "$status" -eq 64 ]
  [[ $output == *usage* ]]
}

@test "an empty message, or too many arguments, is a usage error" {
  run "$BIN/pane-ask" wX:pY ""
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" wX:pY a b
  [ "$status" -eq 64 ]
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "an unknown option, or a malformed number, is a usage error" {
  run "$BIN/pane-ask" --bogus wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --timeout soon wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --read --lines many wX:pY
  [ "$status" -eq 64 ]
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "--node, --host and --machine are exclusive" {
  run "$BIN/pane-ask" --host agent-host --machine lab wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --node lab --host agent-host wX:pY hi
  [ "$status" -eq 64 ]
}

@test "no node, host or machine anywhere is a config error (78) naming nodes.default" {
  user_setting "nodes.default: "
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.default* ]]
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "a node with neither host nor machine is a config error (78)" {
  run "$BIN/pane-ask" --node ghost wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.ghost.host* ]]
}

@test "bad settings are config errors (78)" {
  user_setting "nodes.timeout_seconds: soon"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.timeout_seconds* ]]
  user_setting "nodes.timeout_seconds: 9" "nodes.wait_idle: maybe"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "nodes.* settings are file-only: CREWKIT_* can't point pane-ask at another host" {
  export CREWKIT_NODES_LAB_HOST=evil-host CREWKIT_NODES_DEFAULT=other
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 0 ]
  grep -q -- '-- agent-host ' "$PSTUB/ssh.log"
  none 'evil-host' "$PSTUB/ssh.log"
}

@test "a host, machine label or node name that starts with a dash is refused before anything runs" {
  run "$BIN/pane-ask" --host -Fevil wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --host "-oProxyCommand=touch $PSTUB/pwned" wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --machine -x wX:pY hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" --node -x wX:pY hi
  [ "$status" -eq 64 ]
  user_setting "nodes.lab.host: -Fevil"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [ ! -s "$PSTUB/ssh.log" ]
  [ ! -e "$PSTUB/pwned" ]
}

@test "a target that starts with a dash or holds shell characters is refused" {
  run "$BIN/pane-ask" -- --help hi
  [ "$status" -eq 64 ]
  run "$BIN/pane-ask" "wX:pY';touch $PSTUB/pwned;'" hi
  [ "$status" -eq 64 ]
  [ ! -s "$PSTUB/ssh.log" ]
  [ ! -e "$PSTUB/pwned" ]
}

@test "a prefix that starts with a dash is refused" {
  run "$BIN/pane-ask" --prefix -x wX:pY hi
  [ "$status" -eq 64 ]
}

# ---- lead panes ------------------------------------------------------------------------------

@test "a target listed in the node's lead_pane is refused (65), nothing sent" {
  user_setting "nodes.lab.bridge: w1:p10"
  user_setting "nodes.lab.lead_pane: w1:p1, lead"
  run "$BIN/pane-ask" w1:p1 "hi"
  [ "$status" -eq 65 ]
  [[ $output == *lead* ]]
  run "$BIN/pane-ask" lead "hi"
  [ "$status" -eq 65 ]
  [ ! -s "$PSTUB/ssh.log" ]
  run "$BIN/pane-ask" w1:p10 "hi"
  [ "$status" -eq 0 ]
}

@test "with --host or --machine, a lead pane of any node is refused" {
  user_setting "nodes.other.host: other-host" "nodes.other.lead_pane: w9:p9"
  run "$BIN/pane-ask" --host agent-host w9:p9 "hi"
  [ "$status" -eq 65 ]
  run "$BIN/pane-ask" --machine lab w9:p9 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a lead pane reached by its agent name is refused (65): the pane herdr resolves is checked" {
  user_setting "nodes.lab.bridge: claude-lead"
  user_setting "nodes.lab.lead_pane: w1:p1"
  echo "claude-lead w1:p1 claude-lead" > "$PSTUB/agents"
  run "$BIN/pane-ask" claude-lead "hi"
  [ "$status" -eq 65 ]
  [[ $output == *lead* ]]
  [ ! -e "$PSTUB/sent.1" ]
  none -E '^agent (prompt|wait) ' "$PSTUB/herdr.log"
}

@test "a lead listed by agent name, reached by its pane id, is refused (65)" {
  user_setting "nodes.lab.bridge: w5:p5"
  user_setting "nodes.lab.lead_pane: Lead-Agent"
  echo "w5:p5 w5:p5 lead-agent" > "$PSTUB/agents"
  run "$BIN/pane-ask" w5:p5 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
  none '^agent prompt ' "$PSTUB/herdr.log"
}

@test "herdr's agent field is the agent's kind: a lead list naming claude doesn't refuse an unrelated claude pane" {
  user_setting "nodes.lab.bridge: w5:p5"
  user_setting "nodes.lab.lead_pane: claude"
  run "$BIN/pane-ask" w5:p5 "hi"
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "lead: hi" ]
}

@test "a lead listed by name, targeted by its pane id, is refused (65): herdr's name field is checked" {
  user_setting "nodes.lab.bridge: w1:p1"
  user_setting "nodes.lab.lead_pane: lead"
  echo "w1:p1 w1:p1 lead" > "$PSTUB/agents"
  run "$BIN/pane-ask" w1:p1 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
  none '^agent prompt ' "$PSTUB/herdr.log"
}

@test "an agent with no name is checked and reached by its pane id" {
  user_setting "nodes.lab.bridge: w5:p5"
  user_setting "nodes.lab.lead_pane: w1:p1, lead"
  echo "w5:p5 w5:p5 -" > "$PSTUB/agents"
  run "$BIN/pane-ask" w5:p5 "hi"
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "lead: hi" ]
  echo "w1:p1 w1:p1 -" > "$PSTUB/agents"
  user_setting "nodes.lab.bridge: w1:p1"
  rm "$PSTUB/sent.1"
  run "$BIN/pane-ask" --host agent-host w1:p1 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "the lead-pane check ignores case, typed or resolved" {
  user_setting "nodes.lab.bridge: boss"
  user_setting "nodes.lab.lead_pane: Lead, W1:P1"
  run "$BIN/pane-ask" LEAD "hi"
  [ "$status" -eq 65 ]
  run "$BIN/pane-ask" w1:p1 "hi"
  [ "$status" -eq 65 ]
  # Refused as typed, before herdr is called at all.
  [ ! -s "$PSTUB/ssh.log" ]
  echo "boss W1:p1 -" > "$PSTUB/agents"
  run "$BIN/pane-ask" boss "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "with --host, a target that resolves to any node's lead pane is refused (65)" {
  user_setting "nodes.lab.bridge: boss"
  user_setting "nodes.other.host: other-host" "nodes.other.lead_pane: w9:p9"
  echo "boss w9:p9 boss" > "$PSTUB/agents"
  run "$BIN/pane-ask" --host agent-host boss "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a bridge that is itself a lead pane is refused (65), typed or resolved" {
  user_setting "nodes.lab.bridge: lead" "nodes.lab.lead_pane: lead"
  run "$BIN/pane-ask" "hi"
  [ "$status" -eq 65 ]
  user_setting "nodes.lab.bridge: bridge" "nodes.lab.lead_pane: w1:p1"
  echo "bridge w1:p1 bridge" > "$PSTUB/agents"
  run "$BIN/pane-ask" "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a space-separated lead list is several entries, not one" {
  user_setting "nodes.lab.lead_pane: w1:p1 w2:p2"
  run "$BIN/pane-ask" w2:p2 "hi"
  [ "$status" -eq 65 ]
  run "$BIN/pane-ask" w1:p1 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a project's settings can't change nodes.*: its lead list, host and bridge are ignored" {
  user_setting "nodes.lab.lead_pane: w1:p1"
  mkdir -p "$BATS_TEST_TMPDIR/proj/.claude" "$BATS_TEST_TMPDIR/proj/sub"
  touch "$BATS_TEST_TMPDIR/proj/.git"
  printf -- '---\nnodes.lab.lead_pane: ""\nnodes.lab.host: evil-host\n---\n' > "$BATS_TEST_TMPDIR/proj/.claude/crewkit.local.md"
  printf -- '---\nnodes.lab.lead_pane: other\nnodes.lab.bridge: w1:p1\n---\n' > "$BATS_TEST_TMPDIR/proj/.claude/crewkit.md"
  cd "$BATS_TEST_TMPDIR/proj/sub"
  run "$BIN/pane-ask" w1:p1 "hi"
  [ "$status" -eq 65 ]
  [ ! -e "$PSTUB/sent.1" ]
  # the project's bridge (w1:p1) is ignored: the default target is the user's bridge
  run "$BIN/pane-ask" --read
  [ "$status" -eq 0 ]
  grep -qx 'agent read wX:pY --source recent-unwrapped --lines 80' "$PSTUB/herdr.log"
  grep -q -- '-- agent-host ' "$PSTUB/ssh.log"
  none 'evil-host' "$PSTUB/ssh.log"
}

@test "reading a lead pane that is not the bridge is refused as not a bridge (45)" {
  user_setting "nodes.lab.lead_pane: w1:p1"
  run "$BIN/pane-ask" --read w1:p1
  [ "$status" -eq 45 ]
}

# ---- --read ----------------------------------------------------------------------------------

@test "--read prints the agent's tail with agent read, without sending anything" {
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 0 ]
  [ "$output" = $'earlier work\nolder output' ]
  grep -qx 'agent read wX:pY --source recent-unwrapped --lines 80' "$PSTUB/herdr.log"
  none -E '^agent (prompt|get|wait) ' "$PSTUB/herdr.log"
}

@test "--read --lines N reads N lines, and nodes.read_lines sets the default" {
  user_setting "nodes.lab.bridge: reviewer"
  run "$BIN/pane-ask" --read --lines 1 reviewer
  [ "$status" -eq 0 ]
  [ "$output" = "older output" ]
  grep -qx 'agent read reviewer --source recent-unwrapped --lines 1' "$PSTUB/herdr.log"
  user_setting "nodes.read_lines: 7" "nodes.lab.bridge: wX:pY"
  run "$BIN/pane-ask" --read wX:pY
  grep -qx 'agent read wX:pY --source recent-unwrapped --lines 7' "$PSTUB/herdr.log"
}

@test "the target defaults to the node's bridge" {
  user_setting "nodes.lab.bridge: bridge"
  run "$BIN/pane-ask" --read
  [ "$status" -eq 0 ]
  grep -qx 'agent read bridge --source recent-unwrapped --lines 80' "$PSTUB/herdr.log"
  run "$BIN/pane-ask" "one message"
  [ "$status" -eq 0 ]
  grep -qx 'agent prompt bridge lead: one message --wait --timeout 900000' "$PSTUB/herdr.log"
}

@test "no target and no bridge is a usage error" {
  user_setting "nodes.lab.bridge: "
  run "$BIN/pane-ask" "just a message"
  [ "$status" -eq 64 ]
  [[ $output == *bridge* ]]
}

@test "--node picks another node; --host is an ad hoc ssh target; ssh runs in batch mode" {
  user_setting "nodes.far.host: far-host" "nodes.far.bridge: wX:pY" "nodes.other.host: other-host" "nodes.other.bridge: wX:pY"
  run "$BIN/pane-ask" --read --node far wX:pY
  [ "$status" -eq 0 ]
  grep -q -- '-- far-host ' "$PSTUB/ssh.log"
  run "$BIN/pane-ask" --read --host other-host wX:pY
  [ "$status" -eq 0 ]
  grep -q -- '-- other-host ' "$PSTUB/ssh.log"
  grep -q -- '-o BatchMode=yes' "$PSTUB/ssh.log"
  none -- 'agent-host' "$PSTUB/ssh.log"
}

@test "a failed ssh is exit 1 with a message" {
  touch "$PSTUB/ssh_fail"
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 1 ]
  [[ $output == *pane-ask:*agent-host* ]]
}

# ---- asking ----------------------------------------------------------------------------------

@test "a message is sent prefixed, once, with agent prompt --wait and the timeout in ms" {
  run "$BIN/pane-ask" wX:pY "status please"
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "lead: status please" ]
  [ ! -e "$PSTUB/sent.2" ]
  grep -qx 'agent get wX:pY' "$PSTUB/herdr.log"
  grep -qx 'agent prompt wX:pY lead: status please --wait --timeout 900000' "$PSTUB/herdr.log"
  none -E '^(pane|agent wait) ' "$PSTUB/herdr.log"
}

@test "--timeout and nodes.timeout_seconds set the wait" {
  run "$BIN/pane-ask" --timeout 5 wX:pY hi
  grep -q -- '--wait --timeout 5000$' "$PSTUB/herdr.log"
  user_setting "nodes.timeout_seconds: 7"
  run "$BIN/pane-ask" wX:pY hi
  grep -q -- '--wait --timeout 7000$' "$PSTUB/herdr.log"
}

@test "--prefix overrides nodes.prefix, which defaults to orchestrator_name" {
  run "$BIN/pane-ask" --prefix helper wX:pY "a"
  [ "$(cat "$PSTUB/sent.1")" = "helper: a" ]
  user_setting "nodes.prefix: " "orchestrator_name: coordinator"
  run "$BIN/pane-ask" wX:pY "b"
  [ "$status" -eq 78 ]
  printf -- '---\nnodes.default: lab\nnodes.lab.host: agent-host\nnodes.lab.bridge: wX:pY\nnodes.home.this_host: true\nnodes.home.bridge: homebridge\nnodes.local_herdr: /nonexistent/herdr\norchestrator_name: coordinator\n---\n' > "$HOME/.claude/crewkit.md"
  run "$BIN/pane-ask" wX:pY "b"
  [ "$(cat "$PSTUB/sent.2")" = "coordinator: b" ]
}

@test "it prints only the output from the sent message on" {
  run "$BIN/pane-ask" wX:pY "status please"
  [ "$status" -eq 0 ]
  [ "$output" = $'> lead: status please\nreply line 1\nreply line 2' ]
  grep -q '^agent read wX:pY --source recent-unwrapped --lines 1000$' "$PSTUB/herdr.log"
}

@test "an earlier copy of the same message on the screen is skipped: output starts at the last one" {
  printf '> lead: status please\nan old reply\n' >> "$PSTUB/screen"
  run "$BIN/pane-ask" wX:pY "status please"
  [ "$status" -eq 0 ]
  [ "$output" = $'> lead: status please\nreply line 1\nreply line 2' ]
}

@test "a message scrolled out of the read: the whole read is printed, with a note" {
  user_setting "nodes.scan_lines: 1"
  run "$BIN/pane-ask" wX:pY "long"
  [ "$status" -eq 0 ]
  [[ $output == *"scrolled out"* ]]
  [[ $output == *"reply line 2"* ]]
}

@test "a timeout is exit 40: maybe delivered, never resent" {
  echo timeout > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "long job"
  [ "$status" -eq 40 ]
  [[ $output == *timeout* ]]
  [[ $output == *"may have been delivered"* ]]
  [[ $output == *--read* ]]
  [ "$(grep -c '^agent prompt ' "$PSTUB/herdr.log")" -eq 1 ]
}

@test "agent_prompt_stalled is exit 40 too, and not resent" {
  echo agent_prompt_stalled > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "hello?"
  [ "$status" -eq 40 ]
  [[ $output == *agent_prompt_stalled* ]]
  [ "$(grep -c '^agent prompt ' "$PSTUB/herdr.log")" -eq 1 ]
}

@test "agent_blocked from agent prompt is exit 75, nothing sent" {
  echo agent_blocked > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "now"
  [ "$status" -eq 75 ]
  [[ $output == *blocked* ]]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a turn that ends blocked at a dialog is exit 41, with the screen printed" {
  echo blocked > "$PSTUB/prompt_status"
  run "$BIN/pane-ask" wX:pY "deploy it"
  [ "$status" -eq 41 ]
  [[ $output == *"reply line 2"* ]]
  [[ $output == *dialog* ]]
}

@test "any other failure of the send is exit 1 and says not to resend blindly" {
  echo agent_not_running > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "hi"
  [ "$status" -eq 1 ]
  [[ $output == *agent_not_running* ]]
  [[ $output == *--read* ]]
}

@test "a herdr too old for agent prompt --wait (exit 2) is exit 1 naming the minimum version" {
  touch "$PSTUB/old"
  run "$BIN/pane-ask" wX:pY "hi"
  [ "$status" -eq 1 ]
  [[ $output == *0.9.0* ]]
}

@test "noise on stderr before herdr's error JSON keeps exit 40 and 75" {
  cat > "$PSTUB/remote/.local/bin/herdr.wrap" <<EOF
#!/bin/sh
echo "Warning: Permanently added 'agent-host' to the list of known hosts." >&2
exec "$REPO/tests/stubs/herdr" "\$@"
EOF
  chmod +x "$PSTUB/remote/.local/bin/herdr.wrap"
  user_setting "nodes.lab.herdr: ~/.local/bin/herdr.wrap"
  echo timeout > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "long job"
  [ "$status" -eq 40 ]
  echo agent_blocked > "$PSTUB/prompt_error"
  run "$BIN/pane-ask" wX:pY "now"
  [ "$status" -eq 75 ]
}

@test "a lost ssh connection during the send is exit 1 and says not to resend blindly" {
  # The status check passes; then the connection fails.
  cat > "$PSTUB/remote/.local/bin/herdr.wrap" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "agent prompt" ]; then exit 255; fi
exec "$REPO/tests/stubs/herdr" "\$@"
EOF
  chmod +x "$PSTUB/remote/.local/bin/herdr.wrap"
  user_setting "nodes.lab.herdr: ~/.local/bin/herdr.wrap"
  run "$BIN/pane-ask" wX:pY "hi"
  [ "$status" -eq 1 ]
  [[ $output == *"may have been delivered"* ]]
}

# ---- a busy agent ----------------------------------------------------------------------------

@test "a working agent: agent wait for it to settle, then one send" {
  statuses working working idle
  run "$BIN/pane-ask" wX:pY "after you"
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "lead: after you" ]
  grep -qx 'agent wait wX:pY --timeout 900000' "$PSTUB/herdr.log"
  [ "$(grep -n '^agent prompt ' "$PSTUB/herdr.log" | cut -d: -f1)" -eq 3 ]
}

@test "an agent that stays working: exit 75, nothing sent" {
  statuses working
  run "$BIN/pane-ask" wX:pY "after you"
  [ "$status" -eq 75 ]
  [[ $output == *"nothing sent"* ]]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "an agent that settles blocked is not sent to: exit 75" {
  statuses working blocked
  run "$BIN/pane-ask" wX:pY "after you"
  [ "$status" -eq 75 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a blocked agent is refused at once (75), without waiting" {
  statuses blocked
  run "$BIN/pane-ask" wX:pY "now"
  [ "$status" -eq 75 ]
  [[ $output == *blocked* ]]
  none '^agent wait ' "$PSTUB/herdr.log"
  [ ! -e "$PSTUB/sent.1" ]
}

@test "nodes.wait_idle false: a busy agent is refused at once (75)" {
  statuses working idle
  user_setting "nodes.wait_idle: false"
  run "$BIN/pane-ask" wX:pY "now"
  [ "$status" -eq 75 ]
  none '^agent wait ' "$PSTUB/herdr.log"
  [ ! -e "$PSTUB/sent.1" ]
}

@test "unknown counts as busy" {
  statuses unknown
  user_setting "nodes.wait_idle: false"
  run "$BIN/pane-ask" wX:pY "now"
  [ "$status" -eq 75 ]
}

@test "done counts as idle by default; nodes.idle_statuses changes the set" {
  statuses done
  run "$BIN/pane-ask" wX:pY "a"
  [ "$status" -eq 0 ]
  user_setting "nodes.idle_statuses: idle" "nodes.wait_idle: false"
  run "$BIN/pane-ask" wX:pY "b"
  [ "$status" -eq 75 ]
  [ ! -e "$PSTUB/sent.2" ]
}

@test "a space-separated nodes.idle_statuses is several statuses" {
  statuses done
  user_setting "nodes.idle_statuses: idle done" "nodes.wait_idle: false"
  run "$BIN/pane-ask" wX:pY "a"
  [ "$status" -eq 0 ]
  [ -e "$PSTUB/sent.1" ]
}

@test "a failed status read is exit 1, nothing sent" {
  touch "$PSTUB/get_fail"
  run "$BIN/pane-ask" wX:pY "hi"
  [ "$status" -eq 1 ]
  [ ! -e "$PSTUB/sent.1" ]
}

@test "a status reply that isn't herdr's JSON is exit 1, nothing sent" {
  rm "$PSTUB/remote/.local/bin/herdr"
  printf '#!/bin/sh\necho not json\n' > "$PSTUB/remote/.local/bin/herdr"
  chmod +x "$PSTUB/remote/.local/bin/herdr"
  run "$BIN/pane-ask" wX:pY "hi"
  [ "$status" -eq 1 ]
  [[ $output == *agent_status* ]]
}

# ---- quoting ---------------------------------------------------------------------------------

@test "quotes, \$, backticks, \$(...), backslashes and newlines arrive byte for byte, with no remote injection" {
  msg=$'it\'s "quoted" $HOME `touch '"$PSTUB"$'/pwned1` $(touch '"$PSTUB"$'/pwned2)\nline two; touch '"$PSTUB"$'/pwned3\n\'; touch '"$PSTUB"$'/pwned4; \'\\n \\ end @pane-ask-stdin@\n\n'
  run "$BIN/pane-ask" wX:pY "$msg"
  [ "$status" -eq 0 ]
  printf 'lead: %s' "$msg" > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$PSTUB/sent.1"
  [ ! -e "$PSTUB/pwned1" ] && [ ! -e "$PSTUB/pwned2" ] && [ ! -e "$PSTUB/pwned3" ] && [ ! -e "$PSTUB/pwned4" ]
  # The message never rides on the ssh command line.
  none -F 'quoted' "$PSTUB/ssh.log"
}

@test "a prefix with shell characters arrives as it is" {
  run "$BIN/pane-ask" --prefix "a'b \$(touch $PSTUB/pwned)" wX:pY hi
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "a'b \$(touch $PSTUB/pwned): hi" ]
  [ ! -e "$PSTUB/pwned" ]
}

@test "herdr is reached by path: ~/.local/bin/herdr by default, not PATH" {
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 0 ]
  grep -qF '~/.local/bin/herdr' "$PSTUB/ssh.log"
}

@test "nodes.<name>.herdr: a path with spaces and quotes, under ~, is quoted for the remote shell" {
  mkdir -p "$PSTUB/remote/my bin's"
  ln -s "$REPO/tests/stubs/herdr" "$PSTUB/remote/my bin's/herdr \$(touch pwned)"
  user_setting "nodes.lab.herdr: \"~/my bin's/herdr \$(touch pwned)\""
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/sent.1")" = "lead: hi" ]
  [ ! -e "$PSTUB/remote/pwned" ]
}

@test "a backslash in nodes.<name>.herdr is a config error (78), before anything runs" {
  user_setting 'nodes.lab.herdr: ~/bin\herdr'
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.lab.herdr* ]]
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "a missing herdr on the host is exit 1" {
  user_setting "nodes.lab.herdr: ~/nowhere/herdr"
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 1 ]
}

# ---- a saved herdr machine -------------------------------------------------------------------

@test "a node with a machine profile: the local herdr with --machine, no ssh" {
  local_herdr
  user_setting "nodes.lab.machine: lab box"
  msg=$'two\nlines with "quotes" and $(x)'
  run "$BIN/pane-ask" wX:pY "$msg"
  [ "$status" -eq 0 ]
  [ "$output" = $'> lead: two\nlines with "quotes" and $(x)\nreply line 1\nreply line 2' ]
  printf 'lead: %s' "$msg" > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$PSTUB/sent.1"
  grep -qx -- '--machine lab box agent get wX:pY' "$PSTUB/herdr.log"
  grep -q -- '^--machine lab box agent read wX:pY ' "$PSTUB/herdr.log"
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "--machine is an ad hoc profile, and nodes.local_herdr names the local binary" {
  mkdir -p "$BATS_TEST_TMPDIR/opt"
  ln -s "$REPO/tests/stubs/herdr" "$BATS_TEST_TMPDIR/opt/herdr-new"
  user_setting "nodes.local_herdr: $BATS_TEST_TMPDIR/opt/herdr-new" "nodes.lab.machine: lab"
  run "$BIN/pane-ask" --read --machine lab wX:pY
  [ "$status" -eq 0 ]
  grep -qx -- '--machine lab agent read wX:pY --source recent-unwrapped --lines 80' "$PSTUB/herdr.log"
  [ ! -s "$PSTUB/ssh.log" ]
}

# ---- bridge to bridge only (exit 45) ---------------------------------------------------------
# A guard rail, not enforcement: a caller can claim another pane. Every refusal comes before
# any call to the node, and never prints a pane's contents.

nothing_called() {
  [ ! -s "$PSTUB/ssh.log" ]
  none -E 'agent (get|prompt|read|wait) ' "$PSTUB/herdr.log"
}

@test "a caller that is not this host's bridge is refused (45), nothing called" {
  export HERDR_PANE_ID=w7:p7
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *"caller is not this host's bridge"* ]]
  nothing_called
}

@test "no HERDR_PANE_ID is a caller that is not the bridge (45)" {
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *"caller is not this host's bridge"* ]]
  nothing_called
}

@test "--read from a caller that is not the bridge is refused (45) too" {
  export HERDR_PANE_ID=w7:p7
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 45 ]
  [[ $output == *"caller is not this host's bridge"* ]]
  nothing_called
}

@test "the caller is the bridge when herdr resolves its pane to the bridge's name" {
  local_herdr
  user_setting "nodes.home.bridge: homebridge"
  echo "w3:p3 w3:p3 homebridge" > "$PSTUB/agents"
  export HERDR_PANE_ID=w3:p3
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  grep -qx 'agent get w3:p3' "$PSTUB/herdr.log"
  grep -qx 'agent prompt wX:pY lead: hi --wait --timeout 900000' "$PSTUB/herdr.log"
}

@test "a caller whose pane resolves to some other name is refused (45)" {
  local_herdr
  echo "w3:p3 w3:p3 intruder" > "$PSTUB/agents"
  export HERDR_PANE_ID=w3:p3
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  grep -qx 'agent get w3:p3' "$PSTUB/herdr.log"
  none -E 'agent (prompt|read|wait) ' "$PSTUB/herdr.log"
}

@test "a target that is not the remote node's configured bridge is refused (45)" {
  run "$BIN/pane-ask" w8:p8 hi
  [ "$status" -eq 45 ]
  [[ $output == *"target is not the configured bridge of node 'lab'"* ]]
  nothing_called
  run "$BIN/pane-ask" --read w8:p8
  [ "$status" -eq 45 ]
  nothing_called
}

@test "a node with no bridge configured is a config error (78) naming nodes.<name>.bridge" {
  user_setting "nodes.lab.bridge: "
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.lab.bridge* ]]
  nothing_called
}

@test "the target is compared without case" {
  run "$BIN/pane-ask" WX:PY hi
  [ "$status" -eq 0 ]
}

@test "a host given with --host that is no configured node is refused (45)" {
  run "$BIN/pane-ask" --host stranger wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *"not a configured node"* ]]
  nothing_called
}

@test "--machine is matched to its node, and its bridge is the target" {
  local_herdr
  user_setting "nodes.lab.machine: lab"
  run "$BIN/pane-ask" --machine lab wX:pY hi
  [ "$status" -eq 0 ]
  run "$BIN/pane-ask" --machine lab w8:p8 hi
  [ "$status" -eq 45 ]
}

@test "--host is matched to nodes.*.host only, and --machine to nodes.*.machine only" {
  user_setting "nodes.lab.machine: lab"
  run "$BIN/pane-ask" --host lab wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *"not a configured node"* ]]
  nothing_called
  user_setting "nodes.lab.machine: " "nodes.lab.host: mlabel"
  run "$BIN/pane-ask" --machine mlabel wX:pY hi
  [ "$status" -eq 45 ]
  nothing_called
}

@test "a local node (nodes.<name>.this_host) is refused (45) from a session in a pane, send and --read" {
  run "$BIN/pane-ask" --node home homebridge hi
  [ "$status" -eq 45 ]
  [[ $output == *"target is on this host"* ]]
  run "$BIN/pane-ask" --read --node home
  [ "$status" -eq 45 ]
  nothing_called
}

@test "a local node needs neither host nor machine: a daemon runs the local herdr, no ssh" {
  local_herdr
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" --node home "ids only"
  [ "$status" -eq 0 ]
  grep -qx 'agent prompt homebridge lead: ids only --wait --timeout 900000' "$PSTUB/herdr.log"
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "no node marked local is a config error (78), nothing called" {
  user_setting "nodes.home.this_host: "
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.\<name\>.this_host* ]]
  nothing_called
}

@test "this host's node with no bridge is a config error (78)" {
  user_setting "nodes.home.bridge: "
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.home.bridge* ]]
  nothing_called
}

@test "several local nodes: HERDR_SESSION must match a node's session, and only that node's bridge may send (45 otherwise)" {
  user_setting "nodes.home2.this_host: true" "nodes.home2.bridge: bridge2" "nodes.home.session: s1" "nodes.home2.session: s2"
  export HERDR_PANE_ID=bridge2
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *HERDR_SESSION* ]]
  export HERDR_SESSION=nowhere
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  export HERDR_SESSION=s2
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  export HERDR_SESSION=s1
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  export HERDR_PANE_ID=homebridge
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
}

@test "an absent HERDR_SESSION is the session named default" {
  user_setting "nodes.home2.this_host: true" "nodes.home2.bridge: bridge2" "nodes.home.session: default" "nodes.home2.session: s2"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  export HERDR_PANE_ID=bridge2
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
}

@test "with one local node, the session is not needed (any HERDR_SESSION)" {
  export HERDR_SESSION=anything
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
}

@test "a local target runs the local herdr in its own session: two local nodes share a bridge name" {
  local_herdr
  unset HERDR_PANE_ID
  user_setting "nodes.home.bridge: bridge" "nodes.home2.this_host: true" "nodes.home2.bridge: bridge" "nodes.home.session: s1" "nodes.home2.session: s2"
  run "$BIN/pane-ask" --node home2 bridge "ids only"
  [ "$status" -eq 0 ]
  grep -qx -- '--session s2 agent prompt bridge lead: ids only --wait --timeout 900000' "$PSTUB/herdr.log"
  none -E '^(--session s1|agent) ' "$PSTUB/herdr.log"
  [ ! -s "$PSTUB/ssh.log" ]
}

@test "a local target with no session, among several local nodes, is ambiguous (78) naming nodes.<name>.session" {
  local_herdr
  unset HERDR_PANE_ID
  user_setting "nodes.home2.this_host: true" "nodes.home2.bridge: bridge2" "nodes.home.session: s1"
  run "$BIN/pane-ask" --node home2 bridge2 hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.home2.session* ]]
  nothing_called
}

@test "a bad session name is a config error (78)" {
  local_herdr
  unset HERDR_PANE_ID
  user_setting "nodes.home.session: -x"
  run "$BIN/pane-ask" --node home homebridge hi
  [ "$status" -eq 78 ]
  nothing_called
}

@test "nodes.<name>.this_host is true or false: anything else is a config error (78)" {
  user_setting "nodes.home.this_host: yes"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.home.this_host* ]]
  nothing_called
  user_setting "nodes.home.this_host: true" "nodes.lab.this_host: True"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *nodes.lab.this_host* ]]
  nothing_called
}

@test "this_host: false is a remote node" {
  user_setting "nodes.lab.this_host: false"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  grep -q -- '-- agent-host ' "$PSTUB/ssh.log"
}

@test "a node marked this_host that also has a host or machine is a contradiction (78)" {
  user_setting "nodes.lab.this_host: true"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  [[ $output == *lab* ]]
  nothing_called
  user_setting "nodes.lab.this_host: false" "nodes.home.machine: m"
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 78 ]
  nothing_called
}

@test "a pane id that looks like an option is refused (45), nothing called" {
  local_herdr
  export HERDR_PANE_ID=--x
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *HERDR_PANE_ID* ]]
  none -E 'agent get' "$PSTUB/herdr.log"
}

@test "a caller lookup that fails says herdr couldn't resolve the pane (45)" {
  export HERDR_PANE_ID=w7:p7
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  [[ $output == *"herdr couldn't resolve pane w7:p7"* ]]
  nothing_called
}

@test "a refusal never prints the pane's contents" {
  export HERDR_PANE_ID=w7:p7
  echo "SECRET-SCREEN-TEXT" > "$PSTUB/screen"
  run "$BIN/pane-ask" --read wX:pY
  [ "$status" -eq 45 ]
  [[ $output != *SECRET-SCREEN-TEXT* ]]
}

@test "bridge to the other node's bridge, send and --read, is allowed" {
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 0 ]
  [[ $output == *"reply line 1"* ]]
  run "$BIN/pane-ask" --read
  [ "$status" -eq 0 ]
}

# ---- a watch daemon and this host's bridge ---------------------------------------------------
# The one local case: a caller that is in no herdr pane (a daemon: no pane id in its
# environment) sending to this host's recorded bridge. It is an env check, a guard rail only.

@test "a daemon (no pane id) can send to this host's bridge" {
  local_herdr
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" --node home homebridge "ids only"
  [ "$status" -eq 0 ]
  grep -qx 'agent prompt homebridge lead: ids only --wait --timeout 900000' "$PSTUB/herdr.log"
}

@test "a daemon can read this host's bridge too" {
  local_herdr
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" --read --node home
  [ "$status" -eq 0 ]
}

@test "a daemon can't send to a local pane that is not the bridge (45)" {
  local_herdr
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" --node home w2:p2 hi
  [ "$status" -eq 45 ]
  [[ $output == *"target is on this host"* ]]
  nothing_called
  run "$BIN/pane-ask" --read --node home w2:p2
  [ "$status" -eq 45 ]
  nothing_called
}

@test "a session in a pane can't send to this host's bridge (45): sessions use SendMessage" {
  local_herdr
  export HERDR_PANE_ID=w2:p2
  run "$BIN/pane-ask" --node home homebridge hi
  [ "$status" -eq 45 ]
  [[ $output == *SendMessage* ]]
  nothing_called
}

@test "a caller with the pane variable unset reaches only the local bridge, no other local pane" {
  local_herdr
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" --node home homebridge hi
  [ "$status" -eq 0 ]
  : > "$PSTUB/herdr.log"; : > "$PSTUB/ssh.log"
  run "$BIN/pane-ask" --node home w9:p9 hi
  [ "$status" -eq 45 ]
  run "$BIN/pane-ask" --node home lead hi
  [ "$status" -eq 45 ]
  nothing_called
}

@test "cross-host stays bridge to bridge: a daemon is refused on another node (45)" {
  unset HERDR_PANE_ID
  run "$BIN/pane-ask" wX:pY hi
  [ "$status" -eq 45 ]
  nothing_called
}
