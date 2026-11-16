# shellcheck shell=bash
# usersettings.sh: write keys into the user settings file, ~/.claude/crewkit.md. Source it after
# lib/settings.sh and libexec/ck/common.sh.
#
#   ck_user_set KEY VALUE         write `KEY: "VALUE"`: replace the frontmatter line whose key is exactly
#                                 KEY, else add it before the closing ---; create the file (frontmatter
#                                 only, mode 600, ~/.claude mode 700) when it is missing
#   ck_user_set --secret KEY      the same, VALUE read from stdin (one line) so it is never in an argv;
#                                 nothing prints it, the dry run shows <secret>
#   ck_user_unset KEY             remove that key's line
#
# Refuses: a KEY outside ^[a-z0-9_.-]+$ (64); a VALUE with a quote, a control character or
# leading/trailing space, or an empty secret (65); a symlinked file or ~/.claude, a file not
# owned by you or writable by others (78). A dry run (CK_YES not 1) prints what it would do.
# The whole read, edit and rename holds ck_lock user-settings. Every other line and the body
# are kept as they are, except that a final newline is added when it was missing and the file's
# mode becomes 600: the edit goes to a mode 600 temp file in the same directory, then mv.
# Before the mv the temp file is checked against the source (line count, last line, the new line inside
# the frontmatter): a short or damaged write is refused, never renamed into place.

# _ck_user_find PATH TESTS...: set _CK_FOUND to PATH if the find tests match it; returns 1 if find
# itself failed, so the caller refuses (a failed check is never "safe").
_ck_user_find() {
  local p=$1
  shift
  _CK_FOUND=$(find "$p" -maxdepth 0 "$@" -print 2>/dev/null) || return 1
}

# _ck_user_check: the file and directory are safe to use. Sets _CK_UERR and returns 78 if not.
_ck_user_check() {
  local dir=$HOME/.claude file=$HOME/.claude/crewkit.md p me
  _CK_UERR=
  if [[ -L $dir ]]; then _CK_UERR="$dir is a symlink: crewkit never writes through one"; return 78; fi
  if [[ -L $file ]]; then _CK_UERR="$file is a symlink: crewkit never writes through one"; return 78; fi
  me=$(id -u) || { _CK_UERR="cannot tell who you are (id -u failed)"; return 78; }
  for p in "$dir" "$file"; do
    [[ -e $p ]] || continue
    if [[ $p == "$file" && ! -f $p ]]; then _CK_UERR="$p is not a regular file"; return 78; fi
    _ck_user_find "$p" ! -user "$me" || { _CK_UERR="cannot check the owner of $p"; return 78; }
    if [[ -n $_CK_FOUND ]]; then _CK_UERR="$p is not owned by you"; return 78; fi
    _ck_user_find "$p" -perm -002 || { _CK_UERR="cannot check the mode of $p"; return 78; }
    if [[ -n $_CK_FOUND ]]; then _CK_UERR="$p is writable by others (chmod o-w it)"; return 78; fi
  done
  return 0
}

# _ck_user_scan FILE KEY WANT: read FILE once and set
#   _S_N      its line count (an unterminated last line counts)
#   _S_LAST   its last line
#   _S_FM     1 if it starts with a --- frontmatter line
#   _S_CLOSED 1 if the frontmatter has its closing ---
#   _S_BODY   1 if there is a line after the closing --- (or no frontmatter and any line)
#   _S_KEYS   how many frontmatter lines start with `KEY:`
#   _S_WANT   how many frontmatter lines are exactly WANT
_ck_user_scan() {
  local got n=0 fm=0 closed=0
  _S_N=0 _S_LAST='' _S_FM=0 _S_CLOSED=0 _S_BODY=0 _S_KEYS=0 _S_WANT=0
  while IFS= read -r got || [[ -n $got ]]; do
    n=$((n + 1))
    _S_LAST=$got
    if ((n == 1)); then
      if [[ $got == --- ]]; then fm=1 _S_FM=1; continue; fi
      _S_BODY=1
    elif ((fm)); then
      if [[ $got == --- ]]; then fm=0 closed=1; continue; fi
      [[ $got == "$2":* ]] && _S_KEYS=$((_S_KEYS + 1))
      [[ $got == "$3" ]] && _S_WANT=$((_S_WANT + 1))
    elif ((closed)); then
      _S_BODY=1
    fi
  done < "$1"
  _S_N=$n _S_CLOSED=$closed
  return 0
}

# _ck_user_verify MODE KEY SRC TMP: TMP is SRC with KEY set (to $_CK_UV) or unset, and nothing else
# changed: the line count moves by what the edit adds or removes, the last line is the source's
# (when the source has a body), the closing --- is there exactly when the source's was, and the new line is in the frontmatter (or, for an unset, no KEY
# line is left there). Returns 1 if not.
_ck_user_verify() {
  # Local, so the last line of the temp file (which can be KEY: "secret") is not left in the caller's shell.
  local _S_N _S_LAST _S_FM _S_CLOSED _S_BODY _S_KEYS _S_WANT
  local mode=$1 want sn sl sbody skeys delta sclosed
  want=$2': "'${_CK_UV-}'"'
  _ck_user_scan "$3" "$2" "$want"
  sn=$_S_N sl=$_S_LAST sbody=$_S_BODY skeys=$_S_KEYS sclosed=$_S_CLOSED
  ((sn == 0 || _S_FM == 0)) && [[ $mode == set ]] && sclosed=1   # the new frontmatter is closed
  if [[ $mode == set ]]; then
    if ((sn == 0 || _S_FM == 0)); then delta=3        # a new frontmatter around the key
    elif ((skeys == 0)); then delta=1                 # a new line
    else delta=$((1 - skeys)); fi                     # replaced, later twins dropped
  else
    delta=$((0 - skeys))
  fi
  _ck_user_scan "$4" "$2" "$want"
  ((_S_N == sn + delta)) || return 1
  ((_S_CLOSED == sclosed)) || return 1
  if ((sbody)); then [[ $_S_LAST == "$sl" ]] || return 1; fi
  if [[ $mode == set ]]; then
    ((_S_WANT >= 1 && _S_KEYS == 1)) || return 1
  else
    ((_S_KEYS == 0)) || return 1
  fi
  return 0
}

