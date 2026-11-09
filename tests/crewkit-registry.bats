#!/usr/bin/env bats
# libexec/ck/registry.sh: the registry store (registry.json, nodes/, log.ndjson), git sync and join
# tokens. Each call runs in a fresh bash (rg) so locks and $$ are real. The sync "remote" is the
# local bare repo $SYNC; the registry clone is $R.

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

RID=r-aaaaaaaaaa
HID=n-hhhhhhhhhh
NA=n-aaaaaaaaaa
NB=n-bbbbbbbbbb
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPubKeyForTests crewkit-test'

setup() {
  ck_setup
  R="$BATS_TEST_TMPDIR/reg"
  user_setting "registry.dir: \"$R\"" "registry.remote: \"$SYNC\""
}

# rg ARGS...: run a registry function in a new bash.
rg() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/registry.sh"; shift; "$@"' _ "$TREE" "$@"
}
mkreg() { rg ck_reg_create "$R" "$RID" "$HID"; }
# node ID NAME [STATE]: a valid node record.
node() {
  jq -cn --arg id "$1" --arg name "$2" --arg st "${3:-ready}" '{schema:1,node_id:$id,name:$name,role:"spoke",labels:{},boundary:"owner",state:$st,expires:null,cap:null,joined_at:"2026-10-27T00:00:00Z",versions:{crewkit:"1",herdr:"0.5"},report:null,report_at:null}'
}
sha() { printf '%s' "$1" | if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
commits() { git -C "$R" rev-list --count HEAD; }
# parse TOKEN: print the four parsed parts, tab separated.
parse() {
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/registry.sh"; ck_token_parse "$2" && printf "%s\t%s\t%s\t%s\n" "$TK_REGISTRY_ID" "$TK_NODE_ID" "$TK_SECRET" "$TK_PUBKEY"' _ "$TREE" "$1"
}

@test "create writes registry.json and an empty nodes dir, committed" {
  run mkreg
  [ "$status" -eq 0 ]
  jq -e '.schema==1 and (.registry_id|test("^r-[a-z2-7]{10}$")) and .registry_id=="r-aaaaaaaaaa" and .holder=="n-hhhhhhhhhh" and (.created|test("^[0-9]{4}-"))' "$R/registry.json"
  [ -d "$R/nodes" ]
  [ -e "$R/log.ndjson" ]
  [ -z "$(git -C "$R" status --porcelain)" ]
  [ "$(commits)" -eq 1 ]
  git -C "$R" ls-files | grep -q '^nodes/'
  [ "$(rg ck_reg_dir)" = "$R" ]
  [ "$(rg ck_reg_id)" = "$RID" ]
  [ "$(rg ck_reg_holder)" = "$HID" ]
}

@test "create refuses bad ids (65) and an existing registry" {
  run rg ck_reg_create "$R" r-AAA "$HID"
  [ "$status" -eq 65 ]
  run rg ck_reg_create "$R" "$RID" n-short
  [ "$status" -eq 65 ]
  [ ! -e "$R/registry.json" ]
  mkreg
  run rg ck_reg_create "$R" r-bbbbbbbbbb "$HID"
  [ "$status" -ne 0 ]
  [ "$(rg ck_reg_id)" = "$RID" ]
}

@test "require is 78 without a registry.json and 0 with one" {
  run rg ck_reg_require
  [ "$status" -eq 78 ]
  run rg ck_reg_node_put "$(node $NA homebox)"
  [ "$status" -eq 78 ]
  mkreg
  run rg ck_reg_require
  [ "$status" -eq 0 ]
}

@test "set_holder changes the holder; a bad id is 65 and changes nothing" {
  mkreg
  rg ck_reg_set_holder "$NA"
  [ "$(rg ck_reg_holder)" = "$NA" ]
  [ "$(rg ck_reg_id)" = "$RID" ]
  run rg ck_reg_set_holder 'n-../x'
  [ "$status" -eq 65 ]
  [ "$(rg ck_reg_holder)" = "$NA" ]
}

@test "node_put then get: stable sorted bytes, listing sorted" {
  mkreg
  rg ck_reg_node_put "$(node $NB second)"
  rg ck_reg_node_put "$(node $NA first)"
  [ "$(rg ck_reg_nodes)" = "$NA
$NB" ]
  run rg ck_reg_node_get "$NA"
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = first ]
  [ "$output" = "$(jq -S . "$R/nodes/$NA.json")" ]
  run rg ck_reg_node_get n-cccccccccc
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  # no temp file is left behind
  [ -z "$(ls -A "$R/nodes" | grep '^\.tmp')" ]
}

@test "node_put refuses a host or any unlisted key (65) and writes nothing" {
  mkreg
  run rg ck_reg_node_put '{"schema":1,"node_id":"n-aaaaaaaaaa","name":"homebox","host":"x"}'
  [ "$status" -eq 65 ]
  [ ! -e "$R/nodes/n-aaaaaaaaaa.json" ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '. + {host:"uh"}')"
  [ "$status" -eq 65 ]
  [ ! -e "$R/nodes/$NA.json" ]
}

@test "node_put refuses a missing key, a non-object and bad JSON (65)" {
  mkreg
  run rg ck_reg_node_put "$(node $NA homebox | jq -c 'del(.cap)')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put '[1]'
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put '{nope'
  [ "$status" -eq 65 ]
  [ -z "$(rg ck_reg_nodes)" ]
}

@test "node_put value checks: each bad value is 65 and writes nothing" {
  mkreg
  local f
  for f in '.schema=2' '.boundary="both"' '.state="up"' '.name="Bad Name"' '.name=5' '.labels={"a":1}' '.labels=[]' \
    '.versions={"crewkit":"1"}' '.versions={"crewkit":"1","herdr":"2","x":"3"}' '.expires=5' '.cap="x"' \
    '.report={"host":"x"}' '.report=5' '.role=7' '.state=null'; do
    run rg ck_reg_node_put "$(node $NA homebox | jq -c "$f")"
    [ "$status" -eq 65 ] || { echo "accepted: $f" >&2; return 1; }
  done
  [ ! -e "$R/nodes/$NA.json" ]
}

@test "node_put accepts every state, both boundaries and a report of Task 7's keys" {
  mkreg
  local s
  for s in joining ready paused draining gone; do
    rg ck_reg_node_put "$(node $NA homebox $s)"
  done
  rg ck_reg_node_put "$(node $NA homebox | jq -c '.boundary="client" | .report={"agents":[],"at":"x","boot_start":1,"bridge":{},"crewkit":"1","herdr":"2","join_token_sha256":"x","name":"n","node_id":"n","other_sessions":0,"platform":"p","push_gate":{},"schema":1,"session":"s"}')"
  [ "$(jq -r .boundary "$R/nodes/$NA.json")" = client ]
  # The same constant is what Task 7 consumes.
  [ "$(rg eval 'echo "$CK_REPORT_KEYS"')" = "agents at boot_start bridge crewkit herdr join_token_sha256 name node_id other_sessions platform push_gate schema session" ]
}

@test "a node id with a path in it is 65 everywhere and touches no file" {
  mkreg
  local before
  before=$(find "$BATS_TEST_TMPDIR" -type f | sort | grep -v '/\.git/' | cksum)
  run rg ck_reg_node_get '../registry'
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node 'n-../../x' homebox)"
  [ "$status" -eq 65 ]
  [ ! -e "$R/x.json" ] && [ ! -e "$R/nodes/n-../../x.json" ]
  run rg ck_reg_node_put "$(node 'n-aaaaaaaaaaa' homebox)"
  [ "$status" -eq 65 ]
  run rg ck_reg_log joined '../../x'
  [ "$status" -eq 65 ]
  run rg ck_reg_set_holder '../x'
  [ "$status" -eq 65 ]
  run rg ck_token_mint '../x' ''
  [ "$status" -eq 65 ]
  run rg ck_token_consume "$(sha x)" '../x'
  [ "$status" -eq 65 ]
  [ -z "$(find "$R" -name '*x*' -not -path '*/.git/*')" ]
  [ ! -s "$R/log.ndjson" ]
  [ -z "$(rg ck_reg_nodes)" ]
  [ "$(find "$BATS_TEST_TMPDIR" -type f | sort | grep -v '/\.git/' | cksum)" = "$before" ]
}

