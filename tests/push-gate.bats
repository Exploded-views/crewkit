#!/usr/bin/env bats
# push-gate/push-gate.sh and its dispatcher, in sandbox repositories pushing to a local bare
# remote, with a private HOME. No network. gitleaks is a stub that flags a GitHub token shape
# and is recorded as the verified install; a fault stub fails one git subcommand or grep count
# on demand ($PG_FAULT), to prove that an error never reads as "nothing found".

TERM_FAKE=zorblaxcorp   # stands in for a private denylist term
Z=$(printf '0%.0s' {1..40})   # git's all-zero sha, built here: no long hex in the file

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# none GREP-ARGS...: fail if grep matches (bats ignores a negated command mid-test).
none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}

# user_setting KEY: VALUE...: set keys in ~/.claude/crewkit.md, keeping the others.
user_setting() {
  local f="$HOME/.claude/crewkit.md" kv keys=()
  for kv in "$@"; do keys+=("${kv%%:*}"); done
  {
    echo ---
    [[ -f $f ]] && awk -v drop=" ${keys[*]} " 'NR > 1 && $0 != "---" { k = $0; sub(/:.*/, "", k); if (index(drop, " " k " ") == 0) print }' "$f"
    printf '%s\n' "$@"
    echo ---
  } > "$f.new" && mv "$f.new" "$f"
}

load memory-notices-helpers   # the time scale (ms_bound, TS); a slow lane widens the dispatch bound

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  export GIT_ALLOW_PROTOCOL=file   # no network: the gate's git ls-remote of an https URL fails at once
  unset PUSH_GATE_LOCAL PG_FAULT
  TS=$(scale_of "${CREWKIT_TEST_TIME_SCALE:-}")
  mkdir -p "$HOME/.claude" "$HOME/.config/crewkit" "$HOME/code"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
  ln -s "$REPO/push-gate" "$TREE/push-gate"
  ln -s "$REPO/lib" "$TREE/lib"
  GATE="$TREE/push-gate/push-gate.sh"
  GD="$HOME/.local/share/crewkit/gate"

  # gitleaks stub: flags a ghp_ token on stdin (gitleaks stdin; any other command is an error);
  # GL_FAIL=1 makes it error out. It does what the real one lets a repository do, so the tests
  # prove the gate stops it: with no --config it loads $GITLEAKS_CONFIG, then
  # $GITLEAKS_CONFIG_TOML, then ./.gitleaks.toml, and a config with an [allowlist] passes
  # everything; a non-empty .gitleaksignore in the ignore path or the working directory passes
  # everything; a gitleaks:allow line is skipped unless --ignore-gitleaks-allow. Each call
  # appends its arguments, working directory and GITLEAKS_* variables to $GL_CALLS.
  GL="$BATS_TEST_TMPDIR/gl/gitleaks"
  mkdir -p "${GL%/*}"
  cat > "$GL" <<'EOF'
#!/usr/bin/env bash
{ printf 'args:'; printf ' %s' "$@"; printf '\ncwd: %s\n' "$PWD"; env | "$REAL_GREP" '^GITLEAKS'; } >> "${GL_CALLS:-/dev/null}"
[[ -n ${GL_FAIL:-} ]] && { echo "gitleaks: broken" >&2; exit 2; }
mode=${1:-}; shift
config='' ignore=. allow=1
while (($#)); do
  case $1 in
    -c|--config) config=$2; shift ;;
    -i|--gitleaks-ignore-path) ignore=$2; shift ;;
    --ignore-gitleaks-allow) allow=0 ;;
  esac
  shift
done
if [[ -z $config ]]; then
  if [[ -n ${GITLEAKS_CONFIG:-} ]]; then config=$GITLEAKS_CONFIG
  elif [[ -n ${GITLEAKS_CONFIG_TOML:-} ]]; then [[ $GITLEAKS_CONFIG_TOML == *'[allowlist]'* ]] && exit 0
  elif [[ -f .gitleaks.toml ]]; then config=.gitleaks.toml
  fi
fi
[[ -n $config ]] && "$REAL_GREP" -q '^\[allowlist\]' "$config" && exit 0
for f in "$ignore" "$ignore/.gitleaksignore" .gitleaksignore; do [[ -f $f && -s $f ]] && exit 0; done
[[ $mode == stdin ]] || { echo "gitleaks stub: no such command: $mode" >&2; exit 2; }
in=$(cat)
((allow)) && in=$("$REAL_GREP" -v 'gitleaks:allow' <<<"$in")
"$REAL_GREP" -Eq 'ghp_[A-Za-z0-9]{36}' <<<"$in" && exit 1
exit 0
EOF
  chmod +x "$GL"
  sha "$GL" > "$GL.sha256"
  sha "$GL" > "$TREE/gitleaks.sha256"   # the running gate's own record, as install writes it

  # fault stubs: PG_FAULT=git-<subcommand> fails that git subcommand; PG_FAULT=mv-new fails
  # the mv of a *.new.* directory (install's switch to the new copy); PG_FAULT=grep-count
  # makes every counting grep (-c) exit 2, as grep does on an error; PG_FAULT=grep-iq the
  # same for the case-insensitive yes/no checks (-Eiq).
  local fb="$BATS_TEST_TMPDIR/fault"
  mkdir -p "$fb"
  REAL_GIT=$(command -v git) REAL_GREP=$(command -v grep) REAL_MV=$(command -v mv)
  export REAL_GIT REAL_GREP REAL_MV
  cat > "$fb/mv" <<'EOF'
#!/usr/bin/env bash
[[ ${PG_FAULT:-} == mv-new && ${1:-} == *.new.* ]] && { echo "mv: injected fault" >&2; exit 1; }
exec "$REAL_MV" "$@"
EOF
  cat > "$fb/git" <<'EOF'
#!/usr/bin/env bash
skip=0   # the subcommand: the first word that isn't an option, or the value of -c or -C
for a; do if ((skip)); then skip=0; continue; fi; case $a in -c|-C) skip=1 ;; -*) ;; *) sub=$a; break ;; esac; done
[[ ${PG_FAULT:-} == "git-${sub:-}" ]] && { echo "fatal: injected fault" >&2; exit 128; }
exec "$REAL_GIT" "$@"
EOF
  cat > "$fb/grep" <<'EOF'
