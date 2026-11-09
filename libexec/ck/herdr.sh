# shellcheck shell=bash
# herdr.sh: herdr discovery per server, sanitizing of what a node's herdr reports, and tagging of
# panes. Source it after lib/settings.sh and libexec/ck/common.sh. A node can run several herdr
# servers, one per session (`herdr --session NAME`); every function here that reads or writes one
# takes the session name.
#
#   CK_HERDR_MIN 0.9.1, CK_HERDR_PROTOCOL 22   the herdr crewkit needs (the version and protocol it was built against)
#   ck_herdr_bin                    ~/.local/bin/herdr if executable, else herdr on PATH; nothing and return 1 if neither
#   ck_herdr_versions [SESSION]     one line: client_version client_protocol server_running server_protocol (- for unknown)
#   ck_herdr_sessions               TSV name<TAB>default<TAB>running, one line per session whose name passes ck_herdr_session_ok
#   ck_herdr_default_session        the default session's name (return 1 if there is none)
#   ck_herdr_agents SESSION [--access]   JSON array of {"pane_id","name","status","role","project"}; role and project are the
#                                   tokens of that name; a value that fails its check is null; a session that is not
#                                   running is []. With --access each also has "access": the access token if it is
#                                   exactly reader or writer, else null
#   ck_herdr_tag SESSION PANE KEY VALUE   set one token (herdr pane report-metadata --source crewkit), unless it is already
#                                   that value; 65 if it would be the pane's 33rd token
#   ck_herdr_retag SESSION          re-apply the tags of <state_dir>/node/SESSION.json (Task 12 writes it:
#                                   {"tags":{"<pane>":{"agent":"<name>"|null,"tokens":{"<key>":"<value>"}}}}) through
#                                   ck_herdr_tag, to panes that still exist and, where the state names an agent, still run it
#
# Everything that reaches a herdr argument or a path is checked first, and a bad one is 65 with no
# herdr call: SESSION ck_herdr_session_ok, PANE ^[A-Za-z0-9][A-Za-z0-9:_-]{0,63}$, KEY ck_label_ok's
# key, VALUE ^[A-Za-z0-9_.:-]{1,80}$ (herdr takes at most 80 characters, 16 tokens a request, 32 a pane).
# What herdr reports about a node's agents is untrusted: output is built by jq only. Exit codes are
# docs/exit-codes.md's.

# shellcheck disable=SC2034  # read by the verbs that source this file
CK_HERDR_MIN=0.9.1
# shellcheck disable=SC2034
CK_HERDR_PROTOCOL=22
# herdr's agent statuses (tests/fixtures/herdr/agent-schema.json, AgentStatus).
CK_HERDR_STATUSES='idle working blocked done unknown'

ck_herdr_session_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}
_ck_herdr_pane_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9:_-]{0,63}$ ]]
}
_ck_herdr_key_ok() { ck_label_ok "${1-}=x"; }
_ck_herdr_value_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[A-Za-z0-9_.:-]{1,80}$ ]]
}
_ck_herdr_session_check() {
  ck_herdr_session_ok "${1-}" || ck_die 65 "bad herdr session name (want letters, digits, _ and -, at most 64)"
}

ck_herdr_bin() {
  if [[ -x $HOME/.local/bin/herdr && ! -d $HOME/.local/bin/herdr ]]; then
    printf '%s\n' "$HOME/.local/bin/herdr"
  else
    command -v herdr 2> /dev/null
  fi
}

# _ck_herdr_run SESSION ARGS...: herdr --session SESSION ARGS (SESSION must be checked).
# _ck_herdr_run_default ARGS...: the same, against the default session.
_ck_herdr_run() {
  local bin s=$1
  shift
  bin=$(ck_herdr_bin) || return 127
  "$bin" --session "$s" "$@"
}
_ck_herdr_run_default() {
  local bin
  bin=$(ck_herdr_bin) || return 127
  "$bin" "$@"
}

