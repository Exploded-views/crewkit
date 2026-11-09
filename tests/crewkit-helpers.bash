# Shared setup for the crewkit CLI suites (tests/crewkit*.bats). Load it after `load helpers`.
#
# ck_setup builds a private tree the way a checkout looks to bin/crewkit: symlinks to the real
# bin, libexec, lib, plugins, templates, install.sh and .claude-plugin (so coverage and the
# mutation runs see the real files), a real copy of pins/, and the push-gate fixture. $HOME is
# an empty hub home. ssh and herdr are stubs first on PATH, $PSTUB holds their state, and the
# sync "remote" is a local bare repo. Nothing here touches a real host.

ck_setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  TREE="$BATS_TEST_TMPDIR/tree"
  export HOME="$BATS_TEST_TMPDIR/hub"
  export PSTUB="$BATS_TEST_TMPDIR/pstub"
  export SYNC="$BATS_TEST_TMPDIR/sync.git"
  export CK_NOW=1793000000
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  local v
  while IFS= read -r v; do unset "$v"; done < <(compgen -v | grep '^CREWKIT_' || true)
  unset CK_YES CK_BASH_VERSION
  mkdir -p "$TREE/push-gate" "$HOME/.claude" "$PSTUB/remote/.local/bin" "$BATS_TEST_TMPDIR/bin"
  for v in bin libexec lib plugins templates install.sh .claude-plugin; do
    ln -s "$REPO/$v" "$TREE/$v"
  done
  cp -R "$REPO/pins" "$TREE/pins"
  cp "$REPO/tests/fixtures/push-gate/push-gate.sh" "$TREE/push-gate/push-gate.sh"
  ln -s "$REPO/tests/stubs/ssh" "$BATS_TEST_TMPDIR/bin/ssh"
  ln -s "$REPO/tests/stubs/herdr" "$PSTUB/remote/.local/bin/herdr"
  : > "$PSTUB/ssh.log"
  : > "$PSTUB/herdr.log"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  git init -q --bare "$SYNC"
  cd "$HOME" || return 1
}

# ck ARGS...: the crewkit command of the test tree.
ck() { "$TREE/bin/crewkit" "$@"; }

# ck_lib: source the libraries the way a verb does (settings first, then common.sh).
ck_lib() {
  # shellcheck source=/dev/null
  source "$TREE/lib/settings.sh"
  # shellcheck source=/dev/null
  source "$TREE/libexec/ck/common.sh"
}

# ck_own_libexec: replace the libexec symlink with a real directory holding VERSION and common.sh
# only, so a test can write stub verb scripts without touching the repository.
ck_own_libexec() {
  rm "$TREE/libexec"
  mkdir -p "$TREE/libexec/ck"
  cp "$REPO/libexec/VERSION" "$TREE/libexec/VERSION"
  cp "$REPO/libexec/ck/common.sh" "$TREE/libexec/ck/common.sh"
}

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
  # lib/settings.sh caches the file list per directory when it is sourced: forget it, so a
  # setting written after ck_lib is seen.
  _CREW_FILES_FOR=''
}

# fake_host NAME OS ARCH [MEM_MB]: a fake remote host for tests/stubs/ssh: a home in
# $PSTUB/hosts/NAME with bin/ (a uname for that OS and architecture, jq, and stubs of curl, claude,
# systemctl, loginctl, launchctl and tailscale that log their argv to <home>/calls.log and succeed),
# .local/bin/herdr (the stub herdr, as CK_HOST=NAME), and a .stubenv with CK_PROC_MEMINFO set to a
# meminfo file of MEM_MB (default 8192) megabytes.
fake_host() {
  local name=$1 os=$2 arch=$3 mem=${4:-8192} home t
  home=$PSTUB/hosts/$name
  mkdir -p "$home/bin" "$home/.local/bin" "$home/.ssh"
  ln -sf "$REPO/tests/stubs/herdr" "$home/.local/bin/herdr"
  ln -sf "$(command -v jq)" "$home/bin/jq"
  cat > "$home/bin/uname" <<UNAME
#!/bin/sh
case "\${1:-}" in
  -s) echo $os ;;
  -m) echo $arch ;;
  -n) echo $name ;;
  *) echo "$os $name 1.0 stub $arch" ;;
esac
UNAME
  chmod +x "$home/bin/uname"
  for t in curl claude systemctl loginctl launchctl tailscale; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$t" "$home" > "$home/bin/$t"
    chmod +x "$home/bin/$t"
  done
  printf 'MemTotal:       %d kB\n' "$((mem * 1024))" > "$home/meminfo"
  printf 'CK_PROC_MEMINFO=%s\n' "$home/meminfo" > "$home/.stubenv"
}

# herdr_session HOST NAME DEFAULT RUNNING: a herdr session on a host for tests/stubs/herdr. HOST is
# "local" or a fake_host name; DEFAULT and RUNNING are 1 or 0.
herdr_session() {
  local d=$PSTUB/herdr/$1/$2
  mkdir -p "$d"
  rm -f "$d/default" "$d/stopped"
  [[ $3 == 1 ]] && : > "$d/default"
  [[ $4 == 1 ]] || : > "$d/stopped"
  [[ -f $d/panes.json ]] || echo '[]' > "$d/panes.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  [[ -e $BATS_TEST_TMPDIR/bin/herdr ]] || ln -s "$REPO/tests/stubs/herdr" "$BATS_TEST_TMPDIR/bin/herdr"
  return 0
}

# herdr_agent HOST SESSION PANE NAME STATUS [KEY=VALUE...]: a pane running an agent (claude), named
# NAME (- for none), with those tokens. The workspace is the pane's, "w1" of w1:p1.
herdr_agent() {
  local f=$PSTUB/herdr/$1/$2/panes.json p=$3 n=$4 st=$5 kv toks='{}'
  shift 5
  for kv in "$@"; do toks=$(jq -cn --argjson t "$toks" --arg k "${kv%%=*}" --arg v "${kv#*=}" '$t + {($k): $v}'); done
  [[ $n == - ]] && n=''
  jq -c --arg p "$p" --arg n "$n" --arg st "$st" --argjson t "$toks" \
    '. + [{pane_id: $p, workspace_id: ($p | split(":")[0]), tab_id: (($p | split(":")[0]) + ":t1"), agent: "claude", name: (if $n == "" then null else $n end), agent_status: $st, tokens: $t, cwd: "/work/project"}]' "$f" > "$f.new"
  mv "$f.new" "$f"
}
