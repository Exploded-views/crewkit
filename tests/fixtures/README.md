# Test fixtures

| File | Used by | What it holds |
|---|---|---|
| `verdicts/make.py` | `tests/lane-verdict.bats` (writer) and the landers' tests (readers) | Writes one verdict dir per case into a directory you name and prints `<case> <pr> <headSha> <implementer> <expected>` per line (expected is `accept` or `reject`) ([format](../../docs/review-verdicts.md)). SHAs are built at run time. |
| `campaign-state.py` | `tests/lane-state.bats` (writer) and the landers' tests (readers) | Prints a valid campaign state ([schema](../../docs/campaign-state.md)): `ownerGatedPrs` with a number and a numeric string, a `mergePauseExempt` PR, lanes in `review`, `ready` and `merged` with full SHAs and implementers, and `adapterOnlyFlag`, an unknown key every writer must keep. A generator, so no long hex literal is committed. |
