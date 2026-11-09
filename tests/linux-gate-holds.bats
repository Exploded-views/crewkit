#!/usr/bin/env bats
# tools/linux-gate.sh and the local gate's holds (tests/mutants/local-gate.txt): specs that left
# CI's matrix, each run as its own mutants-only claim (LINUX_GATE_HOLD=N), the list read from the
# gated head and checked in every run, `--holds BRANCH`, and the `holds M` summary line. The setup
# is tests/linux-gate-helpers.bash's (docker, shellcheck and gitleaks stubs, a scratch source checkout).

load linux-gate-helpers

setup() { lg_setup; }
teardown() { lg_teardown; }

LGF=tests/mutants/local-gate.txt
# commit_holds BRANCH CONTENT: the hold list as CONTENT in BRANCH's tip (the checkout goes back to
# main), with an empty spec file for every NAME.json it names (unless NOSPECS is set).
commit_holds() {
  local words w
  git -C "$SRC" checkout -q "$1"
  mkdir -p "$SRC/tests/mutants"
  printf '%b' "$2" > "$SRC/$LGF"
  if [ -z "${NOSPECS:-}" ]; then
    words=$(tr -s ' \t' '\n' < "$SRC/$LGF")
    while IFS= read -r w; do
      if [[ $w =~ ^([A-Za-z0-9_.-]+\.json)(@.*)?$ ]]; then echo '{}' > "$SRC/tests/mutants/${BASH_REMATCH[1]}"; fi
    done <<<"$words"
  fi
  git -C "$SRC" add -A && git -C "$SRC" commit -qm holds
  git -C "$SRC" checkout -q main
}
# commit_raw BRANCH COMMAND...: COMMAND run in the checkout of BRANCH, then everything committed.
commit_raw() {
  local b=$1; shift
  git -C "$SRC" checkout -q "$b"
  (cd "$SRC" && "$@")
  git -C "$SRC" add -A && git -C "$SRC" commit -qm raw
  git -C "$SRC" checkout -q main
}
# hold_gate N [ARGS...]: the mutants-only run of hold N on topic, behind the base run in $BASE.
hold_gate() { local n=$1; shift; LINUX_GATE_BASE=$BASE/summary.txt LINUX_GATE_HOLD=$n mo_gate topic "$OUT" "$@"; }
grep_step() { grep -qE "^$1 +rc=0 " "$OUT/summary.txt"; }
no_docker() { ! grep -q '^docker' "$CALLS"; }
holds_of() { run "$LG" --holds "$1"; }
BAD_LINES='a.txt ZZmark
ZZmark.json@3of2
ZZmark.json@1of101
ZZmark.json@0of4
ZZmark.json@01of4
ZZmark.json@1of0
ZZmark.json@1of4@2of4
ZZmark.json@of4
ZZmark.json # comment
b.json #ZZmark
tests/mutants/ZZmark.json
../ZZmark.json
ZZmark.json@18446744073709551621of100
ZZmark.json b.json ZZmark.js
.json'

@test "holds: LINUX_GATE_HOLD=N runs exactly the Nth hold's tokens, one step each, and marks the mode line" {
  commit_holds topic '# the holds\n\na.json b.json@1of4\n   # indented comment\nd.json\n'
  base_run
  hold_gate 1
  [ "$status" -eq 0 ]
  r=$(first_run)
  [[ $r == *" -e MUTANTS_ONLY=1 "* && $r == *" crewkit-ubuntu bash /run.sh a.json b.json@1of4" ]]
  grep_step mutants-a
  grep_step 'mutants-b@1of4'
  [ "$(grep -c '^mutants-' "$OUT/summary.txt")" -eq 2 ]
  slice=@1of4
  [ -f "$OUT/mutants-b$slice.log" ]
  hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$BASE/summary.txt")
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' mode "mutants-only base-sha256=$hash hold=1/2")" ]
  [[ ${lines[-1]} == "linux-gate: every step passed (topic "* ]]
  : > "$CALLS"
  hold_gate 2
  [ "$status" -eq 0 ]
  r=$(first_run)
  [[ $r == *" crewkit-ubuntu bash /run.sh d.json" ]]
  [ "$(grep -c '^mutants-' "$OUT/summary.txt")" -eq 1 ]
  grep_step mutants-d
  [[ $(sed -n 2p "$OUT/summary.txt") == *"base-sha256=$hash hold=2/2" ]]
}

