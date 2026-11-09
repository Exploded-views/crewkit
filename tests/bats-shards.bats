#!/usr/bin/env bats
# tools/bats-shards.py: split tests/*.bats into N groups by measured file time (tests/bats-times.json),
# for the hosted bats job, the hosted coverage.py shards and tests/run.sh --shard K/N.

: "${BATS_TEST_TIMEOUT:=120}"
export BATS_TEST_TIMEOUT

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  TOOL=$REPO/tools/bats-shards.py
  R=$BATS_TEST_TMPDIR/root
  mkdir -p "$R/tests"
}

# mk_root NAME=SECONDS...: a scratch root with those bats files and that times table.
mk_root() {
  local pair json="{" sep=""
  for pair in "$@"; do
    : > "$R/tests/${pair%%=*}"
    json+="$sep\"${pair%%=*}\": ${pair##*=}"
    sep=", "
  done
  printf '%s}\n' "$json" > "$R/tests/bats-times.json"
}

# shard_files K N [ROOT]: the files of shard K/N, one per line.
shard_files() { python3 -I "$TOOL" --root "${3:-$R}" files "$1/$2"; }

@test "the tool exists and is executable" {
  [ -x "$TOOL" ]
}

@test "files: every bats file is in exactly one shard, for each N from 1 to 8" {
  mk_root a.bats=50 b.bats=40 c.bats=30 d.bats=20 e.bats=10 f.bats=9 g.bats=8 h.bats=7 i.bats=1
  local n k all
  for n in 1 2 3 4 5 6 7 8; do
    all=""
    for k in $(seq 1 "$n"); do
      all+="$(shard_files "$k" "$n")"$'\n'
    done
    [ "$(printf '%s' "$all" | grep . | sort)" = "$(cd "$R/tests" && ls *.bats | sort)" ]
  done
}

@test "files: the heaviest files go to different shards" {
  mk_root big1.bats=600 big2.bats=590 big3.bats=580 s1.bats=5 s2.bats=4 s3.bats=3 s4.bats=2 s5.bats=1
  run shard_files 1 3
  [ "$status" -eq 0 ]
  local f
  for k in 1 2 3; do
    f=$(shard_files "$k" 3 | grep -c '^big')
    [ "$f" -eq 1 ]
  done
}

