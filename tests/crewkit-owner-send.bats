#!/usr/bin/env bats
# `crewkit owner send` (libexec/crewkit-owner-send): the delivery adapter that
# mc-notify's two senders run, onto `yo-human notify --json`. yo-human is a FAKE here: a stub
# script first on PATH (or named by the owner_send.yo_human setting) that records its argv in
# $PSTUB/yh.argv (one argument per line), counts its calls in $PSTUB/yh.calls, prints the fixture
# in $PSTUB/yh.json and exits with the code in $PSTUB/yh.rc. No real yo-human is ever run.

# shellcheck disable=SC2016  # stub scripts are written with single quotes on purpose

bats_require_minimum_version 1.5.0
load helpers
load crewkit-helpers

E=ob-12@3:0123456789abcdef
DK=ob-12-3-0123456789abcdef

setup() {
  ck_setup
  export PSTUB
  cat > "$BATS_TEST_TMPDIR/bin/yo-human" <<'EOF'
#!/bin/sh
echo x >> "$PSTUB/yh.calls"
printf '%s\n' "$@" > "$PSTUB/yh.argv"
cat "$PSTUB/yh.json" 2>/dev/null
exit "$(cat "$PSTUB/yh.rc")"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/yo-human"
  yh 0 "$(result "$(chan iphone sent)" "$(chan phone sent)")"
}

# yh RC JSON: what the fake prints and exits with.
yh() { printf '%s' "$2" > "$PSTUB/yh.json"; printf '%s\n' "$1" > "$PSTUB/yh.rc"; }
# chan NAME STATUS [unconfirmed|error TEXT]: one channels[] entry.
chan() {
  case ${3-} in
    unconfirmed) jq -nc --arg c "$1" --arg s "$2" '{channel:$c,status:$s,unconfirmed:true}' ;;
    error) jq -nc --arg c "$1" --arg s "$2" --arg e "$4" '{channel:$c,status:$s,error:$e}' ;;
    *) jq -nc --arg c "$1" --arg s "$2" '{channel:$c,status:$s}' ;;
  esac
}
# result CHAN...: a notify --json result holding those channel entries.
result() {
  local IFS=,
  printf '{"version":1,"status":"ok","id":"i1","channels":[%s]}' "$*"
}
calls() { cat "$PSTUB/yh.calls" 2>/dev/null | wc -l | tr -d ' '; }
argv() { mapfile -t ARGV < "$PSTUB/yh.argv"; }
send() { ck owner send "$@"; }
bark() { send --notify-entry "$E" --rule "${1-ci-red}" --level "${2-active}" "${@:3}"; }
ntfy() { send --notify-entry "$E" "$@"; }
# one_line: stdout is exactly one line.
one_line() { [ "${#lines[@]}" -eq 1 ]; }

# ---- dispatch --------------------------------------------------------------------------------------

@test "owner-send is reached as 'crewkit owner send', and not as a one-word verb" {
  run -0 --separate-stderr bark
  [ "$(calls)" -eq 1 ]
  run -64 ck owner-send --notify-entry "$E"
  run -64 ck owner
  run -64 ck owner frobnicate
}

# ---- forms and validation --------------------------------------------------------------------------

@test "the bark form takes its arguments in any order" {
  run -0 --separate-stderr send --level active --notify-entry "$E" --note "disk full" --rule ci-red
  [ "$output" = "sent -" ]
  run -0 --separate-stderr send --note "n" --rule r --level passive --notify-entry "$E"
  [ "$output" = "sent -" ]
  [ "$(calls)" -eq 2 ]
}

@test "the note is optional in the bark form" {
  run -0 --separate-stderr bark ci-red active
  [ "$output" = "sent -" ]
}

@test "the ntfy form is the entry alone" {
  run -0 --separate-stderr ntfy
  [ "$output" = "sent -" ]
  [ "$(calls)" -eq 1 ]
}

@test "a flag given twice is usage (64), and nothing is called" {
  run -64 send --notify-entry "$E" --notify-entry "$E" --rule r --level active
  run -64 send --notify-entry "$E" --rule r --rule r --level active
  run -64 send --notify-entry "$E" --rule r --level active --level active
  run -64 send --notify-entry "$E" --rule r --level active --note a --note b
  run -64 send --notify-entry "$E" --notify-entry "$E"
  [ "$(calls)" -eq 0 ]
}

@test "the ntfy form refuses --rule, --level and --note (64)" {
  run -64 ntfy --rule ci-red
  run -64 ntfy --level active
  run -64 ntfy --note "n"
  run -64 --separate-stderr ntfy --rule ci-red
  [ -z "$output" ]
  [ "$(calls)" -eq 0 ]
}

