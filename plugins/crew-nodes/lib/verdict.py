#!/usr/bin/env python3
"""verdict.py: the one review-verdict check every crewkit lander uses.

  verdict.py records  --pr N --head SHA --dir DIR [--lane-implementer WHO] [--reviewers LIST]
                      [--model M]
  verdict.py comments --head SHA --author LOGIN --comments-json FILE --reviewers LIST
                      [--markers LIST] [--require-sha true|false] [--model M]

Prints "accepted" or "not accepted: <reason>". The rules are in crewkit's
docs/review-verdicts.md; in short:

records: in DIR/<pr>/, round 1 is <head>.json and round n is <head>.<n>.json (n >= 2, no
  leading zero). Any other file name for the head, or a body round that differs from its file's
  round, refuses the head. Every JSON value in every file counts. At the top round EVERY record
  must pass: schema 1, pr and headSha matching, verdict "merge", a reviewer that is non-empty,
  not the record's implementer, and in --reviewers when given; with a lane, the record's
  implementer must be the lane's. A PR without a lane needs --reviewers.
comments: candidates are comments by a login in --reviewers (required), not the PR author,
  whose first line (after leading whitespace) names the full head or starts with a marker's
  first word. The latest candidate by created_at decides: it approves only if its first line
  starts with a marker followed by whitespace or the end of the line and, with --require-sha
  (the default), contains the full head. Only that first line counts, never the rest of a body.
--model M (review_model; default opus when the flag is absent, so a caller that leaves it out
  fails closed; only an explicit --model "" checks nothing): with records, every top-round record's "model"
  must match M; with comments, the deciding first line must carry a word model=<model> that
  matches M. A model matches when, ignoring case, it equals M or has M as a whole token after
  splitting on - _ . : / and spaces: "opus" matches "claude-opus-5-5", never "opusx".

Callers pass every value; this file reads no settings, so it can be vendored unchanged into each
plugin (tools/vendor-lib.sh) and stays byte-identical (the lint checks it).

Exit 0 = accepted, 1 = not accepted, 64 = usage, 65 = bad data (a head that isn't a full SHA,
unreadable comment JSON). Stdlib only.
"""
import argparse
import json
import pathlib
import re
import sys

SHA = re.compile(r"^[0-9a-f]{40}$")


