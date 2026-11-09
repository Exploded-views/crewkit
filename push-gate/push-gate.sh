#!/usr/bin/env bash
# push-gate.sh: the host-wide pre-push gate. Refuses a push whose new commits or pushed tree
# hold a private denylist term or a secret.
#
#   push-gate.sh hook REMOTE URL     the gate itself; git's pre-push lines on stdin
#                                    ("<local-ref> <local-sha> <remote-ref> <remote-sha>")
#   push-gate.sh install [--yes]     copy the gate to ~/.local/share/crewkit/gate and point the
#                                    global core.hooksPath at its dispatcher (dry run without --yes)
#   push-gate.sh status --json       {"installed":bool,"denylist":bool}
#   push-gate.sh --doctor            every check, one line each: <check-id> <ok|FAIL> <detail>
#   push-gate.sh gate-check [REPO]   the checks that decide whether pushes from REPO are gated
#   push-gate.sh shim REPO [--yes]   for a repo with its own core.hooksPath (husky, lefthook),
#                                    which bypasses the global dispatcher: add the one-line shim
#                                    to its pre-push, chaining any pre-push already there
#   push-gate.sh doctor-watch        --doctor, for a schedule: when the set of FAIL checks changes,
#                                    one pointer line (check ids only) to push_gate.notify_command
#   push-gate.sh schedule [--yes]    run the installed gate's doctor-watch hourly: a launchd agent
#                                    (macOS) or a systemd user timer (Linux)
#
# Settings (docs/settings.md), user-only, so no repository or environment can redirect them:
# push_gate.denylist, push_gate.exempt, push_gate.gitleaks, push_gate.log, push_gate.root.
#
# The hook fails closed: no gitleaks, a gitleaks that isn't the verified install, a missing,
# empty or invalid denylist, and any git or grep error all refuse the push. An empty result
# counts as clean only when the command that made it succeeded (docs/push-gate.md lists each
# place). The exempt file's regex lines skip the denylist (not gitleaks) for matching push
# URLs; a "skip-all <regex>" line skips every check. Output names commits, paths and counts,
# never the matched text. Each hook run appends one line to the log; a log failure never blocks.
# A push to a local path publishes nothing and isn't gated, unless it is on a mount or in a
# synced folder (local_unpublished); PUSH_GATE_LOCAL=1 gates every one (tests).
#
# Exit (docs/exit-codes.md): hook 0 = pass, 1 = blocked; install 0 = done or dry run,
# 1 = refused, 78 = an owner step first; --doctor, gate-check and doctor-watch 0 = healthy,
# 1 = a FAIL, 2 = their own error; schedule 0 = done or dry run, 1 = failed, 78 = install the
# gate first; 64 = usage.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # not -P: a test tree of symlinks works
root=${here%/*}
# shellcheck source=SCRIPTDIR/../lib/settings.sh
source "$root/lib/settings.sh"
GATE_DIR=$HOME/.local/share/crewkit/gate
SHIM_MARK='# crewkit push-gate shim'
# One line: says why and refuses when the gate's installed copy is gone, else runs the gate.
SHIM_LINE="[ -r \"\$HOME/.local/share/crewkit/gate/push-gate/shim.sh\" ] || { echo \"push-gate shim: the gate isn't installed at ~/.local/share/crewkit/gate (push-gate.sh install --yes); refusing the push\" >&2; exit 1; }; . \"\$HOME/.local/share/crewkit/gate/push-gate/shim.sh\"  $SHIM_MARK"
SHELL_SHEBANG='^#!(/usr/bin/env )?(/bin/)?(sh|bash|dash|zsh)([[:space:]]|$)'

# setting KEY DEFAULT: a user-only setting, with a leading ~/ meaning $HOME.
setting() {
  local v
  v=$(crew_setting "$1" "$2") || return 1
  # shellcheck disable=SC2088  # a literal ~/ in the value
  [[ $v == '~/'* ]] && v=$HOME/${v#'~/'}
  printf '%s\n' "$v"
}
# tilde PATH: PATH with $HOME shown as ~ (also $HOME with its symlinks resolved, as git prints a
# worktree's path); outside $HOME, only its last part.
# shellcheck disable=SC2088  # printed for people, not expanded
tilde() {
  [[ -n ${home_p:-} ]] || home_p=$(cd "$HOME" 2>/dev/null && pwd -P) || home_p=$HOME
  case $1 in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    "$home_p"/*) printf '~/%s\n' "${1#"$home_p"/}" ;;
    *) printf '(outside ~)/%s\n' "${1##*/}" ;;
  esac
}
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

load_settings() {
  denylist=$(setting push_gate.denylist "$HOME/.config/crewkit/denylist.txt") &&
    exempt=$(setting push_gate.exempt "$HOME/.config/crewkit/push-gate-exempt") &&
    gitleaks=$(setting push_gate.gitleaks "$HOME/.local/share/crewkit/gitleaks/gitleaks") &&
    log=$(setting push_gate.log "$HOME/.local/state/crewkit/push-gate.log") &&
    scan_root=$(setting push_gate.root "") &&
    notify=$(setting push_gate.notify_command "")
}