@test "holds: without LINUX_GATE_HOLD the mode line is as ever (no hold field)" {
  commit_holds topic 'a.json\n'
  base_run
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" x.json
  [ "$status" -eq 0 ]
  [[ $(sed -n 2p "$OUT/summary.txt") != *hold* ]]
  grep_step mutants-x
}

@test "holds: run.sh names a hold's steps without .json and passes @KofN to tools/mutate.py verbatim" {
  commit_holds topic 'a.json b.json@1of4\n'
  base_run
  hold_gate 1
  [ "$status" -eq 0 ]
  sb="$BATS_TEST_TMPDIR/sb"; mkdir -p "$sb/src/tools" "$sb/src/tests" "$sb/out" "$sb/bin" "$sb/home"
  sed -e "s|/src|$sb/src|g" -e "s|/out|$sb/out|g" -e "s|/home/t|$sb/home|g" "$LINUX_GATE_WORK/run.sh.last" > "$sb/run.sh"
  printf '#!/bin/sh\necho "python3 $*" >> "$CALLS"\n' > "$sb/bin/python3"
  chmod +x "$sb/bin/python3"
  : > "$CALLS"
  MUTANTS_ONLY=1 PATH="$sb/bin:$PATH" run bash "$sb/run.sh" a.json b.json@1of4 x.json.json@3of100
  [ "$(cat "$CALLS")" = "$(printf 'python3 tools/mutate.py tests/mutants/a.json\npython3 tools/mutate.py tests/mutants/b.json@1of4\npython3 tools/mutate.py tests/mutants/x.json.json@3of100')" ]
  [ "$(awk '{ print $1 }' "$sb/out/steps.txt" | paste -sd' ' -)" = "mutants-a mutants-b@1of4 mutants-x.json@3of100" ]
}

@test "holds: the list is the gated head's, never the source checkout's working tree or this script's repository" {
  commit_holds topic 'head.json\n'
  mkdir -p "$SRC/tests/mutants"; printf 'caller.json\n' > "$SRC/$LGF"
  echo '{}' > "$SRC/tests/mutants/caller.json"
  git -C "$SRC" add -A && git -C "$SRC" commit -qm caller
  printf 'dirty.json\n' > "$SRC/$LGF"
  base_run
  hold_gate 1
  [ "$status" -eq 0 ]
  grep_step mutants-head
  [ "$(grep -c '^mutants-' "$OUT/summary.txt")" -eq 1 ]
  [[ $(sed -n 2p "$OUT/summary.txt") == *"hold=1/1" ]]
}

@test "holds: N must be a whole number from 1 to the number of holds (64, nothing runs; N past the end leaves a failure summary)" {
  commit_holds topic 'a.json\n\n# not counted\nb.json\n'
  base_run
  for bad in 0 3 abc '' 01 -1 1.5 ' 1' 99999999999999999999; do
    : > "$CALLS"
    hold_gate "$bad"
    [ "$status" -eq 64 ] || { echo "accepted: '$bad'" >&2; return 1; }
    [[ $output == *LINUX_GATE_HOLD* ]]
    no_docker
  done
  # N past the end is known only at the head: it leaves a summary that fails
  mkdir -p "$OUT"; echo "stale" > "$OUT/summary.txt"
  hold_gate 3
  [ "$status" -eq 64 ]
  [[ ${lines[-1]} == "linux-gate: failed: holds" ]]
  grep -qE '^holds +rc=64 ' "$OUT/summary.txt"
  [ "$(head -1 "$OUT/summary.txt" | awk '{ print $1 }')" = head ]
  # a head without the file has no holds at all
  commit_raw topic git rm -q "$LGF"
  base_run
  hold_gate 1
  [ "$status" -eq 64 ]
  no_docker
}

