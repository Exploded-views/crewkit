#!/usr/bin/env bats
# The stub herdr (tests/stubs/herdr) answers in real herdr's shape: every JSON reply is checked
# against tests/fixtures/herdr/agent-schema.json, the parts of `herdr api schema --json` (herdr
# 0.9.5) that the stub answers with, by tests/herdr_shape.py. A stub that drifted from herdr
# once hid a bug: it put the agent's name in "agent", which real herdr uses for the agent's kind.

load crewkit-helpers

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export PSTUB="$BATS_TEST_TMPDIR/pstub"
  mkdir -p "$PSTUB"
  : > "$PSTUB/herdr.log"
  echo idle > "$PSTUB/status"
  STUB="$REPO/tests/stubs/herdr"
  FIXTURE="$REPO/tests/fixtures/herdr/agent-schema.json"
}

shape() { python3 "$REPO/tests/herdr_shape.py" "$FIXTURE"; }

@test "the fixture is herdr's schema, naming the version it was copied from" {
  jq -e '._comment | test("herdr [0-9]+[.][0-9]+[.][0-9]+")' "$FIXTURE"
  jq -e '.AgentInfo.properties.agent and .AgentInfo.properties.name and (.AgentInfo.required | index("pane_id"))' "$FIXTURE"
}

@test "agent get, wait, prompt and list answer in herdr's shape, named or not" {
  printf 'boss w1:p1 boss\nw5:p5 w5:p5 -\n' > "$PSTUB/agents"
  {
    "$STUB" agent get boss
    "$STUB" agent get w5:p5
    "$STUB" agent get unlisted
    "$STUB" agent wait boss --timeout 5
    "$STUB" agent prompt boss "hi" --wait --timeout 5
    "$STUB" agent list
  } > "$BATS_TEST_TMPDIR/out"
  run shape < "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out")" -eq 6 ]
}

@test "the agent's kind is in agent and its name in name (null when it has none)" {
  echo "boss w1:p1 boss" > "$PSTUB/agents"
  run "$STUB" agent get boss
  [ "$(jq -r '.result.agent | "\(.pane_id) \(.agent) \(.name)"' <<<"$output")" = "w1:p1 claude boss" ]
  run "$STUB" agent get w7:p7
  [ "$(jq -r '.result.agent | "\(.pane_id) \(.agent) \(.name)"' <<<"$output")" = "w7:p7 claude null" ]
}

@test "errors answer in herdr's shape" {
  echo timeout > "$PSTUB/prompt_error"
  run bash -c '"$1" agent prompt t hi --wait --timeout 5 2>&1 >/dev/null' _ "$STUB"
  [ "$status" -eq 1 ]
  run shape <<<"$output"
  [ "$status" -eq 0 ]
}

@test "the shape check is not vacuous: the old hand-made reply, an unknown field and a bad status fail" {
  run shape <<<'{"id":"cli:agent","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"lead","agent_status":"idle"}}}'
  [ "$status" -eq 1 ]
  [[ $output == *"missing required terminal_id"* ]]
  run shape <<<'{"id":"x","result":{"type":"agent_info","agent":{"terminal_id":"t","workspace_id":"w","tab_id":"t","pane_id":"p","focused":false,"revision":1,"agent_status":"idle","nick":"x"}}}'
  [ "$status" -eq 1 ]
  [[ $output == *"nick is not in herdr's AgentInfo"* ]]
  run shape <<<'{"id":"x","result":{"type":"agent_info","agent":{"terminal_id":"t","workspace_id":"w","tab_id":"t","pane_id":"p","focused":false,"revision":1,"agent_status":"sleepy"}}}'
  [ "$status" -eq 1 ]
  run shape <<<'not json'
  [ "$status" -eq 1 ]
}

# Hosts and sessions: the stub with $PSTUB/herdr/ (herdr_session and herdr_agent make it).

@test "agent list with tokens, session list and status answer in herdr's shape" {
  herdr_session local default 1 1
  herdr_session local scratch 0 0
  herdr_agent local default w1:p1 lead working role=lead project=acme
  herdr_agent local default w1:p2 - idle
  {
    "$STUB" agent list
    "$STUB" session list --json
    "$STUB" status --json
    "$STUB" --session scratch status --json
  } > "$BATS_TEST_TMPDIR/out"
  run shape < "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out")" -eq 4 ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/out" | jq -cS '.result.agents[0].tokens')" = '{"project":"acme","role":"lead"}' ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/out" | jq -c '[.sessions[] | [.name, .default, .running]]')" = '[["default",true,true],["scratch",false,false]]' ]
}

