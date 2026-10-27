#!/usr/bin/env bats
# lib/settings.sh: one reader for every crewkit script's settings.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$HOME/.claude" "$PROJ/.claude"
  cd "$PROJ"
  # Only the environment the test sets.
  while IFS= read -r v; do unset "$v"; done < <(compgen -v | grep '^CREWKIT_' || true)
}

lookup() { run bash -c "source '$REPO/lib/settings.sh' && $*"; }

file() { # file PATH KEY: VALUE lines...
  local f=$1; shift
  { echo ---; printf '%s\n' "$@"; echo ---; echo; echo "Free notes below."; } > "$f"
}

@test "the default is used when nothing sets the key" {
  lookup crew_setting required_check ci-ok
  [ "$status" -eq 0 ]
  [ "$output" = ci-ok ]
}

@test "precedence (an env-OK key): env, project local, project shared, user, default" {
  file "$HOME/.claude/crewkit.md" "poll_seconds: 1"
  lookup crew_setting poll_seconds dflt; [ "$output" = 1 ]
  file "$PROJ/.claude/crewkit.md" "poll_seconds: 2"
  lookup crew_setting poll_seconds dflt; [ "$output" = 2 ]
  file "$PROJ/.claude/crewkit.local.md" "poll_seconds: 3"
  lookup crew_setting poll_seconds dflt; [ "$output" = 3 ]
  CREWKIT_POLL_SECONDS=4 lookup crew_setting poll_seconds dflt; [ "$output" = 4 ]
}

@test "a gate (file-only) key ignores CREWKIT_*, set or empty; crew_require too" {
  CREWKIT_REPO=env/r lookup crew_setting repo dflt; [ "$output" = dflt ]
  CREWKIT_REPO=env/r lookup crew_require repo; [ "$status" -eq 78 ]
  file "$PROJ/.claude/crewkit.md" "repo: shared/r" "review_model: opus"
  CREWKIT_REPO=env/r lookup crew_setting repo dflt; [ "$output" = shared/r ]
  CREWKIT_REVIEW_MODEL= lookup crew_setting review_model x; [ "$output" = opus ]
  CREWKIT_REVIEW_MODEL=claude lookup crew_setting review_model x; [ "$output" = opus ]
}

@test "a file-only prefix covers every key under it" {
  file "$PROJ/.claude/crewkit.md" "high_risk_areas.billing.paths: src/billing/**"
  CREWKIT_HIGH_RISK_AREAS_BILLING_PATHS=nomatch lookup crew_setting high_risk_areas.billing.paths x
  [ "$output" = "src/billing/**" ]
  CREWKIT_CI_WORKFLOW=other.yml lookup crew_setting ci.workflow none; [ "$output" = none ]
  CREWKIT_REVIEW_REVIEWERS=me lookup crew_setting review.reviewers none; [ "$output" = none ]
}

@test "an exact entry beats a prefix: labels.do_not_merge is file-only, other labels take env" {
  CREWKIT_LABELS_DO_NOT_MERGE=nothing lookup crew_setting labels.do_not_merge do-not-merge; [ "$output" = do-not-merge ]
  CREWKIT_LABELS_FIXED_IN_MAIN=fixed lookup crew_setting labels.fixed_in_main x; [ "$output" = fixed ]
  CREWKIT_BRANCH_PREFIX_BATCH=lane/ lookup crew_setting branch_prefix.batch batch/; [ "$output" = batch/ ]
  CREWKIT_BRANCH_PREFIX_LANE=l/ lookup crew_setting branch_prefix.lane lane/; [ "$output" = l/ ]
}

@test "a key in neither list is file-only: an unclassified key fails closed" {
  CREWKIT_BRAND_NEW_GATE=off lookup crew_setting brand_new_gate on; [ "$output" = on ]
}

@test "the project files are found from a subdirectory" {
  file "$PROJ/.claude/crewkit.md" "repo: shared/r"
  mkdir -p "$PROJ/a/b"
  cd "$PROJ/a/b"
  lookup crew_setting repo dflt
  [ "$output" = shared/r ]
}

