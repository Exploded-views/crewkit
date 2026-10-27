# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `tools/export.py` copies its own files (the tool, its lint and their tests) verbatim, and a
  test checks that exporting the repo changes Markdown prose only. The export had dropped a
  fixture from the public copy of its own tests, which let a mutant live there.

- CI runs install.sh's dry runs under bash 3.2 on Linux (`bash32`, the `bash:3.2` image pinned
  by digest) on every PR. The `macos` job and the `mutants` matrix are off while the repo is
  private, and `ci-ok` accepts their skip only then. `tools/check-workflows.py` fails a macOS
  job without the `if: ${{ !github.event.repository.private }}` guard.

- `install.sh` pins claude-memsync v0.3.0-ev.1 (Linux and macOS, amd64 and arm64), accepts a
  pre-release tag suffix, and refuses an unpacked `claude-memsync` whose `version` isn't the
  pinned tag before running its bootstrap.
- `install.sh` installs bitc on macOS too (bitc ships darwin builds since v0.1.0), checks the
  release's `checksums.txt` lists the pinned hash, and refuses a binary whose `bitc version --json`
  isn't the pinned release with `"release":true`, leaving any existing bitc in place.
- Coverage covers the plugins' bash scripts, not just `install.sh`. It runs in its own CI job
  on a kcov image derived on the runner (the pinned digest plus git and jq from a dated Debian
  snapshot, never pushed), over every suite except `docs.bats` and `settings.bats`, and prints
  each file's percentage so new floors can be set from CI's first measurement.
- Python coverage in the same CI job: coverage.py (pinned by sha256, installed on the runner)
  measures the plugins' Python tools while the bats suites run, with floors in the same ratchet
  file (`tools/coverage-floors.py` takes several reports).
- The repo becomes **crewkit**: the marketplace is renamed `crewkit` (was `agent-toolkit`) and
  now also lists `memory-notices`, the hooks-only plugin for claude-memsync's shared index and
  change notices.
- `install.sh` skeleton (dry run by default, `--yes`, `--only`, bootstrap flags after `--`)
  and stub release pins in `pins/`. The plugins step works; the bitc and claude-memsync steps
  are skipped until releases are pinned.
- `docs/install.md` and `docs/getting-started.md`.
- Skills: `herdr` and `using-bitc` in agent-practice; `using-memsync` (a draft) in
  memory-notices. Eval cases for each.
- `tools/lint-skills.py` checks plugin hooks and the pin files, and accepts hooks-only plugins.
- CI: shellcheck and an installer dry run.
- install.sh fetches and installs the pinned bitc and claude-memsync releases: https only,
  sha256 checked before unpacking, safe unpacking (no absolute paths, `..` or links), pin
  files parsed rather than sourced, bootstrap exit 3 passed through, and an edited rules file
  backed up. Pins gain a `*_URL` key; bitc's list Linux targets only.
- Tests: a bats suite for install.sh (pinned bats-core), unit tests for the coverage tool, a
  mutation check (`tools/mutate.sh`), coverage under a digest-pinned kcov image, and a coverage
  ratchet (`coverage-floors.json`, `tools/coverage-floors.py`). See `docs/testing.md`.
- `.github/CODEOWNERS` for review routing.
- `tools/export.py`: builds the public copy as a fresh one-commit export of a reviewed commit.
- `using-bitc`: a spent retry budget means report, not retry (eval-driven).
- memory-notices: `shared-index` shows a note only under a slug name (falling back to the file
  stem) and skips, with a count, notes whose file names aren't slug-safe, since notes come
  from other hosts. The change-notice hooks are a no-op when claude-memsync isn't installed.
