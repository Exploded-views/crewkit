# shellcheck shell=bash
# claudesettings.sh: allow SendMessage in Claude's own user settings, ~/.claude/settings.json. Source it
# after lib/settings.sh and libexec/ck/common.sh. (usersettings.sh writes crewkit's file; this one
# writes Claude's.)
#
#   ck_claude_allow TOOL          add TOOL to .permissions.allow, once: create the file (mode 600,
#                                 ~/.claude mode 700 when it is new), .permissions or .allow when
#                                 they are missing; print `already allowed: TOOL` and write nothing
#                                 (no backup, mtime untouched) when it is there
#   ck_claude_allow_status TOOL   for doctor, writes nothing: prints ok (0) when TOOL is allowed,
#                                 missing (1) when the file, the key or the entry is absent,
#                                 unreadable (2) on malformed or multi-document JSON, the wrong shape,
#                                 or a permissions.deny entry for TOOL (the allow would not take effect)
#
# The library is locked to one rule: TOOL must be exactly SendMessage (64 otherwise), so a later caller
# cannot widen what every Claude session of this user may do without a reviewed change here. The rule
# applies to every Claude session for this user on this node, not only crewkit's. The status looks at the
# user file only (a project or managed deny, or a symlinked file, is not seen).
#
# Refuses: a TOOL other than SendMessage (64); malformed or multi-document JSON, or a top level,
# .permissions or .allow of the wrong type (65: .allow must be an array of strings); a symlinked
# ~/.claude, settings.json or backup, a backup that is not a regular file, a path not owned by you or writable by others
# (a group-writable ~/.claude counts unless its group is your primary group and that group is named after you,
# a user-private group: with the usual umask 002 setup ~/.claude is 775 and the group is just you, as lib/settings.sh
# allows; a shared primary group such as macOS's staff is other people), a settings.json with a second hard link,
# a settings.json that is not a regular file or cannot be read (78); a settings.json that changed while
# crewkit was editing it (75: run again; the other writer's bytes are left as they are). A refusal leaves the file byte for
# byte as it was and writes no backup. A dry run (CK_YES not 1) prints what it would do.
# The whole read, edit and rename holds ck_lock claude-settings, but Claude Code writes this file too
# without that lock, so the run works from one snapshot of it (a mode 600 copy in ~/.claude): the
# checks, the edit, the verify and the backup all use the snapshot, and just before the rename the file
# must still be byte for byte the snapshot (cmp), else 75. The file's content is never in an argument
# list (jq reads files). The snapshot becomes settings.json.crewkit-bak (mode 600, an older backup is
# replaced); the edit goes to a mode 600 temp file in the same directory, then mv: the file is mode 600
# afterwards, whatever it was (a looser mode is tightened, a stricter one is not kept). The write runs in a subshell
# whose own EXIT trap removes this run's temp files if the run is interrupted; the caller's EXIT trap
# is never touched and sees the real exit status. A caller with no TERM trap dies at once on TERM and
# leaves the subshell running: just before each rename the subshell checks that the caller is alive (not
# a zombie) and the lock still names it, else 75 and nothing more is renamed (no trap of the caller is set
# or restored).
# Limit: the caller's pid reused by another of your processes before the check would pass it.
# Limit: if the backup path is swapped for a link to a directory between the check and the rename, mv has
# put the snapshot (a copy of the settings, mode 600, yours) in that directory before the run fails (1);
# settings.json itself is untouched.
# jq rewrites the file pretty-printed: every key keeps its value and its place, the new entry goes last.
# That also re-indents the file, collapses duplicate keys to the last value, writes \u escapes as the
# characters, and (jq 1.6) rounds integers above 2^53. Nothing is fsynced before the rename.
# Before the mv the temp file is checked against the snapshot (it parses, .permissions.allow is the old
# list plus TOOL, everything else is equal, the key order is the same): a damaged write is refused (1),
# never renamed into place.

# _ck_claude_find PATH TESTS...: set _CK_FOUND to PATH if the find tests match it; returns 1 if find
# itself failed, so the caller refuses (a failed check is never "safe").
_ck_claude_find() {
  local p=$1
  shift
  _CK_FOUND=$(find "$p" -maxdepth 0 "$@" -print 2>/dev/null) || return 1
}