@test "dotted keys map to CREWKIT_ env names with dots as underscores" {
  CREWKIT_GATES_TEST="make test" lookup crew_setting gates.test
  [ "$output" = "make test" ]
}

@test "values keep colons and inner spaces; quotes and trailing comments are stripped" {
  file "$PROJ/.claude/crewkit.md" \
    "health_url: https://app.example/healthz   # prod health" \
    'gates.test: "npm test -- --runInBand"' \
    "note: 'a: b'"
  lookup crew_setting health_url; [ "$output" = "https://app.example/healthz" ]
  lookup crew_setting gates.test; [ "$output" = "npm test -- --runInBand" ]
  lookup crew_setting note; [ "$output" = "a: b" ]
}

@test "only the frontmatter is read, not the notes below it" {
  { echo ---; echo "repo: fm/r"; echo ---; echo "repo: body/r"; } > "$PROJ/.claude/crewkit.md"
  lookup crew_setting repo dflt
  [ "$output" = fm/r ]
  { echo ---; echo "repo: fm/r"; echo ---; echo "only_in_body: x"; } > "$PROJ/.claude/crewkit.md"
  lookup crew_setting only_in_body dflt
  [ "$output" = dflt ]
}

@test "an empty value in a higher file overrides a lower one" {
  file "$HOME/.claude/crewkit.md" "page_command: page-me"
  file "$PROJ/.claude/crewkit.md" "page_command:"
  lookup crew_setting page_command dflt
  [ "$output" = "" ]
}

@test "crew_require exits 78 and names the key when it is unset" {
  lookup crew_require repo
  [ "$status" -eq 78 ]
  [[ $output == *"repo"* ]]
}

@test "crew_require prints the value when it is set" {
  file "$PROJ/.claude/crewkit.md" "repo: shared/r"
  lookup crew_require repo
  [ "$status" -eq 0 ]
  [ "$output" = shared/r ]
}

@test "crew_keys lists the keys under a prefix across all files, once each" {
  file "$HOME/.claude/crewkit.md" "high_risk_areas.billing.paths: src/billing/**" "high_risk_areas.auth.paths: old/**"
  file "$PROJ/.claude/crewkit.md" "high_risk_areas.auth.paths: src/auth/**" "high_risk_areas.billing.why: payments" "repo: x/y"
  lookup crew_keys high_risk_areas.
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sort | tr '\n' ' ')" = "high_risk_areas.auth.paths high_risk_areas.billing.paths high_risk_areas.billing.why " ]
}

@test "a settings file is never sourced or executed" {
  file "$PROJ/.claude/crewkit.md" 'repo: $(touch '"$BATS_TEST_TMPDIR"'/pwned)' "x: \`touch $BATS_TEST_TMPDIR/pwned2\`"
  lookup crew_setting repo
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
  [[ $output == *'$(touch'* ]]
}

@test "works under bash's set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$REPO/lib/settings.sh'; crew_setting nothing_here dflt"
  [ "$status" -eq 0 ]
  [ "$output" = dflt ]
}

@test "crew_require treats an empty value as unset" {
  file "$PROJ/.claude/crewkit.md" "repo:"
  lookup crew_require repo
  [ "$status" -eq 78 ]
}

@test "crew_keys ignores keys in the notes below the frontmatter" {
  { echo ---; echo "gates.test: t"; echo ---; echo "gates.body_only: x"; } > "$PROJ/.claude/crewkit.md"
  lookup crew_keys gates.
  [ "$output" = gates.test ]
}

@test "a file without frontmatter sets nothing" {
  printf '# Notes\nrepo: not/frontmatter\n' > "$PROJ/.claude/crewkit.md"
  lookup crew_setting repo dflt
  [ "$output" = dflt ]
}

@test "the search stops at the repo root: a settings file above the repo is not read" {
  mkdir -p "$PROJ/repo/src" "$PROJ/.claude"
  git init -q "$PROJ/repo"
  file "$PROJ/.claude/crewkit.md" "lane.setup_hook: touch $BATS_TEST_TMPDIR/pwned"
  cd "$PROJ/repo/src"
  lookup crew_setting lane.setup_hook dflt
  [ "$output" = dflt ]
}