@test "log lines are appended, never rewritten, and survive quotes, newlines and braces" {
  mkreg
  rg ck_reg_log joined "$NA" 'first'
  head -c 4 "$R/log.ndjson" > "$BATS_TEST_TMPDIR/head1"
  ino=$(ls -i "$R/log.ndjson" | cut -d' ' -f1)
  rg ck_reg_log paused "$NB" 'say "hi"
second line } {'
  rg ck_reg_log gone "$NA"
  [ "$(wc -l < "$R/log.ndjson" | tr -d ' ')" -eq 3 ]
  [ "$(head -c 4 "$R/log.ndjson")" = "$(cat "$BATS_TEST_TMPDIR/head1")" ]
  [ "$(ls -i "$R/log.ndjson" | cut -d' ' -f1)" = "$ino" ]
  while IFS= read -r l; do
    jq -e 'keys==["at","detail","event","node_id"]' <<<"$l" >/dev/null
  done < "$R/log.ndjson"
  [ "$(sed -n 2p "$R/log.ndjson" | jq -r .detail)" = 'say "hi"
second line } {' ]
  [ "$(sed -n 1p "$R/log.ndjson" | jq -r '.at+" "+.event+" "+.node_id')" = "$(jq -rn --argjson t "$CK_NOW" '$t | todate') joined $NA" ]
  [ "$(sed -n 3p "$R/log.ndjson" | jq -r .detail)" = "" ]
}

@test "commit is a no-op without changes, one commit with changes" {
  mkreg
  run rg ck_reg_commit 'nothing'
  [ "$status" -eq 0 ]
  [ "$(commits)" -eq 1 ]
  rg ck_reg_node_put "$(node $NA homebox)"
  rg ck_reg_commit 'add homebox'
  [ "$(commits)" -eq 2 ]
  [ "$(git -C "$R" log -1 --format=%s)" = 'add homebox' ]
  [ "$(git -C "$R" log -1 --format=%an)" = crewkit ]
  [ -z "$(git -C "$R" status --porcelain)" ]
  rg ck_reg_commit 'again'
  [ "$(commits)" -eq 2 ]
}

@test "a timestamp-only change waits sync_min_seconds before it is committed" {
  mkreg
  rg ck_reg_node_put "$(node $NA homebox)"
  rg ck_reg_commit 'add'
  local n
  n=$(commits)
  rg ck_reg_node_put "$(node $NA homebox | jq -c '.report_at="2026-10-27T01:00:00Z"')"
  CK_NOW=$((CK_NOW + 10)) rg ck_reg_commit 'tick'
  [ "$(commits)" -eq "$n" ]
  [ -n "$(git -C "$R" status --porcelain)" ]
  CK_NOW=$((CK_NOW + 301)) rg ck_reg_commit 'tick'
  [ "$(commits)" -eq $((n + 1)) ]
  [ -z "$(git -C "$R" status --porcelain)" ]
}

@test "registry.sync_min_seconds is read; a change besides report_at is committed at once" {
  mkreg
  rg ck_reg_node_put "$(node $NA homebox)"
  rg ck_reg_commit 'add'
  local n
  n=$(commits)
  user_setting 'registry.sync_min_seconds: "5"'
  rg ck_reg_node_put "$(node $NA homebox | jq -c '.report_at="2026-10-27T01:00:00Z"')"
  CK_NOW=$((CK_NOW + 6)) rg ck_reg_commit 'tick'
  [ "$(commits)" -eq $((n + 1)) ]
  # A real change plus a new report_at is not debounced.
  rg ck_reg_node_put "$(node $NA homebox paused | jq -c '.report_at="2026-10-27T02:00:00Z"')"
  CK_NOW=$((CK_NOW + 7)) rg ck_reg_commit 'paused'
  [ "$(commits)" -eq $((n + 2)) ]
  # A debounced node file does not hold back another file.
  rg ck_reg_node_put "$(node $NA homebox paused | jq -c '.report_at="2026-10-27T03:00:00Z"')"
  rg ck_reg_node_put "$(node $NB other)"
  CK_NOW=$((CK_NOW + 8)) rg ck_reg_commit 'b'
  [ "$(commits)" -eq $((n + 3)) ]
  git -C "$R" ls-files | grep -q "$NB"
  [ -n "$(git -C "$R" status --porcelain)" ]
}

@test "push then pull between two clones; synced_at is the last success" {
  mkreg
  [ -z "$(rg ck_reg_synced_at)" ]
  run rg ck_reg_push
  [ "$status" -eq 0 ]
  [ "$(rg ck_reg_synced_at)" = "$CK_NOW" ]
  git clone -q -b main "$SYNC" "$BATS_TEST_TMPDIR/other"
  git -C "$BATS_TEST_TMPDIR/other" -c user.name=o -c user.email=other.invalid commit -q --allow-empty -m remote-change
  git -C "$BATS_TEST_TMPDIR/other" push -q origin HEAD
  CK_NOW=$((CK_NOW + 50)) run rg ck_reg_pull
  [ "$status" -eq 0 ]
  [ "$(git -C "$R" log -1 --format=%s)" = remote-change ]
  [ "$(CK_NOW=0 rg ck_reg_synced_at)" = $((CK_NOW + 50)) ]
  [ "$(ls -ld "$(rg ck_state_dir)/registry" | cut -c1-10)" = drwx------ ]
}

@test "pull is fast-forward only: a diverged history returns 1 and makes no merge" {
  mkreg
  rg ck_reg_push
  git clone -q -b main "$SYNC" "$BATS_TEST_TMPDIR/other"
  git -C "$BATS_TEST_TMPDIR/other" -c user.name=o -c user.email=other.invalid commit -q --allow-empty -m remote-change
  git -C "$BATS_TEST_TMPDIR/other" push -q origin HEAD
  rg ck_reg_node_put "$(node $NA homebox)"
  rg ck_reg_commit local-change
  local head
  head=$(git -C "$R" rev-parse HEAD)
  run rg ck_reg_pull
  [ "$status" -eq 1 ]
  [ "$(git -C "$R" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$R" rev-list --merges --count HEAD)" -eq 0 ]
  run rg ck_reg_push
  [ "$status" -eq 1 ]
}

@test "pull and push against an unreachable remote return 1 quickly and keep local commits" {
  mkreg
  rg ck_reg_push
  rm -rf "$SYNC"
  rg ck_reg_node_put "$(node $NA homebox)"
  rg ck_reg_commit 'local only'
  local t0=$SECONDS before
  before=$(rg ck_reg_synced_at)
  run rg ck_reg_pull
  [ "$status" -eq 1 ]
  run rg ck_reg_push
  [ "$status" -eq 1 ]
  ((SECONDS - t0 < 8))
  git -C "$R" log --oneline | grep -q 'local only'
  [ "$(rg ck_reg_synced_at)" = "$before" ]
}

@test "git runs with BatchMode, a 10 s timeout, no prompt and the registry.ssh_key identity" {
  mkreg
  mkdir "$BATS_TEST_TMPDIR/sshbin"
  printf '%s\n' '#!/bin/sh' 'echo "ssh $*" >> "$SSH_LOG"' 'echo "prompt=${GIT_TERMINAL_PROMPT-unset}" >> "$SSH_LOG"' 'exit 255' > "$BATS_TEST_TMPDIR/sshbin/ssh"
  chmod +x "$BATS_TEST_TMPDIR/sshbin/ssh"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  : > "$SSH_LOG"
  user_setting 'registry.remote: "ssh://example.invalid/r.git"' "registry.ssh_key: \"$HOME/my key\""
  PATH="$BATS_TEST_TMPDIR/sshbin:$PATH" run rg ck_reg_pull
  [ "$status" -eq 1 ]
  grep -q 'BatchMode=yes' "$SSH_LOG"
  grep -q 'ConnectTimeout=10' "$SSH_LOG"
  grep -q "IdentitiesOnly=yes" "$SSH_LOG"
  grep -q -- "-i $HOME/my key" "$SSH_LOG"
  grep -q 'prompt=0' "$SSH_LOG"
  : > "$SSH_LOG"
  PATH="$BATS_TEST_TMPDIR/sshbin:$PATH" run rg ck_reg_push
  [ "$status" -eq 1 ]
  grep -q 'BatchMode=yes' "$SSH_LOG"
}

@test "a minted token parses back to its parts" {
  mkreg
  run --separate-stderr rg ck_token_mint "$NA" "$PUB"
  [ "$status" -eq 0 ]
  tok=$output
  [[ $tok =~ ^ck1\.r-aaaaaaaaaa\.n-aaaaaaaaaa\.[a-z2-7]{26}\.[A-Za-z0-9_-]+$ ]]
  [ -z "$stderr" ]
  run parse "$tok"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r r n s k <<<"$output"
  [ "$r" = "$RID" ] && [ "$n" = "$NA" ] && [ "${#s}" -eq 26 ] && [ "$k" = "$PUB" ]
  [[ $tok == *".$s."* ]]
  # Two tokens never share a secret.
  tok2=$(rg ck_token_mint "$NA" "$PUB")
  [ "$tok" != "$tok2" ]
}

@test "an empty pubkey part is allowed (init's own local token)" {
  mkreg
  tok=$(rg ck_token_mint "$HID" '')
  [[ $tok =~ \.[a-z2-7]{26}\.$ ]]
  run parse "$tok"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r r n s k <<<"$output"
  [ "$n" = "$HID" ] && [ -z "$k" ]
}

@test "parse refuses extra dots, bad charsets and any key but ssh-ed25519 (65)" {
  local b64 s=abcdefghijklmnopqrstuvwxyz
  b64=$(printf '%s' "$PUB" | base64 | tr -d '\n=' | tr '+/' '-_')
  s=abcdefghabcdefghabcdefgh22
  run parse "ck1.$RID.$NA.$s.$b64"
  [ "$status" -eq 0 ]
  local bad
  for bad in "ck1.$RID.$NA.$s.$b64.extra" "ck1.$RID.$NA.$s" "ck2.$RID.$NA.$s.$b64" "ck1.r-AAAAAAAAAA.$NA.$s.$b64" \
    "ck1.$RID.n-aaaaaaaaa.$s.$b64" "ck1.$RID.$NA.${s^^}.$b64" "ck1.$RID.$NA.${s:1}.$b64" "ck1.$RID.$NA.${s}a.$b64" \
    "ck1.$RID.$NA.${s:0:25}1.$b64" "ck1.$RID.$NA.$s.$b64=" "ck1.$RID.$NA.$s.a+b" "ck1.$RID.$NA.$s.!!!!" "" "x"; do
    run parse "$bad"
    [ "$status" -eq 65 ] || { echo "not refused: $bad" >&2; return 1; }
  done
  # Other key types and multi-line keys.
  for bad in 'ssh-rsa AAAAB3Nza user' 'ecdsa-sha2-nistp256 AAAA u' $'ssh-ed25519 AAAA u\nssh-ed25519 BBBB v' $'ssh-ed25519 AAAA u\n' 'ssh-ed25519'; do
    b64=$(printf '%s' "$bad" | base64 | tr -d '\n=' | tr '+/' '-_')
    run parse "ck1.$RID.$NA.$s.$b64"
    [ "$status" -eq 65 ] || { echo "not refused: $bad" >&2; return 1; }
  done
  # Mint refuses them too, and mints nothing.
  mkreg
  run rg ck_token_mint "$NA" 'ssh-rsa AAAAB3Nza user'
  [ "$status" -eq 65 ]
  run rg ck_token_mint "$NA" $'ssh-ed25519 AAAA u\nx'
  [ "$status" -eq 65 ]
  [ ! -e "$(rg ck_state_dir)/registry/tokens.tsv" ]
}

@test "a token is single use, bound to its node, and dies after 24 h (44)" {
  mkreg
  tok=$(rg ck_token_mint "$NA" "$PUB")
  IFS=$'\t' read -r r n s k <<<"$(parse "$tok")"
  h=$(sha "$s")
  # unknown
  run rg ck_token_consume "$(sha nothing)" "$NA"
  [ "$status" -eq 44 ]
  # another node: refused, and the token is still good
  run rg ck_token_consume "$h" "$NB"
  [ "$status" -eq 44 ]
  run rg ck_token_consume "$h" "$NA"
  [ "$status" -eq 0 ]
  run rg ck_token_consume "$h" "$NA"
  [ "$status" -eq 44 ]
  # expiry: valid just inside 24 h, dead after
  tok=$(rg ck_token_mint "$NA" "$PUB")
  IFS=$'\t' read -r r n s k <<<"$(parse "$tok")"
  h=$(sha "$s")
  CK_NOW=$((CK_NOW + 86401)) run rg ck_token_consume "$h" "$NA"
  [ "$status" -eq 44 ]
  tok=$(rg ck_token_mint "$NA" "$PUB")
  IFS=$'\t' read -r r n s k <<<"$(parse "$tok")"
  CK_NOW=$((CK_NOW + 86399)) run rg ck_token_consume "$(sha "$s")" "$NA"
  [ "$status" -eq 0 ]
  # a malformed hash is 65
  run rg ck_token_consume 'not-a-hash' "$NA"
  [ "$status" -eq 65 ]
}

@test "tokens.tsv is 600 and outside the sync repo; the secret is stored only hashed" {
  mkreg
  local f
  f="$(rg ck_state_dir)/registry/tokens.tsv"
  run --separate-stderr bash -c 'umask 000; source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/registry.sh"; ck_token_mint "$2" "$3"' _ "$TREE" "$NA" "$PUB"
  [ "$status" -eq 0 ]
  tok=$output
  IFS=$'\t' read -r r n s k <<<"$(parse "$tok")"
  [ "$(ls -l "$f" | cut -c1-10)" = -rw------- ]
  none -q "$s" "$f"
  none -rq "$s" "$R"
  none -q "$s" <<<"$stderr"
  grep -q "^$(sha "$s")"$'\t'"$NA"$'\t'"$((CK_NOW + 86400))\$" "$f"
  # nothing else leaks it: not the log, not a commit, not stderr of consume
  rg ck_reg_log token-minted "$NA" 'minted'
  rg ck_reg_commit all
  none -rq "$s" "$R"
  ( umask 000; rg ck_token_consume "$(sha "$s")" "$NA" )
  [ "$(ls -l "$f" | cut -c1-10)" = -rw------- ]
  none -q "$s" "$f"
  [ -z "$(ls -A "$(dirname "$f")" | grep '^\.')" ]
  [[ $f != "$R"/* ]]
}

@test "the secret is in no external command's argv" {
  mkreg
  local shims="$BATS_TEST_TMPDIR/shims" cmd
  mkdir "$shims"
  cat > "$shims/shim" <<'SH'
#!/usr/bin/env bash
name=${0##*/}
printf '%s' "$name" >> "$SHIM_LOG"
printf ' %s' "$@" >> "$SHIM_LOG"
printf '\n' >> "$SHIM_LOG"
PATH=${PATH#"$SHIM_DIR":}
exec "$(command -v "$name")" "$@"
SH
  chmod +x "$shims/shim"
  for cmd in jq head tr base64 sha256sum shasum cut awk mv mktemp mkdir ln rm cat sed grep date od xxd openssl; do
    command -v "$cmd" >/dev/null && ln -s shim "$shims/$cmd"
  done
  export SHIM_LOG="$BATS_TEST_TMPDIR/argv.log" SHIM_DIR="$shims"
  : > "$SHIM_LOG"
  run --separate-stderr env PATH="$shims:$PATH" bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; source "$1/libexec/ck/registry.sh"; ck_token_mint "$2" "$3"' _ "$TREE" "$NA" "$PUB"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r r n s k <<<"$(parse "$output")"
  [ -s "$SHIM_LOG" ]
  none -q "$s" "$SHIM_LOG"
  : > "$SHIM_LOG"
  PATH="$shims:$PATH" rg ck_token_consume "$(sha "$s")" "$NA"
  [ -s "$SHIM_LOG" ]
  none -q "$s" "$SHIM_LOG"
}

# ---- fix round 1 ----

@test "fix1.1 a registry_id in registry.json that is not r-+10 is 65 from ck_reg_id and ck_token_mint" {
  mkreg
  jq '.registry_id="r-../x"' "$R/registry.json" > "$R/registry.new" && mv "$R/registry.new" "$R/registry.json"
  run rg ck_reg_id
  [ "$status" -eq 65 ]
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 65 ]
  [ ! -e "$(rg ck_state_dir)/registry/tokens.tsv" ]
}

@test "fix1.2 a failing owner hook is not bypassed, and git's message is shown" {
  mkreg
  mkdir "$BATS_TEST_TMPDIR/hooks"
  printf '%s\n' '#!/bin/sh' 'echo HOOK-REFUSED-9f3e >&2' 'exit 1' > "$BATS_TEST_TMPDIR/hooks/pre-commit"
  chmod +x "$BATS_TEST_TMPDIR/hooks/pre-commit"
  printf '[core]\n\thooksPath = %s\n' "$BATS_TEST_TMPDIR/hooks" > "$HOME/.gitconfig-hooks"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig-hooks"
  rg ck_reg_node_put "$(node $NA homebox)"
  run --separate-stderr rg ck_reg_commit 'x'
  [ "$status" -ne 0 ]
  [[ $stderr == *"crewkit: registry: "* ]]
  [[ $stderr == *HOOK-REFUSED-9f3e* ]]
  [ "$(commits)" -eq 1 ]
  # The lock is released after the failure.
  [ ! -e "$(rg ck_state_dir)/locks/registry.lock" ]
}

@test "fix1.3 commit, pull and push hold the registry lock (75 while it is held); two commits both succeed" {
  mkreg
  rg ck_reg_push
  user_setting 'lock_wait_seconds: "1"'
  bash -c 'source "$1/lib/settings.sh"; source "$1/libexec/ck/common.sh"; ck_lock registry; exec sleep 20' _ "$TREE" &
  holder=$!
  local i
  for i in $(seq 1 50); do [ -L "$(rg ck_state_dir)/locks/registry.lock" ] && break; sleep 0.1; done
  rg ck_reg_node_put "$(node $NA homebox)"
  run rg ck_reg_commit 'x'
  [ "$status" -eq 75 ]
  run rg ck_reg_pull
  [ "$status" -eq 75 ]
  run rg ck_reg_push
  [ "$status" -eq 75 ]
  kill "$holder"; wait "$holder" 2>/dev/null || true
  rg ck_reg_node_put "$(node $NB other)"
  user_setting 'lock_wait_seconds: "30"'
  rg ck_reg_commit 'a' & p1=$!
  rg ck_reg_commit 'b' & p2=$!
  wait "$p1"; wait "$p2"
  [ -z "$(git -C "$R" status --porcelain)" ]
  # The lock is free again, and log (which takes it) does not deadlock after a commit.
  rg ck_reg_log joined "$NA" ok
}

@test "fix1.4 pull and push disable askpass and prompts, and ssh has keepalives" {
  mkreg
  mkdir "$BATS_TEST_TMPDIR/gitbin"
  cat > "$BATS_TEST_TMPDIR/gitbin/git" <<'SH'
#!/bin/sh
case " $* " in *" pull "*|*" push "*) ;; *) PATH=${PATH#"$GIT_SHIM_DIR":}; exec git "$@" ;; esac
{ echo "GIT_ASKPASS=${GIT_ASKPASS-unset}"; echo "SSH_ASKPASS=${SSH_ASKPASS-unset}"; echo "SSH_ASKPASS_REQUIRE=${SSH_ASKPASS_REQUIRE-unset}"; echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT-unset}"; echo "GIT_SSH_COMMAND=${GIT_SSH_COMMAND-unset}"; } >> "$GIT_ENV_LOG"
PATH=${PATH#"$GIT_SHIM_DIR":}
exec git "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/gitbin/git"
  export GIT_ENV_LOG="$BATS_TEST_TMPDIR/gitenv.log" GIT_SHIM_DIR="$BATS_TEST_TMPDIR/gitbin"
  : > "$GIT_ENV_LOG"
  PATH="$GIT_SHIM_DIR:$PATH" rg ck_reg_push
  PATH="$GIT_SHIM_DIR:$PATH" rg ck_reg_pull
  grep -qx 'GIT_ASKPASS=/bin/false' "$GIT_ENV_LOG"
  grep -qx 'SSH_ASKPASS=/bin/false' "$GIT_ENV_LOG"
  grep -qx 'SSH_ASKPASS_REQUIRE=never' "$GIT_ENV_LOG"
  grep -qx 'GIT_TERMINAL_PROMPT=0' "$GIT_ENV_LOG"
  grep -q 'ServerAliveInterval=5 -o ServerAliveCountMax=2' "$GIT_ENV_LOG"
  none -q '=unset' "$GIT_ENV_LOG"
}

@test "fix1.5 a state_dir inside the registry dir (or a symlink into it) is refused with 78 and no tokens.tsv" {
  mkreg
  user_setting "state_dir: \"$R/state\""
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 78 ]
  run rg ck_token_consume "$(sha x)" "$NA"
  [ "$status" -eq 78 ]
  [ ! -e "$R/state/registry/tokens.tsv" ]
  ln -s "$R" "$BATS_TEST_TMPDIR/viaLink"
  user_setting "state_dir: \"$BATS_TEST_TMPDIR/viaLink/st2\""
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 78 ]
  [ ! -e "$R/st2/registry/tokens.tsv" ]
  [ -z "$(git -C "$R" status --porcelain | grep tokens)" ]
}

