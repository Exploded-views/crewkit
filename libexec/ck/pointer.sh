# shellcheck shell=bash
# pointer.sh: the signal path's pointer, on both ends. Source it after lib/settings.sh and
# libexec/ck/common.sh.
#
# A pointer is the one thing that crosses ntfy: "<id> owner:<yes|no>" and nothing else, an item's
# id and whether the owner is wanted. The text of the item stays in the node's outbox and reaches
# the holder only through the report. Both ends check the same pattern, and anything else is
# dropped unread and counted.
#
#   ck_pointer_ok TEXT               the pointer pattern: ^[a-z]{2,8}-[0-9]{1,6} owner:(yes|no)$
#   ck_pointer_id_ok ID              the id part of it
#   ck_pointer_send URL TOKEN BODY   post BODY to URL with the bearer token, which curl reads from
#                                    stdin, never from argv; returns curl's status, prints nothing
#   ck_pointer_listen BASE TOKENFILE CMD...
#                                    the holder side: follow every node's topic on the ntfy at BASE
#                                    (topic crewkit-<nodes.NAME.node_id>) with the read token in
#                                    TOKENFILE; for each valid pointer run `CMD... NAME` once per
#                                    node and id. A stream that ends is reopened after 1, 2, 4 ...
#                                    60 seconds (back to 1 after a stream that delivered a message);
#                                    the count of dropped messages is in <state_dir>/pointer.dropped.
#                                    CK_POINTER_CONNECTS (tests) stops it after that many streams.

ck_pointer_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[a-z]{2,8}-[0-9]{1,6}\ owner:(yes|no)$ ]]
}

ck_pointer_id_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[a-z]{2,8}-[0-9]{1,6}$ ]]
}

# A URL and a token are put into curl's argv and config, so they are checked first: no quote,
# backslash, space or newline can get into the config line.
ck_pointer_url_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^https?://[A-Za-z0-9._:/%+~-]{1,255}$ ]]
}
ck_pointer_token_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[A-Za-z0-9_.-]{1,200}$ ]]
}

ck_pointer_send() {
  curl -fsS -m 10 --proto =https,http -K - -d "$3" "$1" >/dev/null 2>&1 \
    <<<"header = \"Authorization: Bearer $2\""
}

# ck_pointer_dropped: count one dropped message.
ck_pointer_dropped() {
  local f n
  f=$(ck_state_dir)/pointer.dropped
  n=$(cat "$f" 2>/dev/null || echo 0)
  [[ $n =~ ^[0-9]+$ ]] || n=0
  echo "$((n + 1))" > "$f"
}

ck_pointer_listen() {
  local LC_ALL=C base=${1-} tokfile=${2-} key name id token url topic message node
  local -A node_of=() seen=()
  local topics=() connects=0 delay=1 got
  shift 2 || ck_die 64 "ck_pointer_listen BASE TOKENFILE CMD..."
  (($#)) || ck_die 64 "ck_pointer_listen needs a command to run for each pointer"
  ck_pointer_url_ok "$base" || ck_die 78 "the ntfy address is not a plain http(s) URL"
  [[ -f $tokfile && -r $tokfile ]] || ck_die 78 "cannot read the read-token file $tokfile"
  token=$(<"$tokfile")
  ck_pointer_token_ok "$token" || ck_die 78 "the read token in $tokfile is not a plain token"
  while IFS= read -r key; do
    name=${key#nodes.}
    name=${name%.node_id}
    id=$(crew_setting "$key")  # settings-keys: nodes.<name>.node_id
    ck_name_ok "$name" || continue
    [[ $id =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || continue
    node_of["crewkit-$id"]=$name
  done < <(crew_keys nodes. | grep '\.node_id$' || true)
  ((${#node_of[@]})) || ck_die 78 "no node has a node_id, so there is no topic to follow"
  for topic in "${!node_of[@]}"; do topics+=("$topic"); done
  url=${base%/}/$(IFS=,; echo "${topics[*]}")/json
  while :; do
    got=0
    while IFS=$'\t' read -r topic message; do
      got=1
      node=${node_of[$topic]-}
      if [[ -z $node ]] || ! ck_pointer_ok "$message"; then
        ck_pointer_dropped
        continue
      fi
      id=${message%% *}
      if [[ -n ${seen[$node/$id]-} ]]; then continue; fi
      # The command must not read the stream (ssh does by default); only a pull that worked is
      # remembered, so a failed one is tried again when the pointer is sent again.
      if "$@" "$node" </dev/null; then
        ((${#seen[@]} < 1000)) || seen=()
        seen[$node/$id]=1
      fi
    done < <(curl -fsSN --proto =https,http -K - "$url" 2>/dev/null \
      <<<"header = \"Authorization: Bearer $token\"" |
      jq -r --unbuffered 'select(.event == "message") | [(.topic // "" | tostring), (.message // "" | tostring)] | @tsv' 2>/dev/null)
    ((++connects))
    if [[ -n ${CK_POINTER_CONNECTS-} ]] && ((connects >= CK_POINTER_CONNECTS)); then return 0; fi
    ((!got)) || delay=1
    sleep "$delay"
    ((delay = delay * 2 > 60 ? 60 : delay * 2))
  done
}