ck_herdr_versions() {
  local out line
  if [[ $# -gt 0 ]]; then
    _ck_herdr_session_check "$1"
    out=$(_ck_herdr_run "$1" status --json 2> /dev/null) || out=''
  else
    out=$(_ck_herdr_run_default status --json 2> /dev/null) || out=''
  fi
  line=$(jq -r '[.client.version, .client.protocol, .server.running, .server.protocol]
      | map(if (type == "string" or type == "number" or type == "boolean") and (tostring | test("\\A[A-Za-z0-9._-]{1,32}\\z")) then tostring else "-" end)
      | join(" ")' <<< "$out" 2> /dev/null) || line=''
  printf '%s\n' "${line:-- - - -}"
}

# _ck_herdr_say FILE: a node's herdr stderr as one safe line: newlines to spaces, printable ASCII only
# (no ESC, so no terminal sequence gets through), at most 300 bytes.
_ck_herdr_say() {
  LC_ALL=C tr '\n' ' ' < "$1" | LC_ALL=C tr -cd ' -~' | head -c 300
}

# _ck_herdr_sessions_raw: the TSV of ck_herdr_sessions; return 1, with herdr's words on stderr, if herdr
# is there but its session list fails.
_ck_herdr_sessions_raw() {
  local out err
  ck_herdr_bin > /dev/null || { echo 'crewkit: herdr not installed' >&2; return 1; }
  err=$(mktemp "${TMPDIR:-/tmp}/ckherdr.XXXXXX") || return 1
  if ! out=$(_ck_herdr_run_default session list --json 2> "$err"); then
    printf 'crewkit: herdr session list failed: %s\n' "$(_ck_herdr_say "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  jq -r '.sessions // [] | if type == "array" then .[] else empty end
      | select(type == "object" and (.name | type == "string") and (.name | test("\\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\z")))
      | [.name, (.default == true), (.running == true)] | @tsv' <<< "$out" 2> /dev/null || { echo 'crewkit: herdr session list: not JSON' >&2; return 1; }
}

# ck_herdr_sessions: no herdr at all is an empty list; a herdr whose session list fails is 1.
ck_herdr_sessions() {
  ck_herdr_bin > /dev/null || return 0
  _ck_herdr_sessions_raw
}

ck_herdr_default_session() {
  local n
  n=$(ck_herdr_sessions | awk -F'\t' '$2 == "true" { print $1; exit }')
  [[ -n $n ]] || return 1
  printf '%s\n' "$n"
}

# _ck_herdr_list SESSION agent|pane: the JSON array herdr lists. A session that is stopped, or that
# herdr doesn't list at all, is []. If herdr can't say that (no herdr, session list failing) or a
# running session's list fails, nothing and return 1 with herdr's stderr.
_ck_herdr_list() {
  local out err key=agents sessions line
  [[ $2 == pane ]] && key=panes
  err=$(mktemp "${TMPDIR:-/tmp}/ckherdr.XXXXXX") || return 1
  if out=$(_ck_herdr_run "$1" "$2" list 2> "$err") \
    && out=$(jq -c --arg k "$key" '.result[$k] // [] | if type == "array" then map(select(type == "object")) else error("not a list") end' <<< "$out" 2> /dev/null); then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  sessions=$(_ck_herdr_sessions_raw) || { rm -f "$err"; return 1; }
  line=$(awk -F'\t' -v s="$1" '$1 == s { print $3 }' <<< "$sessions")
  if [[ $line != true ]]; then
    rm -f "$err"
    printf '[]\n'
    return 0
  fi
  printf 'crewkit: herdr %s list failed in session %s: %s\n' "$2" "$1" "$(_ck_herdr_say "$err")" >&2
  rm -f "$err"
  return 1
}

ck_herdr_agents() {
  local raw acc=false
  _ck_herdr_session_check "${1-}"
  [[ ${2-} == --access ]] && acc=true
  raw=$(_ck_herdr_list "$1" agent) || return 1
  jq -c --arg st "$CK_HERDR_STATUSES" --argjson acc "$acc" '
    def ok: type == "string" and test("\\A[A-Za-z0-9_.:-]{1,80}\\z");
    def pick: if ok then . else null end;
    def tok($k): (.tokens | if type == "object" then .[$k] else null end) | pick;
    [ .[] | {
        pane_id: (.pane_id | if type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9:_-]{0,63}\\z") then . else null end),
        name: (.name | pick),
        status: (.agent_status | if ok and (. as $s | $st | split(" ") | index($s)) then . else null end),
        role: tok("role"),
        project: tok("project")
      } + (if $acc then {access: (tok("access") | if . == "reader" or . == "writer" then . else null end)} else {} end) ]' <<< "$raw"
}

ck_herdr_tag() {
  local s=${1-} pane=${2-} key=${3-} val=${4-} raw same n has
  _ck_herdr_session_check "$s"
  _ck_herdr_pane_ok "$pane" || ck_die 65 "bad herdr pane id"
  _ck_herdr_key_ok "$key" || ck_die 65 "bad token key (want a lowercase name, no dots)"
  _ck_herdr_value_ok "$val" || ck_die 65 "bad token value for $key (want 1 to 80 of A-Za-z0-9_.:-)"
  raw=$(_ck_herdr_list "$s" pane) || return 1
  has=$(jq -r --arg p "$pane" --arg k "$key" 'first(.[] | select(.pane_id == $p)) | (.tokens // {}) | if type == "object" then has($k) else false end' <<< "$raw")
  same=$(jq -r --arg p "$pane" --arg k "$key" --arg v "$val" 'first(.[] | select(.pane_id == $p)) | (.tokens // {}) | if type == "object" and has($k) then (.[$k] == $v) else false end' <<< "$raw")
  [[ $same == true ]] && return 0
  n=$(jq -r --arg p "$pane" 'first(.[] | select(.pane_id == $p)) | (.tokens // {}) | if type == "object" then length else 0 end' <<< "$raw")
  if [[ $has != true ]] && ((${n:-0} >= 32)); then
    ck_die 65 "pane $pane already has 32 tokens: no room for $key"
  fi
  _ck_herdr_run "$s" pane report-metadata --source crewkit --token "$key=$val" "$pane" > /dev/null 2>&1 \
    || { printf 'crewkit: herdr could not tag pane %s in session %s\n' "$pane" "$s" >&2; return 1; }
}

ck_herdr_retag() {
  local s=${1-} file dir panes agents ent pane want have kv key val rc=0 r
  _ck_herdr_session_check "$s"
  dir=$(ck_state_dir) || exit $?
  file=$dir/node/$s.json
  [[ -f $file ]] || return 0
  jq -e '(.tags | type) == "object"' "$file" > /dev/null 2>&1 || ck_die 65 "$file: not JSON with a tags object"
  panes=$(_ck_herdr_list "$s" pane) || return 1
  agents=$(_ck_herdr_list "$s" agent) || return 1
  while IFS= read -r ent; do
    pane=$(jq -r '.key' <<< "$ent")
    if ! _ck_herdr_pane_ok "$pane"; then
      printf 'crewkit: retag: skipping a bad pane id %q\n' "$pane" >&2
      continue
    fi
    if ! jq -e '.value | type == "object"' <<< "$ent" > /dev/null 2>&1; then
      printf 'crewkit: retag: skipping pane %s: its entry is not an object\n' "$pane" >&2
      continue
    fi
    if ! jq -e '.value.tokens == null or (.value.tokens | type) == "object"' <<< "$ent" > /dev/null 2>&1; then
      printf 'crewkit: retag: skipping pane %s: its tokens are not an object\n' "$pane" >&2
      continue
    fi
    if [[ $(jq -r '.value.agent | type' <<< "$ent") == null ]]; then
      want=''
    else
      want=$(jq -r '.value.agent | if type == "string" then . else "" end' <<< "$ent")
      if ! _ck_herdr_value_ok "$want"; then
        printf 'crewkit: retag: skipping pane %s: bad agent name\n' "$pane" >&2
        continue
      fi
    fi
    jq -e --arg p "$pane" 'any(.[]; .pane_id == $p)' <<< "$panes" > /dev/null || continue
    if [[ -n $want ]]; then
      have=$(jq -r --arg p "$pane" 'first(.[] | select(.pane_id == $p)) | .name // empty' <<< "$agents")
      [[ $have == "$want" ]] || continue
    fi
    while IFS= read -r kv; do
      key=$(jq -r '.key' <<< "$kv")
      val=$(jq -r '.value | if type == "string" then . else "" end' <<< "$kv")
      if ! _ck_herdr_key_ok "$key" || ! _ck_herdr_value_ok "$val"; then
        printf 'crewkit: retag: skipping a bad token %q on pane %s\n' "$key" "$pane" >&2
        continue
      fi
      r=0
      (ck_herdr_tag "$s" "$pane" "$key" "$val") || r=$?
      ((r == 0 || r == 65)) || rc=1
    done < <(jq -c '.value.tokens // {} | if type == "object" then to_entries[] else empty end' <<< "$ent")
  done < <(jq -c '.tags | to_entries[]' "$file")
  return "$rc"
}
