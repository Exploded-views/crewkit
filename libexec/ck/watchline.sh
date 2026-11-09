# shellcheck shell=bash
# watchline.sh: the lines a content-free watcher may write, and the check that passes only those.
# Sourced by libexec/crewkit-watchline, after lib/settings.sh and libexec/ck/common.sh.
#
# A watcher reads text strangers wrote (issues, comments, logs). It must pass none of it on, so it
# writes one line made of fixed fields, each checked against a fixed pattern:
#
#   repo <source>#<N> <issue|pr|comment|discussion|release> <ASSOCIATION> <url> [author:<login>] [text:<quoted>]
#   log <service> <host> <level> <count> <window> sig:<16 hex digits>
#
# The url must be https://github.com/<owner>/<repo>/(issues|pull|discussions)/<N> for the same N.
# The log signature is computed here, from the other fields, never taken from input. Free text is
# added only for a login in watch.trusted_authors (a user-only setting), which the line then names
# (author:<login> is required with a text), so that the check can decide again from its own
# setting. The ASSOCIATION is the watcher's claim and never grants a text. Text is at most 200 characters, one line, no control characters,
# shell-quoted. Nothing here ever prints a rejected value.
#
#   ck_wl_repo_line SOURCE N TYPE ASSOC URL [LOGIN TEXT]   print the line, or return 1 (SOURCE is the
#                                                          url's repository label, ck_wl_label)
#   ck_wl_log_line SERVICE HOST LEVEL COUNT WINDOW         print the line, or return 1
#   ck_wl_line_ok LINE OWNER/REPO...                       0 if LINE is a good repo or log line (a repo
#                                                          line must point into one of the repos given)

CK_WL_TYPES=' issue pr comment discussion release '
CK_WL_ASSOCS=' OWNER MEMBER COLLABORATOR CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE '
CK_WL_LEVELS=' debug info notice warn warning error crit critical fatal '

ck_wl_in() { case $2 in *" $1 "*) [[ -n $1 && $1 != *" "* ]] ;; *) return 1 ;; esac; }

