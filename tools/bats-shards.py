#!/usr/bin/env python3
"""bats-shards.py: split tests/*.bats into N groups by measured file time.

    tools/bats-shards.py [--root DIR] files K/N   # the bats files of shard K of N, one per line
    tools/bats-shards.py [--root DIR] totals N    # each shard's seconds, then the largest
    tools/bats-shards.py [--root DIR] check       # tests/bats-times.json names exactly tests/*.bats

DIR defaults to the repository this script is in. tests/bats-times.json maps each bats file name
to its measured seconds (a positive number). Files are placed heaviest first, each into the shard
with the least time so far (ties go to the lower shard), so the largest shard is within the
heaviest file of the mean. A bats file with no entry still runs, with the median weight; an entry
for a file that is gone is ignored by `files` and `totals` and reported by `check`. The result
depends only on the file names and the table, so every machine computes the same shards.

Exit 0 = ok, 1 = the table is missing or bad, or `check` found a difference, 64 = usage.
"""
import json
import statistics
import sys
from pathlib import Path

MAX_SHARDS = 16


def usage():
    print("bats-shards: usage: bats-shards.py [--root DIR] files K/N | totals N | check  (1 <= K <= N <= 16)",
          file=sys.stderr)
    return 64


def load_table(root):
    path = root / "tests" / "bats-times.json"
    try:
        table = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        raise SystemExit(f"bats-shards: cannot read tests/bats-times.json ({e.__class__.__name__})") from None
    if not isinstance(table, dict) or not table:
        raise SystemExit("bats-shards: tests/bats-times.json must be a non-empty object of file: seconds")
    for name, secs in table.items():
        if isinstance(secs, bool) or not isinstance(secs, (int, float)) or not secs > 0:
            raise SystemExit(f"bats-shards: tests/bats-times.json: {name}: seconds must be a positive number")
    return table


def bats_files(root):
    return sorted(p.name for p in (root / "tests").glob("*.bats"))


def weights(root, table):
    files = bats_files(root)
    known = [table[f] for f in files if f in table]
    median = statistics.median(known) if known else 1
    return {f: table.get(f, median) for f in files}


def split(weight, n):
    """[(files, seconds)] for n shards: heaviest first, each into the lightest shard so far."""
    shards = [([], 0) for _ in range(n)]
    for name in sorted(weight, key=lambda f: (-weight[f], f)):
        i = min(range(n), key=lambda j: (shards[j][1], j))
        shards[i] = (shards[i][0] + [name], shards[i][1] + weight[name])
    return [(sorted(files), secs) for files, secs in shards]


def shard_count(text):
    if not text.isdigit() or not 1 <= int(text) <= MAX_SHARDS:
        return None
    return int(text)


def main(argv):
    args = argv[1:]
    root = Path(__file__).resolve().parent.parent
    if args[:1] == ["--root"]:
        if len(args) < 2:
            return usage()
        root, args = Path(args[1]), args[2:]
    if not args:
        return usage()
    verb, rest = args[0], args[1:]
    if verb == "check":
        if rest:
            return usage()
        table = load_table(root)
        files = set(bats_files(root))
        problems = [f"{f}: no entry in tests/bats-times.json" for f in sorted(files - set(table))]
        problems += [f"{f}: no such file in tests/ (stale entry in tests/bats-times.json)" for f in sorted(set(table) - files)]
        if problems:
            print("\n".join(problems))
        return 1 if problems else 0
    if verb == "files":
        if len(rest) != 1 or rest[0].count("/") != 1:
            return usage()
        k_text, n_text = rest[0].split("/")
        k, n = shard_count(k_text), shard_count(n_text)
        if k is None or n is None or k > n:
            return usage()
        shards = split(weights(root, load_table(root)), n)
        print("\n".join(shards[k - 1][0]))
        return 0
    if verb == "totals":
        n = shard_count(rest[0]) if len(rest) == 1 else None
        if n is None:
            return usage()
        shards = split(weights(root, load_table(root)), n)
        for i, (files, secs) in enumerate(shards, 1):
            print(f"shard {i}/{n}: {secs:g}s ({len(files)} files)")
        print(f"largest: {max(s for _, s in shards):g}s")
        return 0
    return usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