# _ck_claude_check: the file, backup and directory are safe to use. Sets _CK_CERR and returns 78 if not.
_ck_claude_check() {
  local dir=$HOME/.claude file=$HOME/.claude/settings.json p me gid gn un
  _CK_CERR=
  for p in "$dir" "$file" "$file.crewkit-bak"; do
    if [[ -L $p ]]; then _CK_CERR="$p is a symlink: crewkit never writes through one"; return 78; fi
  done
  if [[ -e $file.crewkit-bak && ! -f $file.crewkit-bak ]]; then _CK_CERR="$file.crewkit-bak is not a regular file"; return 78; fi
  me=$(id -u) || { _CK_CERR="cannot tell who you are (id -u failed)"; return 78; }
  for p in "$dir" "$file"; do
    [[ -e $p ]] || continue
    if [[ $p == "$file" && ! -f $p ]]; then _CK_CERR="$p is not a regular file"; return 78; fi
    _ck_claude_find "$p" ! -user "$me" || { _CK_CERR="cannot check the owner of $p"; return 78; }
    if [[ -n $_CK_FOUND ]]; then _CK_CERR="$p is not owned by you"; return 78; fi
    _ck_claude_find "$p" -perm -002 || { _CK_CERR="cannot check the mode of $p"; return 78; }
    if [[ -n $_CK_FOUND ]]; then _CK_CERR="$p is writable by others (chmod o-w it)"; return 78; fi
  done
  if [[ -e $dir ]]; then
    _ck_claude_find "$dir" -perm -020 || { _CK_CERR="cannot check the mode of $dir"; return 78; }
    # Group-write is fine only for a user-private group: your primary group, named after you. The names
    # are looked up only here (id -gn and -un can fail where id -g cannot: no name for the id).
    if [[ -n $_CK_FOUND ]]; then
      gid=$(id -g) || { _CK_CERR="cannot tell your group (id -g failed)"; return 78; }
      if ! gn=$(id -gn 2>/dev/null) || ! un=$(id -un 2>/dev/null); then
        _CK_CERR="$dir is group-writable and your user or group name cannot be looked up, so the group may not be yours alone (chmod g-w it)"
        return 78
      fi
      [[ $gn == "$un" ]] || { _CK_CERR="$dir is writable by a group that is not yours alone (chmod g-w it)"; return 78; }
      _ck_claude_find "$dir" ! -group "$gid" || { _CK_CERR="cannot check the group of $dir"; return 78; }
      if [[ -n $_CK_FOUND ]]; then _CK_CERR="$dir is writable by a group that is not yours alone (chmod g-w it)"; return 78; fi
    fi
  fi
  if [[ -e $file ]]; then
    _ck_claude_find "$file" -links +1 || { _CK_CERR="cannot check the links of $file"; return 78; }
    if [[ -n $_CK_FOUND ]]; then _CK_CERR="$file has more than one hard link: crewkit never writes through one"; return 78; fi
  fi
  if [[ -e $file && ! -r $file ]]; then _CK_CERR="$file cannot be read"; return 78; fi
  return 0
}

# Only this one rule: see the header.
_ck_claude_tool_ok() {
  [[ ${1-} == SendMessage ]] || ck_die 64 "crewkit allows SendMessage only, not: ${1-}"
}

# _ck_claude_shape FILE: 0 if FILE is exactly one JSON document of the shape we can edit (an object;
# .permissions, if there, an object; .permissions.allow, if there, an array of strings), 1 if it is not
# JSON, 2 if the shape is wrong (including more than one document). A missing key is fine; a null one is not.
_ck_claude_shape() {
  jq -s -e . "$1" > /dev/null 2>&1 || return 1
  jq -s -e 'length == 1 and (.[0] | type == "object" and ((has("permissions") | not) or (.permissions | type == "object"
      and ((has("allow") | not) or (.allow | type == "array" and all(type == "string"))))))' "$1" > /dev/null 2>&1 || return 2
}

# _ck_claude_has FILE TOOL: 0 if TOOL is in FILE's .permissions.allow (FILE already has the right shape).
_ck_claude_has() {
  jq -s -e --arg t "$2" '.[0] | (.permissions.allow // []) | any(. == $t)' "$1" > /dev/null 2>&1
}