@test "holds: LINUX_GATE_HOLD with SPECs, without LINUX_GATE_MUTANTS_ONLY, or with FULL=1 is usage (64, nothing runs)" {
  commit_holds topic 'a.json\n'
  base_run
  hold_gate 1 x.json
  [ "$status" -eq 64 ]
  [[ $output == *LINUX_GATE_HOLD* ]]
  no_docker
  LINUX_GATE_HOLD=1 gate topic "$OUT"
  [ "$status" -eq 64 ]
  [[ $output == *LINUX_GATE_HOLD* ]]
  LINUX_GATE_HOLD=1 gate topic "$OUT" x.json
  [ "$status" -eq 64 ]
  FULL=1 hold_gate 1
  [ "$status" -eq 64 ]
  no_docker
}

@test "holds: a hold step that never ran fails the gate, and a failing one is named" {
  commit_holds topic 'a.json b.json@2of3\n'
  base_run
  DROP_STEPS='mutants-b@2of3' hold_gate 1
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: mutants-b@2of3(missing)" ]]
  DOCKER_SUMMARY='mutants-a                    rc=1   9s  baseline failed\nmutants-b@2of3               rc=0   9s  ok\n' hold_gate 1
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: mutants-a" ]]
}

@test "holds: a line that breaks the grammar fails every kind of run, naming its line number only, running nothing" {
  full_src
  commit_holds topic 'a.json\n'
  base_run   # a base of another head: the list is checked before the base is
  while IFS= read -r bad; do
    commit_holds topic "# fine\na.json\n$bad\nb.json\n"
    for kind in plain specs full hold; do
      : > "$CALLS"
      case $kind in
        plain) gate topic "$OUT" ;;
        specs) gate topic "$OUT" x.json ;;
        full) FULL=1 gate topic "$OUT" ;;
        hold) hold_gate 1 ;;
      esac
      [ "$status" -eq 1 ] || { echo "$kind accepted: $bad" >&2; return 1; }
      [[ $output == *"line 3 of tests/mutants/local-gate.txt"* ]] || { echo "$kind: no line number for: $bad" >&2; return 1; }
      [[ $output != *ZZmark* && $output != *a.txt* ]] || { echo "$kind echoed a token: $bad" >&2; return 1; }
      [[ ${lines[-1]} == "linux-gate: failed: holds" ]] || { echo "$kind: no verdict line for: $bad" >&2; return 1; }
      no_docker || { echo "$kind ran docker: $bad" >&2; return 1; }
    done
  done <<<"$BAD_LINES"
}

@test "holds: a refusal replaces the summary of an earlier run in a reused OUTDIR" {
  commit_holds topic 'a.json\n'
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  grep -q '^shellcheck ' "$OUT/summary.txt"
  commit_holds topic 'a.json\nZZmark.txt\n'
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  ! grep -q '^shellcheck ' "$OUT/summary.txt"
  grep -qE '^holds +rc=1 +line 2 of ' "$OUT/summary.txt"
  [ "$(head -1 "$OUT/summary.txt" | awk '{ print $1 }')" = head ]
}

@test "holds: a plain or FULL summary gets a holds M line after the head line (0 without the list)" {
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' holds 0)" ]
  full_src
  commit_holds topic '# c\na.json b.json\n\nd.json@1of2 d.json@2of2\ne.json\n'
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' holds 3)" ]
  FULL=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$OUT/summary.txt")" = "$(printf '%-28s %s' holds 3)" ]
  [ "$(grep -c '^mutants-' "$OUT/summary.txt")" -eq 0 ]
  # a mutants-only summary says hold=N/M instead
  base_run
  hold_gate 3
  [ "$status" -eq 0 ]
  ! grep -q '^holds ' "$OUT/summary.txt"
}

@test "holds: the accepted grammar (blank lines, # lines, tabs, no final newline, @100of100), and --holds counts the holds" {
  commit_holds topic '\n# c\n#tight\n\t# tab comment\n  a.json\tb.json@100of100  \n\nd.x-y_z.json@1of1'
  holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  base_run
  hold_gate 2
  [ "$status" -eq 0 ]
  grep_step 'mutants-d.x-y_z@1of1'
  [[ $(sed -n 2p "$OUT/summary.txt") == *"hold=2/2" ]]
}