@test "files: with N=4 the largest shard is the heaviest file alone (300), the best possible" {
  mk_root a.bats=300 b.bats=200 c.bats=190 d.bats=100 e.bats=90 f.bats=40 g.bats=30 h.bats=20 i.bats=10
  # total 980, N=4: no shard can be below 300 (the heaviest file)
  local k f sum worst=0 files=0
  for k in 1 2 3 4; do
    sum=0
    for f in $(shard_files "$k" 4); do
      files=$((files + 1))
      sum=$((sum + $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$R/tests/bats-times.json" "$f")))
    done
    ((sum > worst)) && worst=$sum
  done
  [ "$files" -eq 9 ]
  [ "$worst" -le 300 ]
}

@test "files: the same input gives the same shards every time, and a shard's files are sorted" {
  # unequal weights, so the order they are placed in is not the order of their names
  mk_root a.bats=1 b.bats=50 c.bats=3 d.bats=40 e.bats=2 f.bats=30 g.bats=4
  run shard_files 3 3
  [ "$status" -eq 0 ]
  first=$output
  [ -n "$first" ]
  run shard_files 3 3
  [ "$output" = "$first" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 3 ]
  [ "$output" = "$(printf '%s\n' "$output" | LC_ALL=C sort)" ]
}

@test "files: a file missing from the table is still run, once, with the median weight" {
  mk_root a.bats=100 b.bats=100 c.bats=100
  : > "$R/tests/new.bats"
  local all
  all="$(shard_files 1 2)"$'\n'"$(shard_files 2 2)"
  [ "$(printf '%s\n' "$all" | grep -c '^new.bats$')" -eq 1 ]
  [ "$(printf '%s\n' "$all" | grep -c .)" -eq 4 ]
}

@test "files: a table entry for a file that is gone is ignored" {
  mk_root a.bats=100 b.bats=100
  printf '{"a.bats": 100, "b.bats": 100, "gone.bats": 999}\n' > "$R/tests/bats-times.json"
  run shard_files 1 1
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a.bats\nb.bats')" ]
}

@test "files: a bad K/N is a usage error (64): 0/3, 4/3, 1/0, 1/17, x, 1/2/3, no argument" {
  mk_root a.bats=1
  local bad
  for bad in 0/3 4/3 1/0 1/17 x 1/2/3 3/-1 ""; do
    run python3 -I "$TOOL" --root "$R" files "$bad"
    [ "$status" -eq 64 ]
  done
  run python3 -I "$TOOL" --root "$R" files
  [ "$status" -eq 64 ]
  run python3 -I "$TOOL" --root "$R"
  [ "$status" -eq 64 ]
  run python3 -I "$TOOL" --root "$R" nonsense
  [ "$status" -eq 64 ]
}

@test "files: a table that is not JSON, is empty, or has a bad weight stops with exit 1 and says which" {
  mk_root a.bats=1
  local bad
  for bad in 'not json' '{}' '[1]' '{"a.bats": 0}' '{"a.bats": -3}' '{"a.bats": "x"}' '{"a.bats": true}'; do
    printf '%s\n' "$bad" > "$R/tests/bats-times.json"
    run python3 -I "$TOOL" --root "$R" files 1/1
    [ "$status" -eq 1 ]
    [[ $output == *bats-times.json* ]]
  done
  rm "$R/tests/bats-times.json"
  run python3 -I "$TOOL" --root "$R" files 1/1
  [ "$status" -eq 1 ]
  [[ $output == *bats-times.json* ]]
}

@test "check: passes when the table names exactly the bats files" {
  mk_root a.bats=1 b.bats=2
  run python3 -I "$TOOL" --root "$R" check
  [ "$status" -eq 0 ]
}

@test "check: a bats file with no entry fails and is named" {
  mk_root a.bats=1 b.bats=2
  : > "$R/tests/new.bats"
  run python3 -I "$TOOL" --root "$R" check
  [ "$status" -eq 1 ]
  [[ $output == *"new.bats: no entry"* ]]
}

@test "check: an entry for a file that is gone fails and is named" {
  mk_root a.bats=1
  printf '{"a.bats": 1, "gone.bats": 5}\n' > "$R/tests/bats-times.json"
  run python3 -I "$TOOL" --root "$R" check
  [ "$status" -eq 1 ]
  [[ $output == *"gone.bats: no such file"* ]]
}

@test "totals N: prints each shard's seconds and the largest, and the largest" {
  mk_root a.bats=300 b.bats=200 c.bats=100
  run python3 -I "$TOOL" --root "$R" totals 2
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "shard 1/2: 300s (1 files)" ]]
  [[ ${lines[1]} == "shard 2/2: 300s (2 files)" ]]
  [[ ${lines[2]} == "largest: 300s" ]]
}

@test "files: shard K is the Kth: the heaviest file is in shard 1, the lightest in shard 3" {
  mk_root a.bats=300 b.bats=200 c.bats=100
  [ "$(shard_files 1 3)" = "a.bats" ]
  [ "$(shard_files 2 3)" = "b.bats" ]
  [ "$(shard_files 3 3)" = "c.bats" ]
}

@test "totals: a file with no entry weighs the median of the others" {
  mk_root a.bats=10 b.bats=20 c.bats=30
  : > "$R/tests/new.bats"
  run python3 -I "$TOOL" --root "$R" totals 1
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "shard 1/1: 80s (4 files)" ]]
}

@test "totals: the largest line is the largest shard, not the smallest" {
  mk_root a.bats=300 b.bats=200
  run python3 -I "$TOOL" --root "$R" totals 2
  [ "${lines[-1]}" = "largest: 300s" ]
}