#!/usr/bin/env bash
case ${PG_FAULT:-} in
  grep-count) for a; do [[ $a == -[A-Za-z]*c* ]] && exit 2; done ;;
  grep-count-body)   # only a count over a commit (its text holds the author's email)
    for a; do if [[ $a == -[A-Za-z]*c* ]]; then in=$(cat); [[ $in == *"@example.com>"* ]] && exit 2; exec "$REAL_GREP" "$@" <<<"$in"; fi; done ;;
  grep-iq) for a; do [[ $a == -[A-Za-z]*i*q* ]] && exit 2; done ;;   # the -Eiq checks: branch name, a hit's path
  grep-iq-path)   # only the -Eiq check of a path git grep reported (its stdin has no "refs/")
    for a; do if [[ $a == -[A-Za-z]*i*q* ]]; then in=$(cat); [[ $in == refs/* ]] || exit 2; exec "$REAL_GREP" "$@" <<<"$in"; fi; done ;;
esac
exec "$REAL_GREP" "$@"
EOF
  chmod +x "$fb"/*
  export PATH="$fb:$PATH"

  printf '# comment\n\n%s\n' "$TERM_FAKE" > "$HOME/.config/crewkit/denylist.txt"
  printf '%s\n' '[:/]client-org/' 'skip-all [:/]example-org/priv-' 'gate-exempt [:/]other/' > "$HOME/.config/crewkit/push-gate-exempt"
  LOG="$HOME/.local/state/crewkit/push-gate.log"
  user_setting "push_gate.gitleaks: $GL" "push_gate.root: ~/code"
  TOKEN_FAKE="ghp_$(printf 'q7Rk2Lm9Xw4Tz8Bn3Vc6Hj1Pd5Fs0Ga7Ye2U')"   # built at runtime: no token in the file
}

# sandbox [URL]: a fresh repo W cloned from bare R, with one commit; pushes go to R.
sandbox() {
  SB="$BATS_TEST_TMPDIR/sb$RANDOM"
  R="$SB/origin.git" W="$SB/work"
  git init -q --bare -b main "$R"
  git clone -q "$R" "$W" 2>/dev/null
  cd "$W"
  URL=${1:-https://github.com/owner/repo.git}
  echo base > a.txt
  git add . && git commit -qm init
}
commit() { # commit FILE CONTENT [MESSAGE] [AUTHOR]
  printf '%s\n' "$2" > "$1"
  git add "$1"
  if [[ -n ${4:-} ]]; then GIT_AUTHOR_NAME=$4 git commit -qm "${3:-change}"; else git commit -qm "${3:-change}"; fi
}
gate() { run bash -c 'printf "%s\n" "$1" | "$2" hook origin "$3"' _ "$1" "$GATE" "$URL"; }
line_new() { echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main $Z"; }
line_upd() { echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main $1"; }
installed() { run "$GATE" install --yes; [ "$status" -eq 0 ]; }

# --- the hook: scope ---------------------------------------------------------------------------

@test "a clean first push to a gated remote passes" {
  sandbox; gate "$(line_new)"
  [ "$status" -eq 0 ]
}

@test "a denylist term in a new file blocks, names the file, never prints the term" {
  sandbox; commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  [[ $output == *b.txt* ]]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "an exempt remote passes with a term, needs no denylist, and still blocks a secret" {
  sandbox https://git.example.test/client-org/client-project.git; commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 0 ]
  rm "$HOME/.config/crewkit/denylist.txt"; gate "$(line_new)"
  [ "$status" -eq 0 ]
  commit c.txt "token=$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -q "$TOKEN_FAKE" <<<"$output"
}

@test "a skip-all remote (ssh alias form) skips every check, gitleaks included, and logs SKIP" {
  sandbox git@gh-example-a:example-org/priv-example.git; commit b.txt "token=$TOKEN_FAKE"
  user_setting "push_gate.gitleaks: $BATS_TEST_TMPDIR/nope"
  gate "$(line_new)"
  [ "$status" -eq 0 ]
  grep -q " SKIP " "$LOG"
}

@test "skip-all doesn't leak to similar names; an ssh alias of a gated remote still blocks" {
  sandbox https://git.example.test/example-org/privtool.git; commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  URL=git@gh-example-b:example-org/example-repo.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a gate-exempt line (another tool's) is not a denylist exemption" {
  sandbox https://git.example.test/other/thing.git; commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a push to a local path or file:// isn't gated; PUSH_GATE_LOCAL=1 gates it" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"
  URL=$R; gate "$(line_new)"
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
  URL=file://$R; gate "$(line_new)"
  [ "$status" -eq 0 ]
  URL=$R PUSH_GATE_LOCAL=1 gate "$(line_new)"
  [ "$status" -eq 1 ]
}

# --- the hook: what is scanned -----------------------------------------------------------------

@test "a term in a commit message blocks, naming the commit and not the text" {
  sandbox; commit b.txt ok "mention $TERM_FAKE in message"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  [[ $output == *"$(git rev-parse --short HEAD)"* ]]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "a term in an author name blocks" {
  sandbox; commit b.txt ok change "Pat $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a term in a file path blocks, without printing the path" {
  sandbox; commit "notes-$TERM_FAKE.md" ok; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
  commit "notes-$TERM_FAKE.md" "body $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "a term only in history (removed from the tree) still blocks" {
  sandbox; commit b.txt "hello $TERM_FAKE"; git rm -q b.txt; git commit -qm "remove it"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "an update push scans only the new range" {
  sandbox; git push -q origin main; old=$(git rev-parse HEAD); commit c.txt fine; gate "$(line_upd "$old")"
  [ "$status" -eq 0 ]
  commit d.txt "x $TERM_FAKE"; gate "$(line_upd "$old")"
  [ "$status" -eq 1 ]
}

@test "a term already on the remote, in a file of the pushed tree, still blocks a clean push on top" {
  sandbox; commit b.txt "hello $TERM_FAKE"; git push -q origin main; old=$(git rev-parse HEAD)
  commit c.txt fine; gate "$(line_upd "$old")"
  [ "$status" -eq 1 ]
  [[ $output == *"denylist: file b.txt in refs/heads/main: 1 line(s)"* ]]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "a secret blocks, and the secret is never printed" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -q "$TOKEN_FAKE" <<<"$output"
}

@test "a branch delete, empty input and an unknown remote sha pass" {
  sandbox; git push -q origin main
  gate "refs/heads/old $Z refs/heads/old $(git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  gate ""
  [ "$status" -eq 0 ]
  commit c.txt fine; gate "$(line_upd $(printf '1%.0s' {1..40}))"
  [ "$status" -eq 0 ]
}

@test "a term in a binary file blocks" {
  sandbox; printf 'x\0y %s z\n' "$TERM_FAKE" > bin.dat; git add bin.dat; git commit -qm bin; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "a term in the pushed branch name blocks, and no message prints the name" {
  sandbox; commit b.txt "hello $TERM_FAKE"
  gate "refs/heads/fix-$TERM_FAKE $(git rev-parse HEAD) refs/heads/fix-$TERM_FAKE $Z"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
}

# --- the hook: what a repository can't switch off ---------------------------------------------

@test "a repo's own .gitleaks.toml, .gitleaksignore or gitleaks:allow, or GITLEAKS_CONFIG*, can't switch gitleaks off" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"
  printf '[allowlist]\npaths = [".*"]\n' > .gitleaks.toml   # untracked works on gitleaks git
  gate "$(line_new)"
  [ "$status" -eq 1 ]
  rm .gitleaks.toml; echo ':github-pat:1' > .gitleaksignore; gate "$(line_new)"
  [ "$status" -eq 1 ]
  rm .gitleaksignore; printf '[allowlist]\npaths = [".*"]\n' > "$BATS_TEST_TMPDIR/allow.toml"
  GITLEAKS_CONFIG=$BATS_TEST_TMPDIR/allow.toml gate "$(line_new)"
  [ "$status" -eq 1 ]
  GITLEAKS_CONFIG_TOML=$'[allowlist]\npaths = [".*"]' gate "$(line_new)"
  [ "$status" -eq 1 ]
  sandbox; commit b.txt "token=$TOKEN_FAKE # gitleaks:allow"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "gitleaks runs on the gate's own config ([extend] useDefault), outside the repository, with no GITLEAKS_* variables" {
  sandbox; export GL_CALLS="$BATS_TEST_TMPDIR/gl-calls"
  GITLEAKS_CONFIG=/nonexistent GITLEAKS_CONFIG_TOML=x gate "$(line_new)"
  [ "$status" -eq 0 ]
  grep -q "^args: stdin .*--config $TREE/push-gate/gitleaks-rules.toml" "$GL_CALLS"
  grep -q -- "--ignore-gitleaks-allow" "$GL_CALLS"
  none -q '^GITLEAKS' "$GL_CALLS"
  none -qx "cwd: $W" "$GL_CALLS"
  grep -qx '\[extend\]' "$REPO/push-gate/gitleaks-rules.toml"
  grep -qx 'useDefault = true' "$REPO/push-gate/gitleaks-rules.toml"
}

@test "a -diff attribute can't hide a secret from gitleaks (.git/info/attributes, nothing pushed)" {
  sandbox; echo '* -diff' > .git/info/attributes
  commit b.txt "token=$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a textconv driver can't hide a secret from gitleaks" {
  sandbox; echo '*.txt diff=hide' > .git/info/attributes; git config diff.hide.textconv true
  commit b.txt "token=$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a -diff attribute or a textconv driver can't hide a term that is only in history" {
  sandbox; printf '* -diff\n' > .gitattributes; git add .gitattributes; git commit -qm attrs
  commit b.txt "hello $TERM_FAKE"; git rm -q b.txt; git commit -qm "remove it"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
  sandbox; echo '*.txt diff=hide' > .git/info/attributes; git config diff.hide.textconv true
  commit b.txt "hello $TERM_FAKE"; git rm -q b.txt; git commit -qm "remove it"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "log.showRoot=false can't hide a root commit's secret from gitleaks" {
  sandbox; git config log.showRoot false; git checkout -q --orphan o; git rm -q -rf .
  commit b.txt "token=$TOKEN_FAKE"; git rm -q b.txt; git commit -qm "remove it"
  gate "refs/heads/o $(git rev-parse HEAD) refs/heads/o $Z"
  [ "$status" -eq 1 ]
}

@test "a secret added in a merge commit (not in either parent) blocks" {
  sandbox; git checkout -q -b side; commit s.txt side; git checkout -q main; commit m.txt main
  git merge -q --no-commit side >/dev/null; printf 'token=%s\n' "$TOKEN_FAKE" > z.txt; git add z.txt; git commit -qm merge
  git rm -q z.txt; git commit -qm "remove it"
  gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a commit that takes out an already-pushed secret passes (removed lines aren't a new leak)" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"; git push -q origin main; old=$(git rev-parse HEAD)
  git rm -q b.txt; git commit -qm "remove it"; gate "$(line_upd "$old")"
  [ "$status" -eq 0 ]
}

@test "a term in a binary file added, then deleted, still blocks" {
  sandbox; printf 'x\0y %s z\n' "$TERM_FAKE" > bin.dat; git add bin.dat; git commit -qm bin
  git rm -q bin.dat; git commit -qm "remove it"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
}

# e2e_gitleaks: the real gitleaks at $CREWKIT_E2E_GITLEAKS (the pinned release, pins/gitleaks.env),
# copied in as the verified install; the test is skipped without it. Nothing is downloaded.
e2e_gitleaks() {
  [[ -n ${CREWKIT_E2E_GITLEAKS:-} ]] || skip "opt-in: CREWKIT_E2E_GITLEAKS=/path/to/the pinned gitleaks"
  local g="$BATS_TEST_TMPDIR/e2e/gitleaks"
  mkdir -p "${g%/*}"; cp "$CREWKIT_E2E_GITLEAKS" "$g"; sha "$g" > "$g.sha256"; sha "$g" > "$TREE/gitleaks.sha256"
  user_setting "push_gate.gitleaks: $g"
  echo "# $("$g" version 2>&1)" >&3
}

@test "end to end, the real gitleaks: a clean push passes; a secret blocks, whatever the repository says" {
  e2e_gitleaks
  sandbox; commit b.txt clean; gate "$(line_new)"
  [ "$status" -eq 0 ]
  git push -q origin main; old=$(git rev-parse HEAD)
  commit c.txt "token=$TOKEN_FAKE # gitleaks:allow"; commit d.txt fine
  printf '[allowlist]\npaths = [".*"]\nregexes = [".*"]\n' > .gitleaks.toml
  cp .gitleaks.toml "$BATS_TEST_TMPDIR/allow.toml"
  printf ':github-pat:1\n:github-pat:2\n:github-pat:3\n' > .gitleaksignore
  echo '* -diff' > .git/info/attributes
  GITLEAKS_CONFIG=$BATS_TEST_TMPDIR/allow.toml gate "$(line_upd "$old")"
  [ "$status" -eq 1 ]
  [[ $output == *"gitleaks: a secret"* ]]
  none -q "$TOKEN_FAKE" <<<"$output"
  gate "refs/heads/topic $(git rev-parse HEAD) refs/heads/topic $Z"
  [ "$status" -eq 1 ]
}

@test "an author name that starts with '-' still reaches gitleaks (only a hunk's removed lines are dropped)" {
  sandbox; commit b.txt fine change "-$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -q "$TOKEN_FAKE" <<<"$output"
}

@test "a replace ref can't swap a pushed commit for a clean one in either scan" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"; bad=$(git rev-parse HEAD)
  git checkout -q -b clean HEAD~1; commit b.txt fine; git checkout -q main; git replace "$bad" clean
  gate "$(line_new)"
  [ "$status" -eq 1 ]
  sandbox; commit b.txt "hello $TERM_FAKE"; bad=$(git rev-parse HEAD)
  git checkout -q -b clean HEAD~1; commit b.txt fine; git checkout -q main; git replace "$bad" clean
  gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "the repository's log output encoding (EBCDIC) can't garble what either scan reads" {
  export LC_ALL=C   # byte-wise tools: an error on the garbled bytes mustn't be what blocks
  sandbox; git config i18n.logOutputEncoding CP037; commit b.txt fine "token=$TOKEN_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  sandbox; git config i18n.logOutputEncoding CP037; commit b.txt fine "mention $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "a non-ASCII term in a path blocks (core.quotePath can't escape it)" {
  sandbox; printf '%s\n' "$TERM_FAKE" 'kundé' > "$HOME/.config/crewkit/denylist.txt"
  commit "notes-kundé.md" ok; gate "$(line_new)"
  [ "$status" -eq 1 ]
  none -q 'kund' <<<"$output"
}

@test "a push to a local path on a mount or a synced folder is gated; an unresolvable one too" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"
  URL=/Volumes/crewkit-test-nas-$$/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  URL=//server/share/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  mkdir -p "$HOME/Dropbox"; git init -q --bare "$HOME/Dropbox/r.git"
  URL=$HOME/Dropbox/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  URL=file://$HOME/Dropbox/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  ln -s "$HOME/Dropbox" "$SB/link"; URL=$SB/link/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  URL=$R; gate "$(line_new)"   # a plain local path still isn't
  [ "$status" -eq 0 ]
}

@test "a synced folder in any letter case (dropbox, onedrive) is gated" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"
  for d in dropbox "onedrive - acme" "mobile documents"; do
    mkdir -p "$HOME/$d"; git init -q --bare "$HOME/$d/r.git"
    URL=$HOME/$d/r.git; gate "$(line_new)"
    [ "$status" -eq 1 ]
  done
}

@test "a local path on another device than \$HOME (a mount not on any list) is gated" {
  sandbox; commit b.txt "token=$TOKEN_FAKE"
  # stat stub: a path through a directory named othermount is on device 4242 (git resolves
  # symlinks in the path, so the match is on the name); the rest as the real stat says
  local sb="$BATS_TEST_TMPDIR/stat-bin"; mkdir -p "$sb"
  printf '#!/bin/sh\nfor a; do last=$a; done\ncase $last in */othermount/*) echo 4242; exit 0 ;; esac\nexec %s "$@"\n' "$(command -v stat)" > "$sb/stat"
  chmod +x "$sb/stat"; PATH="$sb:$PATH"
  git init -q --bare "$SB/othermount/r.git"
  URL=$SB/othermount/r.git; gate "$(line_new)"
  [ "$status" -eq 1 ]
  URL=$R; gate "$(line_new)"   # same device as $HOME: still not gated
  [ "$status" -eq 0 ]
}

@test "a gitleaks swapped together with its sidecar is refused: it must match the gate's own record" {
  sandbox; echo '# swapped' >> "$GL"; sha "$GL" > "$GL.sha256"; gate "$(line_new)"
  [ "$status" -eq 1 ]
  [[ $output == *"recorded at install"* ]]
  installed
  run "$GATE" --doctor
  grep -q '^gitleaks ok ' <<<"$output"
  echo '# swapped again' >> "$GL"; sha "$GL" > "$GL.sha256"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^gitleaks FAIL .*recorded at install' <<<"$output"
}

@test "a sha256 repository: a branch delete passes, a clean push passes, a term blocks" {
  SB="$BATS_TEST_TMPDIR/sb256"; R="$SB/origin.git" W="$SB/work"
  git init -q --bare --object-format=sha256 -b main "$R"; git clone -q "$R" "$W" 2>/dev/null; cd "$W"
  URL=https://github.com/owner/repo.git
  echo base > a.txt; git add . && git commit -qm init
  Z64=$(printf '0%.0s' {1..64})
  gate "refs/heads/old $Z64 refs/heads/old $(git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  gate "refs/heads/main $(git rev-parse HEAD) refs/heads/main $Z64"
  [ "$status" -eq 0 ]
  commit b.txt "hello $TERM_FAKE"; gate "refs/heads/main $(git rev-parse HEAD) refs/heads/main $Z64"
  [ "$status" -eq 1 ]
}

@test "a remote sha git didn't write refuses the push" {
  sandbox; commit b.txt fine
  gate "refs/heads/main $(git rev-parse HEAD) refs/heads/main not-a-sha"
  [ "$status" -eq 1 ]; [[ $output == *"a pre-push line git didn't write"* ]]
}

# --- the hook: which commits are new ----------------------------------------------------------

@test "a term only in a middle commit blocks, on an update push and on a new branch" {
  sandbox; git push -q origin main; old=$(git rev-parse HEAD)
  commit b.txt fine; commit c.txt ok "mention $TERM_FAKE"; commit d.txt fine
  gate "$(line_upd "$old")"
  [ "$status" -eq 1 ]
  gate "refs/heads/topic $(git rev-parse HEAD) refs/heads/topic $Z"
  [ "$status" -eq 1 ]
}

@test "a new branch: history the push URL already has (git ls-remote) isn't scanned again" {
  sandbox; export PUSH_GATE_LOCAL=1; URL=$R
  commit b.txt ok "mention $TERM_FAKE"; git push -q origin main   # already on the remote, ungated
  git checkout -q -b topic; commit c.txt fine
  gate "refs/heads/topic $(git rev-parse HEAD) refs/heads/topic $Z"
  [ "$status" -eq 0 ]
}

@test "a new branch: a forged tracking ref (git update-ref) doesn't hide history from the scans" {
  sandbox; export PUSH_GATE_LOCAL=1; URL=$R
  git push -q origin main
  commit b.txt ok "mention $TERM_FAKE"; commit c.txt fine
  git update-ref refs/remotes/origin/forged HEAD
  gate "refs/heads/topic $(git rev-parse HEAD) refs/heads/topic $Z"
  [ "$status" -eq 1 ]
}

@test "a new branch: with a pushurl, what the fetch remote has doesn't count as pushed" {
  sandbox; export PUSH_GATE_LOCAL=1
  commit b.txt ok "mention $TERM_FAKE"; git push -q origin main; git fetch -q origin   # origin/main has it
  P="$SB/public.git"; git init -q --bare -b main "$P"; git config remote.origin.pushurl "$P"; URL=$P
  gate "refs/heads/topic $(git rev-parse HEAD) refs/heads/topic $Z"
  [ "$status" -eq 1 ]
}

# --- the hook: annotated tags ----------------------------------------------------------------

@test "an annotated tag's message and tagger are scanned, nested tags too" {
  sandbox; git push -q origin main
  git tag -a v1 -m "release $TERM_FAKE"; gate "refs/tags/v1 $(git rev-parse v1) refs/tags/v1 $Z"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
  GIT_COMMITTER_NAME="Pat $TERM_FAKE" git tag -a v2 -m fine; gate "refs/tags/v2 $(git rev-parse v2) refs/tags/v2 $Z"
  [ "$status" -eq 1 ]
  git tag -a v3 -m "token=$TOKEN_FAKE"; gate "refs/tags/v3 $(git rev-parse v3) refs/tags/v3 $Z"
  [ "$status" -eq 1 ]
  none -q "$TOKEN_FAKE" <<<"$output"
  git tag -a inner -m "inner $TERM_FAKE"; git tag -a outer -m fine inner 2>/dev/null
  gate "refs/tags/outer $(git rev-parse outer) refs/tags/outer $Z"
  [ "$status" -eq 1 ]
  git tag -a v4 -m fine; gate "refs/tags/v4 $(git rev-parse v4) refs/tags/v4 $Z"
  [ "$status" -eq 0 ]
}

# --- the hook: audit log -----------------------------------------------------------------------

@test "the log gets one PASS line naming repo and remote; BLOCKED lines hold no term" {
  sandbox; gate "$(line_new)"
  [ "$(grep -c " PASS " "$LOG")" -eq 1 ]
  grep -q "work .*owner/repo" "$LOG"
  commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  grep -q " BLOCKED " "$LOG"
  none -qi "$TERM_FAKE" "$LOG"
}

@test "a credential in the push URL never reaches the log" {
  local at=@   # the URL is built here: no credential-shaped URL in the file
  sandbox "https://x-access-token:${TOKEN_FAKE}${at}github.com/owner/repo.git"; gate "$(line_new)"
  [ "$status" -eq 0 ]
  none -qF "$TOKEN_FAKE" "$LOG"
  none -q 'x-access-token' "$LOG"
  grep -q ' https://github.com/owner/repo.git' "$LOG"
}

@test "an unwritable log never blocks a clean push" {
  sandbox; user_setting "push_gate.log: /nonexistent/dir/log"; gate "$(line_new)"
  [ "$status" -eq 0 ]
}

# --- the hook: fails closed --------------------------------------------------------------------

@test "a missing, comment-only or invalid denylist blocks, even a clean push" {
  sandbox
  rm "$HOME/.config/crewkit/denylist.txt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *denylist* ]]
  printf '# only comments\n\n' > "$HOME/.config/crewkit/denylist.txt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"no patterns"* ]]
  printf '%s\n' '(' "$TERM_FAKE" > "$HOME/.config/crewkit/denylist.txt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"invalid pattern"* ]]
}

@test "a missing exempt file gates everything" {
  sandbox https://git.example.test/client-org/client-project.git; rm "$HOME/.config/crewkit/push-gate-exempt"
  commit b.txt "hello $TERM_FAKE"; gate "$(line_new)"
  [ "$status" -eq 1 ]
}

@test "an unreadable exempt file, or an invalid exempt pattern, refuses the push" {
  sandbox https://git.example.test/client-org/client-project.git
  chmod 000 "$HOME/.config/crewkit/push-gate-exempt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error"* ]]
  chmod 600 "$HOME/.config/crewkit/push-gate-exempt"
  printf '%s\n' '[:/]client-org/' '(' > "$HOME/.config/crewkit/push-gate-exempt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error"* ]]
  printf '%s\n' 'skip-all (' > "$HOME/.config/crewkit/push-gate-exempt"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error"* ]]
}

@test "no gitleaks, no recorded sha256, or a gitleaks that changed since install blocks" {
  sandbox
  user_setting "push_gate.gitleaks: $BATS_TEST_TMPDIR/nope"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"no gitleaks at"* ]]
  user_setting "push_gate.gitleaks: $GL"; mv "$GL.sha256" "$GL.sha256.bak"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"has no recorded sha256"* ]]
  mv "$GL.sha256.bak" "$GL.sha256"; echo "# changed" >> "$GL"; gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"not the verified install"* ]]
}

@test "gitleaks erroring (not a finding) still blocks" {
  sandbox; GL_FAIL=1 gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *gitleaks* ]]
}

@test "fail-open (a): git rev-list failing refuses the push, it doesn't scan nothing" {
  sandbox; commit b.txt ok "mention $TERM_FAKE"   # the term is only in a commit message
  PG_FAULT=git-rev-list gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "fail-open (b): grep exiting 2 on a commit refuses the push, it isn't an empty count" {
  sandbox; commit b.txt fine; PG_FAULT=grep-count-body gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push (grep failed on a commit)"* ]]
}

@test "git show failing on a commit refuses the push" {
  sandbox; PG_FAULT=git-show gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "git grep failing on the pushed tree refuses the push" {
  sandbox; PG_FAULT=git-grep gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "git ls-tree failing on the pushed tree refuses the push" {
  sandbox; PG_FAULT=git-ls-tree gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "grep exiting 2 on the path list refuses the push (a range with no new commits)" {
  sandbox; git push -q origin main; h=$(git rev-parse HEAD)
  PG_FAULT=grep-count gate "refs/heads/main $h refs/heads/other $h"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "grep exiting 2 on the branch name refuses the push" {
  sandbox; PG_FAULT=grep-iq gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"gate error: refusing push"* ]]
}

@test "grep exiting 2 on a hit's path refuses the push, and never prints the unchecked path" {
  sandbox; commit "notes-$TERM_FAKE.md" "body $TERM_FAKE"
  # the branch-name check passes (real grep); the path check after a content hit fails
  run bash -c 'printf "%s\n" "$1" | PG_FAULT=grep-iq-path "$2" hook origin "$3"' _ "$(line_new)" "$GATE" "$URL"
  [ "$status" -eq 1 ]
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "a pushed sha that isn't in the repository, or a line git didn't write, refuses the push" {
  sandbox; gate "refs/heads/main $(printf '2%.0s' {1..40}) refs/heads/main $Z"
  [ "$status" -eq 1 ]; [[ $output == *"the pushed commit isn't in this repository"* ]]
  gate "refs/heads/main not-a-sha refs/heads/main $Z"
  [ "$status" -eq 1 ]; [[ $output == *"a pre-push line git didn't write"* ]]
}

@test "the settings are user-only: neither the environment nor a project can redirect the denylist" {
  sandbox; printf '# nothing\n' > "$BATS_TEST_TMPDIR/empty"
  rm "$HOME/.config/crewkit/denylist.txt"
  mkdir -p .claude; printf -- '---\npush_gate.denylist: %s\n---\n' "$BATS_TEST_TMPDIR/term-free" > .claude/crewkit.md
  echo nothing-matches-this-xyz > "$BATS_TEST_TMPDIR/term-free"
  CREWKIT_PUSH_GATE_DENYLIST="$BATS_TEST_TMPDIR/term-free" gate "$(line_new)"
  [ "$status" -eq 1 ]; [[ $output == *"no denylist"* ]]
}

@test "a user settings file that fails the ownership checks falls back to the defaults, not to nothing" {
  sandbox; commit b.txt "hello $TERM_FAKE"
  user_setting "push_gate.denylist: $BATS_TEST_TMPDIR/term-free"; echo nothing-matches-this-xyz > "$BATS_TEST_TMPDIR/term-free"
  chmod 666 "$HOME/.claude/crewkit.md"
  gate "$(line_new)"
  [ "$status" -eq 1 ]
}

# --- install, status -------------------------------------------------------------------------

@test "install without --yes is a dry run: prints the git config command, changes nothing" {
  run "$GATE" install
  [ "$status" -eq 0 ]
  [[ $output == *"git config --global core.hooksPath ~/.local/share/crewkit/gate/push-gate/hooks"* ]]
  [ ! -e "$GD" ]
  [ -z "$(git config --global core.hooksPath)" ]
}

@test "install --yes copies the gate and sets the global core.hooksPath; status reports it" {
  run "$GATE" status --json
  [ "$output" = '{"installed":false,"denylist":true}' ]
  installed
  [ "$(git config --global core.hooksPath)" = "$GD/push-gate/hooks" ]
  [ -x "$GD/push-gate/hooks/pre-push" ]
  run "$GATE" status --json
  [ "$output" = '{"installed":true,"denylist":true}' ]
  installed   # a re-run is fine
}

@test "an install that fails partway leaves the installed gate in place (a missing gate dir is no gate)" {
  installed
  PG_FAULT=mv-new run "$GATE" install --yes
  [ "$status" -eq 1 ]
  [ -x "$GD/push-gate/hooks/pre-push" ]
  [ -f "$GD/push-gate/push-gate.sh" ]
  [ ! -e "$GD.old" ]
  mv "$GD" "$GD.old"   # an earlier install that stopped between its two renames
  PG_FAULT=mv-new run "$GATE" install --yes
  [ "$status" -eq 1 ]
  [ -x "$GD/push-gate/hooks/pre-push" ]
  none -q '\.new\.' <<<"$(ls -a "${GD%/*}")"
}

@test "install with no denylist is an owner step (78), and changes nothing" {
  rm "$HOME/.config/crewkit/denylist.txt"
  run "$GATE" install --yes
  [ "$status" -eq 78 ]
  [[ $output == *"owner step"*denylist* ]]
  [ ! -e "$GD" ]
  run "$GATE" status --json
  [ "$output" = '{"installed":false,"denylist":false}' ]
}

@test "install with an unverified gitleaks is an owner step (78)" {
  rm "$GL.sha256"
  run "$GATE" install --yes
  [ "$status" -eq 78 ]
  [[ $output == *"owner step"*gitleaks* ]]
  [ ! -e "$GD" ]
}

@test "install refuses to replace someone else's global core.hooksPath" {
  git config --global core.hooksPath "$HOME/elsewhere"
  run "$GATE" install --yes
  [ "$status" -eq 1 ]
  [ "$(git config --global core.hooksPath)" = "$HOME/elsewhere" ]
  [ ! -e "$GD" ]
}

@test "status takes only --json; an unknown verb is usage (64)" {
  run "$GATE" status
  [ "$status" -eq 64 ]
  run "$GATE" bogus
  [ "$status" -eq 64 ]
}

# --- the dispatcher, end to end ----------------------------------------------------------------

@test "a real git push with a term is refused; a clean one goes through" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; commit b.txt "hello $TERM_FAKE"
  run git push -q origin main
  [ "$status" -ne 0 ]
  [ -z "$(git ls-remote "$R" main)" ]
  sandbox; commit b.txt clean
  run git push -q origin main
  [ "$status" -eq 0 ]
  [ -n "$(git ls-remote "$R" main)" ]
}

@test "the repo's own hooks still run (chained), and their failures still count" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox
  printf '#!/bin/sh\necho ran > "%s/precommit-ran"\nexit 1\n' "$SB" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
  printf 'y\n' > c.txt; git add c.txt
  run git commit -qm c
  [ "$status" -ne 0 ]
  [ -f "$SB/precommit-ran" ]
}

@test "the repo's own pre-push gets the same stdin after the gate, and doesn't run after a refusal" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox
  printf '#!/bin/sh\ncat > "%s/prepush-stdin"\n' "$SB" > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
  commit b.txt clean; git push -q origin main
  grep -q "refs/heads/main $(git rev-parse HEAD)" "$SB/prepush-stdin"
  rm "$SB/prepush-stdin"
  commit c.txt "hello $TERM_FAKE"
  run git push -q origin main
  [ "$status" -ne 0 ]
  [ ! -e "$SB/prepush-stdin" ]
}

@test "a push from a linked worktree is gated too" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git worktree add -q "$SB/wt" -b wt; cd "$SB/wt"; commit d.txt "hello $TERM_FAKE"
  run git push -q origin wt
  [ "$status" -ne 0 ]
}

@test "a local bare remote's own receive hooks still run (pre-receive, update, post-receive)" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; commit b.txt clean
  for h in update post-receive; do
    printf '#!/bin/sh\necho ran >> "%s/%s-ran"\n' "$SB" "$h" > "$R/hooks/$h"; chmod +x "$R/hooks/$h"
  done
  git push -q origin main
  [ -f "$SB/update-ran" ]; [ -f "$SB/post-receive-ran" ]
  printf '#!/bin/sh\necho ran > "%s/pre-receive-ran"\nexit 1\n' "$SB" > "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
  commit c.txt clean
  run git push -q origin main
  [ "$status" -ne 0 ]
  [ -f "$SB/pre-receive-ran" ]
}

@test "the dispatcher fails closed when the gate script is missing" {
  installed; export PUSH_GATE_LOCAL=1
  rm "$GD/push-gate/push-gate.sh"
  sandbox; commit b.txt clean
  run git push -q origin main
  [ "$status" -ne 0 ]
}

# --- shim: a repository with its own core.hooksPath ---------------------------------------------

@test "a local core.hooksPath bypasses the global gate (why the shim exists)" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git config core.hooksPath .husky; commit b.txt "hello $TERM_FAKE"
  run git push -q origin main
  [ "$status" -eq 0 ]
}

@test "shim without --yes changes nothing; with it, a push with a term is refused and a clean one passes" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git config core.hooksPath .husky
  run "$GATE" shim "$W"
  [ "$status" -eq 0 ]
  [ ! -e .husky/pre-push ]
  run "$GATE" shim "$W" --yes
  [ "$status" -eq 0 ]
  [ "$(wc -l < .husky/pre-push)" -eq 2 ]
  commit b.txt "hello $TERM_FAKE"
  run git push -q origin main
  [ "$status" -ne 0 ]
  git reset -q --hard HEAD~1; commit b.txt clean
  run git push -q origin main
  [ "$status" -eq 0 ]
}

@test "shim on a shell pre-push: the shim runs first, then the hook with the same stdin" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git config core.hooksPath hooks; mkdir hooks
  printf '#!/usr/bin/env bash\ncat > "%s/own-stdin"\n' "$SB" > hooks/pre-push; chmod +x hooks/pre-push
  run "$GATE" shim "$W" --yes
  [ "$status" -eq 0 ]
  sed -n 2p hooks/pre-push | grep -q 'crewkit push-gate shim'
  cp hooks/pre-push "$SB/once"
  run "$GATE" shim "$W" --yes   # idempotent
  [ "$status" -eq 0 ]
  cmp hooks/pre-push "$SB/once"
  commit b.txt clean; git push -q origin main
  grep -q "refs/heads/main $(git rev-parse HEAD)" "$SB/own-stdin"
  rm "$SB/own-stdin"; commit c.txt "hello $TERM_FAKE"
  run git push -q origin main
  [ "$status" -ne 0 ]
  [ ! -e "$SB/own-stdin" ]
}

@test "shim on a non-shell pre-push: it's moved aside and chained" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git config core.hooksPath hooks; mkdir hooks
  printf '#!/usr/bin/env python3\nimport sys\nopen("%s/py-stdin", "w").write(sys.stdin.read())\n' "$SB" > hooks/pre-push; chmod +x hooks/pre-push
  run "$GATE" shim "$W" --yes
  [ "$status" -eq 0 ]
  [ -x hooks/pre-push.chained ]
  commit b.txt clean; git push -q origin main
  grep -q "refs/heads/main $(git rev-parse HEAD)" "$SB/py-stdin"
}

@test "the shim counts only as line 2 of a shell script: an exit above it is a FAIL; shim again fixes it" {
  installed
  git init -q "$HOME/code/h"; git -C "$HOME/code/h" config core.hooksPath .husky
  "$GATE" shim "$HOME/code/h" --yes >/dev/null
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
  f="$HOME/code/h/.husky/pre-push"
  { head -1 "$f"; echo 'exit 0'; tail -n +2 "$f"; } > "$f.x"; mv "$f.x" "$f"; chmod +x "$f"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^repo:~/code/h FAIL ' <<<"$output"
  "$GATE" shim "$HOME/code/h" --yes >/dev/null
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
}

@test "shim with no local core.hooksPath has nothing to do" {
  sandbox
  run "$GATE" shim "$W" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to do"* ]]
}

# --- --doctor and gate-check ------------------------------------------------------------------

@test "--doctor, healthy: exit 0, one '<check-id> ok <detail>' line per check, no absolute home paths" {
  installed
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
  for id in global-gate dispatcher denylist gitleaks root; do grep -Eq "^$id ok " <<<"$output"; done
  none -Ev '^[a-z][a-z-]*(:[^ ]+)? (ok|FAIL) ' <<<"$output"
  none -qF "$HOME" <<<"$output"
  none -qi "$TERM_FAKE" <<<"$output"
}

@test "--doctor: each check fails on its own fault (exit 1, that check FAIL)" {
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^global-gate FAIL ' <<<"$output"; grep -q '^dispatcher FAIL ' <<<"$output"
  installed
  echo '# stale' >> "$GD/push-gate/shim.sh"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^dispatcher FAIL ' <<<"$output"; grep -q '^global-gate ok ' <<<"$output"
  installed
  mv "$HOME/.config/crewkit/denylist.txt" "$BATS_TEST_TMPDIR/dl"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^denylist FAIL ' <<<"$output"
  mv "$BATS_TEST_TMPDIR/dl" "$HOME/.config/crewkit/denylist.txt"
  echo '# changed' >> "$GL"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^gitleaks FAIL ' <<<"$output"
  sha "$GL" > "$GL.sha256"; installed   # a new gitleaks: install the gate again, which records it
  user_setting "push_gate.root: "
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^root FAIL ' <<<"$output"
  user_setting "push_gate.root: ~/code"
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
  git config --global core.hooksPath "$HOME/elsewhere"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]; grep -q '^global-gate FAIL the global core.hooksPath is ~/elsewhere, not the gate$' <<<"$output"
}

@test "--doctor lists repos with a local core.hooksPath, with or without the shim, and only those" {
  installed
  for r in plain husky shimmed; do git init -q "$HOME/code/$r"; done
  git -C "$HOME/code/husky" config core.hooksPath .husky
  mkdir -p "$HOME/code/husky/.husky"   # the directory exists, with a pre-push that isn't the shim
  printf '#!/bin/sh\nnpm test\n' > "$HOME/code/husky/.husky/pre-push"; chmod +x "$HOME/code/husky/.husky/pre-push"
  git -C "$HOME/code/shimmed" config core.hooksPath .husky
  "$GATE" shim "$HOME/code/shimmed" --yes >/dev/null
  run "$GATE" --doctor
  [ "$status" -eq 1 ]
  grep -q '^repo:~/code/husky FAIL ' <<<"$output"
  grep -q '^repo:~/code/shimmed ok ' <<<"$output"
  none -q 'repo:~/code/plain' <<<"$output"
  "$GATE" shim "$HOME/code/husky" --yes >/dev/null
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
}

@test "--doctor reads the effective core.hooksPath: include.path, includeIf in ~/.gitconfig, config.worktree" {
  installed
  for r in inc client wtc plain; do git init -q "$HOME/code/$r"; done
  printf '[core]\n\thooksPath = .husky\n' > "$HOME/hp.inc"
  git -C "$HOME/code/inc" config include.path "$HOME/hp.inc"
  git config --global 'includeIf.gitdir:~/code/client/.path' "$HOME/hp.inc"
  git -C "$HOME/code/wtc" config extensions.worktreeConfig true
  git -C "$HOME/code/wtc" config --worktree core.hooksPath .husky
  run "$GATE" --doctor
  [ "$status" -eq 1 ]
  grep -q '^repo:~/code/inc FAIL ' <<<"$output"
  grep -q '^repo:~/code/client FAIL ' <<<"$output"
  grep -q '^repo:~/code/wtc FAIL ' <<<"$output"
  none -q 'repo:~/code/plain' <<<"$output"
  run "$GATE" gate-check "$HOME/code/client"
  [ "$status" -eq 1 ]; grep -q '^repo:.* FAIL ' <<<"$output"
  "$GATE" shim "$HOME/code/client" --yes >/dev/null
  [ -x "$HOME/code/client/.husky/pre-push" ]
  run "$GATE" gate-check "$HOME/code/client"
  [ "$status" -eq 0 ]
}

@test "--doctor: a core.hooksPath set to empty (git then runs no hooks at all) is a FAIL" {
  installed
  git init -q "$HOME/code/e"; git -C "$HOME/code/e" config core.hooksPath ''
  run "$GATE" --doctor
  [ "$status" -eq 1 ]
  grep -q '^repo:~/code/e FAIL ' <<<"$output"
}

@test "--doctor checks each linked worktree's own core.hooksPath" {
  installed
  git init -q "$HOME/code/m"; git -C "$HOME/code/m" commit -q --allow-empty -m init
  git -C "$HOME/code/m" worktree add -q "$HOME/code/m-wt" -b wt
  git -C "$HOME/code/m" config extensions.worktreeConfig true
  git -C "$HOME/code/m-wt" config --worktree core.hooksPath .husky
  run "$GATE" --doctor
  [ "$status" -eq 1 ]
  grep -q '^repo:~/code/m-wt FAIL ' <<<"$output"
  none -q '^repo:~/code/m ' <<<"$output"
}

@test "--doctor exits 2 on its own error (the root can't be listed)" {
  installed
  mkdir "$HOME/code/locked"; chmod 000 "$HOME/code/locked"
  run "$GATE" --doctor
  chmod 755 "$HOME/code/locked"
  [ "$status" -eq 2 ]
}

@test "gate-check: 0 when pushes from the repo are gated, 1 when not, 2 outside a repo" {
  sandbox
  run "$GATE" gate-check "$W"
  [ "$status" -eq 1 ]; grep -q '^global-gate FAIL ' <<<"$output"
  installed
  run "$GATE" gate-check "$W"
  [ "$status" -eq 0 ]
  git -C "$W" config core.hooksPath .husky
  run "$GATE" gate-check "$W"
  [ "$status" -eq 1 ]; grep -q '^repo:.* FAIL ' <<<"$output"
  "$GATE" shim "$W" --yes >/dev/null
  run "$GATE" gate-check "$W"
  [ "$status" -eq 0 ]
  run "$GATE" gate-check "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "a non-push hook costs little to dispatch" {
  installed; sandbox
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  for i in 1 2 3 4 5 6 7 8 9 10; do "$GD/push-gate/hooks/post-checkout" x y 1 >/dev/null 2>&1; done
  t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  echo "10 dispatches: $((t1 - t0)) ms"
  [ $((t1 - t0)) -lt "$(ms_bound 500)" ]
}

@test "the dispatch bound honours CREWKIT_TEST_TIME_SCALE: 500 ms at scale 1, 5000 ms at scale 10" {
  TS=1
  [ "$(ms_bound 500)" -eq 500 ]
  TS=10
  [ "$(ms_bound 500)" -eq 5000 ]
  # the dispatch test takes its bound from ms_bound, not a bare number
  run grep -c -x -F '  [ $((t1 - t0)) -lt "$(ms_bound 500)" ]' "$BATS_TEST_FILENAME"
  [ "$output" -eq 1 ]
}

# --- doctor-watch and schedule: the hourly doctor, notifying only when the FAIL set changes --------

# notifier: push_gate.notify_command appends its last argument to $NOTES (NOTIFY_RC sets its exit).
notifier() {
  printf '#!/bin/sh\nfor a; do last=$a; done\necho "$last" >> "%s"\nexit "${NOTIFY_RC:-0}"\n' "$BATS_TEST_TMPDIR/notes" > "$BATS_TEST_TMPDIR/notify"
  chmod +x "$BATS_TEST_TMPDIR/notify"
  user_setting "push_gate.notify_command: $BATS_TEST_TMPDIR/notify --topic gate"
  NOTES="$BATS_TEST_TMPDIR/notes"
}

@test "doctor-watch: a FAIL notifies once with a pointer (check ids only), not again while unchanged" {
  notifier
  run "$GATE" doctor-watch
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$NOTES")" -eq 1 ]
  [ "$(cat "$NOTES")" = "push-gate: 2 FAIL: dispatcher global-gate" ]
  run "$GATE" doctor-watch
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$NOTES")" -eq 1 ]
}

@test "doctor-watch: a change in the FAIL set notifies again; recovery notifies ok" {
  notifier
  "$GATE" doctor-watch >/dev/null || true
  installed
  git init -q "$HOME/code/h"; git -C "$HOME/code/h" config core.hooksPath .husky
  run "$GATE" doctor-watch
  [ "$status" -eq 1 ]
  [ "$(sed -n 2p "$NOTES")" = "push-gate: 1 FAIL: repo:~/code/h" ]
  "$GATE" shim "$HOME/code/h" --yes >/dev/null
  run "$GATE" doctor-watch
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$NOTES")" = "push-gate: ok" ]
  run "$GATE" doctor-watch
  [ "$(wc -l < "$NOTES")" -eq 3 ]
}

@test "doctor-watch: a healthy first run notifies nothing" {
  notifier; installed
  run "$GATE" doctor-watch
  [ "$status" -eq 0 ]
  [ ! -e "$NOTES" ]
}

@test "doctor-watch: a failed notify isn't recorded, so the next run tries again" {
  notifier
  NOTIFY_RC=1 run "$GATE" doctor-watch
  [ "$status" -eq 1 ]
  [[ $output == *"notify failed"* ]]
  run "$GATE" doctor-watch
  [ "$(wc -l < "$NOTES")" -eq 2 ]
}

@test "doctor-watch: no notify_command prints the pointer, only on a change" {
  run "$GATE" doctor-watch
  [[ $output == *"push-gate: 2 FAIL: dispatcher global-gate"* ]]
  run "$GATE" doctor-watch
  [[ $output != *"push-gate: 2 FAIL"* ]]
}

@test "doctor-watch: the pointer never carries a term or an absolute home path" {
  notifier; installed
  printf '%s\n' '(' > "$HOME/.config/crewkit/denylist.txt"
  run "$GATE" doctor-watch
  none -qF "$HOME" "$NOTES"
  none -qi "$TERM_FAKE" "$NOTES"
  [ "$(cat "$NOTES")" = "push-gate: 1 FAIL: denylist" ]
}

# crash_tree: a gate tree whose --doctor exits $PG_DOCTOR_EXIT before any check (127 as for a
# missing command, 137 as for SIGKILL), through a lib/settings.sh that wraps the real one.
crash_tree() {
  local t="$BATS_TEST_TMPDIR/crash"
  mkdir -p "$t/lib"; ln -s "$REPO/push-gate" "$t/push-gate"
  printf 'source "%s/lib/settings.sh"\n[[ ${1:-} == --doctor && -n ${PG_DOCTOR_EXIT:-} ]] && exit "$PG_DOCTOR_EXIT"\n' "$REPO" > "$t/lib/settings.sh"
  CGATE="$t/push-gate/push-gate.sh"
}

@test "doctor-watch: a doctor that crashes or is killed (127, 137), or exits 1 with no FAIL, is an error" {
  notifier; installed; crash_tree
  PG_DOCTOR_EXIT=127 run "$CGATE" doctor-watch
  [ "$status" -eq 2 ]
  [ "$(cat "$NOTES")" = "push-gate: doctor error (exit 127)" ]
  PG_DOCTOR_EXIT=137 run "$CGATE" doctor-watch
  [ "$status" -eq 2 ]
  [ "$(sed -n 2p "$NOTES")" = "push-gate: doctor error (exit 137)" ]
  PG_DOCTOR_EXIT=1 run "$CGATE" doctor-watch
  [ "$status" -eq 2 ]
  [ "$(sed -n 3p "$NOTES")" = "push-gate: doctor error (exit 1)" ]
  run "$CGATE" doctor-watch
  [ "$status" -eq 0 ]
  [ "$(sed -n 4p "$NOTES")" = "push-gate: ok" ]
}

@test "--doctor reports the exempt file: its pattern counts and a fingerprint, never the patterns" {
  installed
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
  grep -Eq '^exempt ok 1 exempt, 1 skip-all \(sha256 [0-9a-f]{12}\)$' <<<"$output"
  none -q 'client-org' <<<"$output"
  echo 'skip-all (' >> "$HOME/.config/crewkit/push-gate-exempt"
  run "$GATE" --doctor
  [ "$status" -eq 1 ]
  grep -q '^exempt FAIL ' <<<"$output"
  rm "$HOME/.config/crewkit/push-gate-exempt"
  run "$GATE" --doctor
  [ "$status" -eq 0 ]
  grep -qx 'exempt ok none (every remote gated)' <<<"$output"
}

@test "doctor-watch: a changed exempt file notifies (counts only), even with no FAIL change" {
  notifier; installed
  run "$GATE" doctor-watch
  [ "$status" -eq 0 ]
  [ ! -e "$NOTES" ]
  echo 'skip-all [:/]someone/' >> "$HOME/.config/crewkit/push-gate-exempt"
  run "$GATE" doctor-watch
  [ "$status" -eq 0 ]
  [ "$(cat "$NOTES")" = "push-gate: the exempt file changed: 1 exempt, 2 skip-all" ]
  run "$GATE" doctor-watch
  [ "$(wc -l < "$NOTES")" -eq 1 ]
}

# sched_stubs OS: uname answers OS; launchctl and systemctl record their arguments in $SCALLS.
sched_stubs() {
  local d="$BATS_TEST_TMPDIR/sched-bin"
  mkdir -p "$d"
  printf '#!/bin/sh\necho %s\n' "$1" > "$d/uname"
  printf '#!/bin/sh\necho "launchctl $*" >> "%s"\n' "$BATS_TEST_TMPDIR/scalls" > "$d/launchctl"
  printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n' "$BATS_TEST_TMPDIR/scalls" > "$d/systemctl"
  chmod +x "$d"/*
  PATH="$d:$PATH"
  SCALLS="$BATS_TEST_TMPDIR/scalls"
}

@test "schedule needs the gate installed first (78)" {
  sched_stubs Linux
  run "$GATE" schedule --yes
  [ "$status" -eq 78 ]
  [[ $output == *"push-gate.sh install"* ]]
}

@test "schedule on Linux: dry run writes nothing; --yes writes the user timer and enables it" {
  installed; sched_stubs Linux
  run "$GATE" schedule
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/systemd/user/crewkit-push-gate-doctor.timer" ]
  [ ! -e "$SCALLS" ]
  run "$GATE" schedule --yes
  [ "$status" -eq 0 ]
  u="$HOME/.config/systemd/user"
  grep -qx "ExecStart=\"$GD/push-gate/push-gate.sh\" doctor-watch" "$u/crewkit-push-gate-doctor.service"
  grep -qx 'OnUnitActiveSec=1h' "$u/crewkit-push-gate-doctor.timer"
  grep -qx 'systemctl --user enable --now crewkit-push-gate-doctor.timer' "$SCALLS"
}

@test "schedule on macOS: --yes writes the launch agent (hourly, the installed gate) and loads it" {
  installed; sched_stubs Darwin
  run "$GATE" schedule --yes
  [ "$status" -eq 0 ]
  p="$HOME/Library/LaunchAgents/com.crewkit.push-gate-doctor.plist"
  grep -q "<string>$GD/push-gate/push-gate.sh</string>" "$p"
  grep -q '<string>doctor-watch</string>' "$p"
  grep -q '<integer>3600</integer>' "$p"
  grep -q "launchctl bootstrap gui/$(id -u) $p" "$SCALLS"
  run "$GATE" schedule --yes   # again: replaced, not duplicated
  [ "$status" -eq 0 ]
  [ "$(grep -c 'launchctl bootstrap' "$SCALLS")" -eq 2 ]
  grep -q "launchctl bootout gui/$(id -u)/com.crewkit.push-gate-doctor" "$SCALLS"
}

@test "schedule escapes what it fills in: & | % \" < in PATH, relative PATH entries dropped, the gate path quoted" {
  installed
  odd='/opt/a&b|c%d"e<f'
  sched_stubs Linux
  PATH="$PATH:$odd:relative/bin" run "$GATE" schedule --yes
  [ "$status" -eq 0 ]
  u="$HOME/.config/systemd/user/crewkit-push-gate-doctor.service"
  grep -qx "ExecStart=\"$GD/push-gate/push-gate.sh\" doctor-watch" "$u"
  grep -qF ':/opt/a&b|c%%d\"e<f"' "$u"
  none -q 'relative/bin' "$u"
  rm "$BATS_TEST_TMPDIR/sched-bin/uname"; sched_stubs Darwin
  PATH="$PATH:$odd:relative/bin" run "$GATE" schedule --yes
  [ "$status" -eq 0 ]
  p="$HOME/Library/LaunchAgents/com.crewkit.push-gate-doctor.plist"
  grep -qF ':/opt/a&amp;b|c%d&quot;e&lt;f</string>' "$p"
  none -q 'relative/bin' "$p"
  if command -v plutil >/dev/null; then plutil -lint "$p"; fi
}

@test "the scheduled doctor (run from the installed copy) compares it with the clone it came from" {
  local t="$BATS_TEST_TMPDIR/clone"; mkdir -p "$t"; cp -R "$REPO/push-gate" "$REPO/lib" "$t/"
  "$t/push-gate/push-gate.sh" install --yes >/dev/null
  run "$GD/push-gate/push-gate.sh" --doctor
  grep -q '^dispatcher ok ' <<<"$output"
  echo '# newer' >> "$t/push-gate/shim.sh"
  run "$GD/push-gate/push-gate.sh" --doctor
  [ "$status" -eq 1 ]; grep -q '^dispatcher FAIL ' <<<"$output"
  rm -rf "$t"
  run "$GD/push-gate/push-gate.sh" --doctor
  [ "$status" -eq 1 ]; grep -q '^dispatcher FAIL ' <<<"$output"
}

@test "the shim says why when the gate's installed copy is missing" {
  installed; export PUSH_GATE_LOCAL=1
  sandbox; git config core.hooksPath .husky
  "$GATE" shim "$W" --yes >/dev/null
  commit b.txt clean
  rm "$GD/push-gate/push-gate.sh"   # the gate script gone, shim.sh still there
  run git push -q origin main
  [ "$status" -ne 0 ]
  [[ $output == *"push-gate shim: the gate isn't installed"* ]]
  rm -rf "$GD"                       # the whole installed copy gone
  run git push -q origin main
  [ "$status" -ne 0 ]
  [[ $output == *"push-gate shim: the gate isn't installed"* ]]
  [ -z "$(git ls-remote "$R" main)" ]
}