@test "the repo's own settings file is read from inside it" {
  mkdir -p "$PROJ/repo/src" "$PROJ/repo/.claude"
  git init -q "$PROJ/repo"
  file "$PROJ/repo/.claude/crewkit.md" "repo: o/r"
  cd "$PROJ/repo/src"
  lookup crew_setting repo dflt
  [ "$output" = o/r ]
}

@test "a world-writable settings file is skipped, with a warning" {
  file "$PROJ/.claude/crewkit.md" "repo: shared/r"
  chmod 666 "$PROJ/.claude/crewkit.md"
  run bash -c "source '$REPO/lib/settings.sh' && crew_setting repo dflt"
  [ "$status" -eq 0 ]
  [[ $output == *dflt* ]]
  [[ $output == *"writable by others"* ]]
  chmod 644 "$PROJ/.claude/crewkit.md"
  lookup crew_setting repo dflt
  [ "$output" = shared/r ]
}

@test "a group-writable file is read (with a user-private group that is normal)" {
  file "$PROJ/.claude/crewkit.md" "repo: shared/r"
  chmod 664 "$PROJ/.claude/crewkit.md"
  lookup crew_setting repo dflt
  [ "$output" = shared/r ]
}

@test "a settings file you don't own is skipped, with a warning" {
  [ -O /etc/hostname ] && skip "running as root"
  ln -s /etc/hostname "$HOME/.claude/crewkit.md"
  run bash -c "source '$REPO/lib/settings.sh' && crew_setting repo dflt"
  [[ $output == *"not owned by you"* ]]
  [[ $output == *dflt* ]]
}

@test "the file list is cached per directory: a cd in the same process sees the new project" {
  mkdir -p "$PROJ/a/.claude" "$PROJ/b/.claude"
  git init -q "$PROJ/a"; git init -q "$PROJ/b"
  file "$PROJ/a/.claude/crewkit.md" "repo: a/r"
  file "$PROJ/b/.claude/crewkit.md" "repo: b/r"
  run bash -c "source '$REPO/lib/settings.sh'; cd '$PROJ/a'; crew_setting repo; cd '$PROJ/b'; crew_setting repo"
  [ "$output" = "$(printf 'a/r\nb/r')" ]
}

@test "sourcing primes the cache, so lookups in command substitutions reuse it" {
  file "$PROJ/.claude/crewkit.md" "repo: shared/r"
  run bash -c "source '$REPO/lib/settings.sh'; [ \"\$_CREW_FILES_FOR\" = \"\$PWD\" ] && echo primed; a=\$(crew_setting repo); echo \$a"
  [ "$output" = "$(printf 'primed\nshared/r')" ]
}

@test "review_model is file-only: the environment is ignored, set or empty" {
  file "$PROJ/.claude/crewkit.md" "review_model: sonnet"
  CREWKIT_REVIEW_MODEL=haiku lookup crew_setting review_model opus
  [ "$output" = sonnet ]
  CREWKIT_REVIEW_MODEL= lookup crew_setting review_model opus
  [ "$output" = sonnet ]
  rm "$PROJ/.claude/crewkit.md"
  CREWKIT_REVIEW_MODEL=haiku lookup crew_setting review_model opus
  [ "$output" = opus ]
}

