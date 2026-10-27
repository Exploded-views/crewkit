#!/usr/bin/env python3
"""make.py OUT_DIR: write the shared verdict-record fixtures (docs/review-verdicts.md).

Each case is its own verdict dir, OUT_DIR/<case>/, holding <pr>/<headSha>[.<round>].json files.
SHAs are built here rather than committed, so no long hex literal sits in the repo. Prints one
line per case: <case> <pr> <headSha> <implementer> <expected: accept|reject>.

make.py --model-cases OUT_DIR writes the review_model cases instead, one line each:
<case> <pr> <headSha> <implementer> <model wanted> <expected>. Their own set, so readers of
the five-column lines above never see a sixth column.

Writers' and readers' tests both use these cases; change them only with both sides' tests.
"""
import json
import pathlib
import sys

HEAD = "ab" * 20          # the PR's current head in every case
OTHER = "cd" * 20         # some other commit
PR = 101


def rec(**over):
    body = {"schema": 1, "pr": PR, "headSha": HEAD, "verdict": "merge", "round": 1,
            "reviewer": "reviewer-session", "implementer": "lane-session", "model": "opus",
            "reviewedAt": "2026-10-26T04:00:00Z"}
    body.update(over)
    return body


CASES = {
    "valid-merge": ("accept", [(f"{HEAD}.json", rec())]),
    "wrong-sha": ("reject", [(f"{HEAD}.json", rec(headSha=OTHER))]),
    "changes": ("reject", [(f"{HEAD}.json", rec(verdict="changes"))]),
    "self-review": ("reject", [(f"{HEAD}.json", rec(reviewer="lane-session"))]),
    "superseded": ("reject", [(f"{HEAD}.json", rec()), (f"{HEAD}.2.json", rec(round=2, verdict="changes"))]),
    "later-merge": ("accept", [(f"{HEAD}.json", rec(verdict="changes")), (f"{HEAD}.2.json", rec(round=2))]),
    "unknown-schema": ("reject", [(f"{HEAD}.json", rec(schema=2))]),
    "no-reviewer": ("reject", [(f"{HEAD}.json", rec(reviewer=""))]),
    "not-json": ("reject", [(f"{HEAD}.json", "{not json")]),
    "tie": ("reject", [(f"{HEAD}.json", rec(round=2, verdict="changes")), (f"{HEAD}.2.json", rec(round=2))]),
    # From the M1 Opus review: two names for round 1, a leading zero, and a file holding two
    # JSON values (how a real tie reaches disk).
    "dup-round-1": ("reject", [(f"{HEAD}.json", rec()), (f"{HEAD}.1.json", rec(verdict="changes"))]),
    "leading-zero": ("reject", [(f"{HEAD}.json", rec()), (f"{HEAD}.2.json", rec(round=2)),
                                (f"{HEAD}.02.json", rec(round=2, verdict="changes"))]),
    "two-values": ("reject", [(f"{HEAD}.json", json.dumps(rec()) + "\n" + json.dumps(rec(verdict="changes")))]),
    "tie-all-merge": ("accept", [(f"{HEAD}.json", json.dumps(rec()) + "\n" + json.dumps(rec(reviewer="reviewer-2")))]),
    # Cases where exactly one rule stands between the record and an accept.
    "only-dot-one": ("reject", [(f"{HEAD}.1.json", rec())]),
    "leading-zero-merge": ("reject", [(f"{HEAD}.json", rec()), (f"{HEAD}.02.json", rec(round=2))]),
    "body-round-mismatch-merge": ("reject", [(f"{HEAD}.json", rec(round=5))]),
    "other-implementer": ("reject", [(f"{HEAD}.json", rec(implementer="someone-else"))]),
    # From the re-review: a boolean round (True == 1 in Python) is not a round.
    "boolean-round": ("reject", [(f"{HEAD}.json", rec(round=True))]),
    "none": ("reject", []),
}

# review_model (--model): every deciding record names the wanted model, matched
# case-insensitively as the whole value or a whole token of it (split on - _ . : / space).
MODEL_CASES = {
    "model-opus": ("opus", "accept", [(f"{HEAD}.json", rec())]),
    "model-full-id": ("opus", "accept", [(f"{HEAD}.json", rec(model="claude-opus-5-5"))]),
    "model-case": ("opus", "accept", [(f"{HEAD}.json", rec(model="Claude Opus 5.5"))]),
    "model-sonnet": ("opus", "reject", [(f"{HEAD}.json", rec(model="sonnet"))]),
    "model-missing": ("opus", "reject", [(f"{HEAD}.json", {k: v for k, v in rec().items() if k != "model"})]),
    "model-empty": ("opus", "reject", [(f"{HEAD}.json", rec(model=""))]),
    "model-prefix-only": ("opus", "reject", [(f"{HEAD}.json", rec(model="opusx"))]),
    "model-not-a-string": ("opus", "reject", [(f"{HEAD}.json", rec(model=["opus"]))]),
    # Every top-round record must match, not just one of them.
    "model-one-of-two": ("opus", "reject", [(f"{HEAD}.json", json.dumps(rec()) + "\n" + json.dumps(rec(reviewer="reviewer-2", model="sonnet")))]),
    # Only the top round decides: an earlier round's model doesn't matter.
    "model-earlier-round": ("opus", "accept", [(f"{HEAD}.json", rec(verdict="changes", model="sonnet")), (f"{HEAD}.2.json", rec(round=2))]),
}


def write(out, case, files):
    d = out / case / str(PR)
    d.mkdir(parents=True, exist_ok=True)
    for name, body in files:
        (d / name).write_text(body if isinstance(body, str) else json.dumps(body))


def main(argv):
    if argv[0] == "--model-cases":
        out = pathlib.Path(argv[1])
        for case, (model, expect, files) in MODEL_CASES.items():
            write(out, case, files)
            print(case, PR, HEAD, "lane-session", model, expect)
        return
    out = pathlib.Path(argv[0])
    for case, (expect, files) in CASES.items():
        write(out, case, files)
        print(case, PR, HEAD, "lane-session", expect)


if __name__ == "__main__":
    main(sys.argv[1:])