# denylist_problem: why the denylist can't gate (empty output when it can). PATS gets its patterns.
denylist_problem() {
  [[ -r $denylist ]] || { echo "no denylist at $(tilde "$denylist")"; return; }
  grep -Ev '^[[:space:]]*(#|$)' "$denylist" > "$pats"; local rc=$?
  ((rc <= 1)) || { echo "the denylist at $(tilde "$denylist") can't be read"; return; }
  [[ -s $pats ]] || { echo "the denylist at $(tilde "$denylist") has no patterns"; return; }
  # grep exits 2 on an invalid pattern and prints nothing, which would read as "no hits"
  grep -Eq -f "$pats" </dev/null 2>/dev/null
  (($? == 2)) && echo "the denylist at $(tilde "$denylist") has an invalid pattern"
}

# gitleaks_problem [RECORD]: why gitleaks can't be trusted (empty when it can): it must be the
# binary install.sh verified against pins/gitleaks.env, whose sha256 sits beside it. A sidecar
# can be rewritten along with its binary, and push_gate.gitleaks can name any binary with any
# sidecar, so with RECORD (the gate's own copy of that sha256, written by push-gate.sh install)
# the binary must match that too.
gitleaks_problem() {
  [[ -x $gitleaks ]] || { echo "no gitleaks at $(tilde "$gitleaks") (install.sh --only gitleaks)"; return; }
  [[ -r $gitleaks.sha256 ]] || { echo "gitleaks at $(tilde "$gitleaks") has no recorded sha256 (install.sh --only gitleaks)"; return; }
  local want got
  want=$(head -c 64 "$gitleaks.sha256") got=$(sha256 "$gitleaks")
  [[ $want =~ ^[0-9a-f]{64}$ && $got == "$want" ]] ||
    { echo "gitleaks at $(tilde "$gitleaks") is not the verified install (sha256 differs; install.sh --only gitleaks)"; return; }
  [[ -z ${1:-} || $(head -c 64 "$1" 2>/dev/null) == "$got" ]] ||
    echo "gitleaks at $(tilde "$gitleaks") is not the one the gate recorded at install (push-gate.sh install again after install.sh --only gitleaks)"
}

# Diffs as git stores them: --text, so a binary or "-diff" attribute can't turn a diff into
# "Binary files differ"; no textconv filter and no external diff, which a repository's config
# or attributes choose and could make print nothing.
NODIFF=(--text --no-textconv --no-ext-diff)

# g: git for the scans. A repository's own refs and config can change what git prints; here they
# can't: no replace refs (a clean commit swapped in for the pushed one) and no grafts, UTF-8
# output whatever i18n.logOutputEncoding says, paths unescaped (core.quotePath would hide a
# non-ASCII term), a root commit's diff shown, and the keys that reshape a diff, a log or git
# grep's output pinned to git's defaults.
g() {
  GIT_GRAFT_FILE=/dev/null git --no-replace-objects -c advice.graftFileDeprecated=false \
    -c i18n.logOutputEncoding=UTF-8 -c core.quotePath=false -c log.showRoot=true \
    -c log.showSignature=false -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c diff.renames=false -c diff.relative=false -c color.ui=never -c grep.patternType=extended \
    -c grep.fullName=false -c grep.column=false -c grep.lineNumber=false "$@"
}

# added_only: the log without the lines a diff hunk removes (as gitleaks git, which scans added
# lines: taking a secret out isn't a new leak). Only inside a hunk, from an @@ line to the next
# "commit <sha>" line: the headers are "Author:"/"Commit:" lines and the message is indented,
# so no header or message line can start a hunk or be dropped.
added_only() { awk '/^commit [0-9a-f]+$/ { h = 0 } /^@@/ { h = 1 } !(h && /^-/)'; }

# remote_has: "^<sha>" for each commit the push URL already has (git ls-remote) that this
# repository holds: what git push itself leaves out. Empty when the URL can't be listed: then
# a new ref's whole history is scanned.
remote_has() {
  [[ $url == -* ]] && return 0   # never an option to ls-remote
  GIT_TERMINAL_PROMPT=0 git ls-remote "$url" 2>/dev/null | cut -f1 | LC_ALL=C sort -u |
    g cat-file --batch-check='%(objecttype) %(objectname)' 2>/dev/null | sed -n 's/^commit /^/p'
  return 0
}

# gl_scan: gitleaks on stdin with the gate's own config (gitleaks-rules.toml beside this script), from
# an empty directory of its own with that directory as the ignore path, and no GITLEAKS_*
# variables, so nothing a repository or the environment holds (.gitleaks.toml, .gitleaksignore,
# $GITLEAKS_CONFIG, an inline gitleaks:allow) switches a rule off. Exit: gitleaks's.
gl_scan() (
  cd "$glwd" || exit 2
  unset "${!GITLEAKS_@}"
  exec "$gitleaks" stdin --no-banner --redact --log-level error --config "$here/gitleaks-rules.toml" \
    --gitleaks-ignore-path "$glwd" --ignore-gitleaks-allow >/dev/null 2>&1
)

