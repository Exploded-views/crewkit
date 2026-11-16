# common.sh: what every crewkit verb shares. Source it after lib/settings.sh:
#
#   source "$CK_ROOT/lib/settings.sh"
#   source "$CK_ROOT/libexec/ck/common.sh"
#
# It sets no shell options and changes no directory. Sourcing it under bash older than 4.4 exits
# 78 first, before anything below is parsed (bash reads a sourced file one command at a time).
#
#   ck_bash_ok MAJOR MINOR      exit 78 below bash 4.4
#   ck_die CODE MSG...          "crewkit: MSG" on stderr, exit CODE
#   CK_YES                      1 when the verb got --yes (each verb sets it); anything else is a dry run
#   ck_run CMD...               print CMD, indented, and run it only when CK_YES=1
#   ck_new_id PREFIX            PREFIX- plus 10 random characters of [a-z2-7]
#   ck_now / ck_iso EPOCH       epoch seconds ($CK_NOW overrides, for tests) / YYYY-MM-DDTHH:MM:SSZ
#   ck_age SECONDS              0s, 59s, 1m, 2h, 2d
#   ck_sq STRING                POSIX single-quoted
#   ck_state_dir                the state_dir setting, ~ expanded, created mode 700, printed
#   ck_lock NAME / ck_unlock NAME   a lock under <state_dir>/locks; a dead holder's lock is taken
#                               over (a symlink to the holder's pid), otherwise wait lock_wait_seconds (30), then exit 75
#   ck_name_ok NAME             a codename: ^[a-z][a-z0-9-]{0,31}$
#   ck_label_ok KEY=VALUE       a herdr token: dot-free key, plain value
#   CK_PUSH_GATE_REL            the push gate's script, relative to the tree (CK_ROOT)
#   ck_owner_step TEXT / ck_owner_steps_done   collect owner-only steps; the second prints them
#                               and returns 3 if there were any (a caller under set -e writes
#                               `|| rc=$?`), else 0
#
# Exit codes are docs/exit-codes.md's.