- CI: actions/checkout v7.0.1.
- Setup docs: path inputs are written `$HOME/<…>` (a `~` inside quotes isn't expanded; the
  lint requires it), and install.md's bootstrap flags live in one `BOOTSTRAP_FLAGS` list so
  adding one never produces a second `--` (a bats test runs the page's own blocks).
- `lib/settings.sh`: one settings reader for every crewkit script (environment, the project's
  `.claude/crewkit.local.md` and `.claude/crewkit.md`, `~/.claude/crewkit.md`, then defaults),
  with `docs/settings.md` as its schema. The lint checks documented keys and byte-identical
  vendored copies; a lookup stays under 5 ms (one awk). `high_risk_areas` has no default: the
  setup agent proposes areas from the repo and the human confirms them.
- `crew-lanes` plugin (M1, in development): `lane-new` creates or reuses a lane's worktree and
  branch, writes the packet's exemptions, commits and pushes the lane note, and runs
  `lane.setup_hook`; `.lane/` scratch is ignored through the shared exclude, written once. The `lanes` skill starts here.
- The settings reader treats settings as code: the project search stops at the repository root,
  and a settings file not owned by you or world-writable is skipped with a warning (raised by an
  automated security review of `lane.setup_hook`). The file list is found once per directory and
  cached, primed when sourced, so ten lookups cost about 29 ms.
- `tools/perf.py` takes the best of 3 trials per scenario, so load from other sessions doesn't
  fail a budget while a real slowdown still does.
- agent-practice uses crewkit's single `state_dir` (with `decisions.md` and `state.md` in it) in
  place of `log_dir`, `decisions_log` and `state_file`; the lint rejects the retired keys. Its
  default moves to `~/.local/state/crewkit`: set `state_dir` to keep an existing directory.
- `lane-land`: the gated lander for one lane's PR, under the shared landing lock: merge pause,
  PR state, the lane's recorded head, checks on the exact head, mergeability, the owner gate
  (every PR needs the owner until `high_risk_areas` is confirmed), `land.precheck_hook`, and an
  independent verdict for the exact head (records, or comments only from `review.reviewers`
  that name the full head and whose marker ends at a word boundary, newest by `createdAt`).
  Squash pinned with `--match-head-commit`, verified MERGED, recorded, labelled. A corrupt
  campaign state fails closed. The PR author's own comments never count, a verdict must name
  the full head SHA, a marker must end at a word boundary, and the state is written under a lock.
- `lib/verdict.py`: the one verdict implementation every lander uses (shared with
  crew-orchestrator's land-batch, so the landers can't drift apart), vendored by `tools/vendor-lib.sh`
  (was `vendor-settings.sh`) and lint-checked byte for byte. Fixes from the M1 review:
  only the first `Verdict:` line of a comment counts (a CHANGES comment that mentioned "Verdict:
  MERGE" later in its body approved); `<sha>.1.json` and `<sha>.02.json` are refused instead of
  colliding with real rounds; every JSON value in a record file counts, and every record at the
  top round must pass; the PR author's comments never count. One suite, `tests/verdict.bats`,
  over shared record and comment fixtures; `lane-verdict check` and `lane-land` call it. A record's
  round must be an integer: `"round": true` equals 1 in Python and is refused.
- `lane-land` (from the M1 review): the required check must come from `ci.workflow` when
  set; commit status contexts are read by their state (a failing one was silently ignored); a
  merge call that errors after merging is recorded, not reported as a failure; the pre-check
  hook has a timeout; a merged PR whose state or journal can't be written fails loudly after
  retries.
- `install.sh` exits 64 for usage errors, per the shared table (it used 2).
- `docs/exit-codes.md`: one exit-code table for every crewkit script, shared with
  crew-orchestrator. crew-lanes now uses 64 for usage and 65 for refused values (it used 2).
- `lane-verdict check` refuses a record whose implementer isn't the lane's, and any record
  whose body round disagrees with its file name (a faked tie); the shared fixture gains a tie
  case.
- `lane-refresh`: merges main into a lane PR in a temporary worktree and pushes only if the
  patch-id of the diff against main still equals the PR's own change; never force-pushes,
  verifies the push with ls-remote, and handles a PR stacked on a squash-merged parent by
  applying its own change onto main and retargeting it first. Distinct exit codes per outcome.
- `gh-write`: the one path for the lanes' GitHub writes (comments and reviews idempotent by
  header, capped bodies, labels, ready), serialised under a lock, spaced, retried and journalled.
  Its duplicate check captures `gh` output before grepping: piping into `grep -q` under
  `pipefail` fails when `gh` gets SIGPIPE, which would double-post (a deterministic test).
  `tests/stub-gh` keeps comments, reviews and labels on disk for the lane tests.
- Campaign state: lanes record their `implementer`, so a lander can check a verdict record
  against it, and `headSha`/`mergedSha` must be full 40-hex SHAs. The shared fixture is now a
  generator (`tests/fixtures/campaign-state.py`).
- Security: `lane-state` and `lane-verdict` pass settings keys and defaults to the reader as
  arguments; `lane-verdict` had interpolated a default built from another setting into shell
  text (found by an automated review; a hostile `state_dir` test now guards it).
- Review verdict records (`docs/review-verdicts.md`, shared with crew-orchestrator): one file per
  round per head, schema 1, accepted only at the highest round with verdict merge and a reviewer
  who isn't the implementer; `lane-verdict` writes and checks them, with a shared fixture
  generator. New settings `review.source`, `review.reviewers`, `review.verdict_dir`.
- The settings lint fails on a non-literal key (a variable or a wrapper's `$1`) unless the line
  says `# settings-keys: ...`; it found an untagged wrapper in `lane-state`.
- `lane-hygiene`: the deterministic clean-worktree check after every agent step, ported with its
  fixture tests (now in bats); it writes JSON in pure bash and makes one `rev-parse`, so it runs
  in about 18 ms against a 25 ms budget (the first version took 49 ms).
- `crew-orchestrator` plugin (M2, in development): `land-batch` lands several reviewed PRs on
  one batch CI run, built test first from 31 landing scenarios. Repo, checks and labels
  are all settings. It is a dry run unless given `--yes`, and exit codes follow bitc
  (64, 75, 78). New rules: nothing is batched until `high_risk_areas` is confirmed, and a PR
  touching a high-risk area lands alone, only with an independent verdict bound to its exact
  head. The verdict comes from an allow-listed reviewer's comment or a review-workflow record,
  never from the PR's own author. Owner gates also cover gated lanes and merge-pause
  exemptions. The `landing-queue` skill starts here.
- `lib/checks.py`: one "green on the exact head" for every lander, covering Actions jobs (the
  required workflow's newest run and every other workflow's) and commit status contexts. Nothing
  else red or pending may count. land-batch's landers use it and `lib/verdict.py`, and their own
  copies of that logic are gone.
- `lane-state` and `docs/campaign-state.md`: the campaign's shared `state.json` with a schema,
  written only under a lock through a temp file and an atomic rename, with a shared fixture for the writers' and readers' tests.
- `tools/mutate.py`: a generic mutation runner driven by `tests/mutants/*.json`, run in CI.
- Performance budgets: `perf-budgets.json` and `tools/perf.py` (test first) hold p95 budgets
  for shared-index (150 notes, under 100 ms), the guarded change hook with memsync absent,
  the installer's dry run, and a no-op plugins re-run; CI enforces them with headroom.
- install.sh's plugins step asks once what is already added and installed and skips it, and
  leaves a current rules file alone; a dry run makes no Claude Code calls. The perf budget
  caught the dry run at 1.5 s before that.
- Tests: a `none` helper replaces `! grep`, which bats doesn't enforce mid-test (four such
  assertions, one of them committed, asserted nothing). The coverage floor rises to 97.7.
- `tools/check-workflows.py`: a reusable workflow lint (GitHub-hosted runners only, no
  `pull_request_target`, every action pinned by SHA), with unit tests and its own mutation
  check, run in CI. Both mutation runners reject a mutant that doesn't parse.
- Public-export checklist: the hosted-runners rule, and fork-PR workflow approval for all
  outside collaborators right after the repo goes public.
- Setup docs are Inputs first and DRY: the README quick start, `docs/install.md` and
  `docs/getting-started.md` declare each value once and use `$NAME` in the steps. The lint
  checks it (declared, quoted and used placeholders; no bare `/path/to/` or `OWNER`; no
  repeated long literal or command), with unit tests. getting-started's settings step no
  longer overwrites an existing settings file.
- `evals/run_cases.py` and `evals/leakcheck.sh`: run eval arms with identical isolation and a
  fake shared-memory index, and check the output names no real notes.
- The scrub exempts the `<TOOL>_SHA256_<os>_<arch>` lines of `pins/*.env` from long-hex, and
  nothing else in those files.
- install.sh hands claude-memsync's unpacked release to its `bootstrap.sh --prebuilt-dir`
  (bootstrap installs the binaries) and cross-checks the release's `SHA256SUMS`.
- From the install.sh review: archives may hold only files and directories; an inherited
  `tmp` variable can't redirect the work dir; a failing command exits 1, never its own code;
  bash 3.2 (stock macOS) no longer trips on an empty flag list; rules backups never overwrite
  an earlier one; the plan doesn't echo bootstrap flags; flags after `--` are reported when
  the memsync step doesn't run; downloads time out and retry.
- The pin lint rejects duplicate keys and CR line endings, and requires a hash for every
  target a tool ships (bitc: Linux; memsync: Linux and macOS).
- CI: the coverage ratchet fails closed (merge base for PRs, the previous commit for pushes),
  kcov runs with no network on a read-only repo, a macOS job dry-runs install.sh on bash 3.2,
  and the mutation check runs the unmutated suite first.

### Changed

- The scrub's default denylist path is `~/.config/crewkit/denylist.txt`.
- Manifests and skills no longer link to a hosting org; docs use placeholders.
- `host-safety`: bitc's exit 64 is "refused, fix the call" and 69 is "unavailable, stop and
  report" (it said 69 meant refused).

- `session-bootstrap` is folded into `orchestrator` as `orchestrator/new-session.md`; the plugin
  has one skill fewer.
- Estimates: the rules fragment and the `orchestrator` skill base estimates on measured
  merge velocity (`velocity_file`), quoted in hours with gating waits listed separately.
  New eval `orch-estimate-hours`.

## [0.1.0] - 2026-10-24

First draft, local only.

### Added

- `agent-practice` plugin with eight skills: cross-session-messaging, orchestrator, landing,
  independent-review, host-safety, secret-safe-checks, crash-recovery, session-bootstrap.
- `rules/CLAUDE-fragment.md`: always-on rules to include from `CLAUDE.md`.
- Settings file with documented placeholders (`settings.example.md`) instead of hard-coded
  names, paths, check names and models.
- Plugin marketplace manifest.
- `evals/cases.json`: behaviour evals, including permission laundering and unquoted approvals.
- `tools/scrub.sh` (counts and file names only, private denylist, `--secrets-only` for CI,
  `--self-test`), `tools/lint-skills.py`, pre-commit config and hook installer.
- CI workflow with SHA-pinned actions.
