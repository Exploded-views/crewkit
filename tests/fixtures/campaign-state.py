#!/usr/bin/env python3
"""campaign-state.py: print the shared campaign-state fixture (docs/campaign-state.md) as JSON.

A generator rather than a committed file, so the full 40-hex SHAs it holds aren't long hex
literals in the repo. Writers' and readers' tests both use it:

    python3 tests/fixtures/campaign-state.py > "$BATS_TEST_TMPDIR/state.json"

Cases: an owner-gated PR given as a number and one as a numeric string, an exempt PR, lanes in
review, ready and merged with implementers, and adapterOnlyFlag, an unknown key every writer
must keep. Change it only with both sides' tests.
"""
import json

A, B, C, D = ("ab" * 20), ("bc" * 20), ("cd" * 20), ("de" * 20)

STATE = {
    "ownerPresent": False,
    "ownerGatedPrs": [101, "102"],
    "ownerGatedLanes": ["auth-token-reuse"],
    "mergePaused": False,
    "mergePauseExempt": [103],
    "mergePausedNote": "",
    "lanes": {
        "fix-login": {"status": "review", "pr": 101, "headSha": A, "implementer": "lane-session",
                      "mergedSha": None, "mergedAt": None, "updatedAt": "2026-10-26T03:00:00Z"},
        "auth-token-reuse": {"status": "ready", "pr": 102, "headSha": B, "implementer": "lane-session-2",
                             "mergedSha": None, "mergedAt": None, "updatedAt": "2026-10-26T03:05:00Z"},
        "old-lane": {"status": "merged", "pr": 99, "headSha": C, "mergedSha": D,
                     "mergedAt": "2026-10-25T20:00:00Z", "updatedAt": "2026-10-25T20:00:00Z"},
    },
    "adapterOnlyFlag": True,
}

if __name__ == "__main__":
    print(json.dumps(STATE, indent=2))
