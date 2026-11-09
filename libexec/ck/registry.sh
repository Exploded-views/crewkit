# shellcheck shell=bash
# registry.sh: the registry store, its git sync and join tokens. Source it after lib/settings.sh and
# libexec/ck/common.sh. The registry is a private git repo (registry.dir is the local clone):
#
#   registry.json     {"schema":1,"registry_id":"r-...","holder":"n-...","created":"<iso>"}
#   nodes/<id>.json   one record per node, exactly the keys in CK_REG_NODE_KEYS
#   log.ndjson        append-only: one {"at","event","node_id","detail"} per line
#
#   ck_reg_dir                       registry.dir, ~ expanded
#   ck_reg_require                   exit 78 unless ck_reg_dir holds a registry.json
#   ck_reg_create DIR RID HOLDER     init the repo, registry.json, nodes/, log.ndjson; one commit
#   ck_reg_id / ck_reg_holder / ck_reg_set_holder NODE_ID
#   ck_reg_node_put JSON             validate (65 on any bad key or value, nothing written), write atomically
#   ck_reg_node_get ID               print the record (return 1 if none); ck_reg_nodes lists the IDs, sorted
#   ck_reg_log EVENT NODE_ID [DETAIL]
#   ck_reg_commit MSG                commit what changed; a node file whose only change is report_at waits
#                                    registry.sync_min_seconds since its last commit
#   ck_reg_pull / ck_reg_push        git --ff-only pull / push, never prompting; return 1 on failure
#   ck_reg_synced_at                 epoch of the last successful pull or push (nothing, return 1, if none)
#
#   ck_token_mint NODE_ID PUBKEY     print ck1.<registry_id>.<node_id>.<secret>.<base64url(pubkey)>
#   ck_token_parse TOKEN             set TK_REGISTRY_ID TK_NODE_ID TK_SECRET TK_PUBKEY, or exit 65
#   ck_token_consume SHA256 NODE_ID  0 and mark it used, or exit 44 (unknown, used, expired, other node)
#
# A node or registry id that is not ^n-[a-z2-7]{10}$ / ^r-[a-z2-7]{10}$ is 65 and touches no file.
# Token secrets live only in the token the mint prints once; <state_dir>/registry/tokens.tsv (mode
# 600, never in the sync repo) holds sha256(secret), node, expiry and a used flag. Exit codes are
# docs/exit-codes.md's.

# Task 7's report keys, defined once here.
CK_REPORT_KEYS='agents at boot_start bridge crewkit herdr join_token_sha256 name node_id other_sessions platform push_gate schema session'
CK_REG_NODE_KEYS='schema node_id name role labels boundary state expires cap joined_at versions report report_at'

_ck_reg_nid() {
  local LC_ALL=C
  [[ ${1-} =~ ^n-[a-z2-7]{10}$ ]] || ck_die 65 "bad node id (want n- and 10 of a-z2-7)"
}
_ck_reg_rid() {
  local LC_ALL=C
  [[ ${1-} =~ ^r-[a-z2-7]{10}$ ]] || ck_die 65 "bad registry id (want r- and 10 of a-z2-7)"
}

# _ck_expand_home PATH SETTING: ~ expanded; absolute or exit 78.
_ck_expand_home() {
  local d=$1
  # shellcheck disable=SC2088  # the literal text ~/ is what is matched
  case $d in
    '~') d=$HOME ;;
    '~/'*) d=$HOME/${d#'~/'} ;;
    '~'*) ck_die 78 "$2: ~user is not supported: $d" ;;
  esac
  [[ $d == /* ]] || ck_die 78 "$2 must be an absolute path (or start with ~/): $d"
  printf '%s\n' "$d"
}

ck_reg_dir() {
  local d
  d=$(crew_setting registry.dir "$HOME/.local/share/crewkit/registry") || exit $?
  _ck_expand_home "$d" registry.dir
}

ck_reg_require() {
  local dir
  dir=$(ck_reg_dir) || exit $?
  [[ -f $dir/registry.json ]] || ck_die 78 "no registry at $dir: run 'crewkit init' (or join a crew) first"
}

# _ck_reg_write FILE JSON: jq -S into a temp file next to FILE, then mv.
_ck_reg_write() {
  local file=$1 tmp
  tmp=${file%/*}/.tmp.${file##*/}.$$
  if printf '%s\n' "$2" | jq -S . > "$tmp" 2>/dev/null && mv -f "$tmp" "$file"; then return 0; fi
  rm -f "$tmp"
  ck_die 1 "cannot write $file"
}