@test "an incomplete bark form, a missing entry, an unknown flag, a stray word or a missing value is usage (64)" {
  run -64 send --notify-entry "$E" --rule r
  run -64 send --notify-entry "$E" --level active
  run -64 send --notify-entry "$E" --note n --rule r
  run -64 send --rule r --level active
  run -64 send
  run -64 send --notify-entry "$E" --frob x
  run -64 send --notify-entry "$E" extra
  run -64 send --notify-entry
  run -64 send --notify-entry "$E" --rule r --level
  [ "$(calls)" -eq 0 ]
}

@test "a bad entry is bad data (65), and nothing is called" {
  local bad
  for bad in "" ob-12 ob-12@3 ob-12@3:0123456789abcde ob-12@3:0123456789abcdef0 ob-12@3:0123456789ABCDEF \
    ob-12@3:0123456789abcdeg OB-12@3:0123456789abcdef ob12@3:0123456789abcdef -12@3:0123456789abcdef \
    ob-@3:0123456789abcdef ob-12@:0123456789abcdef ob-12@x:0123456789abcdef ob-12@1234567:0123456789abcdef \
    ob-1234567890@3:0123456789abcdef abcdefghijklmnopq-1@3:0123456789abcdef "ob-12@3:0123456789abcdef " \
    " ob-12@3:0123456789abcdef" "ob-12@3:0123456789abcdef
x" "ob-12@3 :0123456789abcdef" "1b-12@3:0123456789abcdef"; do
    run --separate-stderr ck owner send --notify-entry "$bad"
    [ "$status" -eq 65 ] || { echo "entry '$bad' gave $status"; return 1; }
    [ -z "$output" ]
  done
  [ "$(calls)" -eq 0 ]
}

@test "entries at the edges of MC's id pattern are accepted" {
  run -0 --separate-stderr ntfy_with a-1@0:0123456789abcdef
  run -0 --separate-stderr ntfy_with abcdefgh-123456@1234:ffffffffffffffff
  run -0 --separate-stderr ntfy_with ob-12345@1:0123456789abcdef
  run -0 --separate-stderr ntfy_with th-1@9999:0123456789abcdef
  [ "$(calls)" -eq 4 ]
}

# MC's grammar (lib/crewpatterns.py RE_RE and SYNTH_ID_RES), as mc-notify's check_ref accepts it.
@test "ruling ids and every synthetic id are accepted, and reach yo-human as title and dedup key" {
  local ref n=0 nonce=0123456789abcdef
  for ref in ruling-20261103-7@2 ruling-20261103-1234@1 \
    digest-20261103T1200Z@1 hub-blind-hub-a1-20261103T1200Z@1 \
    bark-fail-20261103T1200Z@1 bark-fail-20261103T120059Z@1 bridge-20261103T1200Z@1 \
    baseline-20261103T1200Z@1 herdr-20261103T1200Z@1 wall-20261103T1200Z@1 \
    bark-orphan-20261103T1200Z@1 bark-orphan-20261103T120059Z@1; do
    run -0 --separate-stderr ntfy_with "$ref:$nonce"
    [ "$output" = "sent -" ] || { echo "$ref gave '$output'"; return 1; }
    argv
    [ "${ARGV[4]}" = "$ref" ] || { echo "title for $ref: ${ARGV[4]}"; return 1; }
    [ "${ARGV[6]}" = "${ref/@/-}-$nonce" ] || { echo "key for $ref: ${ARGV[6]}"; return 1; }
    n=$((n + 1))
  done
  [ "$(calls)" -eq "$n" ]
  run -0 --separate-stderr bark ci-red active
  run -0 --separate-stderr send --notify-entry "wall-20261103T1200Z@1:$nonce" --rule wall-breach --level time-sensitive --note n
  argv
  [ "${ARGV[4]}" = "wall-20261103T1200Z@1 wall-breach" ]
  [ "${ARGV[9]}" = "Open wall-20261103T1200Z@1 on the board" ]
}

@test "ids outside MC's grammar are refused (65), synthetic forms included" {
  local bad nonce=0123456789abcdef
  for bad in ruling-2026110-7@2 ruling-20261103-12345@2 ruling-20261103@2 ruling-20261103-7 \
    digest-20261103T1200@1 digest-20261103T1200Z@2 digest-20261103t1200z@1 digest-20261103T1200Z \
    hub-blind-20261103T1200Z@1 hub-blind-Hub-20261103T1200Z@1 hub-blind-1a-20261103T1200Z@1 \
    bark-fail-20261103T12000Z@1 bark-fail-20261103T1200599Z@1 bridge-20261103T120059Z@1 \
    baseline-20261103T120059Z@1 herdr-20261103T120059Z@1 wall-20261103T120059Z@1 \
    bark-orphan-20261103T12Z@1 digest-@1 wall-20261103T1200Z@1x abcdefghi-1@1 ob-1234567@1 ob-1@12345 \
    wall-20261103T1200Z@1-extra x-20261103T1200Z@1; do
    run --separate-stderr send --notify-entry "$bad:$nonce"
    [ "$status" -eq 65 ] || { echo "'$bad' gave $status"; return 1; }
    [ -z "$output" ]
  done
  [ "$(calls)" -eq 0 ]
}

