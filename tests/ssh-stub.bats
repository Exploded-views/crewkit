#!/usr/bin/env bats
# The stub ssh (tests/stubs/ssh) with fake hosts (fake_host in tests/crewkit-helpers.bash): per-host
# homes, a forced command per authorized key, and a remote environment that is only what the host's
# home gives it. The hosts-less behaviour is pane-ask.bats's.

bats_require_minimum_version 1.5.0
load crewkit-helpers

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export PSTUB="$BATS_TEST_TMPDIR/pstub"
  mkdir -p "$PSTUB/remote"
  : > "$PSTUB/ssh.log"
  SSH="$REPO/tests/stubs/ssh"
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/key" -C test
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/other" -C other
  fake_host homebox Linux x86_64 4096
  fake_host nodeb Darwin arm64
}

@test "each host has its own home, uname and meminfo" {
  run "$SSH" homebox 'echo $HOME; uname -s; uname -m; cat "$CK_PROC_MEMINFO"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$PSTUB/hosts/homebox" ]
  [ "${lines[1]}" = Linux ]
  [ "${lines[2]}" = x86_64 ]
  [ "${lines[3]}" = "MemTotal:       4194304 kB" ]
  run "$SSH" nodeb uname -m
  [ "$output" = arm64 ]
}

@test "the remote environment is only HOME, PATH and the host's stubenv" {
  export CK_NOW=1 HERDR_SOCKET_PATH=/x SECRET_THING=hunter2
  run "$SSH" homebox 'echo ${CK_NOW:-unset}; echo ${HERDR_SOCKET_PATH:-unset}; echo ${SECRET_THING:-unset}; echo $CK_HOST'
  [ "${lines[0]}" = unset ]
  [ "${lines[1]}" = unset ]
  [ "${lines[2]}" = unset ]
  [ "${lines[3]}" = homebox ]
  run "$SSH" homebox 'env | sed "s/=.*//" | sort | tr "\n" " "'
  # what sh itself adds (PWD, SHLVL, _) is not the stub's
  [ "$(printf '%s' "$output" | tr ' ' '\n' | grep -v '^\(PWD\|SHLVL\|_\)$' | tr '\n' ' ')" = "CK_HOST CK_PROC_MEMINFO HOME PATH PSTUB " ]
}

@test "ssh takes -i, -o, -t, -T, -n and -- ; the call is logged" {
  run "$SSH" -o BatchMode=yes -T -n -- homebox echo hi
  [ "$output" = hi ]
  run "$SSH" -t homebox echo hi
  [ "$output" = hi ]
  [ "$(wc -l < "$PSTUB/ssh.log")" -eq 2 ]
}

@test "ssh -i runs the forced command with SSH_ORIGINAL_COMMAND, whatever was asked" {
  printf 'command="echo forced; echo $SSH_ORIGINAL_COMMAND",no-pty %s\n' "$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/key.pub")" > "$PSTUB/hosts/homebox/.ssh/authorized_keys"
  run "$SSH" -i "$BATS_TEST_TMPDIR/key" homebox 'rm -rf /; echo asked'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = forced ]
  [ "${lines[1]}" = 'rm -rf /; echo asked' ]
}

@test "ssh -i with an unauthorized key is refused (255)" {
  printf 'command="echo forced" %s\n' "$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/key.pub")" > "$PSTUB/hosts/homebox/.ssh/authorized_keys"
  run -255 "$SSH" -i "$BATS_TEST_TMPDIR/other" homebox echo asked
  [[ $output == *"Permission denied (publickey)"* ]]
  [[ $output != *asked* ]]
  run -255 "$SSH" -i "$BATS_TEST_TMPDIR/key" nodeb echo asked
}

@test "a key line without a forced command runs the requested command" {
  cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/key.pub" > "$PSTUB/hosts/homebox/.ssh/authorized_keys"
  run "$SSH" -i "$BATS_TEST_TMPDIR/key" homebox echo asked
  [ "$output" = asked ]
}

@test "a host that is down is 255; corrupt_stdin flips one byte of stdin" {
  touch "$PSTUB/hosts/homebox/down"
  run -255 "$SSH" homebox true
  rm "$PSTUB/hosts/homebox/down"
  printf 'abcdefgh' | "$SSH" homebox cat > "$BATS_TEST_TMPDIR/same"
  [ "$(cat "$BATS_TEST_TMPDIR/same")" = abcdefgh ]
  touch "$PSTUB/hosts/homebox/corrupt_stdin"
  printf 'abcdefgh' | "$SSH" homebox cat > "$BATS_TEST_TMPDIR/diff"
  [ "$(wc -c < "$BATS_TEST_TMPDIR/diff")" -eq 8 ]
  [ "$(cmp -l "$BATS_TEST_TMPDIR/diff" - <<<'abcdefgh' | wc -l)" -ge 1 ]
  [ "$(cmp -l <(printf abcdefgh) "$BATS_TEST_TMPDIR/diff" | wc -l)" -eq 1 ]
}

@test "the host's herdr is the stub, as that host" {
  herdr_session nodeb default 1 1
  run "$SSH" nodeb '"$HOME/.local/bin/herdr" session list --json'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.sessions[0].name' <<<"$output")" = default ]
  grep -q '^\[nodeb/default\]' "$PSTUB/herdr.log"
  run "$SSH" homebox '"$HOME/.local/bin/herdr" session list --json'
  [ "$output" = '{"sessions":[]}' ]
}

@test "without a host home the stub is pane-ask's: -t, -T and -i are exit 98" {
  rm -rf "$PSTUB/hosts"
  run -98 "$SSH" -t somehost true
  run -98 "$SSH" -T somehost true
  run -98 "$SSH" -i k somehost true
}

@test "authorized_keys: a key named in an option or comment is not the key; only the key field counts" {
  local blob other
  blob=$(cut -d' ' -f2 "$BATS_TEST_TMPDIR/key.pub")
  other=$(cut -d' ' -f2 "$BATS_TEST_TMPDIR/other.pub")
  # the command option mentions the other key's blob; the real key field is key's
  printf 'command="echo A ssh-ed25519 %s",no-pty ssh-ed25519 %s comment command="nope"\n' "$other" "$blob" > "$PSTUB/hosts/homebox/.ssh/authorized_keys"
  run "$SSH" -i "$BATS_TEST_TMPDIR/key" homebox echo asked
  [ "$status" -eq 0 ]
  [[ $output == "A ssh-ed25519 $other" ]]
  run -255 "$SSH" -i "$BATS_TEST_TMPDIR/other" homebox echo asked
}