# _ck_reg_err TEXT: git's own words, every line prefixed, on stderr.
_ck_reg_err() {
  local l
  [[ -n $1 ]] || set -- "git failed (it printed nothing)"
  while IFS= read -r l; do printf 'crewkit: registry: %s\n' "$l" >&2; done <<<"$1"
}

# _ck_reg_commit_in DIR MSG: a commit that depends on nobody's git config (its times are $CK_NOW's).
# The owner's hooks still run (we never bypass them); on failure git's output is shown and 1 returned.
_ck_reg_commit_in() {
  local dir=$1 now out
  now=$(ck_now)
  if out=$(GIT_AUTHOR_NAME=crewkit GIT_AUTHOR_EMAIL=crewkit@localhost GIT_COMMITTER_NAME=crewkit GIT_COMMITTER_EMAIL=crewkit@localhost \
    GIT_AUTHOR_DATE="$now +0000" GIT_COMMITTER_DATE="$now +0000" \
    git -C "$dir" -c user.name=crewkit -c user.email=crewkit@localhost commit -q --no-gpg-sign -m "$2" 2>&1 </dev/null); then
    return 0
  fi
  _ck_reg_err "$out"
  return 1
}

ck_reg_create() {
  local dir=${1-} rid=${2-} holder=${3-}
  [[ -n $dir ]] || ck_die 64 "usage: ck_reg_create DIR REGISTRY_ID HOLDER_ID"
  _ck_reg_rid "$rid"
  _ck_reg_nid "$holder"
  [[ ! -e $dir/registry.json ]] || ck_die 65 "$dir already holds a registry"
  mkdir -p "$dir/nodes" || ck_die 1 "cannot create $dir"
  git -C "$dir" init -q >/dev/null 2>&1 || ck_die 1 "git init failed in $dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  : > "$dir/nodes/.gitkeep"
  : > "$dir/log.ndjson"
  _ck_reg_write "$dir/registry.json" "$(jq -cn --arg r "$rid" --arg h "$holder" --arg c "$(ck_iso "$(ck_now)")" \
    '{schema:1,registry_id:$r,holder:$h,created:$c}')"
  git -C "$dir" add -A >/dev/null 2>&1 || ck_die 1 "git add failed in $dir"
  _ck_reg_commit_in "$dir" "registry $rid created" || exit 1
}

ck_reg_id() {
  local dir id
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  id=$(jq -r '.registry_id | if type == "string" then . else "" end' "$dir/registry.json") || ck_die 65 "registry.json is not valid"
  _ck_reg_rid "$id"
  printf '%s\n' "$id"
}

ck_reg_holder() {
  local dir id
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  id=$(jq -r '.holder | if type == "string" then . else "" end' "$dir/registry.json") || ck_die 65 "registry.json is not valid"
  _ck_reg_nid "$id"
  printf '%s\n' "$id"
}

ck_reg_set_holder() {
  local dir
  _ck_reg_nid "${1-}"
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  _ck_reg_write "$dir/registry.json" "$(jq -c --arg h "$1" '.holder=$h' "$dir/registry.json")"
}