@test "fix1.6 any consume drops expired rows" {
  mkreg
  tokA=$(rg ck_token_mint "$NA" '')
  IFS=$'\t' read -r r n sA k <<<"$(parse "$tokA")"
  tokB=$(CK_NOW=$((CK_NOW + 86000)) rg ck_token_mint "$NB" '')
  IFS=$'\t' read -r r n sB k <<<"$(parse "$tokB")"
  f="$(rg ck_state_dir)/registry/tokens.tsv"
  [ "$(wc -l < "$f" | tr -d ' ')" -eq 2 ]
  CK_NOW=$((CK_NOW + 86500)) run rg ck_token_consume "$(sha nothing)" "$NB"
  [ "$status" -eq 44 ]
  [ "$(wc -l < "$f" | tr -d ' ')" -eq 1 ]
  none -q "$(sha "$sA")" "$f"
  grep -q "^$(sha "$sB")" "$f"
  [ "$(ls -l "$f" | cut -c1-10)" = -rw------- ]
  CK_NOW=$((CK_NOW + 86500)) run rg ck_token_consume "$(sha "$sB")" "$NB"
  [ "$status" -eq 0 ]
}

@test "fix1.7 parse refuses non-canonical base64url and a NUL, with only our message on stderr" {
  local good b64 last c alt s=abcdefghabcdefghabcdefgh22 alpha=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_
  # find a pubkey whose base64 length leaves unused bits, and a different last char with the same bytes
  local pk found=''
  for pk in "$PUB" "$PUB-" "$PUB--" "$PUB---"; do
    good=$(printf '%s' "$pk" | base64 | tr -d '\n=' | tr '+/' '-_')
    [ $(( ${#good} % 4 )) -ne 0 ] && { found=$pk; break; }
  done
  [ -n "$found" ]
  last=${good: -1}
  for ((i = 0; i < 64; i++)); do
    c=${alpha:i:1}
    [ "$c" = "$last" ] && continue
    alt=${good%?}$c
    if [ "$(printf '%s' "$alt" | tr -- '-_' '+/' | jq -Rj '@base64d' 2>/dev/null)" = "$found" ]; then break; fi
    alt=
  done
  [ -n "$alt" ]
  run --separate-stderr parse "ck1.$RID.$NA.$s.$good"
  [ "$status" -eq 0 ]
  run --separate-stderr parse "ck1.$RID.$NA.$s.$alt"
  [ "$status" -eq 65 ]
  [ "${#lines[@]}" -eq 0 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ $stderr == crewkit:* ]]
  # a NUL in the decoded bytes
  b64=$(printf 'ssh-ed25519 AAAA c\0d' | base64 | tr -d '\n=' | tr '+/' '-_')
  run --separate-stderr parse "ck1.$RID.$NA.$s.$b64"
  [ "$status" -eq 65 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ $stderr == crewkit:* ]]
}

@test "fix1.8 label keys and values must pass ck_label_ok (a dotted key is 65)" {
  mkreg
  local f
  for f in '.labels={"a.b":"x"}' '.labels={"Role":"x"}' '.labels={"role":"has space"}' '.labels={"role":""}'; do
    run rg ck_reg_node_put "$(node $NA homebox | jq -c "$f")"
    [ "$status" -eq 65 ] || { echo "accepted: $f" >&2; return 1; }
  done
  [ ! -e "$R/nodes/$NA.json" ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.labels={"role":"hub","zone":"a-1"}')"
  [ "$status" -eq 0 ]
}

# ---- fix round 2 ----

@test "fix2.1 expiry is checked before pruning: an expired token is 44 even when the prune cannot write" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory modes"
  mkreg
  tok=$(rg ck_token_mint "$NA" '')
  IFS=$'\t' read -r r n s k <<<"$(parse "$tok")"
  d="$(rg ck_state_dir)/registry"
  chmod 500 "$d"
  CK_NOW=$((CK_NOW + 86401)) run rg ck_token_consume "$(sha "$s")" "$NA"
  chmod 700 "$d"
  [ "$status" -eq 44 ]
  # unchanged: the row is still there (nothing could be written), and a good token still works
  grep -q "^$(sha "$s")" "$d/tokens.tsv"
  tok=$(rg ck_token_mint "$NB" '')
  IFS=$'\t' read -r r n s2 k <<<"$(parse "$tok")"
  run rg ck_token_consume "$(sha "$s2")" "$NB"
  [ "$status" -eq 0 ]
}

@test "fix2.2 tokens.tsv is refused inside the clone whatever the letter case (same inode, not same string)" {
  mkreg
  mkdir "$BATS_TEST_TMPDIR/CaseProbe"
  [ -d "$BATS_TEST_TMPDIR/caseprobe" ] || skip "this file system is case-sensitive"
  user_setting "state_dir: \"$BATS_TEST_TMPDIR/REG/state\""
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 78 ]
  run rg ck_token_consume "$(sha x)" "$NA"
  [ "$status" -eq 78 ]
  [ ! -e "$R/state/registry/tokens.tsv" ]
  [ -z "$(git -C "$R" status --porcelain)" ]
}

@test "fix2.3 a refused state_dir inside the clone leaves no directory there" {
  mkreg
  user_setting "state_dir: \"$R/st3\""
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 78 ]
  [ ! -e "$R/st3/registry" ]
}

