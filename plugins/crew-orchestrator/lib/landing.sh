# landing.sh: what crew-orchestrator's landers share. Source it after lib/settings.sh.
#
#   crew_land_init TOOL [LOCK_WAIT]  read and check the settings (exit 78 on a bad one), set
#                                    the globals below, and create the state directory
#   crew_land_lock                   take <state_dir>/locks/land.lock on fd 9, or exit 75
#   g ARGS / git ARGS                gh and git with fd 9 closed, so no child holds the lock
#   say MSG / note MSG               a timestamped line on stdout / in <state_dir>/landing.log
#   ci_state SHA                     "<attempt> <conclusion>" of required_check on SHA
#   pr_state PR                      eligibility without the high-risk rule: sets PR_HEAD, PROB
#   risk_area < FILES                the first high_risk_areas area matching a changed file
#   has_verdict PR SHA               an independent verdict for exactly SHA, by lib/verdict.py (sets VWHY if not)
#
# The rules behind each are in the plugin README and docs/review-verdicts.md.

CREW_LAND_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # verdict.py sits beside this file
crew_land_config_error() { echo "crewkit: $1" >&2; exit 78; }

# crew_land_bash_ok MAJOR MINOR: the landers need bash 4.4 or later (associative arrays,
# mapfile -d). An older bash would break them in ways that can fail open, so they stop first.
crew_land_bash_ok() {
  (($1 > 4 || ($1 == 4 && $2 >= 4))) ||
    crew_land_config_error "the landers need bash 4.4 or later (this is bash $1.$2); on macOS: brew install bash"
}
crew_land_bash_ok "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
crew_land_home() { if [[ $1 == "~/"* ]]; then printf '%s' "$HOME/${1#"~/"}"; else printf '%s' "$1"; fi; }

crew_land_init() {
  local k v
  TOOL=$1
  # Settings come from the main checkout, never a lane's linked worktree (which could hold its own
  # .claude/crewkit.local.md), wherever the lander was started.
  crew_cd_main_checkout || crew_land_config_error "$TOOL: can't find this repository's main checkout to read settings from; run $TOOL there"
  R=$(crew_require repo) || exit 78
  MAIN=$(crew_setting main_branch main)
  CHECK=$(crew_setting required_check ci-ok)
  MIN_GREEN=$(crew_setting min_green_checks 1)
  IGNORED=$(crew_setting ignored_checks "")
  # Ignoring the required check could never be green: checks.py refuses it (64). Say so as config.
  IFS=, read -ra k <<<"$IGNORED"
  for v in ${k[@]+"${k[@]}"}; do
    v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
    [[ $v != "$CHECK" ]] || { echo "$TOOL: ignored_checks names the required check '$CHECK'; remove it from ignored_checks" >&2; exit 78; }
  done
  NOISE=$(crew_setting ci.noise_step_prefix "")
  DNM=$(crew_setting labels.do_not_merge do-not-merge)
  AWAIT=$(crew_setting labels.awaiting_approval awaiting-approval)
  BPFX=$(crew_setting branch_prefix.batch batch/)
  STATE=$(crew_land_home "$(crew_setting state_dir "$HOME/.local/state/crewkit")")
  CAMPAIGN=$(crew_land_home "$(crew_setting campaign_dir "$STATE/campaign")")/state.json
  POLL=$(crew_setting poll_seconds 60)
  MAXPOLLS=$(crew_setting poll_max 90)
  RETRIES=$(crew_setting merge_retries 3)
  LOCK_WAIT=${2:-$(crew_setting lock_wait_seconds 3600)}
  MARKERS=$(crew_setting review.markers "Verdict: MERGE")
  REQUIRE_SHA=$(crew_setting review.require_sha true)
  HONOR_PAUSE=$(crew_setting land.honor_merge_pause true)
  CI_WORKFLOW=$(crew_require ci.workflow) || exit 78
  CI_EVENT=$(crew_setting ci.event pull_request)
  SOURCE=$(crew_setting review.source comments)
  REVIEWERS=$(crew_setting review.reviewers "")
  # From settings files only: the environment could weaken it (a token like "claude" matches a
  # sonnet model) or empty it. An empty value in a settings file stops the model check.
  REVIEW_MODEL=$(crew_setting review_model opus)   # file-only (CREW_FILE_ONLY in settings.sh)
  VDIR=$(crew_land_home "$(crew_setting review.verdict_dir "$STATE/verdicts")")
  [[ $SOURCE == comments || $SOURCE == records ]] ||
    crew_land_config_error "setting 'review.source' must be comments or records (got '$SOURCE')"
  for v in MIN_GREEN POLL MAXPOLLS RETRIES LOCK_WAIT; do
    [[ ${!v} =~ ^[0-9]+$ ]] || crew_land_config_error "a numeric setting has the value '${!v}' (see docs/settings.md, Timing)"
  done
  [[ -n $(crew_setting high_risk_areas.confirmed_by "") ]] ||
    crew_land_config_error "setting 'high_risk_areas.confirmed_by' is unset: the high-risk areas are not confirmed, so nothing lands (see docs/settings.md)"
  AREAS=()
  while IFS= read -r k; do
    [[ $k == high_risk_areas.*.paths ]] && AREAS+=("$k")
  done < <(crew_keys high_risk_areas.)
  JOURNAL=$STATE/landing.log
  PROB="" PR_HEAD="" VWHY=""
  mkdir -p "$STATE/tmp" "$STATE/logs"
}

