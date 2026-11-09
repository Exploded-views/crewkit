#!/usr/bin/env bats
# The signal path (the holder docs, the phase-1 plan's Task 18b): the pointer format and its check
# (libexec/ck/pointer.sh), `crewkit outbox add` (libexec/crewkit-outbox), the holder's listener
# (ck_pointer_listen), and `crewkit holder tokens` (libexec/crewkit-holder-tokens). curl, ntfy and
# sleep are stubs (tests/stubs, $PSTUB records their calls); nothing here touches a network.

# shellcheck disable=SC2016  # stub scripts are written with single quotes on purpose
# shellcheck disable=SC1091  # libexec/ck/pointer.sh is sourced from the test tree

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

# A time limit for every test, unless the runner (the mutation runner, the Linux gate) set its own:
# see the test "every test of this suite has a time limit". It has to be set here, not in setup().
: "${BATS_TEST_TIMEOUT:=60}"
export BATS_TEST_TIMEOUT

TOKEN=tk_s3cretTOKENvalue9
URL=https://holder.example/crewkit-n-abc12

setup() {
  ck_setup
  ln -s "$REPO/tests/stubs/curl" "$BATS_TEST_TMPDIR/bin/curl"
  ln -s "$REPO/tests/stubs/ntfy" "$BATS_TEST_TMPDIR/bin/ntfy"
  printf '#!/bin/sh\necho "$*" >> "$PSTUB/sleep.log"\n' > "$BATS_TEST_TMPDIR/bin/sleep"
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  export TREE PSTUB
  : > "$PSTUB/sleep.log"
  user_setting "nodes.hub.pointer_url: $URL" "nodes.hub.pointer_token: $TOKEN"
}