ntfy_with() { send --notify-entry "$1"; }

@test "a bad rule is bad data (65), and nothing is called" {
  local bad
  for bad in "" Ci-red 1ci -ci ci_red "ci red" ci.red abcdefghijklmnopqrstuvwxyzabcde ci2; do
    run --separate-stderr bark "$bad" active
    [ "$status" -eq 65 ] || { echo "rule '$bad' gave $status"; return 1; }
    [ -z "$output" ]
  done
  run -0 --separate-stderr bark abcdefghijklmnopqrstuvwxyzabcd active
  run -0 --separate-stderr bark a-b-c active
  [ "$(calls)" -eq 2 ]
}

@test "a bad level is bad data (65): exactly passive, active or time-sensitive" {
  local bad
  for bad in "" Passive ACTIVE time_sensitive time-sensitive2 urgent fyi "passive " " active" critical; do
    run --separate-stderr bark ci-red "$bad"
    [ "$status" -eq 65 ] || { echo "level '$bad' gave $status"; return 1; }
    [ -z "$output" ]
  done
  [ "$(calls)" -eq 0 ]
}

@test "a bad note is bad data (65): empty, two lines, over 200 characters, a control character" {
  local long201 long200
  long200=$(printf 'a%.0s' $(seq 1 200))
  long201=${long200}a
  run -65 bark ci-red active --note ""
  run -65 bark ci-red active --note "$long201"
  run -65 bark ci-red active --note $'two\nlines'
  run -65 bark ci-red active --note $'tab\there'
  run -65 bark ci-red active --note $'esc\e[31m'
  run -65 bark ci-red active --note $'bell\a'
  run -65 bark ci-red active --note $'cr\rhere'
  [ "$(calls)" -eq 0 ]
  run -0 --separate-stderr bark ci-red active --note "$long200"
  argv
  [ "${ARGV[-1]}" = "$long200" ]
}

# ---- the level and channel mapping -----------------------------------------------------------------

@test "passive goes to fyi, active to ask, time-sensitive to urgent, and the ntfy form to wake" {
  local pair
  for pair in passive:fyi active:ask time-sensitive:urgent; do
    run -0 --separate-stderr bark ci-red "${pair%%:*}"
    argv
    [ "${ARGV[2]}" = "${pair##*:}" ] || { echo "${pair%%:*} gave ${ARGV[2]}"; return 1; }
  done
  run -0 --separate-stderr ntfy
  argv
  [ "${ARGV[2]}" = wake ]
}

@test "the level settings override the defaults" {
  user_setting "owner_send.levels.passive: low" "owner_send.levels.active: mid" \
    "owner_send.levels.time_sensitive: high" "owner_send.levels.ntfy: poke"
  run -0 --separate-stderr bark ci-red passive; argv; [ "${ARGV[2]}" = low ]
  run -0 --separate-stderr bark ci-red active; argv; [ "${ARGV[2]}" = mid ]
  run -0 --separate-stderr bark ci-red time-sensitive; argv; [ "${ARGV[2]}" = high ]
  run -0 --separate-stderr ntfy; argv; [ "${ARGV[2]}" = poke ]
}

@test "a bad level or channel setting is config (78), and nothing is called" {
  user_setting "owner_send.levels.active: 'a b'"
  run -78 bark ci-red active
  user_setting "owner_send.levels.active: ask" "owner_send.channels.bark: ''"
  run -78 bark ci-red active
  user_setting "owner_send.channels.bark: iphone" "owner_send.channels.ntfy: '-x'"
  run -78 ntfy
  user_setting "owner_send.channels.ntfy: phone" "owner_send.yo_human: 'rel/yo-human'"
  run -78 ntfy
  [ "$(calls)" -eq 0 ]
}

# ---- the argv the fake sees ------------------------------------------------------------------------

@test "the bark form calls notify with level, title, dedup key and --json, and a body only with a note" {
  run -0 --separate-stderr bark ci-red active
  argv
  [ "${#ARGV[@]}" -eq 10 ]
  [ "${ARGV[*]:0:1}" = notify ]
  [ "${ARGV[1]}" = --level ] && [ "${ARGV[2]}" = ask ]
  [ "${ARGV[3]}" = --title ] && [ "${ARGV[4]}" = "ob-12@3 ci-red" ]
  [ "${ARGV[5]}" = --dedup-key ] && [ "${ARGV[6]}" = "$DK" ]
  [ "${ARGV[7]}" = --json ]
  [ "${ARGV[8]}" = --ask ] && [ "${ARGV[9]}" = "Open ob-12@3 on the board" ]
  run -0 --separate-stderr bark ci-red active --note "disk is full"
  argv
  [ "${#ARGV[@]}" -eq 12 ]
  [ "${ARGV[7]}" = --json ]
  [ "${ARGV[8]}" = --ask ] && [ "${ARGV[9]}" = "Open ob-12@3 on the board" ]
  [ "${ARGV[10]}" = --body ] && [ "${ARGV[11]}" = "disk is full" ]
  none -q -x -e '--project' "$PSTUB/yh.argv"
}