@test "holds: a list that is not a regular file, or has a NUL byte or a CR, fails closed (1, nothing runs)" {
  commit_raw topic sh -c 'mkdir -p tests/mutants && ln -s /dev/null tests/mutants/local-gate.txt'
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *"local-gate.txt"* && $output == *"regular file"* ]]
  no_docker
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"regular file"* ]]
  commit_raw topic sh -c "git rm -q -f $LGF && mkdir -p $LGF && : > $LGF/x"
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  no_docker
  commit_raw topic sh -c "rm -rf tests/mutants/local-gate.txt && printf 'a.json\\n\\0\\n' > tests/mutants/local-gate.txt"
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *NUL* ]]
  no_docker
  commit_holds topic 'a.json\r\nb.json\r\n'
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *CR* ]]
  commit_holds topic '# a comment with a CR\r\na.json\n'
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output == *CR* ]]
  holds_of topic
  [ "$status" -eq 1 ]
  no_docker
}

@test "holds: a link or gitlink for tests or tests/mutants is not 'no holds': it fails closed in --holds and in a run" {
  git -C "$SRC" branch -f linked main
  commit_raw linked sh -c 'mkdir -p tests real && ln -s ../real tests/mutants'
  holds_of linked
  [ "$status" -eq 1 ]
  [[ $output == *"plain directory"* ]]
  gate linked "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: holds" ]]
  no_docker
  # tests itself a link
  git -C "$SRC" branch -f tlink main
  commit_raw tlink sh -c 'mkdir real_tests && : > real_tests/x && ln -s real_tests tests'
  holds_of tlink
  [ "$status" -eq 1 ]
  gate tlink "$OUT"
  [ "$status" -eq 1 ]
  # a gitlink for tests/mutants
  git -C "$SRC" branch -f glink main
  git -C "$SRC" checkout -q glink
  git -C "$SRC" update-index --add --cacheinfo 160000,"$(git -C "$SRC" rev-parse main)",tests/mutants
  git -C "$SRC" commit -qm gitlink
  git -C "$SRC" checkout -q main
  holds_of glink
  [ "$status" -eq 1 ]
  gate glink "$OUT"
  [ "$status" -eq 1 ]
  no_docker
}

@test "holds: a spec a hold names must be a regular file under tests/mutants at the head; no entry there may have an @" {
  NOSPECS=1 commit_holds topic 'a.json\nZZmark.json\n'
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"line 1 of tests/mutants/local-gate.txt"* && $output == *"no such spec"* ]]
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ $output != *ZZmark* ]]
  no_docker
  # a spec that is a link is not a spec
  commit_raw topic sh -c 'echo "{}" > tests/mutants/ZZmark.json && ln -s ZZmark.json tests/mutants/a.json'
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"line 1 of"* ]]
  # a path is no spec name, even to a spec that exists
  commit_raw topic sh -c 'rm -f tests/mutants/a.json && mkdir -p tests/mutants/sub && echo "{}" > tests/mutants/sub/x.json && echo "{}" > tests/mutants/a.json'
  commit_holds topic 'a.json\nsub/x.json\n'
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"line 2 of tests/mutants/local-gate.txt"* && $output == *"not a hold"* ]]
  # a tracked file literally named like a slice would be the spec a sliced hold runs
  commit_holds topic 'a.json@1of2 a.json@2of2\n'
  commit_raw topic sh -c 'rm -f tests/mutants/a.json && echo "{}" > tests/mutants/a.json && echo "{\"mutants\": []}" > "tests/mutants/a.json@1of2"'
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"@"* ]]
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  no_docker
  # nested too; and with the file gone the entry no longer matters (no list, no holds)
  commit_raw topic sh -c 'git rm -q -f "tests/mutants/a.json@1of2" && mkdir -p tests/mutants/sub && echo x > "tests/mutants/sub/y@z"'
  holds_of topic
  [ "$status" -eq 1 ]
  commit_raw topic git rm -q -f "$LGF"
  holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "holds: a plain run with SPECs and a non-empty list at the head says once that the list was skipped" {
  commit_holds topic 'a.json\nb.json\n'
  gate topic "$OUT" x.json
  [ "$status" -eq 0 ]
  [ "$(grep -c skipped <<<"$output")" -eq 1 ]
  [[ $output == *LINUX_GATE_HOLD* ]]
  [ "$(grep -c '^mutants-' "$OUT/summary.txt")" -eq 1 ]
  # no note without SPECs, with an empty list, or in a mutants-only run
  gate topic "$OUT"
  [ "$status" -eq 0 ]
  [[ $output != *skipped* ]]
  base_run x.json
  LINUX_GATE_BASE=$BASE/summary.txt mo_gate topic "$OUT" x.json
  [ "$status" -eq 0 ]
  [[ $output != *skipped* ]]
  commit_holds topic '# nothing held\n'
  gate topic "$OUT" x.json
  [ "$status" -eq 0 ]
  [[ $output != *skipped* ]]
}

