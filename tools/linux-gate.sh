#!/usr/bin/env bash
# linux-gate.sh: the CI-equivalent run of a branch, on this machine, in a pinned Linux container.
#
#   tools/linux-gate.sh BRANCH OUTDIR [SPEC.json...]   gate BRANCH; logs and summary.txt in OUTDIR
#   tools/linux-gate.sh --build-images                 build the gate's images from docker/
#
# It clones BRANCH fresh from the source checkout (LINUX_GATE_SRC, default the main checkout of
# the repository this script is in), with origin/main taken from that checkout.
# First, natively on the clone as cloned (before any container can write it): shellcheck, the
# scrub with the private denylist, and the secrets scan (tools/secrets-scan.sh: the pinned gitleaks,
# the gate's own config, every ref in the clone including merges' changes, the branch's
# .gitleaks.toml refused); with FULL=1, kcov (tools/coverage.sh, its own container, the clone
# read-only), and the floors' base and tool are taken. The scrub, the secrets scan, coverage.sh and
# coverage-floors.py are the GATE's copies (from this script's directory), never the clone's: the
# branch can't edit what checks it, and none of the branch's code runs on the host (shellcheck
# reads its scripts as text, with --norc: the clone's .shellcheckrc is ignored; coverage.sh finds
# bats through its own get-bats.sh, in the clone's staged .cache, and runs python with -I). The
# secrets scan covers every ref the clone holds, so a leak on any other local branch of the source
# checkout fails this gate too. LINUX_GATE_TOOLS (tests only) must be absolute. On INT, TERM or HUP,
# and whenever it exits, the gate kills its named containers before it removes its work directory.
# Then crewkit-ubuntu
# (docker/crewkit-ubuntu.Dockerfile: ubuntu 24.04 by digest, as GitHub's ubuntu-latest) with no
# network, as the caller's uid: the image's locale, the Python tests, the skills and workflow
# lints, the bats suite, the perf budgets, and tools/mutate.py for each SPEC. FULL=1 adds
# install.sh's mutants, coverage.py (crewkit-ubuntu-amd64, with the pinned wheel from
# LINUX_GATE_WHEELS, read-only) and the coverage floors. The container writes its step lines to
# its own out directory; the host writes OUTDIR/summary.txt, whose first line is
# `head BRANCH SHA`, and copies in only the container's own steps' lines and logs.
#
# It is a heavy job: it refuses unless it holds the heavy lock (tools/heavy_lock.py), so run it as
#   crew-heavy run <secs> tools/linux-gate.sh BRANCH OUTDIR [SPEC...]
# Every bats test in the container, and under kcov with FULL=1, stops after
# LINUX_GATE_TEST_TIMEOUT seconds (default 300; BATS_TEST_TIMEOUT), so a hung test fails the
# gate instead of holding the lock. The whole run has a time limit too: LINUX_GATE_TIMEOUT
# seconds (default 7200), shared by every step from the clone's `git clone` on (the clone itself
# has the same limit, the fetch and copy after it none). At
# the limit, the step running is stopped (a container is killed by its name), a `timeout STEP`
# line goes to summary.txt, no further step starts, and the gate fails.
# Work directories go under LINUX_GATE_WORK (default ~/.cache/crewkit/linux-gate), which docker
# must be able to mount; the last run.sh is kept there as run.sh.last.
#
# tests/mutants/local-gate.txt lists the holds: mutation specs that left CI's matrix for its time
# limit. One hold per line; blank and # lines are ignored, no inline #; a line is space-separated
# tokens NAME.json or NAME.json@KofN (1 <= K <= N <= 100), no paths: the lint's grammar, checked
# again here in every run, at the gated head and by git (never the caller's tree, replace refs or
# pathspec settings). Absent at the head: no holds (and then tests and tests/mutants must be
# absent or plain directories). Every NAME.json must be a regular file under tests/mutants at the
# head, and no entry there may have an @ in its name (a file named NAME.json@KofN would alias a
# slice). A file that isn't a regular one, has a NUL byte or a CR, or a bad line exits 1 before
# anything runs, naming the line number of the file (never its text), and leaves a failure summary
# (`holds rc=1`) in OUTDIR. Each hold is its own mutants-only claim; plain and FULL summaries get a
# `holds M` line (M = the number of holds at that head) after the head line:
#   tools/linux-gate.sh --holds BRANCH    print M for BRANCH (or a full SHA) in the source repository
#                                         (0 without the file); runs nothing, needs no lock; 1 if bad
#   LINUX_GATE_MUTANTS_ONLY=1 LINUX_GATE_HOLD=N tools/linux-gate.sh BRANCH OUTDIR
#                                         the tokens of the Nth hold (blank and # lines not counted)
#                                         are this run's SPECs (steps mutants-NAME; NAME.json@KofN is
#                                         passed to mutate.py as it is); no SPEC may be given; N a
#                                         whole number 1..M or exit 64 (with a failure summary); the
#                                         mode line ends `hold=N/M`
# A mutants-only run also needs the base to carry exactly one `holds M` line with this head's M, and
# the base can't be its own OUTDIR's summary.txt (a refusal would overwrite it). A clone whose work
# tree differs from the head (a case-folding collision) fails closed: `checkout rc=1`.
# A plain run given SPECs notes on stderr that a non-empty list was skipped. A lander takes M from
# the base summary's `holds` line and wants, for every N in 1..M, a passing summary whose head line
# equals the base's and whose mode line ends `hold=N/M`.
#
# LINUX_GATE_MUTANTS_ONLY=1 splits a gate run across heavy-lock claims: the container runs only
# tools/mutate.py for each SPEC (at least one; not with FULL=1), after the same native checks and
# with the same head line first in summary.txt; a spec's baseline runs as ever, and a failing one
# fails that spec's step. It must come behind a passed run of the same head:
# LINUX_GATE_BASE=<summary.txt of that run> is checked first, and the gate exits 1 before the
# clone is used if the variable is unset, the file is missing, its first line isn't the head line
# this run would write (the same branch and full SHA), or it records a failed step or a step
# that never ran, by the check that ends every run, or it is itself a mutants-only summary (a
# `mode` line), or it is this run's own summary.txt. The file is trusted as named: its hash goes into
# the new summary's second line, `mode mutants-only base-sha256=HASH`, which marks the summary as
# not a full run. Only the head line is ever printed from it. A reader of a summary (the lander)
# must check line 2: a `mode` line there means it is not a full run.
#
# Exit 0 = every step ran and passed, 1 = a step failed or never ran (named on the last line; a
# container that exits non-zero counts too) or the gate couldn't
# run (or the base run is missing, for another head, or failed), 64 = usage (or a bad
# LINUX_GATE_TEST_TIMEOUT or LINUX_GATE_TIMEOUT, or MUTANTS_ONLY without a SPEC or with FULL=1, or
# a bad LINUX_GATE_HOLD).
set -uo pipefail
# The caller's git environment must not redirect the git commands run here and in the tools.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_REPLACE_REF_BASE GIT_GLOB_PATHSPECS \
  GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS GIT_LITERAL_PATHSPECS
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${here%/*}
# The gate's own copies of the tools it runs on the host against the clone (the scrub, the secrets
# scan, coverage.sh, coverage-floors.py): never the clone's, which is the branch under test.
# LINUX_GATE_TOOLS names another directory for them (the tests' stubs).
trusted=${LINUX_GATE_TOOLS:-$here}
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; exit 64; }

# resolve_src: src = the source checkout (LINUX_GATE_SRC, default the main checkout of this script's repository).
resolve_src() {
  local common
  if [[ -n ${LINUX_GATE_SRC:-} ]]; then src=$LINUX_GATE_SRC
  else
    common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir) || exit 1
    src=${common%/.git}
  fi
}

# The local gate's holds: tests/mutants/local-gate.txt as REV has it in the repository GITDIR (read by
# git, not from any work tree, with no replace refs and literal pathspecs). read_holds GITDIR REV
# TMPDIR fills hold_lines, one validated line each (tokens joined by single spaces), or sets hold_err
# (a message naming a line number of the file, never its text) and returns 1. No file is no holds, if
# tests and tests/mutants are plain directories (ls-tree doesn't follow a link, so a linked one
# would hide the file). Tokens are checked in the C locale.
holds_path=tests/mutants/local-gate.txt
hold_lines=() hold_err=
read_holds() {
  local LC_ALL=C gitdir=$1 rev=$2 tmp=$3 entry mode type line n=0 tok toks k total re ok name
  local -a g=(git -C "$gitdir" --no-replace-objects --literal-pathspecs)
  re='^([A-Za-z0-9_.-]+)\.json(@([1-9][0-9]*)of([1-9][0-9]*))?$'
  hold_lines=() hold_err=
  entry=$("${g[@]}" ls-tree "$rev" -- "$holds_path") || { hold_err="can't read $holds_path"; return 1; }
  if [[ -z $entry ]]; then
    entry=$("${g[@]}" ls-tree "$rev" -- tests tests/mutants) || { hold_err="can't read tests/mutants"; return 1; }
    while read -r mode type _; do
      [[ -z $mode ]] || [[ $mode == 040000 && $type == tree ]] || {
        hold_err="tests or tests/mutants is not a plain directory"; return 1; }
    done <<<"$entry"
    return 0
  fi
  read -r mode type _ <<<"$entry"
  { [[ $type == blob ]] && [[ $mode == 100644 || $mode == 100755 ]]; } || {
    hold_err="$holds_path is not a regular file"; return 1; }
  "${g[@]}" cat-file blob "$rev:$holds_path" > "$tmp/holds.raw" || { hold_err="can't read $holds_path"; return 1; }
  [[ $(tr -d '\0' < "$tmp/holds.raw" | wc -c) -eq $(wc -c < "$tmp/holds.raw") ]] || {
    hold_err="$holds_path has a NUL byte"; return 1; }
  [[ $(tr -d '\r' < "$tmp/holds.raw" | wc -c) -eq $(wc -c < "$tmp/holds.raw") ]] || {
    hold_err="$holds_path has a CR"; return 1; }
  "${g[@]}" ls-tree -r "$rev" -- tests/mutants > "$tmp/tree.txt" || { hold_err="can't read tests/mutants"; return 1; }
  ! awk -F'\t' '$2 ~ /@/ { f = 1 } END { exit !f }' "$tmp/tree.txt" || {
    hold_err="tests/mutants has an entry with an @ in its name"; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    read -ra toks <<<"$line"
    ((${#toks[@]})) || continue
    [[ ${toks[0]} != '#'* ]] || continue
    for tok in "${toks[@]}"; do
      ok=
      if [[ $tok =~ $re ]]; then
        k=${BASH_REMATCH[3]} total=${BASH_REMATCH[4]} name=${BASH_REMATCH[1]}.json
        if [[ -z $k ]] || ((${#k} <= 3 && ${#total} <= 3 && k <= total && total <= 100)); then ok=1; fi
      fi
      [[ -n $ok ]] || { hold_err="line $n of $holds_path: not a hold (NAME.json or NAME.json@KofN, 1 <= K <= N <= 100)"; return 1; }
      awk -F'\t' -v p="tests/mutants/$name" '$2 == p && $1 ~ /^100(644|755) blob / { f = 1 } END { exit !f }' "$tmp/tree.txt" || {
        hold_err="line $n of $holds_path: no such spec in tests/mutants at this head"; return 1; }
    done
    hold_lines+=("${toks[*]}")
  done < "$tmp/holds.raw"
}
# step_name SPEC: the container step of a SPEC, `mutants-` and the spec without its .json (before any @KofN).
step_name() { local n=${1/.json@/@}; echo "mutants-${n%.json}"; }

if [[ ${1:-} == --holds ]]; then
  (($# == 2)) || usage
  [[ $2 != -* ]] || usage
  resolve_src
  sha=
  [[ $2 =~ ^[0-9a-f]{40}$ ]] && sha=$(git -C "$src" rev-parse -q --verify "$2^{commit}")
  [[ -n $sha ]] || sha=$(git -C "$src" rev-parse -q --verify "refs/heads/$2^{commit}" || git -C "$src" rev-parse -q --verify "refs/tags/$2^{commit}") || {
    echo "linux-gate: no branch $2" >&2; exit 1; }
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$tmp"' EXIT
  read_holds "$src" "$sha" "$tmp" || { echo "linux-gate: $hold_err" >&2; exit 1; }
  echo "${#hold_lines[@]}"
  exit 0
fi
if [[ ${1:-} == --build-images ]]; then
  (($# == 1)) || usage
  python3 -I "$here/heavy_lock.py" linux-gate.sh || exit 1
  ubuntu=$(sed -n 's/^ubuntu=\([^ ]*\).*/\1/p' "$root/docker/bases.txt")
  [[ $ubuntu =~ ^ubuntu@sha256:[0-9a-f]{64}$ ]] || { echo "linux-gate: docker/bases.txt has no ubuntu digest" >&2; exit 1; }
  docker build -t crewkit-ubuntu --build-arg BASE="$ubuntu" -f "$root/docker/crewkit-ubuntu.Dockerfile" "$root/docker" &&
    docker build --platform linux/amd64 -t crewkit-ubuntu-amd64 --build-arg BASE="$ubuntu" \
      -f "$root/docker/crewkit-ubuntu-amd64.Dockerfile" "$root/docker" &&
    docker build -t crewkit-kcov --build-arg BASE="$("$root/tools/coverage.sh" --pinned-image)" \
      -f "$root/docker/crewkit-kcov.Dockerfile" "$root/docker" || exit 1
  echo "linux-gate: built crewkit-ubuntu, crewkit-ubuntu-amd64 and crewkit-kcov"
  exit 0
fi
(($# >= 2)) || usage
[[ $1 != -* ]] || usage
test_timeout=${LINUX_GATE_TEST_TIMEOUT-300}
[[ $test_timeout =~ ^[1-9][0-9]*$ ]] || { echo "linux-gate: LINUX_GATE_TEST_TIMEOUT must be a whole number of seconds, at least 1" >&2; exit 64; }
limit=${LINUX_GATE_TIMEOUT-7200}
[[ $limit =~ ^[1-9][0-9]*$ ]] || { echo "linux-gate: LINUX_GATE_TIMEOUT must be a whole number of seconds, at least 1" >&2; exit 64; }
mutants_only='' hold=''
if [[ -n ${LINUX_GATE_HOLD+x} ]]; then
  [[ ${LINUX_GATE_MUTANTS_ONLY:-} == 1 ]] || { echo "linux-gate: LINUX_GATE_HOLD needs LINUX_GATE_MUTANTS_ONLY=1" >&2; exit 64; }
  (($# == 2)) || { echo "linux-gate: LINUX_GATE_HOLD takes no SPEC (the Nth hold of the list is the SPECs)" >&2; exit 64; }
  [[ $LINUX_GATE_HOLD =~ ^[1-9][0-9]{0,5}$ ]] || { echo "linux-gate: LINUX_GATE_HOLD must be the number of a hold (1 up; blank and # lines of the list are not counted)" >&2; exit 64; }
  hold=$LINUX_GATE_HOLD
fi
if [[ ${LINUX_GATE_MUTANTS_ONLY:-} == 1 ]]; then
  mutants_only=1
  [[ -n $hold ]] || (($# >= 3)) || { echo "linux-gate: LINUX_GATE_MUTANTS_ONLY=1 needs at least one SPEC" >&2; exit 64; }
  [[ ${FULL:-} != 1 ]] || { echo "linux-gate: LINUX_GATE_MUTANTS_ONLY=1 can't be combined with FULL=1" >&2; exit 64; }
fi
python3 -I "$here/heavy_lock.py" linux-gate.sh || exit 1
if [[ -n $mutants_only ]]; then
  [[ -n ${LINUX_GATE_BASE:-} ]] || { echo "linux-gate: LINUX_GATE_MUTANTS_ONLY=1 needs LINUX_GATE_BASE=<summary.txt of a passed base run of this head>" >&2; exit 1; }
  base=$LINUX_GATE_BASE   # ./ in front of a relative path, so a name starting with - is no option
  [[ $base == /* ]] || base=./$base
  [[ -f $base ]] || { echo "linux-gate: LINUX_GATE_BASE: no such file" >&2; exit 1; }
fi
command -v timeout >/dev/null || { echo "linux-gate: needs timeout (GNU coreutils) for its time limit" >&2; exit 1; }
deadline=$((SECONDS + limit))

branch=$1 out=$2; shift 2
specs=("$@")
resolve_src
work_root=${LINUX_GATE_WORK:-$HOME/.cache/crewkit/linux-gate}
wheels=${LINUX_GATE_WHEELS:-$HOME/.cache/crewkit/wheels}
mkdir -p "$work_root" "$out" || exit 1
# Absolute, before any cd: docker would take a relative path for a volume name, and the native
# checks run from the clone (which is deleted).
out=$(cd "$out" && pwd) || exit 1
work=$(mktemp -d "$work_root/run.XXXXXX") || exit 1
# Each container has a name (unique to this run), so it can be killed at the time limit or when
# the gate is interrupted: stopping the docker client leaves its container running.
name=crewkit-linux-gate-${work##*/run.}
child='' docker_used=''
# On exit, and on INT, TERM and HUP: stop the step running and kill the named containers (errors
# ignored) before the work directory they mount is removed.
cleanup() {
  trap - EXIT INT TERM HUP
  [[ -z $child ]] || kill "$child" 2>/dev/null
  # Whenever a docker step may have started, not only when interrupted: a step killed from
  # outside (rc 137: the OOM killer, a kill -9 of the docker client) leaves its --rm container
  # running otherwise. A run that never reached docker (a refusal) makes no docker call here.
  local c
  if [[ -n $docker_used ]]; then
    for c in "$name" "$name-kcov" "$name-covpy"; do timeout 60 docker kill "$c" >/dev/null 2>&1; done
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
timeout --kill-after=10 "$limit" git clone -q --no-hardlinks -b "$branch" "$src" "$work/repo" || { echo "linux-gate: can't clone $branch" >&2; exit 1; }
# The work tree must be the head exactly: on a case-folding filesystem two paths that differ only in
# case collide and one file silently stands for the other (a decoy spec for a hold), which git sees
# as a modified file.
modified=$(git -C "$work/repo" ls-files -m) || exit 1
if [[ -n $modified ]]; then
  {
    printf '%-28s %s %s\n' head "$branch" "$(git -C "$work/repo" rev-parse HEAD)"
    printf '%-28s rc=1  the clone is not the head (a path collision, or a filter?)\n' checkout
  } > "$out/summary.txt"
  cat "$out/summary.txt" >&2
  echo "linux-gate: failed: checkout"
  exit 1
fi
# The clone's .cache is the gate's: bats is staged there and coverage.sh removes and writes under
# it on the host, so a branch that tracks anything under .cache (a symlink out of the clone steers
# those writes and that removal anywhere) is refused before anything is staged.
if [[ -n $(git -C "$work/repo" ls-files -- .cache) || -e $work/repo/.cache || -L $work/repo/.cache ]]; then
  {
    printf '%-28s %s %s\n' head "$branch" "$(git -C "$work/repo" rev-parse HEAD)"
    printf '%-28s rc=1  the branch tracks .cache (the gate stages bats there)\n' cache
  } > "$out/summary.txt"
  cat "$out/summary.txt" >&2
  echo "linux-gate: failed: cache"
  exit 1
fi
# The clone's origin is the source checkout, whose own main can be stale: take its origin/main.
if git -C "$src" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
  git -C "$work/repo" fetch -q "$src" "+refs/remotes/origin/main:refs/remotes/origin/main" || exit 1
fi
mkdir -p "$work/repo/.cache" "$work/home"
# ssh-keygen needs the uid in passwd, which the image lacks: mount one (root, and the caller as t, home /home/t).
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$work/passwd"
(($(id -u) == 0)) || printf 't:x:%s:%s:gate:/home/t:/bin/sh\n' "$(id -u)" "$(id -g)" >> "$work/passwd"
cp -R "$src/.cache/bats-v1.14.0" "$work/repo/.cache/bats-v1.14.0" 2>/dev/null
[[ -x $work/repo/.cache/bats-v1.14.0/bin/bats ]] || { echo "linux-gate: bats not staged in $src/.cache (tools/get-bats.sh)" >&2; exit 1; }
# head: the full SHA of the clone, read once, before anything runs (never the branch afterwards,
# which can have moved).
head=$(git -C "$work/repo" rev-parse HEAD) || exit 1
headline=$(printf '%-28s %s %s' head "$branch" "$head")
full_steps=(image-locale python lint-skills check-workflows bats perf-strict perf-ci-headroom)

# MUTANTS_ONLY: the base can't be this run's own summary, which a refusal below would overwrite too.
if [[ -n $mutants_only ]]; then
  realpath_of() { python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
  [[ $(realpath_of "$base") != "$(realpath_of "$out/summary.txt")" ]] || {
    echo "linux-gate: LINUX_GATE_BASE is this run's own summary.txt, which the run overwrites" >&2; exit 1; }
fi

# The hold list is checked in every run; LINUX_GATE_HOLD=N makes the Nth hold's tokens this run's SPECs.
# A refusal leaves a failure summary, so no earlier run's summary in OUTDIR stands for this one.
hold_refuse() {
  { printf '%s\n' "$headline"; printf '%-28s rc=%s  %s\n' holds "$1" "$2"; } > "$out/summary.txt"
  echo "linux-gate: $2" >&2
  echo "linux-gate: failed: holds"
  exit "$1"
}
read_holds "$work/repo" "$head" "$work" || hold_refuse 1 "$hold_err"
if [[ -n $hold ]]; then
  ((hold <= ${#hold_lines[@]})) ||
    hold_refuse 64 "LINUX_GATE_HOLD=$hold, but the hold list at this head has ${#hold_lines[@]} hold(s)"
  read -ra specs <<<"${hold_lines[hold - 1]}"
elif ((${#specs[@]} > 0 && ${#hold_lines[@]} > 0)) && [[ -z $mutants_only ]]; then
  echo "linux-gate: note: the hold list has ${#hold_lines[@]} hold(s), skipped because SPECs were given (each hold is its own mutants-only claim: LINUX_GATE_HOLD=N)" >&2
fi

# summary_failed SUMMARY STEP...: what fails the gate in SUMMARY, one word per failure, deduplicated:
# a first line that isn't the head line, a timeout, a container that died, an rc other than 0, a
# scrub that isn't clean, a "linux-gate: failed:" verdict line, and each STEP with no line.
summary_failed() {
  local file=$1 s f; shift
  f=$(awk -v headline="$headline" -v reject="${reject_mode:-}" 'NR == 1 { if ($0 != headline) print "head"; next }
    $1 == "timeout" { print "timeout(" $2 ")"; next }
    $1 == "mode" && reject { print "mode(" $2 ")"; next }
    $1 == "linux-gate:" && $2 == "failed:" { print "verdict"; next }
    $1 == "container" { print "container(" $2 ")"; next } / rc=[1-9]/ { print $1 }
    $1 == "scrub" && $3 != "scrub:" { print "scrub" } $1 == "scrub" && $3 == "scrub:" && $4 != "clean" { print "scrub" }' "$file"
    for s in "$@"; do
      awk -v s="$s" '$1 == s { found = 1 } END { exit !found }' "$file" || echo "$s(missing)"
    done)
  awk '!seen[$0]++' <<<"$f" | paste -sd' ' -
}

# MUTANTS_ONLY: the base run must be of this head and have passed, before anything runs.
base_steps=("${full_steps[@]}" shellcheck scrub gitleaks)
if [[ -n $mutants_only ]]; then
  # One read: every check below runs on this copy, so the hash covers exactly the bytes checked.
  cp -- "$base" "$work/base.txt" || exit 1
  base=$work/base.txt
  [[ $(head -n 1 "$base") == "$headline" ]] || {
    echo "linux-gate: LINUX_GATE_BASE is not a run of this head: want '$headline'; its head line is '$(head -n 1 "$base" | cut -c1-200)'" >&2; exit 1; }
  # A summary with a mode line (a mutants-only run) isn't a full run: reject_mode counts it as a failure.
  base_failed=$(reject_mode=1 summary_failed "$base" "${base_steps[@]}")
  [[ -z $base_failed ]] || { echo "linux-gate: LINUX_GATE_BASE records a failed base run: $base_failed" >&2; exit 1; }
  # The base's `holds M` is this head's M: one such line, no other (a base from before the list had none).
  [[ $(awk -v m="${#hold_lines[@]}" '$1 == "holds" { n++; if (NF == 2 && $2 == m) ok++ } END { print (n == 1 && ok == 1) }' "$base") == 1 ]] || {
    echo "linux-gate: LINUX_GATE_BASE has no single 'holds ${#hold_lines[@]}' line, so it is not a base for this head's list" >&2; exit 1; }
  base_sha=$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$base") || exit 1
fi
printf '%s\n' "$headline" > "$out/summary.txt"
[[ -z $mutants_only ]] || printf '%-28s %s\n' mode "mutants-only base-sha256=$base_sha${hold:+ hold=$hold/${#hold_lines[@]}}" >> "$out/summary.txt"
[[ -n $mutants_only ]] || printf '%-28s %s\n' holds "${#hold_lines[@]}" >> "$out/summary.txt"
# LINUX_GATE_TOOLS is read after the cd into the clone: a relative path would be the clone's own.
if [[ $trusted != /* ]]; then
  printf '%-28s rc=1  LINUX_GATE_TOOLS must be an absolute path\n' tools | tee -a "$out/summary.txt" >&2
  echo "linux-gate: failed: tools"
  exit 1
fi

# FULL=1's floors: their base (the merge base of head with main, from the clone as cloned) and the
# gate's own tool, taken now: nothing the branch runs later (in a container that can write the
# clone) can change them.
floors_ready=
if [[ ${FULL:-} == 1 ]]; then
  base=$(git -C "$work/repo" merge-base "$head" origin/main) &&
    git -C "$work/repo" show "$base:coverage-floors.json" > "$work/base-floors.json" &&
    cp "$trusted/coverage-floors.py" "$work/coverage-floors.py" && floors_ready=1
fi

# The container's steps: run.sh writes their lines to its own /out/steps.txt, and the host copies
# only these steps' lines into summary.txt (so the container can't add a head or native line).
cnames=("${full_steps[@]}")
[[ -n $mutants_only ]] && cnames=()
for s in ${specs[@]+"${specs[@]}"}; do cnames+=("$(step_name "$s")"); done
[[ ${FULL:-} == 1 ]] && cnames+=(install-mutants)
cout=$work/out
mkdir -p "$cout" || exit 1
cat > "$work/run.sh" <<'IN'
set -uo pipefail
cd /src
export HOME=/home/t GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git config --global --add safe.directory '*'
step() { local name=$1; shift; local t0=$SECONDS
  "$@" > "/out/$name.log" 2>&1; local rc=$?
  printf '%-28s rc=%s %4ss  %s\n' "$name" "$rc" "$((SECONDS - t0))" "$(tail -1 "/out/$name.log")" | tee -a /out/steps.txt; }
if [[ -z ${MUTANTS_ONLY:-} ]]; then
step image-locale sh -c 'locale -a | grep -qix "en_US.utf8" && echo "en_US.UTF-8 present"'
step python python3 -m unittest discover -s tests -p 'test_*.py'
step lint-skills python3 tools/lint-skills.py
step check-workflows python3 tools/check-workflows.py
step bats tests/run.sh
step perf-strict python3 tools/perf.py
step perf-ci-headroom env CI=true python3 tools/perf.py
fi
for s in "$@"; do n=${s/.json@/@}; step "mutants-${n%.json}" python3 tools/mutate.py "tests/mutants/$s"; done
[[ ${FULL:-} == 1 ]] && step install-mutants tools/mutate.sh
true
IN
cp "$work/run.sh" "$work_root/run.sh.last"

# Every image is the local build (--pull never; the kcov image is checked before coverage.sh).
kill_container() { timeout 60 docker kill "$1" >/dev/null 2>&1; true; }
# limited STEP CMD...: CMD under what is left of the overall limit, its status in rc. At the limit
# it writes a timeout line (once) and returns 1; after that, every later step is skipped (2, no
# line), so the end check names it missing.
stopped=
limited() {
  local step=$1 left=$((deadline - SECONDS)); shift
  [[ -z $stopped ]] || return 2
  rc=124
  # In the background and waited for, so a trapped signal is handled at once, not after the step.
  if ((left > 0)); then timeout --kill-after=10 "$left" "$@" & child=$!; wait "$child"; rc=$?; child=; fi
  if (( (rc == 124 || rc == 137) && SECONDS >= deadline )); then
    stopped=$step
    printf '%-28s %s (LINUX_GATE_TIMEOUT=%ss)\n' timeout "$step" "$limit" | tee -a "$out/summary.txt" >&2
    return 1
  fi
}

# Natively, on the clone as cloned, before any container can write it: shellcheck, the gate's own
# scrub (with the private denylist) and its own secrets scan (tools/secrets-scan.sh: the pinned
# gitleaks, the gate's config, every ref, merges included).
run_native() {
  # The same three commands over the same files as ci.yml's shell job (tests/test_shellcheck_parity.py
  # fails when the two lists drift), with --norc: the list lives here, in the gate's own copy, never in
  # the branch under test. A libexec glob that matches nothing is fine, as in ci.yml (compgen); the other
  # globs (evals/*.sh, libexec/ck/*.sh) fail on an empty directory exactly as in ci.yml, so change them
  # on both sides or neither. All three commands run, and the step fails if any does.
  # shellcheck disable=SC2016  # expanded by the inner bash
  limited shellcheck bash -c 'mapfile -t plugin_sh < <(grep -l "^#!/usr/bin/env bash" plugins/crew-*/bin/* 2>/dev/null || true)
    mapfile -t libexec_sh < <(compgen -G "libexec/crewkit-*" || true)
    rc=0
    shellcheck --norc -x install.sh bin/crewkit tools/*.sh tests/run.sh tests/stub-gh evals/*.sh "${plugin_sh[@]}" "${libexec_sh[@]}" push-gate/push-gate.sh push-gate/hooks/_dispatch || rc=1
    shellcheck --norc -s sh push-gate/shim.sh || rc=1
    shellcheck --norc -s bash tests/*.bash lib/settings.sh libexec/ck/*.sh || rc=1
    exit $rc' > "$out/shellcheck.log" 2>&1 || return 0
  printf '%-28s rc=%s\n' shellcheck "$rc" | tee -a "$out/summary.txt"
  limited scrub "$trusted/scrub.sh" --require-denylist > "$out/scrub.log" 2>&1 || return 0
  printf '%-28s rc=%s  %s\n' scrub "$rc" "$(tail -1 "$out/scrub.log")" | tee -a "$out/summary.txt"
  limited gitleaks "$trusted/secrets-scan.sh" > "$out/gitleaks.log" 2>&1 || return 0
  printf '%-28s rc=%s\n' gitleaks "$rc" | tee -a "$out/summary.txt"
}

# FULL=1: kcov, as CI runs it. The gate's coverage.sh starts its own container (the clone
# read-only) and runs before the gate's container can change the clone; it uses its own
# get-bats.sh, so none of the clone's code runs on the host.
run_kcov() {
  local t0=$SECONDS
  docker_used=1
  # coverage.sh's docker run would pull a missing image (from a public registry, by this name).
  if ! timeout 60 docker image inspect crewkit-kcov > "$out/kcov.log" 2>&1; then
    printf '%-28s rc=1  no local crewkit-kcov image (tools/linux-gate.sh --build-images); not pulled\n' kcov | tee -a "$out/summary.txt"
    return 0
  fi
  limited kcov env KCOV_IMAGE=crewkit-kcov KCOV_NAME="$name-kcov" BATS_TEST_TIMEOUT="$test_timeout" "$trusted/coverage.sh" > "$out/kcov.log" 2>&1 ||
    { (($? == 1)) && kill_container "$name-kcov"; return 0; }
  printf '%-28s rc=%s %4ss  %s\n' kcov "$rc" "$((SECONDS - t0))" "$(grep -E 'tests passed|failed' "$out/kcov.log" | tail -1)" | tee -a "$out/summary.txt"
}

run_container() {
  local s
  docker_used=1
  if limited container docker run --name "$name" --pull never --rm --network none --user "$(id -u):$(id -g)" -e BATS_TEST_TIMEOUT="$test_timeout" -v "$work/repo:/src" -v "$cout:/out" \
    -v "$work/home:/home/t" -v "$work/run.sh:/run.sh:ro" -v "$work/passwd:/etc/passwd:ro" -e FULL="${FULL:-}" -e MUTANTS_ONLY="$mutants_only" crewkit-ubuntu bash /run.sh ${specs[@]+"${specs[@]}"}; then
    # A container that died (stopped, killed, out of memory) fails the gate even if its lines look green.
    ((rc == 0)) || printf '%-28s rc=%s\n' container "$rc" | tee -a "$out/summary.txt"
  elif (($? == 1)); then kill_container "$name"
  fi
  [[ -f $cout/steps.txt && ! -L $cout/steps.txt ]] && awk 'NR == FNR { want[$1]; next } $1 in want' <(printf '%s\n' "${cnames[@]}") "$cout/steps.txt" >> "$out/summary.txt"
  for s in "${cnames[@]}"; do
    [[ -f $cout/$s.log && ! -L $cout/$s.log ]] && cp "$cout/$s.log" "$out/$s.log"
  done
  return 0
}

# FULL=1: coverage.py, the pinned cp312 manylinux x86_64 wheel (hash-checked by pip), so linux/amd64.
run_coverage_py() {
  cat > "$work/cov.sh" <<'COV'
set -uo pipefail
cd /src
export HOME=/home/t GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git config --global --add safe.directory '*'
python3 -m venv /tmp/cv && /tmp/cv/bin/pip install --quiet --no-index --find-links /wheels --require-hashes --only-binary :all: -r tools/requirements-coverage.txt \
  && COVERAGE_VENV=/tmp/cv tools/coverage-py.sh
COV
  local t0=$SECONDS
  docker_used=1
  limited coverage-py docker run --name "$name-covpy" --pull never --rm --platform linux/amd64 --network none --user "$(id -u):$(id -g)" -v "$work/repo:/src" -v "$work/home:/home/t" \
    -v "$wheels:/wheels:ro" -v "$work/cov.sh:/cov.sh:ro" -v "$work/passwd:/etc/passwd:ro" crewkit-ubuntu-amd64 bash /cov.sh > "$out/coverage-py.log" 2>&1 ||
    { (($? == 1)) && kill_container "$name-covpy"; return 0; }
  printf '%-28s rc=%s %4ss  %s\n' coverage-py "$rc" "$((SECONDS - t0))" "$(tail -1 "$out/coverage-py.log")" | tee -a "$out/summary.txt"
}

# FULL=1: the floors, both reports, against the base taken before any container (as CI's
# pull_request path does), with the tool as cloned.
run_floors() {
  if [[ -n $floors_ready ]]; then
    limited floors python3 -I "$work/coverage-floors.py" --report .cache/coverage/bats.*/coverage.json --report .cache/coverage-py/report.json \
      --base-floors "$work/base-floors.json" > "$out/floors.log" 2>&1 || return 0
  else
    echo "linux-gate: no base floors (the merge base of $head with origin/main, or its coverage-floors.json)" > "$out/floors.log"; rc=1
  fi
  printf '%-28s rc=%s  %s\n' floors "$rc" "$(tail -1 "$out/floors.log")" | tee -a "$out/summary.txt"
}

cd "$work/repo" || exit 1
run_native
[[ ${FULL:-} == 1 ]] && run_kcov
run_container
[[ ${FULL:-} == 1 ]] && { run_coverage_py; run_floors; }
uptime | tee -a "$out/summary.txt"

# Every step must have run and passed: the head line first, as written; a step with no line
# (the container stopped before it), an rc other than 0, or a scrub that isn't clean fails the gate.
expected=("${cnames[@]}")
[[ ${FULL:-} == 1 ]] && expected+=(kcov coverage-py floors)
expected+=(shellcheck scrub gitleaks)
failed=$(summary_failed "$out/summary.txt" "${expected[@]}")
if [[ -n $failed ]]; then echo "linux-gate: failed: $failed"; exit 1; fi
echo "linux-gate: every step passed ($branch $head)"