@test "the ntfy form sends the id and nonce only: no rule, no note, no body" {
  run -0 --separate-stderr ntfy
  argv
  [ "${#ARGV[@]}" -eq 8 ]
  [ "${ARGV[2]}" = wake ]
  [ "${ARGV[4]}" = "ob-12@3" ]
  [ "${ARGV[6]}" = "$DK" ]
  [ "${ARGV[7]}" = --json ]
  none -q -e body -e ci-red -e '--ask' "$PSTUB/yh.argv"
}

@test "every Bark level passes the ask, the ntfy form never does" {
  local l
  for l in passive active time-sensitive; do
    run -0 --separate-stderr bark ci-red "$l"
    argv
    [ "${ARGV[8]}" = --ask ] || { echo "$l: no --ask"; return 1; }
  done
  run -0 --separate-stderr ntfy
  argv
  [ "${#ARGV[@]}" -eq 8 ]
  none -q -x -e '--ask' "$PSTUB/yh.argv"
}

@test "owner_send.ask overrides the ask text, and <id>@<rev> is filled in" {
  user_setting "owner_send.ask: Look at <id>@<rev> now"
  run -0 --separate-stderr bark
  argv
  [ "${ARGV[9]}" = "Look at ob-12@3 now" ]
  user_setting "owner_send.ask: Check the board"
  run -0 --separate-stderr bark
  argv
  [ "${ARGV[9]}" = "Check the board" ]
}

@test "a bad owner_send.ask is config (78), and nothing is called" {
  local long201
  long201=$(printf 'a%.0s' $(seq 1 201))
  user_setting "owner_send.ask: ''"
  run -78 bark
  user_setting "owner_send.ask: $long201"
  run -78 bark
  user_setting "owner_send.ask: Open <id> and <other>"
  run -78 bark
  user_setting "owner_send.ask: Open <rev>"
  run -78 bark
  [ "$(calls)" -eq 0 ]
  user_setting "owner_send.ask: ${long201:1}"
  run -0 --separate-stderr bark
}

@test "an ask-required level: a yo-human that exits 64 without --ask gives 'sent -' on the Bark form" {
  cat > "$BATS_TEST_TMPDIR/bin/yo-human" <<'EOF'
#!/bin/sh
case " $* " in
  *" --ask "*) cat "$PSTUB/yh.json"; exit 0 ;;
esac
echo '{"version":1,"status":"failed","error":"ask is required for level ask"}'
exit 64
EOF
  run -0 --separate-stderr bark ci-red active
  [ "$output" = "sent -" ]
  run -0 --separate-stderr bark ci-red time-sensitive
  [ "$output" = "sent -" ]
}

@test "the dedup key holds the nonce, so two sends of one entry id carry different keys" {
  run -0 --separate-stderr send --notify-entry ob-12@3:aaaaaaaaaaaaaaaa
  argv; local k1=${ARGV[6]}
  run -0 --separate-stderr send --notify-entry ob-12@3:bbbbbbbbbbbbbbbb
  argv; [ "${ARGV[6]}" != "$k1" ]
  [ "${ARGV[6]}" = ob-12-3-bbbbbbbbbbbbbbbb ]
}

@test "a note with shell metacharacters reaches the fake as one argument, never through a shell" {
  local n=$'$(touch pwned); `id` "q" \'s\' ; && *'
  run -0 --separate-stderr bark ci-red active --note "$n"
  argv
  [ "${ARGV[11]}" = "$n" ]
  [ ! -e "$HOME/pwned" ]
}

# ---- the output table ------------------------------------------------------------------------------

# out CODE JSON EXPECTED: the fake exits CODE printing JSON; stdout is exactly EXPECTED, one line.
out() {
  yh "$1" "$2"
  run -0 --separate-stderr bark
  one_line
  [ "$output" = "$3" ] || { echo "exit $1 gave '$output', want '$3'"; return 1; }
}

@test "exit 0 with the Bark channel sent is 'sent -'" {
  out 0 "$(result "$(chan iphone sent)")" "sent -"
}

@test "exit 0 with sent and unconfirmed, or any other status, is 'unknown -'" {
  out 0 "$(result "$(chan iphone sent unconfirmed)")" "unknown -"
  out 0 "$(result "$(chan iphone queued)")" "unknown -"
  out 0 "$(result "$(chan iphone held)")" "unknown -"
  out 0 "$(result "$(chan iphone skipped)")" "unknown -"
  out 0 "$(result "$(chan iphone dead)")" "unknown -"
  out 0 "$(result "$(chan iphone '')")" "unknown -"
}

