# Shared setup for the crew-lanes tests: a bare origin, a main checkout, an empty HOME, and
# settings written to the checkout's .claude/crewkit.md.
setup_lanes() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  # shellcheck disable=SC2034  # used by the tests that load this file
  BIN="$REPO/plugins/crew-lanes/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  MAIN="$BATS_TEST_TMPDIR/main"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$MAIN"
  echo a > "$MAIN/a.txt"
  git -C "$MAIN" add a.txt
  git -C "$MAIN" commit -qm base
  git -C "$MAIN" remote add origin "$ORIGIN"
  git -C "$MAIN" push -q -u origin main
  # CREWKIT_CAMPAIGN_DIR stays as the tests' name for the path; the setting itself is file-only
  # (lib/settings.sh), so it goes in the user settings file.
  CREWKIT_CAMPAIGN_DIR="$BATS_TEST_TMPDIR/campaign"
  user_setting "campaign_dir: $CREWKIT_CAMPAIGN_DIR"
  mkdir -p "$CREWKIT_CAMPAIGN_DIR/lanes"
  cd "$MAIN" || return 1
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

# settings KEY: VALUE...: write the project's committed settings file.
settings() {
  mkdir -p "$MAIN/.claude"
  { echo ---; printf '%s\n' "$@"; echo ---; } > "$MAIN/.claude/crewkit.md"
}

none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}

# hex40 C: a well-formed commit SHA that matches nothing (C repeated 40 times).
hex40() { printf "$1%.0s" {1..40}; }

# use_stub_gh: put tests/stub-gh first on PATH as `gh`, with its state in $STUB.
use_stub_gh() {
  export STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$BATS_TEST_TMPDIR/stubbin"
  # A copy, not a symlink: a test that rewrites stubbin/gh must never write through to the repo.
  cp "$REPO/tests/stub-gh" "$BATS_TEST_TMPDIR/stubbin/gh"
  export PATH="$BATS_TEST_TMPDIR/stubbin:$PATH"
}

# stub_pr N HEAD_BRANCH BASE_BRANCH [STATE]: a PR the stub gh will report.
stub_pr() {
  mkdir -p "$STUB/pr"
  jq -n --argjson n "$1" --arg h "$2" --arg b "$3" --arg s "${4:-OPEN}" \
    '{number: $n, headRefName: $h, baseRefName: $b, state: $s}' > "$STUB/pr/$1.json"
}

# commit_on BRANCH FILE TEXT [MSG]: commit FILE=TEXT on BRANCH in $MAIN and push it.
commit_on() {
  git -C "$MAIN" checkout -q "$1" 2>/dev/null || git -C "$MAIN" checkout -q -b "$1"
  printf '%s\n' "$3" > "$MAIN/$2"
  git -C "$MAIN" add "$2"
  git -C "$MAIN" commit -qm "${4:-change $2}"
  git -C "$MAIN" push -q origin "$1"
  git -C "$MAIN" checkout -q main
}

# stub_ready_pr N LANE HEAD: an open, non-draft, mergeable PR for LANE at HEAD with green checks
# (stub_ci). Tweak it with jq afterwards.
stub_ready_pr() {
  mkdir -p "$STUB/pr"
  jq -n --argjson n "$1" --arg l "lane/$2" --arg h "$3" '{
    number: $n, headRefName: $l, baseRefName: "main", state: "OPEN", isDraft: false,
    mergeStateStatus: "CLEAN", headRefOid: $h, author: {login: "agent"},
    comments: [], closingIssuesReferences: [{number: 7}]}' > "$STUB/pr/$1.json"
  stub_ci "$3"
}

# stub_ci HEAD: green CI on HEAD, as the Actions and status APIs report it ($STUB/ci): run 100 of
# .github/workflows/ci.yml from pull_request, with jobs ci-ok and unit both successful, and no
# commit status contexts. Tweak it with ci_set.
stub_ci() {
  mkdir -p "$STUB/ci"
  jq -n --arg h "$1" '[{id: 100, path: ".github/workflows/ci.yml", event: "pull_request", head_sha: $h,
    created_at: "2026-10-26T10:00:00Z", run_attempt: 1, status: "completed", conclusion: "success"}]' > "$STUB/ci/runs.json"
  jq -n '[{run_id: 100, run_attempt: 1, name: "ci-ok", status: "completed", conclusion: "success",
      started_at: "2026-10-26T10:01:00Z", steps: []},
    {run_id: 100, run_attempt: 1, name: "unit", status: "completed", conclusion: "success",
      started_at: "2026-10-26T10:01:00Z", steps: []}]' > "$STUB/ci/jobs.json"
  echo '{"state": "success", "statuses": [], "total_count": 0}' > "$STUB/ci/status.json"
}

# ci_set FILE [JQ_ARGS...] FILTER: edit $STUB/ci/FILE.json (runs, jobs or status) with jq.
ci_set() {
  local f=$STUB/ci/$1.json
  shift
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# pr_set N [JQ_ARGS...] FILTER: edit the stub PR N with jq (e.g. pr_set 12 --arg h X '.headRefOid = $h').
pr_set() {
  local n=$1
  shift
  jq "$@" "$STUB/pr/$n.json" > "$STUB/pr/$n.tmp" && mv "$STUB/pr/$n.tmp" "$STUB/pr/$n.json"
}