crew_land_lock() {
  mkdir -p "$STATE/locks"
  exec 9>"$STATE/locks/land.lock"
  flock -w "$LOCK_WAIT" 9 || { say "landing lock busy (another lander is running); try again later"; exit 75; }
}

g() { gh "$@" 9>&-; }
git() { command git "$@" 9>&-; }
say() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
note() { echo "- $(date -u +%FT%TZ) $TOOL: $*" >> "$JOURNAL"; }

# ci_state SHA: "<attempt> <conclusion>" of required_check on SHA, decided by lib/checks.py (the
# one implementation every crewkit lander uses): "success" when the required check is green and
# nothing else on the head is red or pending, "failure" when anything that counts is red, and
# empty while anything is pending.
# This gathers what checks.py reads: the head's runs, every run's jobs (checks.py takes each
# run's newest attempt), and the combined commit status. A read that fails reads as pending.
ci_state() {
  local d out rc att id
  d=$(mktemp -d "$STATE/tmp/checks.XXXXXX")
  if ! g api "repos/$R/actions/runs?head_sha=$1&per_page=100" --paginate | jq -s '[.[].workflow_runs[]?]' > "$d/runs.json" ||
    ! g api "repos/$R/commits/$1/status?per_page=100" > "$d/statuses.json"; then
    rm -rf "$d"; echo "0 "; return 0
  fi
  : > "$d/jobs.ndjson"
  for id in $(jq -r '.[].id' "$d/runs.json"); do
    # A run whose jobs can't be read could hide a red job: the whole state is pending.
    if ! g api "repos/$R/actions/runs/$id/jobs?filter=latest&per_page=100" --paginate > "$d/run-jobs.json" ||
      ! jq --arg id "$id" '.jobs[]? | . + {run_id: ($id | tonumber? // $id)}' "$d/run-jobs.json" >> "$d/jobs.ndjson"; then
      rm -rf "$d"; echo "0 "; return 0
    fi
  done
  jq -s . "$d/jobs.ndjson" > "$d/jobs.json"
  out=$(python3 "$CREW_LAND_LIB/checks.py" --head "$1" --required-check "$CHECK" --workflow "$CI_WORKFLOW" \
    --event "$CI_EVENT" --runs-json "$d/runs.json" --jobs-json "$d/jobs.json" --statuses-json "$d/statuses.json" \
    --ignored "$IGNORED" --min-green "$MIN_GREEN" --noise-step-prefix "$NOISE" 2>/dev/null)
  rc=$?
  rm -rf "$d"
  att=$(sed -n 's/^attempt: //p' <<<"$out")
  case $rc in
    0) echo "${att:-1} success" ;;
    31) echo "${att:-1} failure" ;;
    *) echo "${att:-0} " ;;
  esac
}