@test "holds --holds BRANCH: prints the number of holds at the branch's head (0 without the file), runs nothing, needs no lock" {
  holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  commit_holds topic 'a.json b.json@1of4\n# c\n\nd.json\ne.json@2of2\n'
  mkdir -p "$SRC/tests/mutants"; printf 'x.json\n' > "$SRC/$LGF"   # the source tree's own, not the head's
  holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  [ ! -s "$CALLS" ]
  [ ! -e "$OUT" ]
  # a full SHA works, and so does a tag
  holds_of "$(git -C "$SRC" rev-parse topic)"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  git -C "$SRC" tag v1 topic
  holds_of v1
  [ "$output" = 3 ]
  # a SHA that names no commit
  holds_of "$(printf 'a%.0s' $(seq 40))"
  [ "$status" -eq 1 ]
  rm -f "${SRC:?}/${LGF:?}"
  git -C "$SRC" checkout -q -f main
  commit_holds topic 'a.json\nZZmark.txt\n'
  holds_of topic
  [ "$status" -eq 1 ]
  [[ $output == *"line 2 of tests/mutants/local-gate.txt"* && $output != *ZZmark* ]]
  no_docker
}

@test "holds --holds: replace refs, a caller's object directory and pathspec settings do not change what is read" {
  commit_holds topic 'a.json\n'
  blob=$(git -C "$SRC" rev-parse "topic:$LGF")
  other=$(printf 'a.json\nb.json\n' | git -C "$SRC" hash-object -w --stdin)
  git -C "$SRC" replace "$blob" "$other"
  holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  git -C "$SRC" replace -d "$blob"
  GIT_OBJECT_DIRECTORY="$BATS_TEST_TMPDIR/nowhere" holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  GIT_OBJECT_DIRECTORY="$BATS_TEST_TMPDIR/nowhere" GIT_ALTERNATE_OBJECT_DIRECTORIES="$BATS_TEST_TMPDIR/nowhere" gate topic "$OUT"
  [ "$status" -eq 0 ]
  # an icase pathspec would find Local-Gate.txt: only the exact name is the list
  commit_raw topic sh -c "git rm -q -f $LGF && printf 'a.json\\n' > tests/mutants/Local-Gate.txt"
  GIT_ICASE_PATHSPECS=1 holds_of topic
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  GIT_ICASE_PATHSPECS=1 GIT_GLOB_PATHSPECS=1 gate topic "$OUT"
  [ "$status" -eq 0 ]
}

@test "holds --holds: a bad call is usage (64) or an unknown branch is 1" {
  run "$LG" --holds
  [ "$status" -eq 64 ]
  run "$LG" --holds topic extra
  [ "$status" -eq 64 ]
  run "$LG" --holds -x
  [ "$status" -eq 64 ]
  run "$LG" --holds nosuchbranch
  [ "$status" -eq 1 ]
}