def listing(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def json_values(text):
    """Every JSON value in text (a file may hold several, one after another)."""
    dec, i, out = json.JSONDecoder(), 0, []
    text = text.strip()
    while i < len(text):
        value, j = dec.raw_decode(text, i)
        out.append(value)
        i = j
        while i < len(text) and text[i].isspace():
            i += 1
    return out


def file_round(name, head):
    """1 for <head>.json, n for <head>.<n>.json with n >= 2 and no leading zero, else None."""
    if name == f"{head}.json":
        return 1
    m = re.fullmatch(re.escape(head) + r"\.([1-9][0-9]*)\.json", name)
    if m and int(m.group(1)) >= 2:
        return int(m.group(1))
    return None


def model_matches(value, want):
    """value names the model want: equal to it, or holding it as a whole token, ignoring case."""
    if not isinstance(value, str):
        return False
    v, w = value.lower(), want.lower()
    return v == w or w in re.split(r"[-_.:/ ]+", v)


def check_records(pr, head, directory, lane_impl, reviewers, model=""):
    allowed = listing(reviewers)
    if not lane_impl and not allowed:
        return "records for a PR without a lane need review.reviewers"
    d = pathlib.Path(directory) / str(pr)
    names = sorted(f.name for f in d.glob(f"{head}*.json")) if d.is_dir() else []
    if not names:
        return f"no verdict record for head {head[:12]}"
    records = []
    for name in names:
        rnd = file_round(name, head)
        if rnd is None:
            return f"{name} is not a valid record name for this head (round 1 is <head>.json, round n is <head>.<n>.json)"
        try:
            values = json_values((d / name).read_text())
        except (OSError, ValueError):
            return f"{name} is not readable JSON"
        if not values:
            return f"{name} is empty"
        for v in values:
            if not isinstance(v, dict):
                return f"{name} holds a value that isn't a record"
            # type() rather than isinstance(): True is an int in Python, and True == 1.
            if type(v.get("round")) is not int or v.get("round") != rnd:
                return f"{name} holds a record for round {v.get('round')!r}, but its file is round {rnd}"
            records.append(v)
    top = max(r["round"] for r in records)
    for r in (r for r in records if r["round"] == top):
        if r.get("schema") != 1:
            return f"a round {top} record has an unknown schema {r.get('schema')!r}"
        if r.get("pr") != pr or r.get("headSha") != head:
            return f"a round {top} record names PR {r.get('pr')!r} at {str(r.get('headSha'))[:12]}, not this PR's head"
        if r.get("verdict") != "merge":
            return f"a round {top} record says {r.get('verdict')!r}, not merge"
        who, impl = r.get("reviewer") or "", r.get("implementer") or ""
        if not who:
            return f"a round {top} record names no reviewer"
        if who == impl:
            return f"{who} reviewed their own work"
        if lane_impl and impl != lane_impl:
            return f"a round {top} record names {impl!r} as implementer, but the lane's implementer is {lane_impl!r}"
        if allowed and who not in allowed:
            return f"{who} is not in review.reviewers"
        if model and not model_matches(r.get("model"), model):
            return f"a round {top} record's model {r.get('model')!r} is not {model} (review_model)"
    return None


def marked(line, marker):
    """line starts with marker, followed by whitespace or the end of the line."""
    return line.startswith(marker) and (len(line) == len(marker) or line[len(marker)].isspace())


def check_comments(head, author, comments, reviewers, markers, require_sha, model=""):
    allowed = listing(reviewers)
    if not allowed:
        return "review.reviewers is not set, so no comment verdict counts"
    ms = listing(markers) or ["Verdict: MERGE"]
    openers = [m.split(" ")[0] for m in ms]
    candidates = []
    for c in comments:
        if not isinstance(c, dict):
            continue
        who = ((c.get("user") or {}).get("login")) or ""
        if not who or who == author or who not in allowed:
            continue
        first = (c.get("body") or "").lstrip().split("\n", 1)[0].rstrip("\r")
        if head in first or any(first.startswith(o) for o in openers):
            candidates.append((c.get("created_at") or "", first))
    if not candidates:
        return "no verdict comment from review.reviewers"
    at, line = sorted(candidates, key=lambda x: x[0])[-1]
    if not any(marked(line, m) for m in ms):
        return f"the latest verdict comment ({at}) doesn't start with {' or '.join(ms)}"
    if require_sha and head not in line:
        return f"the latest verdict comment ({at}) doesn't name the full head {head}"
    if model:
        named = re.findall(r"(?:^|\s)model=(\S+)", line)
        if not named:
            return "review_model needs a model on the verdict line"
        if not all(model_matches(n, model) for n in named):
            return f"the latest verdict comment ({at}) names model {', '.join(named)}, not {model} (review_model)"
    return None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print(f"verdict.py: {message}", file=sys.stderr)
        sys.exit(64)


def main(argv):
    p = Parser(prog="verdict.py", add_help=True)
    sub = p.add_subparsers(dest="source")
    r = sub.add_parser("records")
    r.add_argument("--pr", required=True, type=int)
    r.add_argument("--head", required=True)
    r.add_argument("--dir", required=True)
    r.add_argument("--lane-implementer", default="")
    r.add_argument("--reviewers", default="")
    r.add_argument("--model", default="opus")
    c = sub.add_parser("comments")
    c.add_argument("--head", required=True)
    c.add_argument("--author", required=True)
    c.add_argument("--comments-json", required=True)
    c.add_argument("--reviewers", default="")
    c.add_argument("--markers", default="Verdict: MERGE")
    c.add_argument("--require-sha", default="true", choices=["true", "false"])
    c.add_argument("--model", default="opus")
    a = p.parse_args(argv)
    if a.source is None:
        p.print_usage(sys.stderr)
        return 64
    if not SHA.match(a.head):
        print(f"not accepted: the head {a.head!r} is not a full 40-hex SHA")
        return 65
    if a.source == "records":
        why = check_records(a.pr, a.head, a.dir, a.lane_implementer, a.reviewers, a.model)
    else:
        try:
            comments = json.loads(pathlib.Path(a.comments_json).read_text())
        except (OSError, ValueError) as e:
            print(f"not accepted: the comments JSON is unreadable ({e.__class__.__name__})")
            return 65
        if not isinstance(comments, list):
            print("not accepted: the comments JSON is not a list")
            return 65
        why = check_comments(a.head, a.author, comments, a.reviewers, a.markers, a.require_sha == "true", a.model)
    if why:
        print(f"not accepted: {why}")
        return 1
    print("accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