@test "fix2.4 commit refuses (78) when a tokens.tsv is in the repo status, tracked or not, and stages nothing" {
  mkreg
  rg ck_reg_node_put "$(node $NA homebox)"
  mkdir -p "$R/state"
  echo row > "$R/state/tokens.tsv"
  run rg ck_reg_commit 'x'
  [ "$status" -eq 78 ]
  [ "$(commits)" -eq 1 ]
  git -C "$R" diff --cached --quiet
  # tracked and modified
  git -C "$R" add -f state/tokens.tsv
  git -C "$R" -c user.name=t -c user.email=t.invalid commit -q -m 'oops tracked'
  echo more >> "$R/state/tokens.tsv"
  run rg ck_reg_commit 'x'
  [ "$status" -eq 78 ]
  [ "$(commits)" -eq 2 ]
  [ -n "$(git -C "$R" diff --name-only | grep tokens.tsv)" ]
  git -C "$R" diff --cached --quiet
  [ ! -e "$(rg ck_state_dir)/locks/registry.lock" ]
}

@test "fix2.5 a control character in a label key or value is 65 and writes nothing" {
  mkreg
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.labels={"role":"hub\nzone=a"}')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.labels={"role=hub\nzone":"a"}')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.labels={"role":"a\u007fb"}')"
  [ "$status" -eq 65 ]
  [ ! -e "$R/nodes/$NA.json" ]
}

