#!/usr/bin/env bats
# crewkit holder run: the registry holder image's entrypoint (libexec/crewkit-holder-run), run
# against stub tailscaled, tailscale and ntfy, a stub crewkit that records its calls, and a real
# git with a local bare repo as the sync remote. No docker, no network, no real secret.
# The image itself is tools/holder-image-test.sh.

bats_require_minimum_version 1.5.0
load helpers
load stub-reaper

# Stub daemons of an earlier run that was killed (so its teardown never ran) are stopped here; see
# tests/stub-reaper.bash. The registry outlives the run, and lives in the user's temp directory.
STUB_REGISTRY="${TMPDIR:-/tmp}/crewkit-bats-stubs.$(id -u)"

setup_file() {
  reap_stale_stubs "$STUB_REGISTRY"
}

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home"
  export PSTUB="$BATS_TEST_TMPDIR/pstub"
  export CK_ROOT="$BATS_TEST_TMPDIR/tree"
  export CK_HOLDER_STATE="$BATS_TEST_TMPDIR/state"
  export CK_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
  export SYNC="$BATS_TEST_TMPDIR/sync.git"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  local v
  while IFS= read -r v; do unset "$v"; done < <(compgen -v | grep '^CREWKIT_' || true)
  mkdir -p "$HOME" "$PSTUB" "$CK_ROOT/bin" "$BATS_TEST_TMPDIR/bin"
  ln -s "$REPO/holder" "$CK_ROOT/holder"
  : > "$PSTUB/crewkit.log" "$PSTUB/tailscaled.log" "$PSTUB/tailscale.log" "$PSTUB/ntfy.log" "$PSTUB/git.log"
  mkdir -p "$CK_SECRETS_DIR/report_keys"
  TS_KEY="tskey-auth-SECRET-0123456789"
  DEPLOY_KEY="deploy-key-SECRET-abcdef"
  NTFY_AUTH="ntfy-auth-SECRET-xyz"
  REPORT_KEY="report-key-SECRET-qrst"
  printf '%s\n' "$TS_KEY" > "$CK_SECRETS_DIR/ts_authkey"
  printf '%s\n' "$DEPLOY_KEY" > "$CK_SECRETS_DIR/deploy_key"
  printf '%s\n' "$NTFY_AUTH" > "$CK_SECRETS_DIR/ntfy_auth"
  printf '%s\n' "$REPORT_KEY" > "$CK_SECRETS_DIR/report_keys/n-abc123"
  printf '%s\n' "$REPORT_KEY" > "$CK_SECRETS_DIR/report_keys/n-def456"
  printf 'homebox n-abc123 agent@homebox\nlab n-def456 lab.example.ts.net\n' > "$CK_SECRETS_DIR/nodes"
  printf 'homebox ssh-ed25519 AAAAfake\n' > "$CK_SECRETS_DIR/nodes_known_hosts"
  chmod 600 "$CK_SECRETS_DIR/nodes" "$CK_SECRETS_DIR/nodes_known_hosts" "$CK_SECRETS_DIR/ts_authkey" "$CK_SECRETS_DIR/deploy_key" "$CK_SECRETS_DIR/ntfy_auth" "$CK_SECRETS_DIR/report_keys/n-abc123" "$CK_SECRETS_DIR/report_keys/n-def456"
  git init -q --bare "$SYNC"
  git clone -q "$SYNC" "$BATS_TEST_TMPDIR/seed" 2>/dev/null
  (cd "$BATS_TEST_TMPDIR/seed" && git checkout -q -b main && echo '{"schema":1,"registry_id":"r-test"}' > registry.json && git add . && git commit -qm seed && git push -q origin main)
  git -C "$SYNC" symbolic-ref HEAD refs/heads/main
  # stubs, first on PATH. Each records argv and the environment, so a secret in either shows up.
  local s
  for s in tailscaled tailscale ntfy; do
    cat > "$BATS_TEST_TMPDIR/bin/$s" <<STUB