ck_wl_login_ok() { local LC_ALL=C; [[ ${1-} =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; }
ck_wl_name_ok() { local LC_ALL=C; [[ ${1-} =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# ck_wl_url_ok URL N: an issue, pull request or discussion page of that number N (which must be a
# plain number, no leading zero), nothing more.
ck_wl_url_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^https://github\.com/([A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/([A-Za-z0-9_][A-Za-z0-9._-]{0,99})/(issues|pull|discussions)/([1-9][0-9]{0,8})$ ]] &&
    [[ ${BASH_REMATCH[5]} == "${2-}" ]]
}

# ck_wl_label URL: the label of the url's repository: its name, lower-cased, with . and _ as -.
# A line's <source> must be exactly this, so it carries no words of the writer's choosing.
ck_wl_label() {
  local LC_ALL=C r=${1#*://github.com/}
  r=${r#*/}
  r=${r%%/*}
  r=${r,,}
  r=${r//[._]/-}
  printf '%s\n' "$r"
}

# ck_wl_text_ok TEXT: at least one and at most 200 characters, printable ASCII only (space to ~). That
# leaves out control characters, bidi overrides, zero-width and separator characters, and any
# 8-bit byte, so the length is the same in every locale and no hidden text can ride along.
ck_wl_text_ok() {
  local LC_ALL=C t=${1-}
  ((${#t} <= 200)) || return 1
  [[ $t =~ ^[\ -~]+$ ]]
}

# ck_wl_trusted LOGIN: may this author's text be passed on? Only a login this machine's own setting
# names. The association on the line is the watcher's claim and is not looked at: a watcher that
# was talked into writing OWNER would otherwise carry a stranger's text through.
ck_wl_trusted() {
  local a list=()
  read -ra list <<<"$(ck_wl_trusted_authors)"  # words only: no glob, no pathname expansion
  for a in ${list[@]+"${list[@]}"}; do
    [[ $a == "$1" ]] && return 0
  done
  return 1
}

ck_wl_trusted_authors() {
  local v
  v=$(crew_setting watch.trusted_authors) || v=''  # settings-keys: watch.trusted_authors
  v=${v//,/ }
  printf '%s\n' "$v"
}

# ck_wl_sig LINE: the first 16 hex digits of the sha256 of LINE.
ck_wl_sig() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(printf '%s' "$1" | sha256sum)
  else
    h=$(printf '%s' "$1" | shasum -a 256)
  fi
  printf '%s\n' "${h:0:16}"
}

ck_wl_repo_line() {
  local src=${1-} n=${2-} type=${3-} assoc=${4-} url=${5-} login=${6-} text=${7-} line
  ck_wl_in "$type" "$CK_WL_TYPES" || return 1
  ck_wl_in "$assoc" "$CK_WL_ASSOCS" || return 1
  ck_wl_url_ok "$url" "$n" || return 1
  [[ $src == "$(ck_wl_label "$url")" ]] || return 1
  line="repo $src#$n $type $assoc $url"
  if (($# > 5)); then
    ck_wl_text_ok "$text" || return 1
    ck_wl_login_ok "$login" || return 1
    ck_wl_trusted "$login" || return 1
    line+=" author:$login"
    line+=" text:$(ck_sq "$text")"
  fi
  printf '%s\n' "$line"
}

ck_wl_log_line() {
  local service=${1-} host=${2-} level=${3-} count=${4-} window=${5-} LC_ALL=C line
  ck_wl_name_ok "$service" || return 1
  ck_wl_name_ok "$host" || return 1
  ck_wl_in "$level" "$CK_WL_LEVELS" || return 1
  [[ $count =~ ^(0|[1-9][0-9]{0,8})$ ]] || return 1
  [[ $window =~ ^[1-9][0-9]{0,5}[smhd]$ ]] || return 1
  line="log $service $host $level $count $window"
  printf '%s sig:%s\n' "$line" "$(ck_wl_sig "$line")"
}

# ck_wl_repo_arg_ok ARG: an OWNER/REPO with the same name patterns as a url.
ck_wl_repo_arg_ok() {
  local LC_ALL=C
  [[ ${1-} =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/([A-Za-z0-9_][A-Za-z0-9._-]{0,99})$ ]]
}

# ck_wl_watched URL OWNER/REPO...: the url's owner/repo (a
# GitHub name has no case, so compared lower-cased) must be one of them, so a forged line for
# another owner's repository is dropped.
ck_wl_watched() {
  local url=$1 path owner repo want
  shift
  (($#)) || return 1
  path=${url#https://github.com/}
  owner=${path%%/*}
  repo=${path#*/}
  repo=${repo%%/*}
  for want in "$@"; do
    [[ ${want,,} == "${owner,,}/${repo,,}" ]] && return 0
  done
  return 1
}

# ck_wl_line_ok LINE: LINE is exactly what ck_wl_repo_line or ck_wl_log_line would have printed
# (with a text, only if its author is trusted by this machine's own setting).
ck_wl_line_ok() {
  local line=${1-} LC_ALL=C text q="'\\''" login='' sig
  shift || true
  local f=()  # the matched fields: the calls below run their own matches
  ((${#line} <= 2000)) || return 1  # 200 quotes of text quote to 800 characters
  local repo_re='^repo ([A-Za-z0-9_.-]{1,100})#([1-9][0-9]{0,8}) ([a-z]+) ([A-Z_]+) (https://[^ ]+)( author:([A-Za-z0-9-]+))? text:(.*)$'
  local bare_re='^repo ([A-Za-z0-9_.-]{1,100})#([1-9][0-9]{0,8}) ([a-z]+) ([A-Z_]+) (https://[^ ]+)$'
  local log_re='^log ([a-z0-9][a-z0-9._-]{0,63}) ([a-z0-9][a-z0-9._-]{0,63}) ([a-z]+) ([0-9]{1,9}) ([0-9]{1,6}[smhd]) sig:([0-9a-f]{16})$'
  if [[ $line =~ $bare_re ]]; then
    f=("${BASH_REMATCH[@]}")
    [[ $(ck_wl_repo_line "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}") == "$line" ]] &&
      ck_wl_watched "${f[5]}" "$@"
    return
  fi
  if [[ $line =~ $repo_re ]]; then
    f=("${BASH_REMATCH[@]}")
    login=${f[7]}
    text=${f[8]}
    [[ $text =~ ^\'([^\']|\'\\\'\')*\'$ ]] || return 1
    text=${text#\'}
    text=${text%\'}
    text=${text//"$q"/\'}
    [[ $(ck_wl_repo_line "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "$login" "$text") == "$line" ]] &&
      ck_wl_watched "${f[5]}" "$@"
    return
  fi
  if [[ $line =~ $log_re ]]; then
    f=("${BASH_REMATCH[@]}")
    sig=${f[6]}
    [[ $(ck_wl_log_line "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}") == "${line%% sig:*} sig:$sig" ]]
    return
  fi
  return 1
}
