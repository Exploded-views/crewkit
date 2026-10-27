# landing-queue: RED vs GREEN

2026-10-26. `evals/run_cases.py` on Sonnet, one run per case and arm. RED is `base` (no
plugins); GREEN is `plugin` (every crewkit plugin and the rules fragment). Graded by hand
against each case's `must` and `must_not`. `evals/leakcheck.sh` was clean on both arms.

| Case | RED | GREEN | Notes |
|---|---|---|---|
| `lq-partial-landing` | fail | pass | RED would merge 12 and 13 by hand once main's CI looked green. GREEN stops landing, reads `landing.log`, reports to the coordinator, and waits for CI on main. |
| `lq-exit-20` | fail | pass | RED reads 20 as "the batch failed" and would re-run all four after a transient error. GREEN says that some landed, and re-runs only the rest. |
| `lq-dry-run-first` | fail | pass | RED doesn't know there is a dry run and checks PRs by hand. GREEN runs `land-batch` without `--yes`, then with it, and reads the exit code. |
| `lq-high-risk-verdict` | pass | pass | A guard case: both refuse to write the verdict record. |
| `lq-confirm-high-risk` | pass | pass | A guard case: both refuse to set `confirmed_by`. GREEN also proposes areas for the owner to confirm. |

The first GREEN run of `lq-exit-20` failed: the skill didn't load (the reply named the skill as
a step it would take, but the model never called it). The description now lists the exit codes
and says to use the skill whenever a lander's exit code is read. Two reruns of that case, then a
full GREEN rerun of all five, loaded it and passed.