#!/usr/bin/env bash
{ printf '%s\n' "\$*"; env; } >> "$PSTUB/$s.log"
case $s in
  tailscale)
    sub=; for a in "\$@"; do case \$a in --*) ;; *) sub=\$a; break ;; esac; done
    [[ \$sub == ip ]] && { echo 100.64.0.7; exit 0; }
    [[ -e "$PSTUB/tailscale_up_fail" && \$sub == up ]] && exit 1
    exit 0 ;;
  ntfy)
    for ((i = 1; i <= \$#; i++)); do
      [[ \${!i} == --config || \${!i} == -c ]] && { j=\$((i + 1)); cp "\${!j}" "$PSTUB/ntfy.conf"; }
    done
    [[ -e "$PSTUB/ntfy_dies" ]] && exit 3
    echo \$\$ >> "$PSTUB/daemon.pids"
    source "$REPO/tests/stub-reaper.bash"; stub_register "$STUB_REGISTRY" "$BATS_ROOT_PID"
    exec sleep 60 ;;
  tailscaled)
    [[ -e "$PSTUB/tailscaled_dies" ]] && exit 3
    echo \$\$ >> "$PSTUB/daemon.pids"
    source "$REPO/tests/stub-reaper.bash"; stub_register "$STUB_REGISTRY" "$BATS_ROOT_PID"
    exec sleep 60 ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/$s"
  done
  # git: log argv and GIT_SSH_COMMAND, then the real git.
  REAL_GIT=$(command -v git)
  cat > "$BATS_TEST_TMPDIR/bin/git" <<STUB
#!/usr/bin/env bash
{ printf 'git %s\n' "\$*"; printf 'GIT_SSH_COMMAND=%s\n' "\${GIT_SSH_COMMAND-}"; } >> "$PSTUB/git.log"
exec "$REAL_GIT" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  # the crewkit stub: records argv and the holder variables the real verbs read.
  cat > "$CK_ROOT/bin/crewkit" <<STUB
#!/usr/bin/env bash
{ printf 'crewkit %s\n' "\$*"; env | grep '^CK_'; } >> "$PSTUB/crewkit.log"
echo "STATUS-TABLE node homebox ready"
STUB
  chmod +x "$CK_ROOT/bin/crewkit"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CK_REGISTRY_REMOTE="$SYNC" CK_REGISTRY_ID=r-test CK_HOLDER_NAME=holder1
  export CK_POLL_SECONDS=600 CK_HOLDER_MAX_ROUNDS=1
  # The holder under test is started through a launcher that registers its own process with the
  # reaper and then becomes the holder, so a holder left behind by a killed run is found too.
  HOLDER_RUN="$BATS_TEST_TMPDIR/holder-run"
  cat > "$HOLDER_RUN" <<LAUNCHER
#!/usr/bin/env bash
source "$REPO/tests/stub-reaper.bash"
stub_exec "$STUB_REGISTRY" "$BATS_ROOT_PID" "$REPO/libexec/crewkit-holder-run" "\$@"
LAUNCHER
  chmod +x "$HOLDER_RUN"
  cd "$BATS_TEST_TMPDIR" || return 1
}

holder() { timeout 20 "$HOLDER_RUN" "$@"; }