@test "exit 75 is 'unknown -' whether the read channel is queued or absent" {
  out 75 "$(result "$(chan iphone queued)")" "unknown -"
  out 75 "$(result "$(chan journal sent)")" "unknown -"
  out 75 '{"version":1,"status":"queued","id":"i1"}' "unknown -"
}

@test "exit 69 is 'failed -' whether the read channel is dead, failed, skipped or absent" {
  out 69 "$(result "$(chan iphone dead)")" "failed -"
  out 69 "$(result "$(chan iphone failed)")" "failed -"
  out 69 "$(result "$(chan iphone skipped)")" "failed -"
  out 69 "$(result "$(chan journal dead)")" "failed -"
  out 69 '{"version":1,"status":"failed","id":"i1"}' "failed -"
}

@test "the journal and every other channel are ignored: journal sent and Bark dead with exit 69 is 'failed -'" {
  out 69 "$(result "$(chan journal sent)" "$(chan iphone dead)")" "failed -"
  out 0 "$(result "$(chan journal sent)" "$(chan iphone queued)")" "unknown -"
  out 0 "$(result "$(chan journal dead)" "$(chan pager sent)" "$(chan iphone sent)")" "sent -"
  out 0 "$(result "$(chan iphone sent unconfirmed)" "$(chan journal sent)" "$(chan phone sent)")" "unknown -"
}

@test "the read channel is chosen by setting: the Bark form reads owner_send.channels.bark, the ntfy form .ntfy" {
  yh 0 "$(result "$(chan iphone sent)" "$(chan phone dead)")"
  run -0 --separate-stderr bark; [ "$output" = "sent -" ]
  run -0 --separate-stderr ntfy; [ "$output" = "unknown -" ]
  yh 0 "$(result "$(chan iphone dead)" "$(chan phone sent)")"
  run -0 --separate-stderr bark; [ "$output" = "unknown -" ]
  run -0 --separate-stderr ntfy; [ "$output" = "sent -" ]
  user_setting "owner_send.channels.bark: watch" "owner_send.channels.ntfy: tablet"
  yh 0 "$(result "$(chan iphone sent)" "$(chan watch dead)" "$(chan tablet sent)")"
  run -0 --separate-stderr bark; [ "$output" = "unknown -" ]
  run -0 --separate-stderr ntfy; [ "$output" = "sent -" ]
}

# yo-human v0.2.0's real shapes: fail() writes {"version":1,"error":{what,valid,fix}} (exit 64 for a
# usage problem); finish() with a result writes the result plus "errors":[{what,valid,fix}] and no
# "error" key (exit 78 for a channel that could not be built).
@test "exit 64 with error{}: 'refused config', and error.what on stderr, nothing else on stdout" {
  yh 64 '{"version":1,"error":{"what":"unknown level: fyi","valid":"ask, wake, urgent","fix":"run yo-human levels"}}'
  run -0 --separate-stderr bark
  one_line
  [ "$output" = "refused config" ]
  [[ $stderr == *"unknown level: fyi"* ]]
  none -q '"what"' <<<"$stderr"
  [ "$(calls)" -eq 1 ]
}

# yo-human exits 78 whenever ANY channel of the level could not be built, even if the channel this
# tool reads did send, so 78 is never "refused config" (a retry would page twice): the read channel
# decides, and the " config" tag makes mc-notify raise one blocked item and never resend.
# w78 JSON...: yo-human's exit-78 shape: the result object with channels[] and errors[], no error key.
w78() {
  jq -nc --argjson r "$(result "$@")" \
    '$r + {status:"failed",errors:[{what:"channel phone: the key is not set",valid:"a key in secrets",fix:"set the key"},{what:"second",valid:"v",fix:"f"}]}'
}

@test "exit 78, the read channel sent: 'sent - config', with the error text on stderr" {
  yh 78 "$(w78 "$(chan iphone sent)" "$(chan phone skipped)")"
  run -0 --separate-stderr bark
  one_line
  [ "$output" = "sent - config" ]
  [[ $stderr == *"channel phone: the key is not set"* ]]
  none -q "second" <<<"$stderr"
  none -q '"what"' <<<"$stderr"
  [ "$(calls)" -eq 1 ]
}

@test "exit 78, the read channel skipped: 'unknown - config', with the error text on stderr" {
  yh 78 "$(w78 "$(chan iphone skipped)" "$(chan journal sent)")"
  run -0 --separate-stderr bark
  one_line
  [ "$output" = "unknown - config" ]
  [[ $stderr == *"channel phone: the key is not set"* ]]
}

@test "exit 78, the read channel sent but unconfirmed: 'unknown - config'" {
  yh 78 "$(w78 "$(chan iphone sent unconfirmed)")"
  run -0 --separate-stderr bark
  [ "$output" = "unknown - config" ]
}