# The first problem with a node record (empty when it is fine). One jq program: the key set is
# exactly CK_REG_NODE_KEYS, then each value.
# shellcheck disable=SC2016  # a jq program: $K and $R are jq variables
_CK_NODE_CHECK='
  ($keys | split(" ")) as $K | ($rk | split(" ")) as $R |
  if (keys != ($K | sort)) then "the keys are not exactly: " + $keys
  elif ([.. | strings | explode[] | select(. < 32 or . == 127)] | length > 0) then "a string holds a control character"
  elif .schema != 1 then "schema must be 1"
  elif (.boundary | IN("owner", "client") | not) then "boundary must be owner or client"
  elif (.state | IN("joining", "ready", "paused", "draining", "gone") | not) then "state is not one of joining ready paused draining gone"
  elif ((.role | type) | IN("string", "null") | not) then "role must be a string or null"
  elif ((.labels | type) != "object" or (.labels | to_entries | all(.value | type == "string") | not)) then "labels must be an object of strings"
  elif (.labels | to_entries | any((.key + .value) | explode | any(. < 32 or . == 127))) then "a label holds a control character"
  elif ((.versions | type) != "object" or ((.versions | keys) != ["crewkit", "herdr"])
        or (.versions | to_entries | all(.value | type | IN("string", "null")) | not)) then "versions must be an object with exactly crewkit and herdr"
  elif .expires != null then "expires must be null"
  elif .cap != null then "cap must be null"
  elif ((.joined_at | type) | IN("string", "null") | not) then "joined_at must be a string or null"
  elif ((.report_at | type) | IN("string", "null") | not) then "report_at must be a string or null"
  elif (.report != null and ((.report | type) != "object" or ((.report | keys) - $R | length) > 0)) then "report has a key outside the report keys"
  else "" end'

ck_reg_node_put() {
  local json=${1-} dir id name err lab
  [[ -n $json ]] || ck_die 64 "usage: ck_reg_node_put JSON"
  jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1 || ck_die 65 "a node record must be a JSON object"
  id=$(jq -r '.node_id | if type == "string" then . else "" end' <<<"$json")
  _ck_reg_nid "$id"
  name=$(jq -r '.name | if type == "string" then . else "" end' <<<"$json")
  ck_name_ok "$name" || ck_die 65 "bad node name"
  err=$(jq -r --arg keys "$CK_REG_NODE_KEYS" --arg rk "$CK_REPORT_KEYS" "$_CK_NODE_CHECK" <<<"$json" 2>/dev/null) ||
    ck_die 65 "node record refused: not the node record shape"
  [[ -z $err ]] || ck_die 65 "node record refused: $err"
  while IFS= read -r lab; do
    ck_label_ok "$lab" || ck_die 65 "node record refused: a label must be KEY=VALUE with a dot-free key and a plain value"
  done < <(jq -r '.labels | to_entries[] | .key + "=" + .value' <<<"$json")
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  _ck_reg_write "$dir/nodes/$id.json" "$json"
}

ck_reg_node_get() {
  local dir
  _ck_reg_nid "${1-}"
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  [[ -f $dir/nodes/$1.json ]] || return 1
  cat "$dir/nodes/$1.json"
}