outbox() { ck outbox "$@"; }
logs() { cat "$HOME"/.local/state/crewkit/outbox/*.log 2>/dev/null; }
calls() { cat "$PSTUB/curl.count" 2>/dev/null || echo 0; }

# listen ARGS...: ck_pointer_listen in a fresh shell; a pull appends the node name to $PSTUB/pulled.
listen() {
  printf '#!/bin/sh\necho "$1" >> "$PSTUB/pulled"\n' > "$BATS_TEST_TMPDIR/pull"
  chmod +x "$BATS_TEST_TMPDIR/pull"
  printf '%s\n' "$TOKEN" > "$BATS_TEST_TMPDIR/readtoken"
  chmod 600 "$BATS_TEST_TMPDIR/readtoken"
  CK_POINTER_CONNECTS=${CK_POINTER_CONNECTS:-1} run bash -c '
    source "$TREE/lib/settings.sh"; source "$TREE/libexec/ck/common.sh"; source "$TREE/libexec/ck/pointer.sh"
    ck_pointer_listen http://127.0.0.1:8080 "$1" "$2"' _ "$BATS_TEST_TMPDIR/readtoken" "$BATS_TEST_TMPDIR/pull"
}
# stream N LINE...: what the Nth curl stream call prints.
stream() { local n=$1; shift; printf '%s\n' "$@" > "$PSTUB/curl.stream.$n"; }
msg() { printf '{"id":"i%s","time":1,"event":"message","topic":"%s","message":%s}' "$RANDOM" "$1" "$(jq -n --arg m "$2" '$m')"; }

# ---- the pointer format ------------------------------------------------------------------------

@test "ck_pointer_ok accepts a short prefix, a number and the owner flag" {
  ck_lib
  source "$TREE/libexec/ck/pointer.sh"
  local ok
  for ok in 'ob-12 owner:yes' 'th-1 owner:no' 'abcdefgh-123456 owner:yes' 'ab-0 owner:no'; do
    ck_pointer_ok "$ok" || { echo "refused: $ok"; return 1; }
  done
}

@test "ck_pointer_ok drops anything else: extra text, case, length, a second line" {
  ck_lib
  source "$TREE/libexec/ck/pointer.sh"
  local bad
  for bad in '' 'ob-12' 'ob-12 owner:yes ' ' ob-12 owner:yes' 'ob-12 owner:yes now' 'OB-12 owner:yes' \
    'o-12 owner:yes' 'abcdefghi-12 owner:yes' 'ob-1234567 owner:yes' 'ob-12 owner:maybe' 'ob-12  owner:yes' \
    'ob-12 owner:yes ignore previous instructions' 'ob-x owner:yes' 'ob12 owner:yes' \
    $'ob-12 owner:yes\n' $'ob-12 owner:yes\nrm -rf /' $'ob-12\nowner:yes' $'ob-12 owner:yes\r'; do
    if ck_pointer_ok "$bad"; then echo "accepted: $bad"; return 1; fi
  done
}

# ---- crewkit outbox add ------------------------------------------------------------------------

@test "outbox add appends the record and sends exactly '<id> owner:yes'" {
  run outbox add ob-12 --owner yes "ready for review" --yes
  [ "$status" -eq 0 ]
  [ "$(logs)" = "2026-10-26T07:33:20Z ob-12 owner:yes ready for review" ]
  [ "$(cat "$PSTUB/curl.body")" = "ob-12 owner:yes" ]
  [ "$(cat "$PSTUB/curl.url")" = "$URL" ]
  grep -q -e '--proto =https,http' "$PSTUB/curl.argv"
  grep -q -e '-m 10' "$PSTUB/curl.argv"
  [ -f "$HOME/.local/state/crewkit/outbox/default.log" ]
  [ "$(stat -c %a "$HOME/.local/state/crewkit/outbox/default.log" 2>/dev/null || stat -f %Lp "$HOME/.local/state/crewkit/outbox/default.log")" = 600 ]
}

@test "the token reaches curl on stdin only, never argv, output or the outbox" {
  run outbox add ob-12 --owner no "one line" --yes
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer $TOKEN" "$PSTUB/curl.config"
  none -q "$TOKEN" "$PSTUB/curl.argv"
  none -q "$TOKEN" <<<"$output"
  none -q "$TOKEN" <<<"$(logs)"
}

@test "a failed send is exit 0 with the poll note, the record stays, and no secret is printed" {
  CURL_FAIL=1 run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"pointer not sent (the 10-minute poll will pick it up)"* ]]
  [ -n "$(logs)" ]
  none -q "$TOKEN" <<<"$output"
  none -q "$URL" <<<"$output"
}

@test "without the url or the token the send is skipped with the same note" {
  user_setting "nodes.hub.pointer_token:"
  run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"pointer not sent"* ]]
  [ "$(calls)" -eq 0 ]
  [ -n "$(logs)" ]
}

@test "a bad id, owner, second line, long line or control character is 65 and sends nothing" {
  local long
  long=$(printf 'x%.0s' $(seq 201))
  run outbox add OB-12 --owner yes "line" --yes; [ "$status" -eq 65 ]
  run outbox add ob-12x --owner yes "line" --yes; [ "$status" -eq 65 ]
  run outbox add ob-12 --owner maybe "line" --yes; [ "$status" -eq 65 ]
  run outbox add ob-12 --owner yes $'two\nlines' --yes; [ "$status" -eq 65 ]
  [[ $output == *"must be one line"* ]]   # a newline is also a control character, so name the check
  run outbox add ob-12 --owner yes "$long" --yes; [ "$status" -eq 65 ]
  run outbox add ob-12 --owner yes $'bell\a' --yes; [ "$status" -eq 65 ]
  run outbox add ob-12 --owner yes "" --yes; [ "$status" -eq 65 ]
  [ "$(calls)" -eq 0 ]
  [ -z "$(logs)" ]
}

@test "a line of exactly 200 characters is accepted" {
  local line
  line=$(printf 'x%.0s' $(seq 200))
  run outbox add ob-12 --owner yes "$line" --yes
  [ "$status" -eq 0 ]
}

@test "the same id and line again appends nothing and sends again" {
  run outbox add ob-12 --owner yes "line" --yes; [ "$status" -eq 0 ]
  run outbox add ob-12 --owner yes "line" --yes; [ "$status" -eq 0 ]
  [ "$(logs | wc -l)" -eq 1 ]
  [ "$(calls)" -eq 2 ]
}

@test "the same id with another line, or another owner flag, is 65" {
  run outbox add ob-12 --owner yes "line" --yes; [ "$status" -eq 0 ]
  run outbox add ob-12 --owner yes "other line" --yes; [ "$status" -eq 65 ]
  run outbox add ob-12 --owner no "line" --yes; [ "$status" -eq 65 ]
  [ "$(logs | wc -l)" -eq 1 ]
  [ "$(calls)" -eq 1 ]
}

@test "without --yes it is a dry run: nothing written, nothing sent" {
  run outbox add ob-12 --owner yes "line"
  [ "$status" -eq 0 ]
  [ -z "$(logs)" ]
  [ "$(calls)" -eq 0 ]
}

@test "a record goes to the session's own log" {
  run outbox add ob-12 --owner yes --session bridge "line" --yes
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/state/crewkit/outbox/bridge.log" ]
}

@test "the outbox directory is private to the user" {
  run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  local d="$HOME/.local/state/crewkit/outbox"
  [ "$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d")" = 700 ]
}

@test "a session name that is not a plain name is 64 and nothing is recorded or sent" {
  local bad
  for bad in '../escape' 'a/b' 'a b' '.hidden' ''; do
    run outbox add ob-12 --owner yes --session "$bad" "line" --yes
    [ "$status" -eq 64 ]
  done
  [ -z "$(logs)" ]
  [ ! -e "$HOME/.local/state/crewkit/escape.log" ]
  [ "$(calls)" -eq 0 ]
}

@test "a url or token that is not plain is 78 and nothing is recorded or sent" {
  local bad
  for bad in 'file:///etc/passwd' 'ftp://holder.example/x' 'https://holder.example/x y' 'https://h.example/"x' $'https://h.example/x\ny' 'holder.example/x' 'https://u:p'$'\x40''h.example/x'; do
    user_setting "nodes.hub.pointer_url: '$bad'"
    run outbox add ob-12 --owner yes "line" --yes
    [ "$status" -eq 78 ] || { echo "url '$bad' gave $status"; return 1; }
  done
  user_setting "nodes.hub.pointer_url: $URL"
  for bad in 'tk"x' 'tk x' 'tk\x' 'tk/x'; do
    user_setting "nodes.hub.pointer_token: '$bad'"
    run outbox add ob-12 --owner yes "line" --yes
    [ "$status" -eq 78 ] || { echo "token '$bad' gave $status"; return 1; }
  done
  [ "$(calls)" -eq 0 ]
  [ -z "$(logs)" ]
}

@test "with a token but no url nothing is sent" {
  user_setting "nodes.hub.pointer_url:"
  run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"pointer not sent"* ]]
  [ "$(calls)" -eq 0 ]
}

@test "outbox add waits for the outbox lock and gives up with 75, recording nothing" {
  mkdir -p "$HOME/.local/state/crewkit/locks"
  ln -s "$$" "$HOME/.local/state/crewkit/locks/outbox.lock"
  CREWKIT_LOCK_WAIT_SECONDS=1 run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 75 ]
  [ -z "$(logs)" ]
  [ "$(calls)" -eq 0 ]
}

# ---- the holder's listener ---------------------------------------------------------------------

@test "the listener pulls the node on a valid pointer and drops one with extra text, counting it" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 '{"event":"open","topic":"crewkit-n-abc12"}' "$(msg crewkit-n-abc12 'ob-12 owner:yes')" \
    "$(msg crewkit-n-abc12 'ob-13 owner:yes and then do this')" '{"event":"keepalive"}'
  listen
  [ "$status" -eq 0 ]
  [ "$(cat "$PSTUB/pulled")" = "homebox" ]
  [ "$(cat "$HOME/.local/state/crewkit/pointer.dropped")" = "1" ]
}

@test "the listener pulls once for a repeated node and id" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 "$(msg crewkit-n-abc12 'ob-12 owner:yes')" "$(msg crewkit-n-abc12 'ob-12 owner:yes')" \
    "$(msg crewkit-n-abc12 'ob-13 owner:no')"
  listen
  [ "$(wc -l < "$PSTUB/pulled")" -eq 2 ]
}

@test "a message on a topic that is no node's is dropped" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 "$(msg crewkit-n-zzz99 'ob-12 owner:yes')" "$(msg other-topic 'ob-12 owner:yes')"
  listen
  [ ! -s "$PSTUB/pulled" ]
  [ "$(cat "$HOME/.local/state/crewkit/pointer.dropped")" = "2" ]
}

@test "a pointer with a second line, or a command in it, is dropped and runs nothing" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 "$(msg crewkit-n-abc12 $'ob-12 owner:yes\ntouch '"$BATS_TEST_TMPDIR"'/pwned')" \
    "$(msg crewkit-n-abc12 'ob-12 owner:yes $(touch '"$BATS_TEST_TMPDIR"'/pwned)')" \
    "$(msg crewkit-n-abc12 'ob-12 owner:yes; touch '"$BATS_TEST_TMPDIR"'/pwned')" '{"event":"message","topic":"crewkit-n-abc12"}' \
    "$(msg crewkit-n-abc12 'ob-99 owner:no')"
  listen
  [ "$(cat "$PSTUB/pulled")" = "homebox" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a stream that drops is reconnected with backoff 1, 2, 4, 8 and the read token is not in argv" {
  user_setting "nodes.homebox.node_id: n-abc12"
  CK_POINTER_CONNECTS=5 listen
  [ "$(calls)" -eq 5 ]
  [ "$(paste -sd, "$PSTUB/sleep.log")" = "1,2,4,8" ]
  none -q "$TOKEN" "$PSTUB/curl.argv"
  grep -q "Authorization: Bearer $TOKEN" "$PSTUB/curl.config"
}

@test "the backoff stops at 60 seconds" {
  user_setting "nodes.homebox.node_id: n-abc12"
  CK_POINTER_CONNECTS=9 listen
  [ "$(paste -sd, "$PSTUB/sleep.log")" = "1,2,4,8,16,32,60,60" ]
}

@test "a stream that delivered something starts the backoff over" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 3 "$(msg crewkit-n-abc12 'ob-12 owner:yes')"
  CK_POINTER_CONNECTS=5 listen
  [ "$(paste -sd, "$PSTUB/sleep.log")" = "1,2,1,2" ]
}

@test "the pull command cannot read the stream: a command that reads stdin loses no later pointer" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 "$(msg crewkit-n-abc12 'ob-12 owner:yes')" "$(msg crewkit-n-abc12 'ob-13 owner:no')"
  printf '#!/bin/sh\ncat >/dev/null\necho "$1" >> "$PSTUB/pulled"\n' > "$BATS_TEST_TMPDIR/pull"
  chmod +x "$BATS_TEST_TMPDIR/pull"
  printf '%s\n' "$TOKEN" > "$BATS_TEST_TMPDIR/readtoken"
  CK_POINTER_CONNECTS=1 run bash -c '
    source "$TREE/lib/settings.sh"; source "$TREE/libexec/ck/common.sh"; source "$TREE/libexec/ck/pointer.sh"
    ck_pointer_listen http://127.0.0.1:8080 "$1" "$2"' _ "$BATS_TEST_TMPDIR/readtoken" "$BATS_TEST_TMPDIR/pull"
  [ "$(wc -l < "$PSTUB/pulled")" -eq 2 ]
}

@test "a pull that failed is tried again when the same pointer comes back" {
  user_setting "nodes.homebox.node_id: n-abc12"
  stream 1 "$(msg crewkit-n-abc12 'ob-12 owner:yes')" "$(msg crewkit-n-abc12 'ob-12 owner:yes')"
  printf '#!/bin/sh\necho "$1" >> "$PSTUB/pulled"\n[ "$(wc -l < "$PSTUB/pulled")" -gt 1 ]\n' > "$BATS_TEST_TMPDIR/pull"
  chmod +x "$BATS_TEST_TMPDIR/pull"
  printf '%s\n' "$TOKEN" > "$BATS_TEST_TMPDIR/readtoken"
  CK_POINTER_CONNECTS=1 run bash -c '
    source "$TREE/lib/settings.sh"; source "$TREE/libexec/ck/common.sh"; source "$TREE/libexec/ck/pointer.sh"
    ck_pointer_listen http://127.0.0.1:8080 "$1" "$2"' _ "$BATS_TEST_TMPDIR/readtoken" "$BATS_TEST_TMPDIR/pull"
  [ "$(wc -l < "$PSTUB/pulled")" -eq 2 ]
}

@test "the same id from two nodes pulls both" {
  user_setting "nodes.homebox.node_id: n-abc12" "nodes.other.node_id: n-zzz99"
  stream 1 "$(msg crewkit-n-abc12 'ob-12 owner:yes')" "$(msg crewkit-n-zzz99 'ob-12 owner:yes')"
  listen
  [ "$(sort "$PSTUB/pulled" | paste -sd, -)" = "homebox,other" ]
}

# The listener loops until CK_POINTER_CONNECTS streams are done, and `sleep` is a stub here, so a
# listener test that lost its stop would spin for ever (and its bats run be left behind when the
# shell that started it died). bats ends a test that outlives BATS_TEST_TIMEOUT and takes the
# test's processes with it.
@test "every test of this suite has a time limit: a listener that never stops is cut off" {
  [[ ${BATS_TEST_TIMEOUT-} =~ ^[1-9][0-9]*$ ]]
  [ "$BATS_TEST_TIMEOUT" -le 3600 ]   # the most the mutation runner allows; a limit of hours is no limit
}

# refuse BASE TOKENFILE: ck_pointer_listen in a fresh shell, one stream at most so that a missing
# check ends the test with the wrong status instead of looping.
refuse() {
  CK_POINTER_CONNECTS=1 run bash -c '
    source "$TREE/lib/settings.sh"; source "$TREE/libexec/ck/common.sh"; source "$TREE/libexec/ck/pointer.sh"
    ck_pointer_listen "$1" "$2" true' _ "$1" "$2"
}

@test "the listener refuses a read-token file it cannot read, or a token that is not plain" {
  user_setting "nodes.homebox.node_id: n-abc12"
  printf '%s\n' "$TOKEN" > "$BATS_TEST_TMPDIR/readtoken"
  printf '%s\n' 'tk"x' > "$BATS_TEST_TMPDIR/badtoken"
  refuse http://127.0.0.1:8080 "$BATS_TEST_TMPDIR/badtoken"
  [ "$status" -eq 78 ]
  [[ $output == *"not a plain token"* ]]
  refuse http://127.0.0.1:8080 /nonexistent
  [ "$status" -eq 78 ]
  [[ $output == *"cannot read the read-token file"* ]]
  refuse file:///etc "$BATS_TEST_TMPDIR/readtoken"
  [ "$status" -eq 78 ]
  [[ $output == *"not a plain http(s) URL"* ]]
  [ "$(calls)" -eq 0 ]
}

@test "the listener with no node to follow is 78" {
  printf '%s\n' "$TOKEN" > "$BATS_TEST_TMPDIR/readtoken"
  refuse http://127.0.0.1:8080 "$BATS_TEST_TMPDIR/readtoken"
  [ "$status" -eq 78 ]
  [[ $output == *"no topic to follow"* ]]
  [ "$(calls)" -eq 0 ]
}

# ---- crewkit holder tokens ---------------------------------------------------------------------

tokens() { ck holder tokens homebox --base-url http://holder:8080 "$@"; }
authdb() { cat "$HOME/.local/state/crewkit/holder/ntfy_auth" 2>/dev/null; }

@test "holder tokens without --yes is a dry run: nothing made" {
  user_setting "nodes.homebox.node_id: n-abc12"
  run tokens
  [ "$status" -eq 0 ]
  [ -z "$(authdb)" ]
  [ ! -e "$PSTUB/ntfy.log" ]
}

@test "holder tokens: write-only to its own topic, the file written, the two lines printed" {
  user_setting "nodes.homebox.node_id: n-abc12"
  run tokens --yes
  [ "$status" -eq 0 ]
  grep -q '^access .* crewkit-n-abc12 write-only$' "$HOME/.local/state/crewkit/holder/ntfy_auth"
  [ "$(grep -c '^access ' <<<"$(authdb)")" -eq 1 ]
  grep -q ntfy-auth-db <<<"$(authdb)"
  grep -q '^default_access deny-all$' "$PSTUB/ntfy.env"
  [[ $output == *"nodes.hub.pointer_url: http://holder:8080/crewkit-n-abc12"* ]]
  [[ $output == *"nodes.hub.pointer_token: tk_stub1"* ]]
  [ "$(stat -c %a "$HOME/.local/state/crewkit/holder/ntfy_auth" 2>/dev/null || stat -f %Lp "$HOME/.local/state/crewkit/holder/ntfy_auth")" = 600 ]
}

@test "holder tokens: the password is never in argv, the log or the output" {
  user_setting "nodes.homebox.node_id: n-abc12"
  run tokens --yes
  [ "$status" -eq 0 ]
  local pw
  pw=$(sed -n 's/^password //p' "$PSTUB/ntfy.env")
  [ -n "$pw" ]
  [ -s "$PSTUB/ntfy.log" ]
  none -q -i password "$PSTUB/ntfy.log"
  none -q -F "$pw" <<<"$output"
  none -q -F "$pw" "$HOME/.local/state/crewkit/holder/ntfy_auth"
}

@test "holder tokens: a re-run kills the old token and prints a new one" {
  user_setting "nodes.homebox.node_id: n-abc12"
  run tokens --yes
  [[ $output == *"tk_stub1"* ]]
  run tokens --yes
  [ "$status" -eq 0 ]
  [[ $output == *"nodes.hub.pointer_token: tk_stub2"* ]]
  none -q tk_stub1 <<<"$(authdb)"
  grep -q tk_stub2 <<<"$(authdb)"
}

@test "holder tokens: another node's token is untouched" {
  user_setting "nodes.homebox.node_id: n-abc12" "nodes.other.node_id: n-zzz99"
  ck holder tokens other --base-url http://holder:8080 --yes
  run tokens --yes
  [ "$status" -eq 0 ]
  grep -q 'crewkit-n-zzz99 write-only' <<<"$(authdb)"
  grep -q 'crewkit-n-abc12 write-only' <<<"$(authdb)"
}

@test "holder tokens: a node with no node_id, a bad name or a bad base url is refused" {
  run tokens --yes; [ "$status" -eq 78 ]
  user_setting "nodes.homebox.node_id: n-abc12"
  run ck holder tokens 'Bad Name' --base-url http://holder:8080 --yes; [ "$status" -eq 64 ]
  run ck holder tokens homebox --base-url 'file:///etc' --yes; [ "$status" -eq 64 ]
  run ck holder tokens homebox --yes; [ "$status" -eq 64 ]
  [ ! -e "$PSTUB/ntfy.log" ]
}

@test "holder tokens waits for its lock and gives up with 75, changing nothing" {
  user_setting "nodes.homebox.node_id: n-abc12"
  mkdir -p "$HOME/.local/state/crewkit/locks"
  ln -s "$$" "$HOME/.local/state/crewkit/locks/holder-tokens.lock"
  CREWKIT_LOCK_WAIT_SECONDS=1 run tokens --yes
  [ "$status" -eq 75 ]
  [ -z "$(authdb)" ]
  [ ! -e "$PSTUB/ntfy.log" ]
}

@test "holder tokens without ntfy installed is 78 naming it" {
  user_setting "nodes.homebox.node_id: n-abc12"
  rm "$BATS_TEST_TMPDIR/bin/ntfy"
  local d p=''
  while IFS= read -r d; do [[ -x $d/ntfy ]] || p+=${p:+:}$d; done < <(tr ':' '\n' <<<"$PATH")
  PATH=$p run tokens --yes
  [ "$status" -eq 78 ]
  [[ $output == *ntfy* ]]
}

# ---- settings ----------------------------------------------------------------------------------

@test "the pointer settings are user-only: the environment cannot set them" {
  user_setting "nodes.hub.pointer_url:" "nodes.hub.pointer_token:"
  CREWKIT_NODES_HUB_POINTER_URL=https://evil.example/x CREWKIT_NODES_HUB_POINTER_TOKEN=tk_evil \
    run outbox add ob-12 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  user_setting "nodes.hub.pointer_url: https://hub.example/x"
  CREWKIT_NODES_HUB_POINTER_TOKEN=tk_evil run outbox add ob-13 --owner yes "line" --yes
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}