@test "exit 78, the read channel absent, or any other status: 'unknown - config'" {
  local c
  yh 78 "$(w78 "$(chan journal sent)")"
  run -0 --separate-stderr bark
  [ "$output" = "unknown - config" ]
  yh 78 "$(w78)"
  run -0 --separate-stderr bark
  [ "$output" = "unknown - config" ]
  for c in queued held dead failed ""; do
    yh 78 "$(w78 "$(chan iphone "$c")")"
    run -0 --separate-stderr bark
    [ "$output" = "unknown - config" ] || { echo "status '$c' gave '$output'"; return 1; }
  done
}

@test "exit 78, unparseable output: 'unknown - config', and a stderr line" {
  local j
  for j in 'not json' '' '[1]' '{' '{"version":1,"error":"plain text"}'; do
    yh 78 "$j"
    run -0 --separate-stderr bark
    one_line
    [ "$output" = "unknown - config" ] || { echo "'$j' gave '$output'"; return 1; }
    [ -n "$stderr" ]
  done
}

@test "exit 78 reads the error text from errors[0], error.what or a plain string" {
  yh 78 '{"version":1,"error":{"what":"w1","valid":"v","fix":"f"}}'
  run -0 --separate-stderr bark; [ "$output" = "unknown - config" ]; [[ $stderr == *w1* ]]
  yh 78 '{"version":1,"error":"plain text"}'
  run -0 --separate-stderr bark; [[ $stderr == *"plain text"* ]]
  yh 78 '{"version":1,"status":"failed"}'
  run -0 --separate-stderr bark; [[ $stderr == *"no error text"* ]]
}

@test "exit 78 is the same on the ntfy form: its own channel decides" {
  yh 78 "$(w78 "$(chan iphone skipped)" "$(chan phone sent)")"
  run -0 --separate-stderr ntfy
  [ "$output" = "sent - config" ]
  run -0 --separate-stderr bark
  [ "$output" = "unknown - config" ]
}

@test "exit 64 is still 'refused config', whatever the channels say, and reads the error text" {
  local j
  for j in "$(result "$(chan iphone sent)")" 'not json' ''; do
    yh 64 "$j"
    run -0 --separate-stderr bark
    one_line
    [ "$output" = "refused config" ] || { echo "'$j' gave '$output'"; return 1; }
    [ -n "$stderr" ]
  done
  yh 64 '{"version":1,"error":{"what":"w1","valid":"v","fix":"f"}}'
  run -0 --separate-stderr bark; [[ $stderr == *w1* ]]
  yh 64 '{"version":1,"status":"failed","errors":[{"what":"w2","valid":"v","fix":"f"}]}'
  run -0 --separate-stderr bark; [[ $stderr == *w2* ]]
  yh 64 '{"version":1,"error":"plain text"}'
  run -0 --separate-stderr bark; [[ $stderr == *"plain text"* ]]
  yh 64 '{"version":1,"status":"failed"}'
  run -0 --separate-stderr bark; [[ $stderr == *"no error text"* ]]
}

