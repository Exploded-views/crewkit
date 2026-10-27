# Shared setup for the crew-orchestrator tests: a bare origin standing in for GitHub, a work
# clone the landers run from, the stub gh (tests/stubs/gh) first on PATH, an empty HOME, and
# gate settings in the test HOME's ~/.claude/crewkit.md or the clone's .claude/crewkit.md.
setup_orch() {
  # The variables below are read by the .bats files that load this helper, so they are exported.
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export BIN="$REPO/plugins/crew-orchestrator/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  export STUB="$BATS_TEST_TMPDIR/stub" STUB_BARE="$BATS_TEST_TMPDIR/origin.git"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$HOME" "$STUB/ci" "$STUB/pr" "$STUB/hooks" "$STUB/jobs" "$STUB/runs" "$BATS_TEST_TMPDIR/bin"
  ln -s "$REPO/tests/stubs/gh" "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  git init -q --bare -b main "$STUB_BARE"
  W="$BATS_TEST_TMPDIR/work"
  git clone -q "$STUB_BARE" "$W" 2>/dev/null
  cd "$W" || return
  echo .claude >> .git/info/exclude
  printf 'line1\nline2\nline3\n' > shared.txt
  git add shared.txt
  git commit -qm init
  git push -q origin HEAD:main
  # Gate settings are file-only (lib/settings.sh): they go in the test HOME's user file. The
  # operational ones (env-OK) stay in the environment.
  export ORCH_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCH_CAMPAIGN_DIR="$BATS_TEST_TMPDIR/campaign"
  user_setting "repo: OWNER/REPO" "state_dir: $ORCH_STATE_DIR" "campaign_dir: $ORCH_CAMPAIGN_DIR" \
    "ci.workflow: .github/workflows/ci.yml" "high_risk_areas.confirmed_by: owner" "review.reviewers: reviewer"
  export CREWKIT_FLAKES_FILE="$BATS_TEST_TMPDIR/flakes.txt"
  export CREWKIT_POLL_SECONDS=0 CREWKIT_POLL_MAX=5 CREWKIT_LOCK_WAIT_SECONDS=5
  printf '%s\n' 'bigmem.test.ts' 'catalog-snapshot.db.test.ts' > "$CREWKIT_FLAKES_FILE"
  export JOURNAL="$ORCH_STATE_DIR/landing.log"
  OTHER_SHA=$(printf 'cd%.0s' {1..20})   # a full SHA no PR has (built here: no hex literals in the repo)
  export OTHER_SHA
}

# user_setting KEY: VALUE...: set keys in the test HOME's ~/.claude/crewkit.md (the user file,
# read below the project files), replacing any earlier value of the same key. Gate settings are
# file-only (lib/settings.sh), so tests set them here, never through CREWKIT_*.
user_setting() {
  local f="$HOME/.claude/crewkit.md" kv keys=()
  mkdir -p "$HOME/.claude"
  for kv in "$@"; do keys+=("${kv%%:*}"); done
  {
    echo ---
    [[ -f $f ]] && awk -v drop=" ${keys[*]} " 'NR > 1 && $0 != "---" { k = $0; sub(/:.*/, "", k); if (index(drop, " " k " ") == 0) print }' "$f"
    printf '%s\n' "$@"
    echo ---
  } > "$f.new" && mv "$f.new" "$f"
}

# user_unset KEY...: drop keys from the test HOME's user file.
user_unset() {
  local f="$HOME/.claude/crewkit.md"
  awk -v drop=" $* " 'NR == 1 || $0 == "---" { print; next } { k = $0; sub(/:.*/, "", k); if (index(drop, " " k " ") == 0) print }' "$f" > "$f.new" &&
    mv "$f.new" "$f"
}

# settings KEY: VALUE...: write the work clone's committed settings file.
settings() {
  mkdir -p "$W/.claude"
  { echo ---; printf '%s\n' "$@"; echo ---; } > "$W/.claude/crewkit.md"
}

# pr_meta N HEAD: the stub's view of an open PR from a feature branch onto main, green CI.
pr_meta() {
  local d=$STUB/pr/$1
  mkdir -p "$d"
  echo OPEN > "$d/state"; echo main > "$d/base"; echo "feature-$1" > "$d/ref"
  : > "$d/labels"; echo false > "$d/draft"; echo "$2" > "$d/head"
  echo success > "$STUB/ci/$2"
}

# mkpr N [--bad "kind\nlog..."] [--bad2 "kind\nlog..."] [--shared "first line"] [--file PATH]: a
# PR off main. --bad fails the unit job (kind "flake": attempt 1 only); --bad2 adds a failing e2e job.
mkpr() {
  local n=$1 files h
  files=("f-$n.txt")
  shift
  cd "$W" || return
  git checkout -q -B "pr$n" main
  git reset -q --hard main
  echo "feature $n" > "f-$n.txt"
  while (($#)); do
    case $1 in
      --bad) printf '%b\n' "$2" > "bad-$n.txt"; files+=("bad-$n.txt"); shift 2 ;;
      --bad2) printf '%b\n' "$2" > "bad2-$n.txt"; files+=("bad2-$n.txt"); shift 2 ;;
      --shared) printf '%s\nline2\nline3\n' "$2" > shared.txt; files+=(shared.txt); shift 2 ;;
      --file) mkdir -p "$(dirname "$2")"; echo "change $n" > "$2"; files+=("$2"); shift 2 ;;
    esac
  done
  git add "${files[@]}"
  git commit -qm "pr $n"
  h=$(git rev-parse HEAD)
  git push -q origin "HEAD:refs/pull/$n/head"
  pr_meta "$n" "$h"
  git checkout -q main
}

# mkpr_on N BASE: PR N stacked on PR BASE's head (it carries BASE's commit).
mkpr_on() {
  local n=$1 h
  cd "$W" || return
  git checkout -q -B "pr$n" "$(cat "$STUB/pr/$2/head")"
  echo "feature $n" > "f-$n.txt"
  git add "f-$n.txt"
  git commit -qm "pr $n"
  h=$(git rev-parse HEAD)
  git push -q origin "HEAD:refs/pull/$n/head"
  pr_meta "$n" "$h"
  git checkout -q main
}

# hook NAME SCRIPT: a one-shot stub hook (on_poll, on_merge, after_merge).
hook() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB/hooks/$1"
  chmod +x "$STUB/hooks/$1"
}

# A shell snippet (for hooks) that lands an unrelated commit on main. It is code for the hook to
# run later, so its $(...) and $t must stay unexpanded here.
push_main_snippet() {
  # shellcheck disable=SC2016  # the single quotes are deliberate (see above)
  printf 't=$(mktemp -d %s/tmp.XXXX); git clone -q %s $t; cd $t; echo s > other.txt; git add other.txt; git commit -qm other; git push -q origin HEAD:main' "$STUB" "$STUB_BARE"
}

merged() { tr '\n' ' ' < "$STUB/merged.log" 2>/dev/null || true; }
merge_calls() { grep -c '^pr merge' "$STUB/calls.log" || true; }
no_batch_branches() { [[ -z $(git --git-dir="$STUB_BARE" for-each-ref refs/heads/batch) ]]; }

# hold_lock SECONDS: hold the landing lock in the background (wait for it with `wait`).
hold_lock() {
  mkdir -p "$ORCH_STATE_DIR/locks"
  (exec 8>"$ORCH_STATE_DIR/locks/land.lock"; flock 8; sleep "$1") &
  sleep 0.5
}

none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}
