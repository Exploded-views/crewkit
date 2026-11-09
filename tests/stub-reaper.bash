# Stub daemons that outlive an aborted bats run (tests/crewkit-holder.bats).
#
# A suite that starts a stub daemon stops it in teardown, which a bats run that is killed never
# reaches. So each stub registers itself in a file that outlives the run: one line per stub,
#
#     PID OWNER START
#
# PID is the stub's, OWNER the pid of the bats run that owns it (BATS_ROOT_PID), START its start
# time as `ps` prints it with spaces made underscores. The next run's setup_file calls
# reap_stale_stubs, which stops a stub only if its owner is no longer running and the process now
# at PID still started when the stub did (so neither a live run's stub nor a reused pid is hit),
# and keeps the lines of runs that are alive.
#
#   stub_register FILE OWNER    from inside the stub: add this process (source this file first)
#   stub_exec FILE OWNER CMD..  register this process, then become CMD (same pid, same start time):
#                               for a program under test that is not a stub, such as the holder
#   reap_stale_stubs FILE       from setup_file

# _stub_start PID: the start time of PID, one word; empty when there is no such process.
_stub_start() {
  local s
  s=$(LC_ALL=C ps -o lstart= -p "$1" 2> /dev/null) || return 0
  s=${s//[[:space:]]/_}
  printf '%s\n' "$s"
}

stub_register() {
  # never through a link, and never into a file that is not ours (the registry is in a directory
  # other users may write to)
  [[ ! -L $1 ]] && { [[ ! -e $1 ]] || [[ -O $1 ]]; } || return 0
  printf '%s %s %s\n' "$$" "$2" "$(_stub_start "$$")" >> "$1"
}

stub_exec() {
  local file=$1 owner=$2
  shift 2
  stub_register "$file" "$owner"
  exec "$@"
}

reap_stale_stubs() {
  local file=$1 pid owner start now keep
  # only a plain file of ours: in a shared temp directory anyone could have made it, and a line in it
  # decides which process is killed
  [[ -f $file && ! -L $file && -O $file ]] || return 0
  keep=$(mktemp "${file}.XXXXXX") || return 0
  while read -r pid owner start; do
    [[ $pid =~ ^[0-9]{1,9}$ && $owner =~ ^[0-9]{1,9}$ && -n $start ]] || continue
    # 0 and 1 are never a stub or its run; kill -0 1 fails for a user who is not root, which would
    # make a run "dead"
    ((pid > 1 && owner > 1)) || continue
    if kill -0 "$owner" 2> /dev/null; then
      printf '%s %s %s\n' "$pid" "$owner" "$start" >> "$keep"
      continue
    fi
    now=$(_stub_start "$pid")
    [[ -n $now && $now == "$start" ]] && kill -9 "$pid" 2> /dev/null
  done < "$file"
  mv "$keep" "$file"
  return 0
}