ck_bash_ok() {
  local major=${1:-0} minor=${2:-0}
  minor=${minor%%.*}
  case $major$minor in
    ''|*[!0123456789]*) major=0 minor=0 ;;
  esac
  if ((major < 4 || (major == 4 && minor < 4))); then
    echo "crewkit: needs bash 4.4 or newer (this is bash $1.$2). On macOS: brew install bash, and put it first on PATH." >&2
    exit 78
  fi
}
# CK_BASH_VERSION (MAJOR.MINOR, tests only) can only make the check stricter: it counts only when
# it names a version older than the running bash.
ck_vmaj=${BASH_VERSINFO[0]:-0} ck_vmin=${BASH_VERSINFO[1]:-0}
ck_re='^([0-9]{1,3})\.([0-9]{1,3})$'
if [[ ${CK_BASH_VERSION-} =~ $ck_re ]]; then
  if ((10#${BASH_REMATCH[1]} < ck_vmaj || (10#${BASH_REMATCH[1]} == ck_vmaj && 10#${BASH_REMATCH[2]} < ck_vmin))); then
    ck_vmaj=$((10#${BASH_REMATCH[1]})) ck_vmin=$((10#${BASH_REMATCH[2]}))
  fi
fi
ck_bash_ok "$ck_vmaj" "$ck_vmin"
unset ck_vmaj ck_vmin ck_re

ck_die() {
  local code=$1
  shift
  printf 'crewkit: %s\n' "$*" >&2
  exit "$code"
}

# The push gate's script inside the tree. A constant, never taken from the environment.
# shellcheck disable=SC2034  # read by the verbs that source this file
CK_PUSH_GATE_REL=push-gate/push-gate.sh

# Never taken from the environment: a verb sets it to 1 itself, from its own --yes.
CK_YES=0
# ck_run CMD...: print it, and run it only when CK_YES is exactly 1.
ck_run() {
  printf '  %s\n' "$*"
  if [[ ${CK_YES:-0} == 1 ]]; then "$@"; fi
}

# ck_new_id PREFIX: PREFIX- plus 10 characters of [a-z2-7] (base32) from /dev/urandom.
ck_new_id() {
  local s='' tries=0
  while ((${#s} < 10)); do
    ((++tries <= 8)) || ck_die 1 "cannot read random bytes from /dev/urandom"
    s+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'a-z2-7')
  done
  printf '%s-%s\n' "$1" "${s:0:10}"
}

ck_now() { printf '%s\n' "${CK_NOW:-$(date +%s)}"; }

ck_iso() {
  local LC_ALL=C
  [[ ${1-} =~ ^[0-9]+$ ]] || ck_die 64 "not an epoch: ${1-}"
  jq -rn --argjson t "$1" '$t | todate'
}

ck_age() {
  local LC_ALL=C s
  [[ ${1-} =~ ^-?[0-9]+$ ]] || ck_die 64 "not a number of seconds: ${1-}"
  if [[ $1 == -* ]]; then echo 0s; return 0; fi
  s=$((10#$1))
  if ((s <= 0)); then echo 0s
  elif ((s < 60)); then echo "${s}s"
  elif ((s < 3600)); then echo "$((s / 60))m"
  elif ((s < 172800)); then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"
  fi
}

ck_sq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }

ck_state_dir() {
  local d
  d=$(crew_setting state_dir "$HOME/.local/state/crewkit")
  # shellcheck disable=SC2088  # the literal text ~/ is what is matched
  case $d in
    '~') d=$HOME ;;
    '~/'*) d=$HOME/${d#'~/'} ;;
    '~'*) ck_die 78 "state_dir: ~user is not supported: $d" ;;
  esac
  [[ $d == /* ]] || ck_die 78 "state_dir must be an absolute path (or start with ~/): $d"
  # Private only when we create it; an existing directory's mode is the owner's business.
  if [[ ! -d $d ]]; then
    { mkdir -p "$d" && chmod 700 "$d"; } || ck_die 1 "cannot create $d"
  fi
  printf '%s\n' "$d"
}

# A pid is alive if kill -0 says so, or ps still lists it (kill -0 fails on another user's
# process). Anything but digits is not a pid.
ck_pid_alive() {
  local LC_ALL=C
  [[ ${1-} =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# ck_lock NAME: take <state_dir>/locks/NAME.lock, a symlink whose target is our pid. `ln -s`
# creates it atomically with its content, so a lock is never without its pid. A dead holder's lock
# is removed only while holding the reap mutex (NAME.reap, a directory), after reading the link
# again and finding the same dead pid; then the loop retries. Any other lock is waited for,
# lock_wait_seconds (30), then exit 75.
ck_lock() {
  local LC_ALL=C name=${1-} dir wait lock reap pid start=$SECONDS
  [[ $name =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || ck_die 64 "bad lock name: $name"
  dir=$(ck_state_dir) || exit $?
  dir=$dir/locks
  mkdir -p "$dir" || ck_die 1 "cannot create $dir"
  wait=$(crew_setting lock_wait_seconds 30)
  [[ $wait =~ ^[0-9]+$ ]] || ck_die 78 "lock_wait_seconds must be a whole number: $wait"
  lock=$dir/$name.lock reap=$dir/$name.reap
  while :; do
    # ln -s into an existing directory succeeds inside it: refuse one (a leftover of the old
    # mkdir-style lock), never delete it.
    [[ -d $lock && ! -L $lock ]] && ck_die 78 "$lock is a directory, not a crewkit lock: remove it once nothing holds it"
    # -n: a symlink to a directory at the lock path is a link to replace, never one to follow.
    ln -sn "$$" "$lock" 2>/dev/null && return 0
    if [[ ! -e $lock && ! -L $lock ]]; then
      # Not there, yet it could not be made: released in between, or the directory is unusable.
      ((SECONDS - start <= wait)) || ck_die 1 "cannot create the lock $lock"
      sleep 0.05
      continue
    fi
    pid=$(readlink "$lock" 2>/dev/null || true)
    if [[ -L $lock ]] && ! ck_pid_alive "$pid"; then
      if mkdir "$reap" 2>/dev/null; then
        if [[ $(readlink "$lock" 2>/dev/null || true) == "$pid" ]]; then rm -f "$lock"; fi
        rmdir "$reap" 2>/dev/null || true
        continue
      else
        # A reaper died inside its few milliseconds: clear its mutex once it is over a minute old.
        # The age test and the rmdir are separate steps, so in a narrow window this can remove a
        # fresh mutex that replaced the stale one; that needs a reaper to have crashed first.
        find "$reap" -maxdepth 0 -mmin +1 -exec rmdir {} \; 2>/dev/null || true
      fi
    fi
    ((SECONDS - start <= wait)) || ck_die 75 "lock $name is held (pid ${pid:-unknown}; $lock); waited ${wait}s"
    sleep 0.2
  done
}

# ck_unlock NAME: release a lock, only if it is ours.
ck_unlock() {
  local LC_ALL=C lock
  [[ ${1-} =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || ck_die 64 "bad lock name: ${1-}"
  lock=$(ck_state_dir) || exit $?
  lock=$lock/locks/$1.lock
  if [[ -L $lock && $(readlink "$lock" 2>/dev/null || true) == "$$" ]]; then rm -f "$lock"; fi
  return 0
}

ck_name_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

# A herdr token key has no dot (herdr rejects dotted keys).
ck_label_ok() {
  local LC_ALL=C
  [[ ${1-} == *=* ]] || return 1
  [[ ${1%%=*} =~ ^[a-z][a-z0-9_-]{0,31}$ && ${1#*=} =~ ^[A-Za-z0-9_.:-]{1,64}$ ]]
}

CK_OWNER_STEPS=()
ck_owner_step() { CK_OWNER_STEPS+=("$1"); }
ck_owner_steps_done() {
  local i
  ((${#CK_OWNER_STEPS[@]})) || return 0
  echo "Owner-only steps (crewkit never runs these):"
  for i in "${!CK_OWNER_STEPS[@]}"; do
    printf '  %d. %s\n' "$((i + 1))" "${CK_OWNER_STEPS[i]}"
  done
  return 3
}
