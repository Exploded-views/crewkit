# settings.sh: the one settings reader every crewkit script sources.
#
#   crew_setting KEY [DEFAULT]   print the value (or DEFAULT, or nothing)
#   crew_require KEY             print the value, or exit 78 ("config") naming the key if it
#                                is unset or empty
#   crew_keys PREFIX             list the keys starting with PREFIX set in any settings file
#   crew_cd_main_checkout        cd to the repository's main checkout, so the project files
#                                come from there and never from a lane's linked worktree (which
#                                could hold its own .claude/crewkit.local.md). Outside a
#                                repository it does nothing; inside a worktree whose main
#                                checkout can't be found it returns 1 (callers exit 78).
#
# Lookup order, first match wins (an empty value counts as set):
#   1. environment  CREWKIT_<KEY>, the key upper-cased with dots as underscores
#                   (gates.test -> CREWKIT_GATES_TEST), for keys in CREW_ENV_OK only (below)
#   2. project      .claude/crewkit.local.md   (per checkout, git-ignored)
#   3. project      .claude/crewkit.md         (committed, shared by the team)
#   4. user         ~/.claude/crewkit.md
#   5. DEFAULT
# The project files are found from the current directory upwards, stopping at the repository
# root (or before $HOME outside a repository). Files not owned by you, or world-writable, are
# skipped with a warning, because settings can name commands to run.
#
# Settings files are Markdown with YAML-style frontmatter holding flat `key: value` lines;
# dotted keys group settings (`high_risk_areas.billing.paths`). Values may be quoted, and an
# unquoted ` # comment` is dropped. Only the frontmatter is read, and nothing in a settings
# file is ever sourced or run. Keys are documented in docs/settings.md.
#
# Portable to bash 3.2 (no associative arrays); safe under `set -euo pipefail`.

# Which keys the environment may set. Anything that changes whether or what merges (a gate) is
# FILE-ONLY: any session can set its own environment, so CREWKIT_* must not be able to turn a
# gate off. Entries are exact keys or prefixes ("ci.*"); an exact entry beats a prefix, and a key
# in neither list is file-only. tools/lint-skills.py fails unless every key in docs/settings.md
# is in exactly one list, so a new key gets classified in review. CREW_ENV_OK lists exact keys;
# its only prefixes are placeholder families documented "Never gates a merge" (the lint checks).
CREW_FILE_ONLY='repo main_branch required_check ci.* min_green_checks ignored_checks
  release_workflows health_url high_risk_areas.* review_model review.* labels.do_not_merge
  labels.awaiting_approval land.* state_dir campaign_dir branch_prefix.batch'
CREW_ENV_OK='checkout implement_model branch_prefix.lane branch_prefix.refresh lane.worktree_dir
  lane.note_dir lane.setup_hook lane.db_hook gates.* pool_command gh_write.min_gap_ms
  gh_write.retries gh_write.backoff_seconds gh_write.max_body_bytes labels.* owner_name
  orchestrator_name page_command notify_command poll_seconds poll_max lock_wait_seconds
  stale_seconds labels.fixed_in_main flakes_file merge_retries'

_CREW_LISTS_SRC="" _CREW_FO_FLAT="" _CREW_EO_FLAT=""
# _crew_flatten_lists: each list as one space-separated string, split with read -a (no pathname
# expansion: an unquoted $CREW_FILE_ONLY would glob "ci.*" against files in the current dir).
# Redone only when a list changes.
_crew_flatten_lists() {
  local _crew_fo=() _crew_eo=() IFS=$' \t\n'
  read -rd '' -a _crew_fo <<<"$CREW_FILE_ONLY" || true
  read -rd '' -a _crew_eo <<<"$CREW_ENV_OK" || true
  IFS=' '
  _CREW_FO_FLAT=" ${_crew_fo[*]-} " _CREW_EO_FLAT=" ${_crew_eo[*]-} "
  _CREW_LISTS_SRC="$CREW_FILE_ONLY|$CREW_ENV_OK"
}

# _crew_env_ok KEY: true if CREWKIT_* may set KEY. An exact entry first (file-only, then
# env-OK), then the key's dotted prefixes from the longest, file-only winning a tie; a key no
# entry matches is file-only. Quoted case patterns, so "*" in an entry is literal.
_crew_env_ok() {
  local key=$1 p
  # Only a plain setting name can take the environment (a space could match across two list
  # entries). The characters are spelled out: a range like [a-z] follows the locale.
  case $key in ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_.-]*) return 1 ;; esac
  [[ $_CREW_LISTS_SRC == "$CREW_FILE_ONLY|$CREW_ENV_OK" ]] || _crew_flatten_lists
  case $_CREW_FO_FLAT in *" $key "*) return 1 ;; esac
  case $_CREW_EO_FLAT in *" $key "*) return 0 ;; esac
  p=$key
  while [[ $p == *.* ]]; do
    p=${p%.*}
    case $_CREW_FO_FLAT in *" $p.* "*) return 1 ;; esac
    case $_CREW_EO_FLAT in *" $p.* "*) return 0 ;; esac
  done
  return 1
}