@test "fix2.6 ck_reg_holder checks its id; a silent git failure still says something" {
  mkreg
  jq '.holder="n-../x"' "$R/registry.json" > "$R/registry.new" && mv "$R/registry.new" "$R/registry.json"
  run rg ck_reg_holder
  [ "$status" -eq 65 ]
  mkdir "$BATS_TEST_TMPDIR/hooks2"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$BATS_TEST_TMPDIR/hooks2/pre-commit"
  chmod +x "$BATS_TEST_TMPDIR/hooks2/pre-commit"
  printf '[core]\n\thooksPath = %s\n' "$BATS_TEST_TMPDIR/hooks2" > "$HOME/.gitconfig-hooks2"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig-hooks2"
  rg ck_reg_node_put "$(node $NA homebox)"
  run --separate-stderr rg ck_reg_commit 'x'
  [ "$status" -ne 0 ]
  [[ $stderr == *"crewkit: registry: "?* ]]
}

@test "fix2.7 a registry.dir that is a symlink to the clone does not hide a state_dir inside it" {
  mkreg
  ln -s "$R" "$BATS_TEST_TMPDIR/regLink"
  user_setting "registry.dir: \"$BATS_TEST_TMPDIR/regLink\"" "state_dir: \"$R/state\""
  run rg ck_token_mint "$NA" ''
  [ "$status" -eq 78 ]
  [ ! -e "$R/state/registry/tokens.tsv" ]
}

