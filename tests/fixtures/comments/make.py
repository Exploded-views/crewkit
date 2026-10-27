#!/usr/bin/env python3
"""make.py OUT_DIR: write the shared comment-verdict fixtures (docs/review-verdicts.md).

Each case is OUT_DIR/<case>.json, a REST issue-comments array as `gh api
repos/R/issues/N/comments --paginate | jq -s add` returns it (user.login, created_at, body).
Prints one line per case: <case> <headSha> <pr author> <reviewers> <expected: accept|reject>.
The reviewers column is comma-separated, or "-" for none. SHAs are built here so no long hex
literal is committed. Change cases only with both landers' tests.

make.py --model-cases OUT_DIR writes the review_model cases instead, one line each:
<case> <headSha> <pr author> <reviewers> <model wanted> <expected>. A comment can't show its
model, so with review_model set the verdict line must carry model=<model> after the head.
"""
import json
import pathlib
import sys

HEAD = "ab" * 20
OTHER = "cd" * 20


def c(who, at, body):
    return {"user": {"login": who}, "created_at": f"2026-10-26T0{at}:00:00Z", "body": body}


M = f"Verdict: MERGE {HEAD}"
CASES = {
    "valid": ("accept", "author", "rev-a", [c("rev-a", 1, M)]),
    "leading-space": ("accept", "author", "rev-a", [c("rev-a", 1, "  " + M)]),
    # HIGH 1: only the first "Verdict:" line counts, never the rest of the body.
    "body-trick": ("reject", "author", "rev-a", [c("rev-a", 1, f"Verdict: CHANGES-REQUESTED on {HEAD}\n\nAfter the fix I expect Verdict: MERGE")]),
    "quotes-old-merge": ("reject", "author", "rev-a", [c("rev-a", 1, f"Verdict: CHANGES-REQUESTED {HEAD}\n\n> {M}")]),
    "prefix-word": ("reject", "author", "rev-a", [c("rev-a", 1, f"Verdict: MERGE-WITH-FIXES {HEAD}")]),
    "not-a-reviewer": ("reject", "author", "rev-a", [c("intruder", 1, M)]),
    # MEDIUM 3: the PR author never counts, even if listed as a reviewer.
    "pr-author": ("reject", "rev-a", "rev-a", [c("rev-a", 1, M)]),
    "later-sha-less-changes": ("reject", "author", "rev-a", [c("rev-a", 1, M), c("rev-a", 2, "Verdict: CHANGES-REQUESTED")]),
    "later-merge-other-sha": ("reject", "author", "rev-a", [c("rev-a", 1, M), c("rev-a", 2, f"Verdict: MERGE {OTHER}")]),
    "later-merge-wins": ("accept", "author", "rev-a", [c("rev-a", 1, f"Verdict: CHANGES-REQUESTED {HEAD}"), c("rev-a", 2, M)]),
    "out-of-order-list": ("reject", "author", "rev-a", [c("rev-a", 2, f"Verdict: CHANGES-REQUESTED {HEAD}"), c("rev-a", 1, M)]),
    "short-sha": ("reject", "author", "rev-a", [c("rev-a", 1, f"Verdict: MERGE {HEAD[:9]}")]),
    "chatter-after": ("accept", "author", "rev-a", [c("rev-a", 1, M), c("rev-a", 2, "Thanks, landing soon.")]),
    "no-reviewers": ("reject", "author", "-", [c("rev-a", 1, M)]),
    "sha-on-second-line": ("reject", "author", "rev-a", [c("rev-a", 1, f"Verdict: MERGE\n{HEAD}")]),
}


MODEL_CASES = {
    "model-opus": ("opus", "accept", [c("rev-a", 1, f"{M} model=opus")]),
    "model-full-id": ("opus", "accept", [c("rev-a", 1, f"{M} model=claude-opus-5-5")]),
    "model-missing": ("opus", "reject", [c("rev-a", 1, M)]),
    "model-sonnet": ("opus", "reject", [c("rev-a", 1, f"{M} model=sonnet")]),
    "model-prefix-only": ("opus", "reject", [c("rev-a", 1, f"{M} model=opusx")]),
    # Only the first line counts, for the model as for the verdict.
    "model-in-body": ("opus", "reject", [c("rev-a", 1, f"{M}\n\nmodel=opus")]),
    # "model=" must be its own word on the line, not the tail of another one.
    "model-glued": ("opus", "reject", [c("rev-a", 1, f"{M} xmodel=opus")]),
    # Every model= on the line must match: a second, other model makes the line ambiguous.
    "model-two-names": ("opus", "reject", [c("rev-a", 1, f"{M} model=opus model=sonnet")]),
}


def main(argv):
    model_cases = argv[0] == "--model-cases"
    out = pathlib.Path(argv[1] if model_cases else argv[0])
    out.mkdir(parents=True, exist_ok=True)
    if model_cases:
        for case, (model, expect, comments) in MODEL_CASES.items():
            (out / f"{case}.json").write_text(json.dumps(comments))
            print(case, HEAD, "author", "rev-a", model, expect)
        return
    for case, (expect, author, reviewers, comments) in CASES.items():
        (out / f"{case}.json").write_text(json.dumps(comments))
        print(case, HEAD, author, reviewers, expect)


if __name__ == "__main__":
    main(sys.argv[1:])