@test "an error text with control characters reaches stderr as one clean line" {
  yh 78 "$(jq -nc '{error:{what:"bad\u001b[31m\nsecond line",valid:"v",fix:"f"}}')"
  run -0 --separate-stderr bark
  [ "$output" = "unknown - config" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  none -q $'\033' <<<"$stderr"
}

# ---- the two buckets (MC's ruling): a duplicate ping is cheap, a silent miss is not --------------
# AMBIGUOUS (a request may have left): "unknown -", exit 0, so mc-notify never resends.
# PROVEN NOT SENT: 64 and a missing binary are "refused config" (78 is its own case, above); 69 with the read channel dead,
# failed or skipped is "failed -"; 75 is queued, which yo-human retries itself: "unknown -".

@test "ambiguous bucket: every other yo-human exit code is 'unknown -' and exit 0, one per code" {
  local rc
  for rc in 1 2 3 65 66 67 68 70 71 72 73 74 76 77 79 100 126 127 128; do
    yh "$rc" "$(result "$(chan iphone sent)")"
    run -0 --separate-stderr bark
    one_line
    [ "$output" = "unknown -" ] || { echo "exit $rc gave '$output'"; return 1; }
    [ -n "$stderr" ]
  done
}

@test "ambiguous bucket: exit 70 and exit 74 are 'unknown -' whatever they print" {
  local rc j
  for rc in 70 74; do
    for j in '' 'garbage' '{"version":1,"error":{"what":"w","valid":"v","fix":"f"}}' "$(result "$(chan iphone dead)")"; do
      yh "$rc" "$j"
      run -0 --separate-stderr bark
      [ "$output" = "unknown -" ] || { echo "exit $rc '$j' gave '$output'"; return 1; }
    done
  done
}

@test "ambiguous bucket: yo-human killed by a signal (exit above 128) is 'unknown -'" {
  local rc
  for rc in 129 130 137 139 143 255; do
    yh "$rc" ''
    run -0 --separate-stderr bark
    one_line
    [ "$output" = "unknown -" ] || { echo "exit $rc gave '$output'"; return 1; }
  done
  printf '#!/bin/sh\nkill -9 $$\n' > "$BATS_TEST_TMPDIR/bin/yo-human"
  run -0 --separate-stderr bark
  [ "$output" = "unknown -" ]
}

@test "ambiguous bucket: exit 0 with unparseable JSON is 'unknown -'" {
  local j
  for j in 'RESULT ok i1' '' '[1,2]' '"x"' '{'; do
    yh 0 "$j"
    run -0 --separate-stderr bark
    one_line
    [ "$output" = "unknown -" ] || { echo "'$j' gave '$output'"; return 1; }
    [ -n "$stderr" ]
  done
}

@test "ambiguous bucket: exit 0 with the read channel missing is 'unknown -'" {
  local j
  for j in "$(result "$(chan journal sent)")" "$(result)" '{"version":1,"status":"ok","id":"i1"}' \
    '{"version":1,"status":"ok","channels":"x"}' '{"version":1,"status":"ok","channels":null}'; do
    yh 0 "$j"
    run -0 --separate-stderr bark
    [ "$output" = "unknown -" ] || { echo "$j gave '$output'"; return 1; }
  done
}

@test "exit 75 is 'unknown -' whatever it prints, unparseable JSON included" {
  local j
  for j in "$(result "$(chan iphone queued)")" "$(result "$(chan iphone sent)")" 'junk' ''; do
    yh 75 "$j"
    run -0 --separate-stderr bark
    [ "$output" = "unknown -" ] || { echo "'$j' gave '$output'"; return 1; }
  done
}

@test "exit 69 with a read channel that says sent contradicts the code: 'unknown -'; unparseable under 69 too" {
  yh 69 "$(result "$(chan iphone sent)")"
  run -0 --separate-stderr bark
  [ "$output" = "unknown -" ]
  yh 69 'junk'
  run -0 --separate-stderr bark
  [ "$output" = "unknown -" ]
}

@test "the adapter's own exit 70, with no line, is only for an internal error before yo-human is called (no jq)" {
  # a PATH that holds bash and coreutils but no jq
  local d="$BATS_TEST_TMPDIR/nojq" t
  mkdir -p "$d"
  for t in bash cat head tr env dirname mkdir printf; do ln -sf "$(command -v "$t")" "$d/$t" 2>/dev/null || true; done
  run -70 --separate-stderr env PATH="$d" "$BASH" "$TREE/bin/crewkit" owner send --notify-entry "$E"
  [ -z "$output" ]
  [[ $stderr == *jq* ]]
  [ "$(calls)" -eq 0 ]
}

@test "exactly one stdout line, and diagnostics go to stderr" {
  yh 0 "$(result "$(chan iphone sent)")"
  run -0 --separate-stderr bark ci-red active --note "n"
  one_line
  # yo-human's own stderr is passed on to stderr, never to stdout
  printf '#!/bin/sh\necho "warn: slow" >&2\ncat "$PSTUB/yh.json"\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/yo-human"
  run -0 --separate-stderr bark
  [ "$output" = "sent -" ]
  [[ $stderr == *"warn: slow"* ]]
}

@test "yo-human's stdout never reaches ours, and it is run with no stdin" {
  printf '#!/bin/sh\necho "RESULT ok i1"\ncat "$PSTUB/yh.json"\nexit 0\n' \
    > "$BATS_TEST_TMPDIR/bin/yo-human"
  run -0 --separate-stderr bark
  [ "$output" = "unknown -" ]
  printf '#!/bin/sh\nif read -r _l; then echo "stdin was open" >> "$PSTUB/stdin"; fi\ncat "$PSTUB/yh.json"\nexit 0\n' \
    > "$BATS_TEST_TMPDIR/bin/yo-human"
  run -0 --separate-stderr bark <<<"input that must not be passed on"
  [ "$output" = "sent -" ]
  [ ! -e "$PSTUB/stdin" ]
}

# ---- the binary ------------------------------------------------------------------------------------

@test "owner_send.yo_human can name an absolute path, used instead of the one on PATH" {
  local fake="$BATS_TEST_TMPDIR/other-yh"
  printf '#!/bin/sh\necho other >> "$PSTUB/other.calls"\ncat "$PSTUB/yh.json"\nexit 0\n' > "$fake"
  chmod +x "$fake"
  user_setting "owner_send.yo_human: $fake"
  run -0 --separate-stderr bark
  [ "$output" = "sent -" ]
  [ -e "$PSTUB/other.calls" ]
  [ "$(calls)" -eq 0 ]
}

@test "owner_send.yo_human can name another binary found on PATH" {
  ln -s "$BATS_TEST_TMPDIR/bin/yo-human" "$BATS_TEST_TMPDIR/bin/yo-human-alt"
  user_setting "owner_send.yo_human: yo-human-alt"
  run -0 --separate-stderr bark
  [ "$output" = "sent -" ]
  [ "$(calls)" -eq 1 ]
}

@test "a missing or non-executable binary is 'refused config' (proven not sent), with a stderr line naming the setting" {
  # never fall back to a real yo-human that may sit on this machine's PATH: name one that is not there
  user_setting "owner_send.yo_human: no-such-yo-human"
  run -0 --separate-stderr bark
  one_line
  [ "$output" = "refused config" ]
  [[ $stderr == *owner_send.yo_human* ]]
  user_setting "owner_send.yo_human: $BATS_TEST_TMPDIR/nowhere/yo-human"
  run -0 --separate-stderr bark
  [ "$output" = "refused config" ]
  [[ $stderr == *owner_send.yo_human* ]]
  user_setting "owner_send.yo_human: $BATS_TEST_TMPDIR/bin"
  run -0 --separate-stderr bark
  [ "$output" = "refused config" ]
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/not-exec"
  user_setting "owner_send.yo_human: $BATS_TEST_TMPDIR/not-exec"
  run -0 --separate-stderr bark
  [ "$output" = "refused config" ]
  [[ $stderr == *owner_send.yo_human* ]]
  [ "$(calls)" -eq 0 ]
}

@test "the dry-run convention does not apply: the tool sends without --yes, and ignores CK_YES" {
  CK_YES=0 run -0 --separate-stderr bark
  [ "$(calls)" -eq 1 ]
}

# jq16: put a jq on PATH that answers like jq 1.6 on empty input (exit 0, no output, even with -e;
# jq 1.7 and later exit 4) and hands everything else to the real jq. Debian 12 and Ubuntu 22.04 ship
# jq 1.6, so the adapter must not depend on that exit code. -n, alone or in a short-flag cluster
# (-nc, as chan uses), reads no stdin and goes straight to the real jq.
jq16() {
  local real
  real=$(type -P jq)
  cat > "$BATS_TEST_TMPDIR/bin/jq" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do case \$a in --null-input) exec "$real" "\$@" ;; --*) ;; -*n*) exec "$real" "\$@" ;; esac; done