# ---- fix round 3 ----

@test "fix3.1 a state_dir that cannot be resolved is 78, never 'not inside'" {
  [ "$(id -u)" -ne 0 ] || skip "root can search any directory"
  mkreg
  mkdir "$BATS_TEST_TMPDIR/locked"
  user_setting "state_dir: \"$BATS_TEST_TMPDIR/locked\""
  chmod 000 "$BATS_TEST_TMPDIR/locked"
  run --separate-stderr rg ck_token_mint "$NA" ''
  chmod 700 "$BATS_TEST_TMPDIR/locked"
  [ "$status" -eq 78 ]
  [[ $stderr == *"cannot resolve"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/locked/registry/tokens.tsv" ]
}

@test "fix3.2 a control character in role or name (any string field) is 65 and writes nothing" {
  mkreg
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.role="hub\nzone"')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.name="homebox\n"')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.joined_at="x\u0001y"')"
  [ "$status" -eq 65 ]
  run rg ck_reg_node_put "$(node $NA homebox | jq -c '.versions.herdr="1\u007f"')"
  [ "$status" -eq 65 ]
  [ ! -e "$R/nodes/$NA.json" ]
}

@test "fix3.3 a leftover .tokens.* temp in the clone refuses the commit (78) before anything is staged" {
  mkreg
  rg ck_reg_node_put "$(node $NA homebox)"
  echo row > "$R/.tokens.ABC123"
  run rg ck_reg_commit 'x'
  [ "$status" -eq 78 ]
  [ "$(commits)" -eq 1 ]
  git -C "$R" diff --cached --quiet
  # and an index the owner staged by hand is left as it was
  rm "$R/.tokens.ABC123"
  echo hand > "$R/hand.txt"
  git -C "$R" add hand.txt
  mkdir -p "$R/zz"; echo row > "$R/zz/tokens.tsv"
  run rg ck_reg_commit 'x'
  [ "$status" -eq 78 ]
  [ "$(git -C "$R" diff --cached --name-only)" = hand.txt ]
}