# _crew_find_files: set _CREW_FILES to the settings files to read, in precedence order.
# The project search goes up from the current directory and stops at the repository root (the
# first directory holding .git), or before $HOME outside a repository, so a settings file above
# the repo never applies to it. A file not owned by you, or world-writable, is skipped with a
# warning: settings can name commands to run (hooks, gates). Group-writable is allowed, since
# with a user-private group (the usual umask 002 setup) the group is just you.
_crew_find_files() {
  # Cached per working directory for the life of the process (scripts are short-lived).
  [[ ${_CREW_FILES_FOR:-} == "$PWD" ]] && return 0
  local dir=$PWD found=() f bad
  _CREW_FILES=()
  _CREW_FILES_FOR=$PWD
  while [[ -n $dir && $dir != "$HOME" ]]; do
    [[ -f $dir/.claude/crewkit.local.md ]] && found+=("$dir/.claude/crewkit.local.md")
    [[ -f $dir/.claude/crewkit.md ]] && found+=("$dir/.claude/crewkit.md")
    ((${#found[@]})) && break
    [[ -e $dir/.git || $dir == / ]] && break
    dir=${dir%/*}
    [[ -n $dir ]] || dir=/
  done
  [[ -f $HOME/.claude/crewkit.md ]] && found+=("$HOME/.claude/crewkit.md")
  ((${#found[@]})) || return 0
  bad=$'\n'$(find "${found[@]}" -perm -002 -print 2>/dev/null)$'\n'
  for f in "${found[@]}"; do
    if [[ ! -O $f ]]; then
      echo "crewkit: skipping $f: not owned by you" >&2
    elif [[ $bad == *$'\n'"$f"$'\n'* ]]; then
      echo "crewkit: skipping $f: writable by others (chmod go-w it)" >&2
    else
      _CREW_FILES+=("$f")
    fi
  done
}

crew_settings_files() {
  _crew_find_files
  ((${#_CREW_FILES[@]})) && printf '%s\n' "${_CREW_FILES[@]}"
  return 0
}

# _crew_frontmatter FILE: the frontmatter lines of FILE (nothing if it has none).
_crew_frontmatter() {
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}

# _crew_clean RAW: strip surrounding space, a trailing unquoted comment, and quotes.
_crew_clean() {
  local v=$1
  v="${v#"${v%%[![:space:]]*}"}"
  case $v in
    \"*\"*) v=${v#\"}; v=${v%%\"*} ;;
    \'*\'*) v=${v#\'}; v=${v%%\'*} ;;
    *) v=${v%%[[:space:]]#*}; v="${v%"${v##*[![:space:]]}"}" ;;
  esac
  printf '%s' "$v"
}

# The lookup awk (one fork per lookup): the environment first, then each file's frontmatter in
# precedence order. It prints "E=<value>" for an environment hit, "F=<raw value>" for a file
# hit, and nothing on a miss.
# shellcheck disable=SC2016  # an awk program: $0 and friends are awk's, not the shell's
_CREW_AWK='
  BEGIN {
    e = "CREWKIT_" toupper(k); gsub(/\./, "_", e)
    if (!fo && (e in ENVIRON)) { print "E=" ENVIRON[e]; exit }
  }
  FNR == 1 { fm = ($0 == "---"); next }
  fm && $0 == "---" { fm = 0; nextfile }
  fm && index($0, k ":") == 1 { print "F=" substr($0, length(k) + 2); exit }'

# crew_setting KEY [DEFAULT]: the environment only for keys in CREW_ENV_OK, then the files.
crew_setting() {
  local key=$1 hit fo=1
  _crew_env_ok "$key" && fo=0
  _crew_find_files   # in this shell, so the cache survives between lookups
  hit=$(awk -v k="$key" -v fo="$fo" "$_CREW_AWK" ${_CREW_FILES[@]+"${_CREW_FILES[@]}"} </dev/null)
  case $hit in
    E=*) printf '%s\n' "${hit#E=}"; return 0 ;;   # environment values are taken as they are
    F=*) _crew_clean "${hit#F=}"; printf '\n'; return 0 ;;
  esac
  if (($# > 1)); then printf '%s\n' "$2"; fi
  return 0
}

crew_require() {
  local key=$1 v
  v=$(crew_setting "$key" "")
  if [[ -z $v ]]; then
    echo "crewkit: setting '$key' is required; set it in .claude/crewkit.md (see docs/settings.md)" >&2
    exit 78
  fi
  printf '%s\n' "$v"
}

crew_cd_main_checkout() {
  local common
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ $common == */.git && -d ${common%/.git} ]] || return 1
  cd "${common%/.git}" || return 1
}

crew_keys() {
  local prefix=$1 f
  while IFS= read -r f; do
    _crew_frontmatter "$f"
  done < <(crew_settings_files) | awk -F: -v p="$prefix" '
    /^[A-Za-z0-9_.-]+:/ && index($1, p) == 1 && !seen[$1]++ { print $1 }'
}

# Find the settings files and split the key lists once when sourced; lookups in $(...)
# subshells inherit both caches.
_crew_find_files
_crew_flatten_lists