# _ck_claude_denied FILE TOOL: 0 if TOOL is in FILE's .permissions.deny (an array, else no).
_ck_claude_denied() {
  jq -s -e --arg t "$2" '.[0] | (.permissions.deny // []) | (type == "array") and any(. == $t)' "$1" > /dev/null 2>&1
}

# _ck_claude_verify OLD NEW TOOL: the file NEW is the file OLD would be with TOOL added. Both are read
# by jq from the files, never passed in an argument.
_ck_claude_verify() {
  jq -e -n --slurpfile old "$1" --slurpfile new "$2" --arg t "$3" '
    $new[0] as $n | $old[0] as $o
    | ($n | type == "object")
    and ($n.permissions.allow == ((($o.permissions // {}).allow // []) + [$t]))
    and (($o | if has("permissions") then . else .permissions = {} end | del(.permissions.allow)) == ($n | del(.permissions.allow)))
    and (($o | keys_unsorted) + (if $o | has("permissions") then [] else ["permissions"] end) == ($n | keys_unsorted))
    and ((($o.permissions // {}) | keys_unsorted) + (if ($o.permissions // {}) | has("allow") then [] else ["allow"] end) == ($n.permissions | keys_unsorted))
  ' > /dev/null 2>&1
}

# _ck_claude_held: the write may go on: the process that took the lock ($$, also in the write subshell)
# is alive and the lock still names it. Its caller, killed by a TERM it does not trap, leaves the
# subshell running without the lock; then nothing more is renamed. A killed caller its parent has not
# reaped yet is a zombie, which kill -0 (and so the lock's own liveness test) still finds: ps shows its
# state starting with Z (BSD and procps alike). Without a working ps, kill -0 alone decides.
_ck_claude_held() {
  local dir
  kill -0 "$$" 2>/dev/null || return 1
  [[ $(ps -o stat= -p "$$" 2>/dev/null) =~ ^[[:space:]]*Z ]] && return 1
  dir=$(ck_state_dir 2>/dev/null) || return 1
  [[ $(readlink "$dir/locks/claude-settings.lock" 2>/dev/null) == "$$" ]]
}

# This run's temp files, removed by _ck_claude_cleanup. The write runs in a subshell with its own EXIT
# trap, so the caller's EXIT trap is never touched (init and join keep one that prints their result).
_CK_CTMPS=()

_ck_claude_cleanup() {
  local f
  for f in ${_CK_CTMPS[@]+"${_CK_CTMPS[@]}"}; do rm -f "$f"; done
  _CK_CTMPS=()
}

# _ck_claude_write TOOL: under the lock; returns a code with _CK_CERR set, never exits, so the
# caller can release the lock. Prints what it did.
_ck_claude_write() {
  local tool=$1 dir=$HOME/.claude file=$HOME/.claude/settings.json bak snap tmp rc=0 existed=0
  bak=$file.crewkit-bak
  _ck_claude_check || return $?
  if [[ ! -d $dir ]]; then
    mkdir -m 700 "$dir" 2>/dev/null || { _CK_CERR="cannot create $dir"; return 1; }
  fi
  # mktemp creates 0600 by itself; the umask is defence in depth.
  snap=$(umask 077; mktemp "$dir/.settings.json.snap.XXXXXX" 2>/dev/null) || { _CK_CERR="cannot create a temp file in $dir"; return 1; }
  _CK_CTMPS+=("$snap")
  if [[ -e $file ]]; then
    existed=1
    cat "$file" > "$snap" 2>/dev/null || { _CK_CERR="cannot read $file"; return 78; }
    _ck_claude_shape "$snap" || rc=$?
    case $rc in
      0) ;;
      1) _CK_CERR="$file is not valid JSON: left as it was"; return 65 ;;
      *) _CK_CERR="$file is not the shape crewkit edits (one object, permissions.allow an array of strings): left as it was"; return 65 ;;
    esac
    if _ck_claude_has "$snap" "$tool"; then printf 'already allowed: %s\n' "$tool"; return 0; fi
  else
    printf '{}\n' > "$snap" || { _CK_CERR="cannot write $snap"; return 1; }
  fi
  tmp=$(umask 077; mktemp "$dir/.settings.json.XXXXXX" 2>/dev/null) || { _CK_CERR="cannot create a temp file in $dir"; return 1; }
  _CK_CTMPS+=("$tmp")
  # A new .permissions or .allow goes last; the existing keys keep their place.
  jq --arg t "$tool" '.permissions = ((.permissions // {}) | .allow = ((.allow // []) + [$t]))' "$snap" > "$tmp" 2>/dev/null \
    || { _CK_CERR="cannot write $tmp"; return 1; }
  _ck_claude_verify "$snap" "$tmp" "$tool" || { _CK_CERR="the new settings file was not written as expected"; return 1; }
  # Claude Code writes this file without our lock: it must still be what the edit started from.
  if ((existed)); then
    cmp -s "$snap" "$file" || { _CK_CERR="$file changed while crewkit was editing it; run again"; return 75; }
    _ck_claude_held || { _CK_CERR="crewkit was stopped, or lost its lock, before the backup; $file left as it was"; return 75; }
    # The snapshot is the old bytes at mode 600: it becomes the backup.
    mv "$snap" "$bak" || { _CK_CERR="cannot write the backup $bak"; return 1; }
    # The path could have been swapped for a directory (or a link to one) after the check: then mv put
    # the snapshot inside it. Settings.json is not touched.
    [[ -f $bak && ! -L $bak && ! -e $snap ]] || { _CK_CERR="the backup $bak is not a regular file now; $file left as it was"; return 1; }
  elif [[ -e $file || -L $file ]]; then
    _CK_CERR="$file appeared while crewkit was creating it; run again"; return 75
  fi
  _ck_claude_held || { _CK_CERR="crewkit was stopped, or lost its lock, before the rename; $file left as it was"; return 75; }
  mv "$tmp" "$file" || { _CK_CERR="cannot replace $file"; return 1; }
  printf 'allowed: %s\n' "$tool"
  return 0
}

ck_claude_allow() {
  local file=$HOME/.claude/settings.json rc=0
  (($# == 1)) || ck_die 64 "usage: ck_claude_allow SendMessage"
  _ck_claude_tool_ok "$1"
  _ck_claude_check || ck_die "$?" "$_CK_CERR"
  if [[ -e $file ]] && _ck_claude_denied "$file" "$1"; then
    printf 'crewkit: warning: %s is also in permissions.deny in %s: the deny wins, the allow has no effect\n' "$1" "$file" >&2
  fi
  if [[ ${CK_YES:-0} != 1 ]]; then
    # A dry run reads the file (jq opens it; nothing is copied or written).
    if [[ -e $file ]]; then
      _ck_claude_shape "$file" || rc=$?
      case $rc in
        1) ck_die 65 "$file is not valid JSON: left as it was" ;;
        2) ck_die 65 "$file is not the shape crewkit edits (one object, permissions.allow an array of strings): left as it was" ;;
      esac
      if _ck_claude_has "$file" "$1"; then printf 'already allowed: %s\n' "$1"; return 0; fi
    fi
    printf 'would allow %s in ~/.claude/settings.json\n' "$1"
    return 0
  fi
  ck_lock claude-settings
  # $$ in the subshell is still this process, so the lock is ours. The subshell prints the refusal and
  # exits with its code; its EXIT trap removes the temp files, also when a signal ends it.
  (
    trap _ck_claude_cleanup EXIT
    rc=0
    _ck_claude_write "$1" || rc=$?
    ((rc == 0)) || ck_die "$rc" "$_CK_CERR"
  ) || rc=$?
  ck_unlock claude-settings
  ((rc == 0)) || exit "$rc"
}

ck_claude_allow_status() {
  local file=$HOME/.claude/settings.json rc=0
  (($# == 1)) || ck_die 64 "usage: ck_claude_allow_status SendMessage"
  _ck_claude_tool_ok "$1"
  if [[ ! -e $file ]]; then echo missing; return 1; fi
  _ck_claude_shape "$file" || rc=$?
  if ((rc != 0)) || _ck_claude_denied "$file" "$1"; then echo unreadable; return 2; fi
  if _ck_claude_has "$file" "$1"; then echo ok; return 0; fi
  echo missing
  return 1
}