@test "the document shape check is not vacuous: a wrong field, a missing one and an extra one fail" {
  run shape <<<'{"sessions":[{"name":"a","default":"yes","running":true,"socket_path":"s","session_dir":"d"}]}'
  [ "$status" -eq 1 ]
  run shape <<<'{"client":{"version":"1","protocol":22},"server":{"running":true,"version":"1"}}'
  [ "$status" -eq 1 ]
  [[ $output == *"server: missing protocol"* ]]
}

@test "--session can stand anywhere; without it the default session answers; the log names host and session" {
  herdr_session local default 1 1
  herdr_session local other 0 1
  herdr_agent local other w3:p1 x idle
  run "$STUB" agent list
  [ "$(jq '.result.agents | length' <<<"$output")" -eq 0 ]
  run "$STUB" agent --session other list
  [ "$(jq '.result.agents | length' <<<"$output")" -eq 1 ]
  run "$STUB" --session other agent list
  [ "$(jq '.result.agents | length' <<<"$output")" -eq 1 ]
  [ "$(tail -2 "$PSTUB/herdr.log" | sort -u)" = "[local/other] agent list" ]
  CK_HOST=nodeb run "$STUB" session list --json
  [ "$output" = '{"sessions":[]}' ]
  CK_HOST=nodeb "$STUB" status --json
  grep -q '^\[nodeb/default\] status --json$' "$PSTUB/herdr.log"
}

@test "agent list takes no --json, as in herdr; a stopped session's server is not running" {
  herdr_session local default 1 1
  run "$STUB" agent list --json
  [ "$status" -eq 2 ]
  herdr_session local default 1 0
  run "$STUB" agent list
  [ "$status" -eq 1 ]
  [[ $output == *server_not_running* ]]
  [ "$("$STUB" status --json | jq -c .server)" = '{"running":false,"version":null,"protocol":null}' ]
}

@test "report-metadata sets and clears tokens, with herdr's limits (16 a request, 32 a pane, 80 characters)" {
  herdr_session local default 1 1
  herdr_agent local default w1:p1 lead idle
  run "$STUB" pane report-metadata --source crewkit --token role=lead --token project=acme w1:p1
  [ "$status" -eq 0 ]
  [ "$("$STUB" agent list | jq -cS '.result.agents[0].tokens')" = '{"project":"acme","role":"lead"}' ]
  "$STUB" pane report-metadata --source crewkit --clear-token role w1:p1
  [ "$("$STUB" agent list | jq -cS '.result.agents[0].tokens')" = '{"project":"acme"}' ]
  run "$STUB" pane report-metadata --source crewkit --token "k=$(printf 'x%.0s' $(seq 81))" w1:p1
  [ "$status" -eq 1 ]
  run "$STUB" pane report-metadata --source crewkit --token role=a w9:p9
  [[ $output == *pane_not_found* ]]
  args=()
  for i in $(seq 17); do args+=(--token "k$i=v"); done
  run "$STUB" pane report-metadata --source crewkit "${args[@]}" w1:p1
  [ "$status" -eq 1 ]
  for i in $(seq 31); do "$STUB" pane report-metadata --source crewkit --token "n$i=v" w1:p1; done
  run "$STUB" pane report-metadata --source crewkit --token "n32=v" w1:p1
  [ "$status" -eq 1 ]
}

@test "workspace create, agent start (and not ready), agent focus and session attach" {
  herdr_session local default 1 1
  run "$STUB" workspace create --label proj --cwd /work/proj --no-focus
  [ "$(jq -r .result.root_pane.pane_id <<<"$output")" = w1:p1 ]
  run "$STUB" agent start lead --kind claude --pane w1:p1 -- --model x
  [ "$status" -eq 0 ]
  run shape <<<"$output"
  [ "$status" -eq 0 ]
  [ "$("$STUB" agent focus lead | jq -r .result.agent.pane_id)" = w1:p1 ]
  run "$STUB" agent focus nobody
  [[ $output == *agent_not_found* ]]
  touch "$PSTUB/herdr/local/default/start_not_ready"
  run "$STUB" workspace create --label b --cwd /w --no-focus
  [ "$(jq -r .result.root_pane.pane_id <<<"$output")" = w2:p1 ]
  run "$STUB" agent start two --kind claude --pane w2:p1
  [ "$status" -eq 1 ]
  [[ $output == *agent_not_ready* ]]
  run "$STUB" session attach default
  [ "$output" = "attached default" ]
}

@test "integration install and status" {
  herdr_session local default 1 1
  [ "$("$STUB" integration status | jq -c '.result.integrations[0].installed')" = false ]
  "$STUB" integration install claude
  [ "$("$STUB" integration status | jq -c '.result.integrations[0].installed')" = true ]
}