# every file the stubs logged, one place to look for a secret.
all_logs() { cat "$PSTUB"/*.log; }

@test "a missing secret is 78, names the file, and prints no value" {
  local f
  for f in ts_authkey deploy_key ntfy_auth nodes nodes_known_hosts report_keys; do
    mv "$CK_SECRETS_DIR/$f" "$CK_SECRETS_DIR/$f.gone"
    run -78 --separate-stderr holder
    [[ $stderr == *"$f"* ]]
    none -q -e "$TS_KEY" -e "$DEPLOY_KEY" -e "$NTFY_AUTH" -e "$REPORT_KEY" <<<"$output$stderr"
    [ ! -s "$PSTUB/tailscaled.log" ]
    mv "$CK_SECRETS_DIR/$f.gone" "$CK_SECRETS_DIR/$f"
  done
}

@test "a secret file that others can read is 78" {
  chmod 644 "$CK_SECRETS_DIR/deploy_key"
  run -78 --separate-stderr holder
  [[ $stderr == *"deploy_key"* ]]
  chmod 640 "$CK_SECRETS_DIR/deploy_key"
  run -78 holder
  chmod 600 "$CK_SECRETS_DIR/deploy_key"
  chmod 666 "$CK_SECRETS_DIR/report_keys/n-abc123"
  run -78 --separate-stderr holder
  [[ $stderr == *"report_keys/n-abc123"* ]]
  [ ! -s "$PSTUB/tailscaled.log" ]
}

@test "a mode 400 secret is accepted" {
  chmod 400 "$CK_SECRETS_DIR/deploy_key" "$CK_SECRETS_DIR/ts_authkey"
  run -0 holder
}

@test "missing settings are 78 and name the variable" {
  local v
  for v in CK_REGISTRY_REMOTE CK_REGISTRY_ID CK_HOLDER_NAME; do
    run -78 --separate-stderr env -u "$v" "$HOLDER_RUN"
    [[ $stderr == *"$v"* ]]
  done
  CK_POLL_SECONDS=soon run -78 holder
  CK_POLL_SECONDS=0 run -78 holder
}

@test "the tailscale auth key reaches tailscale as file:, never in argv or env" {
  run -0 holder
  grep -q -- "up --authkey file:$CK_SECRETS_DIR/ts_authkey" "$PSTUB/tailscale.log"
  grep -q -- "--hostname holder1" "$PSTUB/tailscale.log"
  none -rq -e "$TS_KEY" -e "$DEPLOY_KEY" -e "$NTFY_AUTH" -e "$REPORT_KEY" "$PSTUB"
  none -q -e "$TS_KEY" <<<"$output"
}

# The stub daemons record their pids; none may outlive its test (a TERM-ignoring one would loop forever).
teardown() {
  local pid
  [[ -f $PSTUB/daemon.pids ]] || return 0
  while read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done < "$PSTUB/daemon.pids"
}

@test "ntfy binds loopback only (where userspace tailscale delivers), with deny-all by default" {
  run -0 holder
  grep -q '^listen-http: "127\.0\.0\.1:8080"$' "$PSTUB/ntfy.conf"
  grep -q '^auth-default-access: "deny-all"' "$PSTUB/ntfy.conf"
  none -q -e '0\.0\.0\.0' -e 'listen-http: *":' -e '\[::\]' "$PSTUB/ntfy.conf"
  grep -q '^auth-file: ' "$PSTUB/ntfy.conf"
}

@test "ntfy's auth database is a private copy, not the mounted secret" {
  run -0 holder
  local db; db=$(sed -n 's/^auth-file: *"\(.*\)"$/\1/p' "$PSTUB/ntfy.conf")
  [ -n "$db" ]
  [ "$db" != "$CK_SECRETS_DIR/ntfy_auth" ]
  [ "$db" = "$CK_HOLDER_STATE/ntfy/auth.db" ]
  [ "$(cat "$db")" = "$NTFY_AUTH" ]
  [ "$(stat -c %a "$db" 2>/dev/null || stat -f %Lp "$db")" = 600 ]
}

@test "tailscaled always runs in userspace networking, tun device or not" {
  run -0 holder
  grep -q -- '--tun=userspace-networking' "$PSTUB/tailscaled.log"
}

@test "tailscale up is bounded and leaves DNS alone" {
  run -0 holder
  grep -q -- '--timeout=60s' "$PSTUB/tailscale.log"
  grep -q -- '--accept-dns=false' "$PSTUB/tailscale.log"
}

@test "each node's host gets an ssh block through tailscale nc with a strict key check, and no other host does" {
  run -0 holder
  [ "$(stat -c %a "$HOME/.ssh/config" 2>/dev/null || stat -f %Lp "$HOME/.ssh/config")" = 600 ]
  grep -q '^Host homebox$' "$HOME/.ssh/config"
  grep -q '^Host lab.example.ts.net$' "$HOME/.ssh/config"
  [ "$(grep -c '^Host ' "$HOME/.ssh/config")" = 2 ]
  [ "$(grep -c "ProxyCommand tailscale --socket=$CK_HOLDER_STATE/tailscaled.sock nc %h %p" "$HOME/.ssh/config")" = 2 ]
  [ "$(grep -c "UserKnownHostsFile $CK_SECRETS_DIR/nodes_known_hosts" "$HOME/.ssh/config")" = 2 ]
  [ "$(grep -c 'StrictHostKeyChecking yes' "$HOME/.ssh/config")" = 2 ]
  none -q -e '^Host \*' -e 'github' "$HOME/.ssh/config"
}

@test "ssh resolves the node as typed (user@homebox) to its tailscale block" {
  run -0 holder
  run -0 ssh -G -F "$HOME/.ssh/config" agent@homebox
  grep -q '^proxycommand tailscale ' <<<"$output"
  grep -q '^stricthostkeychecking true' <<<"$output"
}

@test "the nodes become nodes.<name>.host and node_id settings for crewkit" {
  run -0 holder
  grep -q '^nodes.homebox.host: agent@homebox$' "$HOME/.claude/crewkit.md"
  grep -q '^nodes.homebox.node_id: n-abc123$' "$HOME/.claude/crewkit.md"
  grep -q '^nodes.lab.host: lab.example.ts.net$' "$HOME/.claude/crewkit.md"
}

@test "a bad line in the nodes secret is refused (78) and nothing starts" {
  local bad
  for bad in 'x n-1' 'Bad n-1 host' 'a n-1 host extra' 'a n-1 ho st;rm' 'a N_1 host' 'a n-1 -oProxyCommand=x' 'a n-1 u@h@x'; do
    printf '%s\n' "$bad" > "$CK_SECRETS_DIR/nodes"
    run -78 holder
  done
  # Each of these has a report key (n-abc123), so only the line check can refuse it.
  for bad in 'Bad n-abc123 host' 'a n-abc123 ho;st' 'a n-abc123 -oProxyCommand=x' 'a n-abc123 host extra' 'a n-abc123 u@h@x' 'a N-abc123 host' 'a n_abc123 host'; do
    printf '%s\n' "$bad" > "$CK_SECRETS_DIR/nodes"
    run -78 --separate-stderr holder
    [[ $stderr == *"bad line"* ]]
  done
  [ ! -s "$PSTUB/tailscaled.log" ]
}

@test "tailscale up failing stops the holder before ntfy or git run" {
  : > "$PSTUB/tailscale_up_fail"
  run -1 holder
  [ ! -s "$PSTUB/ntfy.log" ]
  [ ! -s "$PSTUB/git.log" ]
}

@test "the sync repo is cloned with the deploy key, and registry settings are written for crewkit" {
  run -0 holder
  [ -f "$CK_HOLDER_STATE/registry/registry.json" ]
  grep -q "GIT_SSH_COMMAND=.*-i $CK_SECRETS_DIR/deploy_key" "$PSTUB/git.log"
  grep -q 'IdentitiesOnly=yes' "$PSTUB/git.log"
  grep -q "^registry.dir: $CK_HOLDER_STATE/registry\$" "$HOME/.claude/crewkit.md"
  grep -q "^registry.remote: $SYNC\$" "$HOME/.claude/crewkit.md"
  none -rq "$DEPLOY_KEY" "$HOME/.claude"
}

@test "an unreachable sync repo stops the holder (non-zero) and says so" {
  CK_REGISTRY_REMOTE="$BATS_TEST_TMPDIR/nope.git" run -1 --separate-stderr holder
  [[ $stderr == *"sync repo"* ]]
}

@test "the first round pulls every node, and the poll pulls everyone again after CK_POLL_SECONDS" {
  CK_POLL_SECONDS=1 CK_HOLDER_MAX_ROUNDS=3 run -0 holder
  [ "$(grep -c '^crewkit status --pull$' "$PSTUB/crewkit.log")" = 3 ]
}

@test "the poll interval is honoured: nothing runs between polls" {
  CK_POLL_SECONDS=600 CK_HOLDER_MAX_ROUNDS=2 run -124 timeout 3 "$HOLDER_RUN"
  [ "$(grep -c '^crewkit status --pull$' "$PSTUB/crewkit.log")" = 1 ]
}

@test "a pointer for homebox pulls homebox only; the poll pulls everyone" {
  export CK_HOLDER_MAX_ROUNDS=2
  ( for _ in $(seq 40); do [ -p "$CK_HOLDER_STATE/pointers" ] && break; sleep 0.1; done
    printf 'homebox\n' > "$CK_HOLDER_STATE/pointers" ) &
  writer=$!
  run -0 holder
  wait "$writer"
  [ "$(sed -n 's/^crewkit status --pull\( .*\)\{0,1\}$/\1/p' "$PSTUB/crewkit.log" | tr '\n' '|')" = "| homebox|" ]
}

@test "a pointer line that is not a node name is dropped and pulls nothing" {
  export CK_HOLDER_MAX_ROUNDS=2 CK_POLL_SECONDS=2
  ( for _ in $(seq 40); do [ -p "$CK_HOLDER_STATE/pointers" ] && break; sleep 0.1; done
    printf '%s\n' 'x; touch '"$BATS_TEST_TMPDIR"'/pwned' '../etc' 'Up' '1abc' 'a..b' 'a_b' '' '-rf' > "$CK_HOLDER_STATE/pointers" ) &
  writer=$!
  run -0 holder
  wait "$writer"
  [ "$(grep -c '^crewkit status --pull$' "$PSTUB/crewkit.log")" = 2 ]
  [ "$(grep -c '^crewkit' "$PSTUB/crewkit.log")" = 2 ]
}

@test "the holder calls crewkit status --pull with the holder variables, and no other verb" {
  run -0 holder
  grep -q "^CK_HOLDER=1$" "$PSTUB/crewkit.log"
  grep -q "^CK_REPORT_KEYS=$CK_SECRETS_DIR/report_keys$" "$PSTUB/crewkit.log"
  none -q -e '^crewkit node ' -e '^crewkit open' -e '^crewkit ask' "$PSTUB/crewkit.log"
  [ "$(grep -c '^crewkit ' "$PSTUB/crewkit.log")" = "$(grep -c '^crewkit status --pull' "$PSTUB/crewkit.log")" ]
  none -rq -e "$TS_KEY" -e "$DEPLOY_KEY" -e "$NTFY_AUTH" -e "$REPORT_KEY" "$PSTUB"
}

@test "ntfy dying stops the holder (non-zero)" {
  : > "$PSTUB/ntfy_dies"
  export CK_POLL_SECONDS=30 CK_HOLDER_MAX_ROUNDS=5
  run -3 holder
}

@test "tailscaled dying stops the holder (non-zero)" {
  : > "$PSTUB/tailscaled_dies"
  export CK_POLL_SECONDS=30 CK_HOLDER_MAX_ROUNDS=5
  run -3 holder
}

@test "the holder's own daemons are stopped when it exits" {
  run -0 holder
  [ "$(wc -l < "$PSTUB/daemon.pids" | tr -d " ")" = 2 ]
  sleep 0.3
  local pid
  while read -r pid; do ! kill -0 "$pid" 2>/dev/null; done < "$PSTUB/daemon.pids"
}

@test "the status table is not echoed to the container log" {
  run -0 holder
  none -q 'STATUS-TABLE' <<<"$output"
}

@test "an unreadable secret says unreadable, not missing" {
  chmod 000 "$CK_SECRETS_DIR/deploy_key"
  run -78 --separate-stderr holder
  chmod 600 "$CK_SECRETS_DIR/deploy_key"
  [[ $stderr == *"deploy_key"*"not readable"* ]]
  none -q 'missing' <<<"$stderr"
}

@test "an ssh remote needs the known_hosts secret and is checked strictly, never on first use" {
  export CK_REGISTRY_REMOTE=ssh://git@127.0.0.1:1/o/r.git
  run -78 --separate-stderr holder
  [[ $stderr == *"known_hosts"* ]]
  printf 'host key\n' > "$CK_SECRETS_DIR/known_hosts"
  chmod 600 "$CK_SECRETS_DIR/known_hosts"
  run -1 holder
  grep -q "UserKnownHostsFile=$CK_SECRETS_DIR/known_hosts" "$PSTUB/git.log"
  grep -q 'StrictHostKeyChecking=yes' "$PSTUB/git.log"
  grep -q 'BatchMode=yes' "$PSTUB/git.log"
  grep -q 'ConnectTimeout=' "$PSTUB/git.log"
  none -q 'accept-new' "$PSTUB/git.log"
}

@test "every ssh remote form needs known_hosts; local, file and https do not" {
  local r
  for r in 'git@example.com:o/r.git' 'example.com:o/r.git' 'git+ssh://git@example.com/o/r.git' 'ssh://git@example.com/o/r.git'; do
    CK_REGISTRY_REMOTE=$r run -78 --separate-stderr holder
    [[ $stderr == *known_hosts* ]]
  done
  for r in "$SYNC" "file://$SYNC"; do
    CK_REGISTRY_REMOTE=$r run -0 holder
  done
  rm -rf "$CK_HOLDER_STATE/registry"
  CK_REGISTRY_REMOTE=https://example.com/o/r.git run -1 holder
  [[ $(cat "$PSTUB/git.log") != *StrictHostKeyChecking* ]]
}

@test "a local remote needs no known_hosts" {
  rm -f "$CK_SECRETS_DIR/known_hosts"
  run -0 holder
}

@test "paths with shell or sed metacharacters are refused" {
  local bad
  for bad in "$BATS_TEST_TMPDIR/a b" "$BATS_TEST_TMPDIR/a;b" "$BATS_TEST_TMPDIR/a|b" "$BATS_TEST_TMPDIR/a\"b" 'relative/dir' "$BATS_TEST_TMPDIR/\$(x)"; do
    CK_HOLDER_STATE=$bad run -78 holder
    CK_SECRETS_DIR=$bad run -78 holder
  done
  [ ! -s "$PSTUB/tailscaled.log" ]
}

@test "a secrets dir with a metacharacter is refused for its path even when the secrets are all there" {
  local bad="$BATS_TEST_TMPDIR/sec ret;x"
  cp -R "$CK_SECRETS_DIR" "$bad"
  CK_SECRETS_DIR=$bad run -78 --separate-stderr holder
  [[ $stderr == *CK_SECRETS_DIR* ]]
  [ ! -s "$PSTUB/tailscaled.log" ]
}

@test "a remote with a newline or a quote is refused, and nothing is written" {
  local bad
  for bad in $'https://x/y\nstate_dir: /etc' "https://x/y'z" 'https://x/y z' 'a;b'; do
    CK_REGISTRY_REMOTE=$bad run -78 holder
  done
  [ ! -e "$HOME/.claude/crewkit.md" ]
}

@test "a sync repo with another registry_id is refused (78)" {
  CK_REGISTRY_ID=r-other run -78 --separate-stderr holder
  [[ $stderr == *registry_id* ]]
}

@test "a second start fetches instead of cloning and picks up new commits" {
  run -0 holder
  (cd "$BATS_TEST_TMPDIR/seed" && echo '{"schema":1,"registry_id":"r-test","n":2}' > registry.json && git commit -qam two && git push -q origin main)
  : > "$PSTUB/git.log"
  run -0 holder
  none -q '^git clone' "$PSTUB/git.log"
  grep -q '"n":2' "$CK_HOLDER_STATE/registry/registry.json"
}

@test "a restart with unpushed local work keeps it on a branch and takes the remote" {
  run -0 holder
  git -C "$CK_HOLDER_STATE/registry" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m local-only
  (cd "$BATS_TEST_TMPDIR/seed" && echo '{"schema":1,"registry_id":"r-test","n":3}' > registry.json && git commit -qam three && git push -q origin main)
  run -0 holder
  grep -q '"n":3' "$CK_HOLDER_STATE/registry/registry.json"
  git -C "$CK_HOLDER_STATE/registry" branch --list 'holder-aside-*' | grep -q holder-aside
  git -C "$CK_HOLDER_STATE/registry" log --all --format=%s | grep -q local-only
}

@test "a half-written clone is replaced, not fatal" {
  mkdir -p "$CK_HOLDER_STATE/registry/.git"
  run -0 holder
  [ -f "$CK_HOLDER_STATE/registry/registry.json" ]
}

@test "a daemon that ignores TERM is killed after a short wait on exit" {
  cat > "$BATS_TEST_TMPDIR/bin/ntfy" <<STUB
#!/usr/bin/env bash
echo \$\$ >> "$PSTUB/daemon.pids"
source "$REPO/tests/stub-reaper.bash"; stub_register "$STUB_REGISTRY" "$BATS_ROOT_PID"
exec >/dev/null 2>&1 </dev/null
trap '' TERM
while :; do sleep 1; done
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ntfy"
  # The daemon holds none of the test's pipes (the exec above), so a shutdown that waits for it
  # forever ends at the holder's 20 s timeout (rc 124) and fails here, not as a hung suite.
  run -0 holder
  sleep 0.3
  local pid
  while read -r pid; do ! kill -0 "$pid" 2>/dev/null; done < "$PSTUB/daemon.pids"
}

@test "a clone with no upstream branch stops with a message, not a bare git error" {
  run -0 holder
  git -C "$CK_HOLDER_STATE/registry" branch --unset-upstream
  run -1 --separate-stderr holder
  [[ $stderr == *"no upstream"* ]]
}

@test "a stale index.lock from a killed commit does not block the restart" {
  run -0 holder
  : > "$CK_HOLDER_STATE/registry/.git/index.lock"
  (cd "$BATS_TEST_TMPDIR/seed" && echo '{"schema":1,"registry_id":"r-test","n":5}' > registry.json && git commit -qam five && git push -q origin main)
  run -0 holder
  grep -q '"n":5' "$CK_HOLDER_STATE/registry/registry.json"
}

@test "a branch deleted upstream is not resurrected from a stale remote ref" {
  run -0 holder
  git -C "$CK_HOLDER_STATE/registry" update-ref refs/remotes/origin/ghost refs/remotes/origin/main
  run -0 holder
  none -q ghost <(git -C "$CK_HOLDER_STATE/registry" branch -r)
}

@test "a restart uses the remote the setting names now, not the one the clone was made from" {
  run -0 holder
  git clone -q --bare "$SYNC" "$BATS_TEST_TMPDIR/moved.git"
  (cd "$BATS_TEST_TMPDIR/seed" && echo '{"schema":1,"registry_id":"r-test","n":9}' > registry.json && git commit -qam nine && git push -q "$BATS_TEST_TMPDIR/moved.git" main)
  CK_REGISTRY_REMOTE="$BATS_TEST_TMPDIR/moved.git" run -0 holder
  grep -q '"n":9' "$CK_HOLDER_STATE/registry/registry.json"
}

@test "the nodes secret: no trailing newline, comments and blank lines are fine" {
  printf '# the nodes\n\n  # indented comment\nhomebox n-abc123 agent@homebox\n\nlab n-def456 lab.example.ts.net' > "$CK_SECRETS_DIR/nodes"
  printf 'k\n' > "$CK_SECRETS_DIR/report_keys/n-def456"
  chmod 600 "$CK_SECRETS_DIR/report_keys/n-def456"
  run -0 holder
  grep -q '^nodes.lab.host: lab.example.ts.net$' "$HOME/.claude/crewkit.md"
  grep -q '^Host lab.example.ts.net$' "$HOME/.ssh/config"
}

@test "a node listed twice is refused (78)" {
  printf 'homebox n-abc123 agent@homebox\nhomebox n-abc123 other@homebox\n' > "$CK_SECRETS_DIR/nodes"
  run -78 --separate-stderr holder
  [[ $stderr == *"twice"* ]]
}

@test "a node with no report key is refused (78), naming the file" {
  printf 'homebox n-abc123 agent@homebox\nlab n-nokey1 lab.example.ts.net\n' > "$CK_SECRETS_DIR/nodes"
  run -78 --separate-stderr holder
  [[ $stderr == *"report_keys/n-nokey1"* ]]
}