@test "a file-only key: an empty value in a settings file still counts as set" {
  file "$PROJ/.claude/crewkit.md" 'review_model: ""'
  CREWKIT_REVIEW_MODEL=haiku lookup crew_setting review_model opus
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "an env-OK key still takes an empty environment value as set" {
  file "$PROJ/.claude/crewkit.md" "poll_seconds: 60"
  CREWKIT_POLL_SECONDS= lookup crew_setting poll_seconds fallback
  [ "$output" = "" ]
}

@test "crew_cd_main_checkout: from a linked worktree, the main checkout's settings apply, not the worktree's" {
  git init -q -b main "$PROJ/repo"
  git -C "$PROJ/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  mkdir -p "$PROJ/repo/.claude"
  file "$PROJ/repo/.claude/crewkit.md" "review_model: opus"
  git -C "$PROJ/repo" worktree add -q "$PROJ/wt" -b lane
  mkdir -p "$PROJ/wt/.claude" "$PROJ/wt/sub"
  file "$PROJ/wt/.claude/crewkit.local.md" 'review_model: ""'
  cd "$PROJ/wt/sub"
  lookup 'crew_cd_main_checkout && pwd && crew_setting review_model none'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(cd "$PROJ/repo" && pwd -P)" ]
  [ "${lines[1]}" = opus ]
}

@test "crew_cd_main_checkout: outside a repository it stays put and succeeds" {
  mkdir -p "$PROJ/plain"
  cd "$PROJ/plain"
  lookup 'crew_cd_main_checkout && pwd'
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/plain" ]
}

@test "crew_cd_main_checkout: a worktree of a bare repository has no main checkout, so it fails" {
  git init -q --bare -b main "$PROJ/bare.git"
  git clone -q "$PROJ/bare.git" "$PROJ/seed" 2>/dev/null
  git -C "$PROJ/seed" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
  git -C "$PROJ/seed" push -q origin main
  git -C "$PROJ/bare.git" worktree add -q "$PROJ/bare-wt" main
  cd "$PROJ/bare-wt"
  lookup 'crew_cd_main_checkout'
  [ "$status" -eq 1 ]
}

@test "a file-only prefix nested inside an env-OK prefix wins for its keys" {
  lookup 'CREW_ENV_OK="a.*"; CREW_FILE_ONLY="a.b.*"; CREWKIT_A_B_C=env CREWKIT_A_X=env; export CREWKIT_A_B_C CREWKIT_A_X; crew_setting a.b.c file; crew_setting a.x file'
  [ "${lines[0]}" = file ]
  [ "${lines[1]}" = env ]
}

@test "the classification ignores files in the current directory (no glob expansion of the lists)" {
  # A file for every prefix in both lists, in the directory lookups run from.
  local entry key var file_only env_ok
  file_only=$(bash -fc "source '$REPO/lib/settings.sh'; printf '%s\n' \$CREW_FILE_ONLY")
  env_ok=$(bash -fc "source '$REPO/lib/settings.sh'; printf '%s\n' \$CREW_ENV_OK")
  for entry in $(set -f; echo $file_only $env_ok); do
    [[ $entry == *.\* ]] && touch "$PROJ/${entry%\*}x" "$PROJ/${entry%\*}yml"
  done
  ls "$PROJ" | grep -q '^ci\.x$'
  while read -r entry; do
    key=${entry%\*}; [[ $entry == *.\* ]] && key=${key}probe
    var=CREWKIT_$(tr 'a-z.' 'A-Z_' <<<"$key")
    run env "$var=from-env" bash -c "cd '$PROJ' && source '$REPO/lib/settings.sh' && crew_setting $key dflt"
    [ "$output" = dflt ] || { echo "file-only $key took the environment"; return 1; }
  done <<<"$file_only"
  while read -r entry; do
    key=${entry%\*}; [[ $entry == *.\* ]] && key=${key}probe
    var=CREWKIT_$(tr 'a-z.' 'A-Z_' <<<"$key")
    run env "$var=from-env" bash -c "cd '$PROJ' && source '$REPO/lib/settings.sh' && crew_setting $key dflt"
    [ "$output" = from-env ] || { echo "env-OK $key refused the environment"; return 1; }
  done <<<"$env_ok"
}

@test "a nested file-only prefix still wins with a file matching it in the current directory" {
  touch "$PROJ/a.b.yml" "$PROJ/a.yml"
  lookup 'CREW_ENV_OK="a.*"; CREW_FILE_ONLY="a.b.*"; CREWKIT_A_B_C=env; export CREWKIT_A_B_C; crew_setting a.b.c file'
  [ "$output" = file ]
}

@test "a key that isn't a plain setting name is file-only (no match across two list entries)" {
  lookup '_crew_env_ok "poll_max lock_wait_seconds" && echo env || echo file; _crew_env_ok "poll*" && echo env || echo file; _crew_env_ok "" && echo env || echo file'
  [ "$output" = "file
file
file" ]
}