# gate_check PR: owner gates (by PR or by lane) and the merge pause, from the campaign state
# (docs/campaign-state.md); a missing file or key takes the schema's default. Sets PROB.
gate_check() {
  [[ -e $CAMPAIGN ]] || return 0
  # A state that can't be read, or isn't a JSON object, holds everything: an empty read would
  # otherwise open every gate.
  if [[ ! -r $CAMPAIGN ]] || ! jq -e 'type == "object"' "$CAMPAIGN" >/dev/null 2>&1; then
    PROB="campaign-unreadable($CAMPAIGN)"; return
  fi
  if [[ $(jq -r '.ownerPresent // false' "$CAMPAIGN") != true ]] &&
    [[ $(jq -r --arg pr "$1" '((.ownerGatedPrs // []) | map(tostring) | index($pr) != null)
      or ((.ownerGatedLanes // []) as $gl | [(.lanes // {}) | to_entries[]
          | select((.value.pr | tostring) == $pr and (.key as $k | $gl | index($k) != null))] | length > 0)' "$CAMPAIGN") == true ]]; then
    PROB="owner-gated(ownerPresent=false)"; return
  fi
  # The lane's own record of its head must be the PR's head, exactly: otherwise the lane's view
  # (and any review it asked for) is stale.
  local lane
  lane=$(lane_of "$1" '"\(.key)\t\(.value.headSha // "")"')
  if [[ -n $lane && ${lane#*$'\t'} != "" && ${lane#*$'\t'} != "$PR_HEAD" ]]; then
    lane=${lane#*$'\t'}
    PROB="lane-head-stale($(lane_of "$1" '.key') reports ${lane:0:9})"; return
  fi
  if [[ $HONOR_PAUSE == true && $(jq -r '.mergePaused // false' "$CAMPAIGN") == true ]] &&
    [[ $(jq -r --arg pr "$1" '(.mergePauseExempt // []) | map(tostring) | index($pr) != null' "$CAMPAIGN") != true ]]; then
    PROB="merge-paused"
  fi
}

# lane_of PR JQ: JQ applied to the campaign lane entry ({key, value}) whose pr is PR; nothing
# when there is no such lane or no campaign state.
lane_of() {
  [[ -f $CAMPAIGN ]] || return 0
  jq -r --arg pr "$1" "[(.lanes // {}) | to_entries[] | select((.value.pr | tostring) == \$pr)] | first // empty | $2" "$CAMPAIGN" 2>/dev/null
}

# pr_state PR: sets PR_HEAD, and PROB ("" when the PR may land, apart from the high-risk rule).
pr_state() {
  local info st draft base ref labels
  PROB="" PR_HEAD=""
  info=$(g pr view "$1" -R "$R" --json state,isDraft,headRefOid,baseRefName,headRefName,labels) || { PROB=unreadable; return; }
  IFS=$'\t' read -r st draft PR_HEAD base ref labels < <(jq -r '[.state, .isDraft, .headRefOid, .baseRefName, .headRefName, ([.labels[].name] | join(","))] | @tsv' <<<"$info")
  if [[ $st != OPEN || $draft != false ]]; then PROB="not-ready($st,draft=$draft)"; return; fi
  [[ $base == "$MAIN" ]] || { PROB="base-is-$base-not-$MAIN"; return; }
  [[ $ref != "$BPFX"* ]] || { PROB="batch-branch-head($ref)"; return; }
  case ",${labels:-}," in *",$DNM,"* | *",$AWAIT,"*) PROB="blocked-label($labels)"; return ;; esac
  gate_check "$1"
}

# risk_area < FILES: the first high-risk area whose globs match one of the changed files on
# stdin, NUL-separated ("" if none): every path a change touches, both sides of a rename, never
# C-quoted. In a glob, * matches across directories, so a glob over-matches rather than misses.
risk_area() {
  local files=() f k globs glob area
  mapfile -d '' files || return 1   # unread files are not "no high-risk files"
  for k in ${AREAS[@]+"${AREAS[@]}"}; do
    area=${k#high_risk_areas.}; area=${area%.paths}
    IFS=, read -ra globs <<<"$(crew_setting "$k")"   # settings-keys: high_risk_areas.<name>.paths
    for glob in ${globs[@]+"${globs[@]}"}; do
      glob="${glob#"${glob%%[![:space:]]*}"}"; glob="${glob%"${glob##*[![:space:]]}"}"
      [[ -n $glob ]] || continue
      for f in ${files[@]+"${files[@]}"}; do
        # shellcheck disable=SC2053  # the glob is a pattern on purpose
        [[ -n $f && $f == $glob ]] && { echo "$area"; return 0; }
      done
    done
  done
  return 0
}

# has_verdict PR SHA: an independent verdict for exactly SHA, from review.source, decided by
# lib/verdict.py, the one verdict implementation every crewkit lander uses (its rules are in
# docs/review-verdicts.md). Sets VWHY when there is none.
#   comments  every conversation comment on the PR (all pages), with the PR's author, the
#             review.reviewers allow-list, review.markers and review.require_sha
#   records   <review.verdict_dir>/<pr>/, with the campaign lane's implementer when the PR has a
#             lane, and review.reviewers
# Both pass review_model: has_verdict runs only for high-risk PRs, whose verdict must come from
# that model (docs/review-verdicts.md, "The review model"). An empty review_model checks none.
has_verdict() {
  local author out rc limpl args f
  VWHY=""
  if [[ $SOURCE == comments ]]; then
    author=$(g pr view "$1" -R "$R" --json author | jq -r '.author.login // ""') ||
      { VWHY="the PR's author can't be read"; return 1; }
    # gh names a GitHub App author app/<slug>; its REST comments say <slug>[bot]. Same account.
    [[ $author != app/* ]] || author="${author#app/}[bot]"
    # Without a named author, "not the PR's author" protects nothing.
    [[ -n $author ]] || { VWHY="the PR's author can't be named"; return 1; }
    f=$(mktemp "$STATE/tmp/comments.XXXXXX")
    if ! g api "repos/$R/issues/$1/comments?per_page=100" --paginate | jq -s 'add // []' > "$f"; then
      rm -f "$f"; VWHY="the PR's comments can't be read"; return 1
    fi
    out=$(python3 "$CREW_LAND_LIB/verdict.py" comments --head "$2" --author "$author" --comments-json "$f" \
      --reviewers "$REVIEWERS" --markers "$MARKERS" --require-sha "$REQUIRE_SHA" --model "$REVIEW_MODEL" 2>&1)
    rc=$?
    rm -f "$f"
  else
    limpl=$(lane_of "$1" '.value.implementer // ""')
    args=(records --pr "$1" --head "$2" --dir "$VDIR" --reviewers "$REVIEWERS" --model "$REVIEW_MODEL")
    [[ -z $limpl ]] || args+=(--lane-implementer "$limpl")
    out=$(python3 "$CREW_LAND_LIB/verdict.py" "${args[@]}" 2>&1)
    rc=$?
  fi
  ((rc == 0)) && return 0
  VWHY=${out#not accepted: }
  return 1
}