@test "holds: a clone whose work tree is not the head fails closed (checkout), naming no path, running nothing" {
  commit_holds topic 'a.json\n'
  # git is a shim that edits a tracked file of the clone once it is made: the check itself, on any filesystem
  real_git=$(command -v git)
  printf '#!/bin/bash\n"%s" "$@"; rc=$?\nif [ $rc -eq 0 ] && [[ " $* " == *" clone "* ]]; then echo tampered >> "${!#}/tools/scrub.sh"; fi\nexit $rc\n' "$real_git" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  gate topic "$OUT"
  [ "$status" -eq 1 ]
  [[ ${lines[-1]} == "linux-gate: failed: checkout" ]]
  grep -qE '^checkout +rc=1 ' "$OUT/summary.txt"
  [[ $output != *scrub.sh* ]]
  no_docker
  rm -f "$BATS_TEST_TMPDIR/bin/git"
  gate topic "$OUT"
  [ "$status" -eq 0 ]
}

@test "holds: two tracked paths that differ only in case: fail closed where the filesystem folds case, run where it doesn't" {
  NOSPECS=1 commit_holds topic 'Big.json\n'
  git -C "$SRC" checkout -q topic
  git -C "$SRC" update-index --add --cacheinfo 100644,"$(echo REAL | git -C "$SRC" hash-object -w --stdin)",tests/mutants/Big.json
  git -C "$SRC" update-index --add --cacheinfo 100644,"$(echo DECOY | git -C "$SRC" hash-object -w --stdin)",tests/mutants/big.json
  git -C "$SRC" commit -qm collide
  git -C "$SRC" checkout -q -f main
  : > "$BATS_TEST_TMPDIR/CaseProbe"
  gate topic "$OUT"
  if [ -e "$BATS_TEST_TMPDIR/caseprobe" ]; then
    [ "$status" -eq 1 ]
    [[ ${lines[-1]} == "linux-gate: failed: checkout" ]]
    no_docker
  else
    [ "$status" -eq 0 ]
  fi
}

@test "holds: a hold's refusal cannot overwrite the base summary it was asked to stand on" {
  commit_holds topic 'a.json\n'
  base_run
  before=$(cat "$BASE/summary.txt")
  LINUX_GATE_BASE=$BASE/summary.txt LINUX_GATE_HOLD=3 mo_gate topic "$BASE"
  [ "$status" -eq 1 ]
  [[ $output == *"own summary.txt"* ]]
  [ "$(cat "$BASE/summary.txt")" = "$before" ]
  no_docker
}

@test "holds: a mutants-only run needs a base with exactly one holds line equal to this head's M" {
  commit_holds topic 'a.json\nb.json\n'
  base_run
  grep -qE '^holds +2$' "$BASE/summary.txt"
  mkdir -p "$BATS_TEST_TMPDIR/b2" "$BATS_TEST_TMPDIR/b3" "$BATS_TEST_TMPDIR/b4"
  grep -v '^holds ' "$BASE/summary.txt" > "$BATS_TEST_TMPDIR/b2/summary.txt"
  sed 's/^holds .*/holds                        3/' "$BASE/summary.txt" > "$BATS_TEST_TMPDIR/b3/summary.txt"
  { cat "$BASE/summary.txt"; printf '%-28s %s\n' holds 2; } > "$BATS_TEST_TMPDIR/b4/summary.txt"
  for b in b2 b3 b4; do
    : > "$CALLS"
    LINUX_GATE_BASE=$BATS_TEST_TMPDIR/$b/summary.txt LINUX_GATE_HOLD=1 mo_gate topic "$OUT"
    [ "$status" -eq 1 ] || { echo "$b accepted for a hold" >&2; return 1; }
    [[ $output == *"holds 2"* ]]
    no_docker
    LINUX_GATE_BASE=$BATS_TEST_TMPDIR/$b/summary.txt mo_gate topic "$OUT" x.json
    [ "$status" -eq 1 ] || { echo "$b accepted for a SPEC run" >&2; return 1; }
    no_docker
  done
  hold_gate 1
  [ "$status" -eq 0 ]
}