# local_unpublished: the push URL is a local directory that stays on this machine. It fails
# closed: the directory (symlinks resolved; one that can't be resolved is gated) must be on the
# same device as $HOME, so any other mount is gated (/Volumes, NFS, SMB, //server, a USB disk),
# and not in a synced folder (iCloud Drive, Dropbox, Google Drive, OneDrive,
# ~/Library/CloudStorage), matched in any letter case: APFS is case-insensitive.
local_unpublished() {
  local d lc dev
  [[ $url == //* ]] && return 1
  d=$(cd "${url#file://}" 2>/dev/null && pwd -P) || return 1
  dev=$(device "$d") && [[ -n $dev && $dev == "$(device "$HOME")" ]] || return 1
  lc=$(tr '[:upper:]' '[:lower:]' <<<"$d/")
  case $lc in
    /volumes/* | /mnt/* | /media/* | /net/* | /run/media/* | */library/cloudstorage/* | */mobile\ documents/* | \
      */dropbox/* | */dropbox\ */* | */google\ drive/* | */onedrive/* | */onedrive\ */*) return 1 ;;
  esac
}
# device PATH: the device number of the file system PATH is on (GNU stat, then BSD stat).
device() { stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------------------------
# hook
cmd_hook() {
  local url=${2:-} shown
  # The URL as logged: without its userinfo (the part before an @ in the host), where a token
  # often sits.
  shown=$(sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#' <<<"$url")
  say() { echo "push-gate: $*" >&2; }
  lg() { { mkdir -p "${log%/*}" && printf '%s %s %s %s %s\n' "$(date -u +%FT%TZ)" "$1" \
    "$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")" "$shown" "${2:-}" >> "$log"; } 2>/dev/null || true; }
  block() { lg BLOCKED "$*"; say "BLOCKED: $*"; say "fix the commits (amend or rebase), then push again. Only the owner may bypass."; exit 1; }
  fatal() { lg BLOCKED "gate error"; say "gate error: refusing push ($*)"; exit 1; }

  load_settings || { log=/dev/null; fatal "the settings can't be read"; }
  if [[ -z ${PUSH_GATE_LOCAL:-} && ( $url == /* || $url == file://* ) ]] && local_unpublished; then exit 0; fi

  local deny=1 skip rc
  if [[ -e $exempt ]]; then
    skip=$(sed -n 's/^skip-all[[:space:]]\{1,\}//p' "$exempt") || fatal "the exempt file can't be read"
    if [[ -n $skip ]]; then
      grep -Eq -f <(printf '%s\n' "$skip") <<<"$url"; rc=$?
      ((rc == 0)) && { lg SKIP; exit 0; }
      ((rc == 1)) || fatal "the exempt file has an invalid skip-all pattern"
    fi
    grep -Eq -f <(grep -Ev '^[[:space:]]*(#|$|skip-all[[:space:]]|gate-exempt[[:space:]])' "$exempt") <<<"$url"; rc=$?
    ((rc == 0)) && deny=0
    ((rc <= 1)) || fatal "the exempt file has an invalid pattern"
  fi

  local p
  p=$(gitleaks_problem "$root/gitleaks.sha256"); [[ -z $p ]] || block "$p"
  pats=$(mktemp) || fatal "mktemp failed"
  glwd=$(mktemp -d) || fatal "mktemp failed"
  trap 'rm -rf "$pats" "$glwd"' EXIT
  if ((deny)); then p=$(denylist_problem); [[ -z $p ]] || block "$p"; fi

  local findings=0 _ lsha rref rsha ref commits c body n hits hit path f names revs t ty tags have='' listed=0
  while read -r _ lsha rref rsha; do
    [[ -z ${lsha:-} || $lsha =~ ^0+$ ]] && continue   # a delete: all zeros, 40 or 64 of them
    [[ $lsha =~ ^[0-9a-f]{40,64}$ && ${rsha:-} =~ ^[0-9a-f]{40,64}$ ]] || fatal "a pre-push line git didn't write"
    g cat-file -e "$lsha^{commit}" 2>/dev/null || fatal "the pushed commit isn't in this repository"
    # An annotated tag, and any tag it points to: the message, tagger and signature are scanned
    # too (indented, so no line of theirs can start a hunk for added_only).
    tags='' t=$lsha
    while :; do
      ty=$(g cat-file -t "$t") || fatal "git cat-file failed on the pushed object"
      [[ $ty == tag ]] || break
      body=$(g cat-file tag "$t") || fatal "git cat-file failed on a tag"
      tags+="    ${body//$'\n'/$'\n    '}"$'\n'
      t=$(sed -n '1s/^object //p' <<<"$body")
    done
    # The new commits: rsha..lsha for an update; for a new ref, lsha down to what the push URL
    # already has (remote_has), not to local tracking refs, which any process can move (git
    # update-ref) and which, with a pushurl, track another remote. git reads them on stdin.
    if [[ ! $rsha =~ ^0+$ ]] && g cat-file -e "$rsha^{commit}" 2>/dev/null; then
      revs=$lsha$'\n'"^$rsha"
    else
      ((listed)) || { have=$(remote_has); listed=1; }
      revs=$lsha$'\n'$have
    fi
    ref=$rref   # a branch name holding a term is itself a finding, and never printed
    if ((deny)); then
      grep -Eiq -f "$pats" <<<"$rref"; rc=$?
      ((rc <= 1)) || fatal "grep failed on the branch name"
      if ((rc == 0)); then
        ref="(a branch name that holds a term)"; say "denylist: the pushed branch name holds a term; rename it"; findings=1
      fi
      if [[ -n $tags ]]; then
        n=$(grep -Eic -f "$pats" <<<"$tags"); rc=$?
        ((rc <= 1)) || fatal "grep failed on a tag"
        ((n > 0)) && { say "denylist: the annotated tag $ref (message or tagger): $n line(s)"; findings=1; }
      fi
      commits=$(g rev-list --stdin <<<"$revs") || fatal "git rev-list failed"
      for c in $commits; do
        body=$(g show --no-color "${NODIFF[@]}" --format='%an <%ae>%n%cn <%ce>%n%B' "$c") || fatal "git show failed for a commit"
        n=$(grep -Eic -f "$pats" <<<"$body"); rc=$?
        ((rc <= 1)) || fatal "grep failed on a commit"
        ((n > 0)) && { say "denylist: commit $(git rev-parse --short "$c") (message, author or diff): $n line(s)"; findings=1; }
      done
      hits=$(g grep -a -Eic -f "$pats" "$lsha" -- 2>/dev/null); rc=$?
      ((rc <= 1)) || fatal "git grep failed on the pushed tree"
      while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        path=${hit#"$lsha":}; f=${path%:*}
        grep -Eiq -f "$pats" <<<"$f"; rc=$?
        ((rc <= 1)) || fatal "grep failed on a path"   # never print a path it couldn't check
        ((rc == 0)) && f="(a path that itself holds a term)"
        say "denylist: file $f in $ref: ${path##*:} line(s)"; findings=1
      done <<<"$hits"
      names=$(g ls-tree -r --name-only "$lsha") || fatal "git ls-tree failed on the pushed tree"
      n=$(grep -Eic -f "$pats" <<<"$names"); rc=$?
      ((rc <= 1)) || fatal "grep failed on the pushed paths"
      ((n > 0)) && { say "denylist: $n file path(s) in $ref contain a term"; findings=1; }
    fi
    # gitleaks reads the tags, then the range's headers, messages and added lines, on stdin.
    # Exit: gitleaks's, or git's.
    { printf '%s' "$tags"
      g log -p --cc -U0 --no-color "${NODIFF[@]}" --stdin \
        --format='commit %H%nAuthor: %an <%ae>%nCommit: %cn <%ce>%n%n%w(0,4,4)%B' -- <<<"$revs"
    } | added_only | gl_scan; rc=$?
    if ((rc != 0)); then
      say "gitleaks: a secret in the commits for $ref, or gitleaks failed (exit $rc; to see it: git log -p --text --no-textconv <the new commits> | gitleaks stdin --config $(tilde "$here/gitleaks-rules.toml") --redact -v)"; findings=1
    fi
  done
  ((findings)) && block "remove the findings above"
  lg PASS
  exit 0
}

# ---------------------------------------------------------------------------------------------
# checks shared by --doctor, gate-check, status and install. Each prints one
# "<check-id> <ok|FAIL> <detail>" line and returns 0 for ok, 1 for FAIL.
report() { printf '%s %s %s\n' "$1" "$2" "$3"; [[ $2 == ok ]]; }

GATE_FILES=(push-gate/push-gate.sh push-gate/hooks/_dispatch push-gate/shim.sh push-gate/gitleaks-rules.toml)
tree_version() { (cd "$1" && cat "${GATE_FILES[@]}") | sha256 /dev/stdin | cut -c1-12; }
gate_version() { (cd "$GATE_DIR" 2>/dev/null && cat "${GATE_FILES[@]}" 2>/dev/null) | sha256 /dev/stdin | cut -c1-12; }

check_global() {
  local hp
  hp=$(git config --global core.hooksPath 2>/dev/null)
  # shellcheck disable=SC2088  # a literal ~/ in git's config
  [[ $hp == '~/'* ]] && hp=$HOME/${hp#'~/'}
  if [[ -z $hp ]]; then report global-gate FAIL "no global core.hooksPath (push-gate.sh install)"
  elif [[ ${hp%/} != "$GATE_DIR/push-gate/hooks" ]]; then report global-gate FAIL "the global core.hooksPath is $(tilde "$hp"), not the gate"
  elif [[ ! -x $GATE_DIR/push-gate/hooks/pre-push ]]; then report global-gate FAIL "the global core.hooksPath has no pre-push dispatcher"
  else report global-gate ok "$(tilde "$hp")"
  fi
}
check_dispatcher() {
  local want got src=$root
  [[ -f $GATE_DIR/push-gate/push-gate.sh ]] || { report dispatcher FAIL "not installed (push-gate.sh install)"; return; }
  # Run from the installed copy (the scheduled doctor), "this crewkit" is the clone it was
  # installed from (install records it): comparing the copy with itself would always pass.
  if [[ $root -ef $GATE_DIR ]]; then
    if ! src=$(cat "$GATE_DIR/source" 2>/dev/null) || [[ ! -f $src/push-gate/push-gate.sh ]]; then
      report dispatcher FAIL "the crewkit it was installed from is gone (push-gate.sh install, from the crewkit clone)"; return
    fi
  fi
  want=$(tree_version "$src") got=$(gate_version)
  if [[ $got == "$want" ]]; then report dispatcher ok "$got"
  else report dispatcher FAIL "installed $got, this crewkit $want (push-gate.sh install)"
  fi
}
check_denylist() {
  local p; p=$(denylist_problem)
  if [[ -z $p ]]; then report denylist ok "$(tilde "$denylist")"; else report denylist FAIL "$p"; fi
}
check_gitleaks() {
  local p; p=$(gitleaks_problem)
  # Once the gate is installed, gitleaks must also match the gate's own record.
  [[ -f $GATE_DIR/push-gate/push-gate.sh ]] && p=$(gitleaks_problem "$GATE_DIR/gitleaks.sha256")
  if [[ -z $p ]]; then report gitleaks ok "$(tilde "$gitleaks") $(head -c 12 "$gitleaks.sha256")"; else report gitleaks FAIL "$p"; fi
}
# check_exempt: the exempt file is the owner's, so it isn't a FAIL, but a change to it (a
# skip-all line added) must be seen: pattern counts and a fingerprint, never the patterns.
# doctor-watch notifies when this line changes. An unreadable file or an invalid pattern
# refuses every push to a gated remote: a FAIL.
check_exempt() {
  [[ -e $exempt ]] || { report exempt ok "none (every remote gated)"; return; }
  local lines skip ex set
  lines=$(cat "$exempt") || { report exempt FAIL "the exempt file at $(tilde "$exempt") can't be read"; return; }
  skip=$(sed -n 's/^skip-all[[:space:]]\{1,\}//p' <<<"$lines")
  ex=$(grep -Ev '^[[:space:]]*(#|$|skip-all[[:space:]]|gate-exempt[[:space:]])' <<<"$lines")
  for set in "$skip" "$ex"; do
    [[ -z $set ]] && continue
    grep -Eq -f <(printf '%s\n' "$set") </dev/null
    (($? == 2)) && { report exempt FAIL "the exempt file at $(tilde "$exempt") has an invalid pattern"; return; }
  done
  report exempt ok "$(nlines "$ex") exempt, $(nlines "$skip") skip-all (sha256 $(sha256 "$exempt" | cut -c1-12))"
}
nlines() { if [[ -z $1 ]]; then echo 0; else grep -c '' <<<"$1"; fi; }

# hooks_path DIR: the core.hooksPath git uses for DIR, as an absolute path without a trailing
# slash; empty when none is set. It's git's own reading, every scope and include applied:
# config.worktree, include.path, and an includeIf in ~/.gitconfig, which is how a client tree
# gets hooks of its own (--local or --global alone sees none of those). 1 when git can't read it.
hooks_path() {
  local hp rc top
  hp=$(git -C "$1" config --type=path --get core.hooksPath 2>/dev/null); rc=$?
  ((rc == 1)) && return 0
  ((rc == 0)) || return 1
  [[ -n $hp ]] || return 0   # set to empty: git then runs no hooks at all
  if [[ $hp != /* ]]; then top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1; hp=$top/$hp; fi
  printf '%s\n' "${hp%/}"
}
global_hooks_path() { local hp; hp=$(git config --global --type=path core.hooksPath 2>/dev/null); printf '%s\n' "${hp%/}"; }

# has_shim FILE: FILE is an executable shell script whose line 2 is the shim, so nothing runs
# before it (an "exit 0" above the shim would skip the gate).
has_shim() {
  [[ -x $1 ]] && head -1 "$1" | grep -Eq "$SHELL_SHEBANG" && [[ $(sed -n 2p "$1") == "$SHIM_LINE" ]]
}

# check_repo DIR: ok when pushes from DIR go through the gate: the core.hooksPath git uses there
# is the gate's dispatcher, or a directory whose pre-push has the shim.
check_repo() {
  local dir=$1 hp id
  id="repo:$(tilde "$dir")"
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || ! hp=$(hooks_path "$dir"); then
    report "$id" FAIL "not a readable git repository"; return
  fi
  if [[ -z $hp ]]; then report "$id" FAIL "no core.hooksPath applies: git runs only the repository's own hooks (push-gate.sh install)"
  elif [[ $hp == "$GATE_DIR/push-gate/hooks" && -x $hp/pre-push ]]; then report "$id" ok "the gate's dispatcher"
  elif has_shim "$hp/pre-push"; then report "$id" ok "its own core.hooksPath, with the shim"
  else report "$id" FAIL "its own core.hooksPath bypasses the gate (push-gate.sh shim $(tilde "$dir") --yes)"
  fi
}
# repos_under DIR: every git repository at most 4 levels down (main checkouts, not worktrees).
repos_under() { find "$1" -maxdepth 4 -type d -name .git -prune -print | sed 's|/\.git$||' | LC_ALL=C sort; }

cmd_doctor() {
  load_settings || { echo "push-gate: the settings can't be read" >&2; exit 2; }
  pats=$(mktemp) || exit 2; trap 'rm -f "$pats"' EXIT
  local bad=0 r list
  check_global || bad=1
  check_dispatcher || bad=1
  check_denylist || bad=1
  check_gitleaks || bad=1
  check_exempt || bad=1
  if [[ -z $scan_root ]]; then report root FAIL "push_gate.root is not set (docs/settings.md)"; bad=1
  elif [[ ! -d $scan_root ]]; then report root FAIL "push_gate.root $(tilde "$scan_root") is not a directory"; bad=1
  else
    list=$(repos_under "$scan_root") || { echo "push-gate: can't list the repositories under $(tilde "$scan_root")" >&2; exit 2; }
    report root ok "$(tilde "$scan_root"): $(grep -c . <<<"$list") repositories"
    # Only a checkout whose core.hooksPath (git's own reading) isn't the global one gets a line:
    # the global-gate check covers the rest. Every worktree counts: config.worktree is per worktree.
    local ghp wts w hp
    ghp=$(global_hooks_path)
    while IFS= read -r r; do
      [[ -n $r ]] || continue
      wts=$(git -C "$r" worktree list --porcelain 2>/dev/null | sed -n '2,$s/^worktree //p') || wts=''
      while IFS= read -r w; do
        [[ -n $w ]] || continue
        hp=$(hooks_path "$w") && [[ $hp == "$ghp" ]] && continue
        check_repo "$w" || bad=1
      done <<<"$r"$'\n'"$wts"
    done <<<"$list"
  fi
  exit "$bad"
}

cmd_gate_check() {
  local dir=${1:-.} bad=0
  load_settings || { echo "push-gate: the settings can't be read" >&2; exit 2; }
  pats=$(mktemp) || exit 2; trap 'rm -f "$pats"' EXIT
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo "push-gate: $(tilde "$(cd "$dir" 2>/dev/null && pwd || echo "$dir")") is not a git repository" >&2; exit 2; }
  if [[ $(hooks_path "$dir") == "$(global_hooks_path)" ]]; then check_global || bad=1; fi
  check_dispatcher || bad=1
  check_denylist || bad=1
  check_gitleaks || bad=1
  check_repo "$(cd "$dir" && pwd)" || bad=1
  exit "$bad"
}

cmd_status() {
  [[ ${1:-} == --json ]] || usage
  load_settings || exit 2
  pats=$(mktemp) || exit 2; trap 'rm -f "$pats"' EXIT
  local i=false d=false
  check_global >/dev/null && check_dispatcher >/dev/null && i=true
  check_denylist >/dev/null && d=true
  printf '{"installed":%s,"denylist":%s}\n' "$i" "$d"
}

cmd_install() {
  local yes=0 hp
  case ${1:-} in --yes) yes=1 ;; '') ;; *) usage ;; esac
  load_settings || { echo "push-gate: the settings can't be read" >&2; exit 1; }
  pats=$(mktemp) || exit 1; trap 'rm -f "$pats"' EXIT
  local p owner=0
  p=$(denylist_problem)
  [[ -z $p ]] || { echo "owner step: $p. Put the push-gate denylist at $(tilde "$denylist") (one extended regex per line), then run this again."; owner=1; }
  p=$(gitleaks_problem)
  [[ -z $p ]] || { echo "owner step: $p."; owner=1; }
  ((owner)) && exit 78
  hp=$(git config --global core.hooksPath 2>/dev/null)
  if [[ -n $hp && ${hp%/} != "$GATE_DIR/push-gate/hooks" ]]; then
    echo "push-gate: the global core.hooksPath is already $(tilde "$hp"); not replacing it (the owner decides)" >&2
    exit 1
  fi
  echo "copy the gate to $(tilde "$GATE_DIR")"
  echo "git config --global core.hooksPath $(tilde "$GATE_DIR/push-gate/hooks")"
  ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
  local new=$GATE_DIR.new.$$
  if ! { rm -rf "$new" && mkdir -p "$new/push-gate" "$new/lib" &&
    cp -R "$root/push-gate/." "$new/push-gate/" && cp "$root/lib/settings.sh" "$new/lib/" &&
    head -c 64 "$gitleaks.sha256" > "$new/gitleaks.sha256" && printf '%s\n' "$root" > "$new/source"; }; then
    echo "push-gate: install failed (the copy); the installed gate is unchanged" >&2; rm -rf "$new"; exit 1
  fi
  # The switch is two renames, and a failure between them puts the old copy back: git runs no
  # hooks at all from a core.hooksPath that doesn't exist, so a missing gate dir is no gate. An
  # install that stopped between them left only the .old copy: that is the gate, put it back.
  if [[ ! -e $GATE_DIR && -e $GATE_DIR.old ]]; then mv "$GATE_DIR.old" "$GATE_DIR" || exit 1; fi
  if ! { rm -rf "$GATE_DIR.old" && { [[ ! -e $GATE_DIR ]] || mv "$GATE_DIR" "$GATE_DIR.old"; }; }; then
    echo "push-gate: install failed (moving the old copy aside)" >&2; rm -rf "$new"; exit 1
  fi
  if ! mv "$new" "$GATE_DIR"; then
    [[ ! -e $GATE_DIR.old ]] || mv "$GATE_DIR.old" "$GATE_DIR"
    echo "push-gate: install failed; the installed gate is unchanged" >&2; rm -rf "$new"; exit 1
  fi
  rm -rf "$GATE_DIR.old"
  git config --global core.hooksPath "$GATE_DIR/push-gate/hooks" || { echo "push-gate: install failed (git config)" >&2; exit 1; }
  echo "installed: $(gate_version)"
}

cmd_shim() {
  local dir=${1:-} yes=0 hp top hook
  [[ -n $dir ]] || usage
  case ${2:-} in --yes) yes=1 ;; '') ;; *) usage ;; esac
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { echo "push-gate: not a git repository" >&2; exit 1; }
  hp=$(hooks_path "$dir") || { echo "push-gate: can't read the repository's git config" >&2; exit 1; }
  if [[ -z $hp || $hp == "$GATE_DIR/push-gate/hooks" ]]; then
    echo "no core.hooksPath of its own: the global gate covers this repository; nothing to do"; exit 0
  fi
  hook=$hp/pre-push
  if has_shim "$hook"; then echo "the shim is already in $(tilde "$hook")"; exit 0; fi
  if [[ ! -e $hook ]]; then
    echo "write $(tilde "$hook"): the shim"
    ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
    mkdir -p "$hp" && printf '#!/bin/sh\n%s\n' "$SHIM_LINE" > "$hook" && chmod +x "$hook" || exit 1
  elif head -1 "$hook" | grep -Eq "$SHELL_SHEBANG"; then
    echo "add the shim as line 2 of $(tilde "$hook") (a shell script: the shim runs first)"
    ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
    { head -1 "$hook" && printf '%s\n' "$SHIM_LINE" && tail -n +2 "$hook"; } > "$hook.crewkit-new" &&
      chmod +x "$hook.crewkit-new" && mv "$hook.crewkit-new" "$hook" || exit 1
  else
    [[ ! -e $hook.chained ]] || { echo "push-gate: $(tilde "$hook.chained") already exists; not overwriting it" >&2; exit 1; }
    echo "move $(tilde "$hook") to pre-push.chained, and write a shim that runs the gate, then it"
    ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
    # shellcheck disable=SC2016  # $0 and $@ are the shim's, at run time
    mv "$hook" "$hook.chained" &&
      printf '#!/bin/sh\n%s\nexec "$(dirname "$0")/pre-push.chained" "$@"\n' "$SHIM_LINE" > "$hook" && chmod +x "$hook" || exit 1
  fi
  echo "shimmed: pushes from $(tilde "$top") now go through the gate"
}

# doctor-watch: run --doctor and compare its FAIL set, and its exempt line, with the last run's.
# Only a change sends a pointer: "push-gate: N FAIL: <ids>", "push-gate: ok", "push-gate: doctor
# error (exit N)", and "the exempt file changed: <counts>", joined with "; " when both change.
# The message is the notify command's last argument; a notify that fails isn't recorded, so the
# next run sends it again. Exit: 0 healthy, 1 a FAIL, 2 the doctor's own error.
cmd_doctor_watch() {
  local out rc state prev=ok prev_ex='' ex line n ids=() parts=() pointer f
  load_settings || { echo "push-gate: the settings can't be read" >&2; exit 2; }
  out=$("$0" --doctor 2>/dev/null); rc=$?
  while IFS= read -r line; do
    [[ $line == *" FAIL "* ]] && ids+=("${line%% *}")
  done <<<"$out"
  # 0 is healthy, 1 with FAIL lines a FAIL; anything else (2, 127 for a missing command, 137 or
  # 143 for a signal, 1 with no FAIL line) is the doctor's own error, never ok.
  if ((rc == 0)); then state="ok"; pointer="ok"
  elif ((rc == 1 && ${#ids[@]})); then
    state=$(printf '%s\n' "${ids[@]}" | LC_ALL=C sort | paste -sd' ' -)
    n=${#ids[@]}; pointer="$n FAIL: $state"
  else state="error $rc"; pointer="doctor error (exit $rc)"; rc=2
  fi
  f=$HOME/.local/state/crewkit/push-gate-doctor.state
  if [[ -r $f ]]; then { IFS= read -r prev; IFS= read -r prev_ex; } < "$f" || true; fi
  ex=$(sed -n 's/^exempt ok //p' <<<"$out")
  [[ -n $ex ]] || ex=$prev_ex   # no exempt line this run (an error): nothing to compare
  [[ $state != "$prev" ]] && parts+=("$pointer")
  [[ -n $prev_ex && $ex != "$prev_ex" ]] && parts+=("the exempt file changed: ${ex% (sha256 *}")
  if ((${#parts[@]})); then
    pointer="push-gate: ${parts[0]}${parts[1]:+; ${parts[1]}}"
    if [[ -n $notify ]]; then
      sh -c "$notify \"\$1\"" sh "$pointer" >/dev/null 2>&1 ||
        { echo "push-gate: notify failed; not recorded, the next run tries again" >&2; exit "$rc"; }
    else
      echo "$pointer"
    fi
  fi
  if [[ $state != "$prev" || $ex != "$prev_ex" ]]; then
    mkdir -p "${f%/*}" && printf '%s\n%s\n' "$state" "$ex" > "$f.new" && mv "$f.new" "$f"
  fi
  exit "$rc"
}

# xml VALUE: VALUE for a plist <string>. sd VALUE [exec]: VALUE inside a systemd unit's double
# quotes: \ and " escaped, % doubled (a specifier), and for ExecStart (exec) $ doubled too.
xml() { local v=$1 a='&amp;' l='&lt;' g='&gt;' q='&quot;'; v=${v//&/"$a"}; v=${v//</"$l"}; v=${v//>/"$g"}; v=${v//\"/"$q"}; printf '%s' "$v"; }
sd() { local v=$1 b="\\\\" q='\"' pc='%%' dl='$$'; v=${v//\\/"$b"}; v=${v//\"/"$q"}; v=${v//%/"$pc"}; [[ ${2:-} == exec ]] && v=${v//\$/"$dl"}; printf '%s' "$v"; }

# schedule: write the hourly unit for this OS from push-gate/templates, pointing at the installed
# gate, and load it. Dry run without --yes.
cmd_schedule() {
  local yes=0 gate=$GATE_DIR/push-gate/push-gate.sh t=$root/push-gate/templates os dir f
  case ${1:-} in --yes) yes=1 ;; '') ;; *) usage ;; esac
  [[ -x $gate ]] || { echo "owner step: install the gate first (push-gate.sh install --yes)"; exit 78; }
  # fill TEMPLATE ESCAPE: the template with each @…@ value made safe by ESCAPE (xml for the plist,
  # sd for a systemd unit), in bash, not sed: a value's & | \ can't corrupt it. PATH keeps only
  # absolute entries: the job runs with no working directory of its own.
  local d sp=''
  IFS=: read -ra d <<<"$PATH"
  for f in "${d[@]}"; do [[ $f == /* ]] && sp+=${sp:+:}$f; done
  fill() {
    local t; t=$(<"$1") || return 1
    t=${t//@GATE@/"$("$2" "$gate" exec)"}; t=${t//@PATH@/"$("$2" "$sp")"}
    t=${t//@LOG@/"$("$2" "$HOME/.local/state/crewkit/push-gate-doctor.log")"}
    printf '%s\n' "$t"
  }
  os=$(uname -s)
  case $os in
    Darwin)
      dir=$HOME/Library/LaunchAgents f=$dir/com.crewkit.push-gate-doctor.plist
      echo "write $(tilde "$f"), then: launchctl bootstrap gui/$(id -u) $(tilde "$f")"
      ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
      mkdir -p "$dir" "$HOME/.local/state/crewkit" && fill "$t/com.crewkit.push-gate-doctor.plist" xml > "$f" || exit 1
      launchctl bootout "gui/$(id -u)/com.crewkit.push-gate-doctor" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$f" || exit 1 ;;
    Linux)
      dir=$HOME/.config/systemd/user
      echo "write $(tilde "$dir")/crewkit-push-gate-doctor.{service,timer}, then: systemctl --user enable --now crewkit-push-gate-doctor.timer"
      ((yes)) || { echo "(dry run: nothing changed; --yes to do it)"; exit 0; }
      mkdir -p "$dir" && fill "$t/crewkit-push-gate-doctor.service" sd > "$dir/crewkit-push-gate-doctor.service" &&
        fill "$t/crewkit-push-gate-doctor.timer" sd > "$dir/crewkit-push-gate-doctor.timer" || exit 1
      systemctl --user daemon-reload || exit 1
      systemctl --user enable --now crewkit-push-gate-doctor.timer || exit 1 ;;
    *) echo "push-gate: no scheduler for $os (macOS and Linux)" >&2; exit 1 ;;
  esac
  echo "scheduled: the push gate's doctor runs hourly"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; exit 64; }

case ${1:-} in
  hook) shift; cmd_hook "$@" ;;
  install) shift; cmd_install "$@" ;;
  status) shift; cmd_status "$@" ;;
  --doctor) shift; cmd_doctor "$@" ;;
  gate-check) shift; cmd_gate_check "$@" ;;
  shim) shift; cmd_shim "$@" ;;
  doctor-watch) shift; cmd_doctor_watch "$@" ;;
  schedule) shift; cmd_schedule "$@" ;;
  *) usage ;;
esac