@test "without --root the tool reads the repository it is in, whatever the working directory" {
  cd "$BATS_TEST_TMPDIR"
  run python3 -I "$TOOL" check
  [ "$status" -eq 0 ]
}

@test "the repository's own table names exactly tests/*.bats" {
  run python3 -I "$TOOL" --root "$REPO" check
  [ "$status" -eq 0 ]
}

# tests/run.sh --shard K/N: the same split for the hosted bats job.
@test "run.sh --shard K/N runs only that shard's files" {
  git init -q "$R"
  mkdir -p "$R/tools"
  mk_root a.bats=50 b.bats=40 c.bats=30
  cp "$REPO/tests/run.sh" "$R/tests/"
  cp "$TOOL" "$R/tools/"
  # a stand-in for the pinned bats that records what it was asked to run
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$R/fake-bats"
  chmod +x "$R/fake-bats"
  printf '#!/bin/sh\necho "%s/fake-bats"\n' "$R" > "$R/tools/get-bats.sh"
  chmod +x "$R/tools/get-bats.sh"
  cd "$R"
  run tests/run.sh --shard 2/2 --abort
  [ "$status" -eq 0 ]
  expected=$(python3 -I "$TOOL" --root "$R" files 2/2 | sed "s|^|$(cd "$R" && pwd -P)/tests/|")
  got=$(grep '\.bats$' "$BATS_TEST_TMPDIR/ran" | sort)
  [ "$got" = "$(printf '%s\n' "$expected" | sort)" ]
  grep -qx -- '--abort' "$BATS_TEST_TMPDIR/ran"
  [ -z "$(grep -e '--shard' "$BATS_TEST_TMPDIR/ran" || true)" ]
}

@test "run.sh --shard with a bad value stops with exit 64 before running anything" {
  git init -q "$R"
  mkdir -p "$R/tools"
  mk_root a.bats=1
  cp "$REPO/tests/run.sh" "$R/tests/"
  cp "$TOOL" "$R/tools/"
  printf '#!/bin/sh\necho ran > "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$R/fake-bats"
  chmod +x "$R/fake-bats"
  printf '#!/bin/sh\necho "%s/fake-bats"\n' "$R" > "$R/tools/get-bats.sh"
  chmod +x "$R/tools/get-bats.sh"
  cd "$R"
  run tests/run.sh --shard 3/2
  [ "$status" -eq 64 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "run.sh --shard K/N with a shard that has no files stops with exit 64 and runs nothing" {
  git init -q "$R"
  mkdir -p "$R/tools"
  mk_root a.bats=1 b.bats=1
  cp "$REPO/tests/run.sh" "$R/tests/"
  cp "$TOOL" "$R/tools/"
  printf '#!/bin/sh\necho ran > "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$R/fake-bats"
  chmod +x "$R/fake-bats"
  printf '#!/bin/sh\necho "%s/fake-bats"\n' "$R" > "$R/tools/get-bats.sh"
  chmod +x "$R/tools/get-bats.sh"
  cd "$R"
  run tests/run.sh --shard 3/3
  [ "$status" -eq 64 ]
  [[ $output == *"no bats files"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "run.sh --shard with a broken times table stops with the planner's exit 1 and runs nothing" {
  git init -q "$R"
  mkdir -p "$R/tools"
  mk_root a.bats=1
  printf 'not json\n' > "$R/tests/bats-times.json"
  cp "$REPO/tests/run.sh" "$R/tests/"
  cp "$TOOL" "$R/tools/"
  printf '#!/bin/sh\necho ran > "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$R/fake-bats"
  chmod +x "$R/fake-bats"
  printf '#!/bin/sh\necho "%s/fake-bats"\n' "$R" > "$R/tools/get-bats.sh"
  chmod +x "$R/tools/get-bats.sh"
  cd "$R"
  run tests/run.sh --shard 1/1
  [ "$status" -eq 1 ]
  [[ $output == *bats-times.json* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}