in=\$(cat)
if [[ -z \${in//[[:space:]]/} ]]; then exit 0; fi
printf '%s\n' "\$in" | exec "$real" "\$@"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/bin/jq"
}

@test "empty stdout is ambiguous whatever the exit code, with the real jq" {
  local rc want
  for rc in 0 69 78; do
    yh "$rc" ''
    run -0 --separate-stderr bark
    one_line
    want="unknown -"; [ "$rc" -ne 78 ] || want="unknown - config"
    [ "$output" = "$want" ] || { echo "exit $rc gave '$output'"; return 1; }
    [ -n "$stderr" ] || { echo "exit $rc: no diagnostic"; return 1; }
  done
}

@test "empty stdout is ambiguous whatever the exit code, under jq 1.6's empty-input exit 0" {
  local rc want bad=0
  jq16
  for rc in 0 69 78; do
    yh "$rc" ''
    run -0 --separate-stderr bark
    one_line
    want="unknown -"; [ "$rc" -ne 78 ] || want="unknown - config"
    [ "$output" = "$want" ] || { echo "exit $rc gave '$output'"; bad=1; }
    [ -n "$stderr" ] || { echo "exit $rc: no diagnostic"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "the jq 1.6 shim is faithful: empty input exits 0 with no output, other input is the real jq" {
  jq16
  run -0 jq -e . <<< ''
  [ -z "$output" ]
  run jq -e . <<< 'RESULT ok'
  [ "$status" -ne 0 ]
  run -0 jq -c . <<< '{"a":1}'
  [ "$output" = '{"a":1}' ]
}

@test "a valid result followed by junk is ambiguous, not the channel's word" {
  local rc j
  for rc in 0 69; do
    for j in "$(result "$(chan iphone sent)") junk" "$(result "$(chan iphone failed)")"$'\n'"[1,"; do
      yh "$rc" "$j"
      run -0 --separate-stderr bark
      one_line
      [ "$output" = "unknown -" ] || { echo "exit $rc, '$j' gave '$output'"; return 1; }
      [ -n "$stderr" ]
    done
  done
}

@test "two JSON values on stdout are ambiguous, not the first value's word" {
  local rc bad=0
  for rc in 0 69; do
    yh "$rc" "$(result "$(chan iphone sent)")$(result "$(chan iphone failed)")"
    run -0 --separate-stderr bark
    one_line || { echo "exit $rc: ${#lines[@]} lines"; bad=1; }
    [ "$output" = "unknown -" ] || { echo "exit $rc gave '$output'"; bad=1; }
    [ -n "$stderr" ] || { echo "exit $rc: no diagnostic"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "the jq 1.6 shim passes -n through even inside a short-flag cluster" {
  jq16
  run -0 jq -nc '{a:1}' < /dev/null
  [ "$output" = '{"a":1}' ]
  run -0 jq -cn '{a:1}' < /dev/null
  [ "$output" = '{"a":1}' ]
}