# _ck_user_write MODE KEY: MODE set (value in $_CK_UV) or unset. Under the lock; returns a code
# with _CK_UERR set, never exits, so the caller can release the lock.
_ck_user_write() {
  local mode=$1 dir=$HOME/.claude file=$HOME/.claude/crewkit.md tmp src=/dev/null
  _ck_user_check || return $?
  if [[ -e $file ]]; then
    src=$file
  elif [[ $mode == unset ]]; then
    return 0
  fi
  if [[ ! -d $dir ]]; then
    mkdir -m 700 "$dir" 2>/dev/null || { _CK_UERR="cannot create $dir"; return 1; }
  fi
  # mktemp creates 0600 by itself; the umask is defence in depth.
  tmp=$(umask 077; mktemp "$dir/.crewkit.md.XXXXXX" 2>/dev/null) || { _CK_UERR="cannot create a temp file in $dir"; return 1; }
  # The key and value go in through the environment, not argv.
  # shellcheck disable=SC2016  # an awk program
  CK_UK=$2 CK_UM=$mode CK_UV=${_CK_UV-} awk '
    BEGIN { k = ENVIRON["CK_UK"]; set = (ENVIRON["CK_UM"] == "set"); line = k ": \"" ENVIRON["CK_UV"] "\"" }
    NR == 1 && $0 != "---" { if (set) { print "---"; print line; print "---" } done = 1; print; next }
    NR == 1 { fm = 1; print; next }
    fm && $0 == "---" { if (set && !done) print line; done = 1; fm = 0; print; next }
    fm && index($0, k ":") == 1 { if (set && !done) print line; done = 1; next }
    { print }
    END { if (NR == 0 && set) { print "---"; print line; print "---" } else if (fm && set && !done) print line }
  ' "$src" > "$tmp" || { rm -f "$tmp"; _CK_UERR="cannot write $tmp"; return 1; }
  # Before the rename: the temp file must be what the edit should have made of the source. Checked in
  # bash (the value is never in an argv, never printed).
  _ck_user_verify "$mode" "$2" "$src" "$tmp" || { rm -f "$tmp"; _CK_UERR="the new settings file was not written as expected"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; _CK_UERR="cannot replace $file"; return 1; }
  _CREW_FILES_FOR=''   # lib/settings.sh caches the file list: forget it
  return 0
}

_ck_user_key_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^[a-z0-9_.-]+$ ]] || ck_die 64 "bad settings key: ${1-}"
}

# _ck_user_locked MODE KEY: _ck_user_write under the lock, released on every path.
_ck_user_locked() {
  local rc=0
  ck_lock user-settings
  _ck_user_write "$@" || rc=$?
  ck_unlock user-settings
  ((rc == 0)) || ck_die "$rc" "$_CK_UERR"
}

ck_user_set() {
  local LC_ALL=C secret=0 key value shown rc=0
  if [[ ${1-} == --secret ]]; then secret=1; shift; fi
  key=${1-}
  _ck_user_key_ok "$key"
  if ((secret)); then
    (($# == 1)) || ck_die 64 "usage: ck_user_set --secret KEY (the value comes on stdin)"
    IFS= read -r value || [[ -n $value ]] || ck_die 65 "no value on stdin for $key"
    [[ -n $value ]] || ck_die 65 "empty value on stdin for $key"
    shown='<secret>'
  else
    (($# == 2)) || ck_die 64 "usage: ck_user_set KEY VALUE"
    value=$2
    shown="\"$value\""
  fi
  # The messages below name the key, never the value.
  case $value in
    *[\"\']*) ck_die 65 "the value for $key has a quote" ;;
    *[[:cntrl:]]*) ck_die 65 "the value for $key has a control character" ;;
    ' '*|*' ') ck_die 65 "the value for $key has leading or trailing space" ;;
  esac
  _ck_user_check || ck_die "$?" "$_CK_UERR"
  if [[ ${CK_YES:-0} != 1 ]]; then
    printf 'set %s: %s in ~/.claude/crewkit.md\n' "$key" "$shown"
    return 0
  fi
  _CK_UV=$value
  _ck_user_locked set "$key" || rc=$?
  _CK_UV=
  return "$rc"
}

ck_user_unset() {
  local key=${1-}
  _ck_user_key_ok "$key"
  _ck_user_check || ck_die "$?" "$_CK_UERR"
  if [[ ${CK_YES:-0} != 1 ]]; then
    printf 'unset %s in ~/.claude/crewkit.md\n' "$key"
    return 0
  fi
  _ck_user_locked unset "$key"
}