ck_reg_nodes() {
  local dir f id
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  for f in "$dir"/nodes/n-*.json; do
    [[ -f $f ]] || continue
    id=${f##*/}
    id=${id%.json}
    [[ $id =~ ^n-[a-z2-7]{10}$ ]] && printf '%s\n' "$id"
  done | LC_ALL=C sort
}

ck_reg_log() {
  local event=${1-} id=${2-} detail=${3-} dir line
  [[ $event =~ ^[a-z][a-z0-9_.-]{0,63}$ ]] || ck_die 65 "bad log event name"
  _ck_reg_nid "$id"
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  line=$(jq -cn --arg at "$(ck_iso "$(ck_now)")" --arg event "$event" --arg node_id "$id" --arg detail "$detail" \
    '{at:$at,event:$event,node_id:$node_id,detail:$detail}') || ck_die 1 "cannot build the log line"
  ck_lock registry
  printf '%s\n' "$line" >> "$dir/log.ndjson" || { ck_unlock registry; ck_die 1 "cannot append to $dir/log.ndjson"; }
  ck_unlock registry
}

# _ck_reg_only_report_at DIR PATH: the working file equals HEAD's but for .report_at.
_ck_reg_only_report_at() {
  local old new
  old=$(git -C "$1" show "HEAD:$2" 2>/dev/null | jq -cS 'del(.report_at)' 2>/dev/null) || return 1
  new=$(jq -cS 'del(.report_at)' "$1/$2" 2>/dev/null) || return 1
  [[ -n $old && $old == "$new" ]]
}

ck_reg_commit() {
  local msg=${1-} dir min rc
  [[ -n $msg ]] || ck_die 64 "usage: ck_reg_commit MESSAGE"
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  min=$(crew_setting registry.sync_min_seconds 300)
  [[ $min =~ ^[0-9]+$ ]] || ck_die 78 "registry.sync_min_seconds must be a whole number: $min"
  ck_lock registry
  _ck_reg_commit_locked "$dir" "$msg" "$((10#$min))"
  rc=$?
  ck_unlock registry
  return "$rc"
}

# _ck_reg_commit_locked DIR MSG MIN: the body of ck_reg_commit, run holding the registry lock.
_ck_reg_commit_locked() {
  local dir=$1 msg=$2 min=$3 now ent xy path last out ents
  local LC_ALL=C
  now=$(ck_now)
  mapfile -d '' ents < <(git -C "$dir" status --porcelain -z --untracked-files=all 2>/dev/null)
  # First look for token files, before anything is staged: the index is left as it was.
  for ent in ${ents[@]+"${ents[@]}"}; do
    path=${ent:3}
    if [[ ${path##*/} == tokens.tsv || ${path##*/} == .tokens.* ]]; then
      echo "crewkit: registry: $path is in the sync repo; token files must never be committed (move state_dir out of it)" >&2
      return 78
    fi
  done
  for ent in ${ents[@]+"${ents[@]}"}; do
    xy=${ent:0:2} path=${ent:3}
    [[ ${path##*/} == .tmp.* ]] && continue
    if [[ $xy == ' M' && $path =~ ^nodes/n-[a-z2-7]{10}\.json$ ]] && _ck_reg_only_report_at "$dir" "$path"; then
      last=$(git -C "$dir" log -1 --format=%ct -- "$path" 2>/dev/null)
      if [[ $last =~ ^[0-9]+$ ]] && ((now - last < min)); then continue; fi
    fi
    if ! out=$(git -C "$dir" add -- "$path" 2>&1); then _ck_reg_err "$out"; return 1; fi
  done
  git -C "$dir" diff --cached --quiet >/dev/null 2>&1 && return 0
  _ck_reg_commit_in "$dir" "$msg"
}

# _ck_reg_remote DIR: make sure origin exists when registry.remote is set.
_ck_reg_remote() {
  local url
  url=$(crew_setting registry.remote "") || return 1
  [[ -n $url ]] || return 0
  git -C "$1" remote get-url origin >/dev/null 2>&1 || git -C "$1" remote add origin "$url" >/dev/null 2>&1 || return 1
}

# _ck_reg_git_net DIR ARGS...: git for the network: no prompt, ssh in batch mode with a timeout, and
# the registry.ssh_key identity when set. Returns git's status.
_ck_reg_git_net() {
  local dir=$1 key ssh='ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2'
  shift
  key=$(crew_setting registry.ssh_key "") || exit $?
  if [[ -n $key ]]; then
    key=$(_ck_expand_home "$key" registry.ssh_key) || exit $?
    ssh+=" -i $(ck_sq "$key") -o IdentitiesOnly=yes"
  fi
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false SSH_ASKPASS_REQUIRE=never GIT_SSH_COMMAND=$ssh git -C "$dir" "$@"
}

_ck_reg_synced() {
  local d tmp
  d=$(ck_state_dir) || return 1
  d=$d/registry
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  tmp=$d/.synced_at.$$
  { ck_now > "$tmp" && mv -f "$tmp" "$d/synced_at"; } || rm -f "$tmp"
}

ck_reg_pull() {
  local dir br out rc=1
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  ck_lock registry
  if ! _ck_reg_remote "$dir"; then
    echo "crewkit: registry pull: cannot set the remote" >&2
  elif ! br=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null); then
    echo "crewkit: registry pull: no branch checked out" >&2
  elif out=$(_ck_reg_git_net "$dir" pull -q --ff-only origin "$br" 2>&1 </dev/null); then
    _ck_reg_synced
    rc=0
  else
    _ck_reg_err "$out"
  fi
  ck_unlock registry
  return "$rc"
}

ck_reg_push() {
  local dir br out rc=1
  ck_reg_require
  dir=$(ck_reg_dir) || exit $?
  ck_lock registry
  if ! _ck_reg_remote "$dir"; then
    echo "crewkit: registry push: cannot set the remote" >&2
  elif ! br=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null); then
    echo "crewkit: registry push: no branch checked out" >&2
  elif out=$(_ck_reg_git_net "$dir" push -q origin "$br" 2>&1 </dev/null); then
    _ck_reg_synced
    rc=0
  else
    _ck_reg_err "$out"
  fi
  ck_unlock registry
  return "$rc"
}

ck_reg_synced_at() {
  local f t
  f=$(ck_state_dir) || exit $?
  f=$f/registry/synced_at
  [[ -f $f ]] || return 1
  t=$(cat "$f")
  [[ $t =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$t"
}

# ---- join tokens ----

# _ck_sha256: the hex sha256 of stdin.
_ck_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum); else out=$(shasum -a 256); fi
  out=${out%% *}
  [[ $out =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}

# _ck_secret: 26 characters of [a-z2-7] from /dev/urandom.
_ck_secret() {
  local s='' tries=0
  while ((${#s} < 26)); do
    ((++tries <= 16)) || ck_die 1 "cannot read random bytes from /dev/urandom"
    s+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-z2-7')
  done
  printf '%s\n' "${s:0:26}"
}

# _ck_pub_ok LINE: empty, or one line `ssh-ed25519 <base64> [comment]`.
_ck_pub_ok() {
  local LC_ALL=C
  [[ -z $1 ]] && return 0
  [[ $1 == *[[:cntrl:]]* ]] && return 1
  [[ $1 =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ .*)?$ ]]
}

_ck_b64url_enc() { printf '%s' "$1" | base64 | LC_ALL=C tr -d '\n=' | LC_ALL=C tr '+/' '-_'; }

# _ck_b64url_dec TEXT: the decoded bytes (a trailing newline kept), or return 1 when the text is not
# valid base64url or decodes to a NUL. jq decodes, so no platform's base64 changes what is accepted.
_ck_b64url_dec() {
  local out
  out=$(printf '%s' "$1" | LC_ALL=C tr -- '-_' '+/' |
    jq -Rj '@base64d | if (explode | any(. == 0)) then error("nul") else . end' 2>/dev/null; printf x) 2>/dev/null
  printf '%s' "${out%x}"
}

# _ck_tok_inside PATH REG: succeed if PATH, or any directory above it, is the registry clone REG (the
# same device and inode, so a symlink or a letter-case difference on a case-insensitive file system
# cannot hide it).
_ck_tok_inside() {
  local p=$1
  while :; do
    [[ $p -ef $2 ]] && return 0
    [[ $p == / || $p == . || -z $p ]] && return 1
    p=$(dirname "$p")
  done
}

# _ck_tok_real PATH: PATH resolved with cd -P, or exit 78 (a check that cannot resolve must not pass).
_ck_tok_real() {
  local p
  p=$(cd -P "$1" 2>/dev/null && pwd) || ck_die 78 "cannot resolve $1"
  printf '%s\n' "$p"
}

# _ck_tok_dir: print <state_dir>/registry, created 700; exit 78 if it is the registry clone or under it,
# because tokens.tsv must never reach the sync repo. state_dir is checked before the registry
# directory is made, so a refused run leaves nothing in the clone.
_ck_tok_dir() {
  local sd dir rreg rsd
  sd=$(ck_state_dir) || exit $?
  dir=$sd/registry
  rreg=$(ck_reg_dir) || exit $?
  if [[ -d $rreg ]]; then
    rsd=$(_ck_tok_real "$sd") || exit $?
    ! _ck_tok_inside "$rsd" "$rreg" || ck_die 78 "state_dir is inside the registry clone ($rreg): tokens.tsv must stay out of the sync repo"
  fi
  (umask 077; mkdir -p "$dir") || ck_die 1 "cannot create $dir"
  if [[ -d $rreg ]]; then
    rsd=$(_ck_tok_real "$dir") || exit $?
    ! _ck_tok_inside "$rsd" "$rreg" || ck_die 78 "state_dir/registry is inside the registry clone ($rreg): tokens.tsv must stay out of the sync repo"
  fi
  printf '%s\n' "$dir"
}

ck_token_mint() {
  local node=${1-} pub=${2-} rid secret hash exp dir f rc=0
  _ck_reg_nid "$node"
  _ck_pub_ok "$pub" || ck_die 65 "the public key must be one ssh-ed25519 line"
  rid=$(ck_reg_id) || exit $?
  secret=$(_ck_secret) || exit $?
  hash=$(printf '%s' "$secret" | _ck_sha256) || ck_die 1 "cannot hash the secret"
  exp=$(($(ck_now) + 86400))
  dir=$(_ck_tok_dir) || exit $?
  f=$dir/tokens.tsv
  ck_lock tokens
  (umask 077; printf '%s\t%s\t%s\n' "$hash" "$node" "$exp" >> "$f") || rc=1
  ck_unlock tokens
  ((rc == 0)) || ck_die 1 "cannot write $f"
  printf 'ck1.%s.%s.%s.%s\n' "$rid" "$node" "$secret" "$(_ck_b64url_enc "$pub")"
}

ck_token_parse() {
  local LC_ALL=C tok=${1-} dots rest rid node secret b64 pub
  dots=${tok//[^.]/}
  ((${#dots} == 4)) || ck_die 65 "not a join token"
  [[ $tok == ck1.* ]] || ck_die 65 "not a join token"
  rest=${tok#ck1.}
  rid=${rest%%.*} rest=${rest#*.}
  node=${rest%%.*} rest=${rest#*.}
  secret=${rest%%.*} b64=${rest#*.}
  _ck_reg_rid "$rid"
  _ck_reg_nid "$node"
  [[ $secret =~ ^[a-z2-7]{26}$ ]] || ck_die 65 "not a join token"
  [[ $b64 =~ ^[A-Za-z0-9_-]*$ ]] || ck_die 65 "not a join token"
  pub=$(_ck_b64url_dec "$b64"; printf x)
  pub=${pub%x}
  [[ $(_ck_b64url_enc "$pub") == "$b64" ]] || ck_die 65 "not a join token (the key part is not canonical base64url)"
  _ck_pub_ok "$pub" || ck_die 65 "the token's public key is not one ssh-ed25519 line"
  # shellcheck disable=SC2034  # the caller reads these
  TK_REGISTRY_ID=$rid TK_NODE_ID=$node TK_SECRET=$secret TK_PUBKEY=$pub
}

# _ck_tok_prune FILE DIR NOW: drop the rows that are expired (a used row is expired by then too: it was
# never valid for longer than 24 h). Rewrites only when a row goes; temp + mv, mode 600. Call it holding
# the tokens lock; a failure leaves the file as it was.
_ck_tok_prune() {
  local tmp
  awk -F'\t' -v now="$3" '$3 + 0 <= now + 0 { found = 1 } END { exit !found }' "$1" || return 0
  tmp=$(umask 077; mktemp "$2/.tokens.XXXXXX" 2>/dev/null) || return 0
  if awk -F'\t' -v OFS='\t' -v now="$3" '$3 + 0 > now + 0' "$1" > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
}

ck_token_consume() {
  local LC_ALL=C hash=${1-} node=${2-} dir f row tmp rc=0 rnode exp used now
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || ck_die 65 "bad token hash"
  _ck_reg_nid "$node"
  dir=$(_ck_tok_dir) || exit $?
  f=$dir/tokens.tsv
  now=$(ck_now)
  ck_lock tokens
  if [[ ! -f $f ]]; then
    rc=44
  else
    row=$(awk -F'\t' -v h="$hash" '$1 == h { print; exit }' "$f")
    IFS=$'\t' read -r _ rnode exp used <<<"$row"
    if [[ -z $row || $rnode != "$node" || -n $used || ! $exp =~ ^[0-9]+$ ]] || ((now >= exp)); then
      rc=44
      _ck_tok_prune "$f" "$dir" "$now"
    else
      # Mark it used and drop the expired rows in one rewrite.
      tmp=$(umask 077; mktemp "$dir/.tokens.XXXXXX" 2>/dev/null) || rc=1
      if ((rc == 0)); then
        if awk -F'\t' -v OFS='\t' -v h="$hash" -v now="$now" '$3 + 0 <= now + 0 { next } $1 == h && NF == 3 { print $0, "used"; next } { print }' "$f" > "$tmp" && mv -f "$tmp" "$f"; then
          rc=0
        else
          rm -f "$tmp"
          rc=1
        fi
      fi
    fi
  fi
  ck_unlock tokens
  case $rc in
    0) return 0 ;;
    44) ck_die 44 "the join token was refused (unknown, used, expired or for another node)" ;;
    *) ck_die 1 "cannot update $f" ;;
  esac
}
