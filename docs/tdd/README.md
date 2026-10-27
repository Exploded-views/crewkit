# RED records

Failing test runs recorded before the code that made them pass. Commit SHAs and review
rounds in them refer to the development history, which the public repo doesn't carry.

| File | What it shows |
|---|---|
| [install-red.txt](install-red.txt) | The install.sh suite against the skeleton installer. The tests that passed were existing behaviour (usage, dry run, unsupported OS, the plugins step) or exited 1 only because the step was not implemented yet; the mutation check is what proves those bite. |
| [coverage-floors-red.txt](coverage-floors-red.txt) | The `coverage-floors.py` tests before the script existed. The one pass ("missing report is exit 2") was Python's own exit 2 for a missing script, not the behaviour. |
| [install-prebuilt-red.txt](install-prebuilt-red.txt) | The suite against the old memsync step after the tests moved to the `--prebuilt-dir` flow. |
| [install-review-red.txt](install-review-red.txt) | Tests for the Opus review's findings before the fixes. The bad-tag, absolute-path and missing-bitc-binary tests passed at once: the code was right, and they were missing; their mutants are the proof they bite. |
| [lint-pins-red.txt](lint-pins-red.txt) | The pin-lint tests before duplicate keys, CR, per-tool targets and URL hosts were checked. |
| [shared-index-red.txt](shared-index-red.txt) | Hostile note names and file names against the old `shared-index`. |
| [hooks-guard-red.txt](hooks-guard-red.txt) | The change-notice hooks without claude-memsync installed, before the guard (exit 127). |
| [lint-inputs-red.txt](lint-inputs-red.txt) | The Inputs-first lint tests before `check_inputs` existed. |
| [setup-pages-red.txt](setup-pages-red.txt) | The new lint against the old README, install.md and getting-started (4 errors); the page rewrites made it pass. Running the snippets then found unquoted assignments, which the lint now also catches. |
| [check-workflows-red.txt](check-workflows-red.txt) | The workflow-lint tests before the script existed. Two passed for the wrong reasons: Python's own exit 2 for a missing script, and a case that expects no finding. |
| [check-workflows-mutants.txt](check-workflows-mutants.txt) | The workflow lint's mutation check. A first ad hoc run reported 7/7 killed, but one mutant was a syntax error; the honest rerun found an untested inline runner group, now tested. |
| [tilde-red.txt](tilde-red.txt) | The lint tests for `$HOME/<…>` path inputs before the rule existed. |
| [double-dash-red.txt](double-dash-red.txt) | install.md's own blocks run against a stub installer, before `BOOTSTRAP_FLAGS`. The first test also failed because the path input wasn't under `$HOME` yet. |
| [perf-red.txt](perf-red.txt) | The perf harness tests before `tools/perf.py` existed. The first real run then failed the dry-run budget (1.5 s): the new skip logic called Claude Code during a dry run. |
| [plugins-rerun-red.txt](plugins-rerun-red.txt) | The plugin re-run tests before the skip logic, after replacing `! grep` with `none`: a first run showed a test passing that should not, because bats ignores `!` mid-test. |
| [dry-run-claude-red.txt](dry-run-claude-red.txt) | "A dry run makes no claude calls", before the fix. |
| [settings-red.txt](settings-red.txt) | The settings-reader tests before `lib/settings.sh` existed. |
| [settings-mutants.txt](settings-mutants.txt) | The reader's mutation check; three survivors along the way became tests (frontmatter-only reads for `crew_keys`, duplicate keys, a file with no frontmatter). |
| [settings-perf-red.txt](settings-perf-red.txt) | The 5 ms lookup budget against the first reader (9.4 ms); one awk per lookup brought it to about 4 ms. |
| [mutate-py-red.txt](mutate-py-red.txt), [lint-settings-red.txt](lint-settings-red.txt) | The mutation runner's and the settings lint's tests before the code. |
| [lane-new-red.txt](lane-new-red.txt), [lane-new-mutants.txt](lane-new-mutants.txt) | `lane-new` before it existed, and its mutation check (a survivor became the "worktree removed, branch kept" test). |
| [lane-state-red.txt](lane-state-red.txt), [lane-state-mutants.txt](lane-state-mutants.txt) | `lane-state` before it existed (13 tests), and its 12 mutants, all killed. |
| [lane-hygiene-red.txt](lane-hygiene-red.txt), [lane-hygiene-mutants.txt](lane-hygiene-mutants.txt), [lane-hygiene-perf-red.txt](lane-hygiene-perf-red.txt) | `lane-hygiene` before it existed (the reference's fixture cases, ported), its 9 mutants, and the 25 ms budget against the first version (49 ms). |
| [settings-trust-red.txt](settings-trust-red.txt) | The reader's trust checks (stop at the repo root, skip files writable by others) before they existed. A first version also refused group-writable files and broke every normal `umask 002` setup; it now refuses world-writable only. |
| [lane-verdict-red.txt](lane-verdict-red.txt), [lane-verdict-mutants.txt](lane-verdict-mutants.txt) | `lane-verdict` against the shared fixture cases before it existed; its 12 mutants (an equivalent one was replaced: an unreadable record also fails the schema check). |
| [lint-nonliteral-red.txt](lint-nonliteral-red.txt) | The non-literal settings-key rule before it existed. |
| [settings-injection-red.txt](settings-injection-red.txt) | A settings value with quotes and `$(...)` reaching `bash -c` in `lane-verdict`, before the fix. |
| [gh-write-red.txt](gh-write-red.txt), [gh-write-mutants.txt](gh-write-mutants.txt) | `gh-write` before it existed, and its 14 mutants, including the piped duplicate check, which a padded `gh api` reply kills every time. |
| [lane-refresh-red.txt](lane-refresh-red.txt), [lane-refresh-mutants.txt](lane-refresh-mutants.txt) | `lane-refresh` before it existed, and its 10 mutants. One test first passed for the wrong reason: two commits were byte-identical (same parent, tree, message and second). |
| [lane-land-red.txt](lane-land-red.txt), [lane-land-mutants.txt](lane-land-mutants.txt) | `lane-land` before it existed (27 tests), and its mutants. Writing it found two bugs elsewhere: `lane-verdict` never compared a record's implementer with the lane's, and a test that rewrote the stub `gh` wrote through a symlink into the repo's own `tests/stub-gh` (the helper now copies it). |
| [lane-land-review-red.txt](lane-land-review-red.txt) | The Opus review's MEDIUM 4 and LOW 5–8 as tests before the fixes. One passed by accident and exposed a worse bug: a failing commit status context had no name, so it was never counted as red. |
| [verdict-red.txt](verdict-red.txt), [verdict-mutants.txt](verdict-mutants.txt) | `lib/verdict.py` before it existed, against both fixture sets. Its mutation check first left seven survivors where another rule also rejected the fixture; each got a case where its rule alone decides. |
| [install-mutants.txt](install-mutants.txt) | The mutation check after GREEN: every mutant killed. |
| [land-batch-red.txt](land-batch-red.txt) | The land-batch suite (31 landing scenarios plus the new rules) before `plugins/crew-orchestrator/bin/land-batch` existed: all 55 fail. |
| [land-batch-verdicts-red.txt](land-batch-verdicts-red.txt) | The reviewer-identity tests (`review.source` comments or records) before the code; one passed for the wrong reason (see its header). |
| [land-batch-survivors-red.txt](land-batch-survivors-red.txt) | Tests for the first mutation run's survivors; one exposed a false "PARTIAL LANDING" alarm on a normal exit 20. A third survivor was a redundant check, now removed. |
| [land-batch-mutants.txt](land-batch-mutants.txt) | The final mutation run for land-batch (all killed) and lib/landing.sh, and what was done about each item it left. |
| [land-batch-review-red.txt](land-batch-review-red.txt) | The first independent review's nine findings on land-batch, one failing test each, before the fixes. |
| [land-batch-rereview-red.txt](land-batch-rereview-red.txt) | The re-review's items (file-name rounds, a required ci.workflow, bash 4.4, every comment page and later verdicts), before the fixes. The lander-level mutant for a failed risk read was dropped: only the library can fail that way, and its own test covers it. |
| [landing-lane-crosscheck-red.txt](landing-lane-crosscheck-red.txt) | The landers' lane cross-checks (a stale lane head; the lane's implementer against the verdict record) before the code. |
| [coverage-sh-red.txt](coverage-sh-red.txt) | `tools/coverage.sh`'s new tests (which suites run under kcov, what is covered, `KCOV_IMAGE`) against the old script. |
| [coverage-py-red.txt](coverage-py-red.txt) | Python coverage: several reports for the floors tool, coverage.py's report converted, and `tools/coverage-py.sh`'s venv guards, before the code. |
| [lint-mutants-red.txt](lint-mutants-red.txt) | The lint that every `tests/mutants/*.json` is in CI's `mutants` matrix, before the check existed. |
| [landing-queue-red-green.md](landing-queue-red-green.md) | RED vs GREEN for the 5 `landing-queue` cases: 3 RED failures, all GREEN; the description fix that made the skill load. |
| [checks-red.txt](checks-red.txt) | `lib/checks.py`'s suite before the code, its widened rules (no other red, every workflow, status contexts) before they were written, and land-batch's status-context test on the old `ci_state`. The mutation run then found a real bug: the required check's state overwrote a same-named red job from another workflow. |
| [lint-conflicts-red.txt](lint-conflicts-red.txt) | The conflict-marker lint, added after a merge left markers in a committed JSON file: RED, its run on that commit, and its mutation check. |
| [landers-review-model-red.txt](landers-review-model-red.txt) | The landers passing `review_model` to `verdict.py` for high-risk PRs, before the change. |
| [land-batch-review2-red.txt](land-batch-review2-red.txt) | The second delta review of land-batch: a failed or empty jobs read let an older green run vouch (fail-open), statuses past the first page, an unnamed PR author; the failing cases before the fixes. |
| [checks-fail-closed-red.txt](checks-fail-closed-red.txt) | `lib/checks.py` made fail-closed after a review found that a run which couldn't speak yet (no jobs listed, a failed read) let an older green run vouch: the new cases on the old code. |
| [checks-invariant-red.txt](checks-invariant-red.txt) | The checks invariant: every combination of CI states compared with an oracle, run against earlier versions of `lib/checks.py` (581, 282 and 234 wrong cells), and the ignored-job bug it found. |
| [landers-review-model-file-only-red.txt](landers-review-model-file-only-red.txt) | The landers reading `review_model` from settings files only, before the change: the environment could weaken or empty it. |
| [landers-jobs-filter-latest-red.txt](landers-jobs-filter-latest-red.txt) | The landers listing jobs with `filter=latest`, so a re-run lists only its latest attempt (checks.py reads a mixed list as pending): the test on the old call. |
| [landers-ignored-required-red.txt](landers-ignored-required-red.txt) | The landers refusing `ignored_checks` that names `required_check` (78) up front, which checks.py would refuse (64) on every poll: the test on the old code. |
| [landers-review3-red.txt](landers-review3-red.txt) | After the third review of land-batch: the stub's failed reads now print real gh's error body (a lander ignoring the status read's exit code had passed), App authors match their `[bot]` comments, and each PR's head is re-checked before the squash. |
| [landers-file-only-red.txt](landers-file-only-red.txt) | The landers with every gate setting file-only: an exported `CREWKIT_*` could drop a high-risk area (the third review's repro) or add a reviewer. |
| [landers-main-checkout-red.txt](landers-main-checkout-red.txt) | The landers reading settings from the main checkout (`crew_cd_main_checkout` in `crew_land_init`): run from a lane worktree, a local file could drop a high-risk area. |
| [checks-allow-list-red.txt](checks-allow-list-red.txt) | `lib/checks.py` redesigned as an allow-list (only "success" is green, no fallback to an older run, mixed attempts pending) after a fourth review found skipped `needs:` dependents passing: the new invariant, its states generated from GitHub's documented values, on the old code. |
| [skills-baseline.md](skills-baseline.md) | The first RED run for the new skills, under `--safe-mode` (kept as history). |
| [skills-red-green.md](skills-red-green.md) | RED vs GREEN for the 10 skill cases, both arms with the same isolation. |

Two tests were written after their code (links in an archive, https-only curl); their mutants
are killed, which is the evidence that they guard those lines.
