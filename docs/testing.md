# Testing

crewkit is built test first: a failing test before the code, recorded, then the code that
makes it pass. Key safety lines also get a mutation check, and coverage can only move up.

## Run everything

```bash
tests/run.sh                                          # bats suite for install.sh
python3 -m unittest discover -s tests -p 'test_*.py'  # tests for the repo's Python tools
tools/mutate.sh                                       # mutation check (runs the suite once per mutant)
tools/coverage.sh                                     # coverage under kcov, in its container
tools/coverage-floors.py --report .cache/coverage/bats.*/coverage.json
python3 tools/lint-skills.py                          # skills, manifests, hooks, evals, pins, setup pages
python3 tools/check-workflows.py                      # GitHub-hosted runners, no pull_request_target, SHA pins
python3 tools/mutate-check-workflows.py               # mutation check for the workflow lint
python3 tools/mutate.py tests/mutants/*.json          # mutation checks for lib/ and the plugins' scripts
```

The suite needs GNU tools (`sed -i`, `sha256sum`), so run it on Linux. CI dry-runs the
installer under bash 3.2 (macOS's stock `/bin/bash`) on every PR, in the `bash:3.2` image pinned
by digest (job `bash32`); on a public repo it also dry-runs it on macOS itself.

`tests/run.sh` fetches the pinned bats-core release into `.cache/` the first time
(`tools/get-bats.sh` checks its sha256 before unpacking). `tools/coverage.sh` needs Docker: it
runs the bats suites under kcov, as your user, unprivileged, with no network and the repo
mounted read-only, and covers `install.sh` and the plugins' bash scripts. `docs.bats` and
`settings.bats` are left out, because kcov's trace hook breaks under `bash -u -c`.

## Writing bats assertions

Use the `none` helper from `tests/helpers.bash` to assert that something did **not** happen
(`none -q '^curl' "$CALLS"`). A bare `! grep …` only counts on a test's last line: bats
ignores a negated command anywhere else, so it would assert nothing.

## How the install.sh tests work

Each test copies a small installer tree into a temp directory, with `install.sh` linked in,
an empty `$HOME`, and stub `curl`, `claude` and `uname` first on `PATH`. The `curl` stub
serves release archives the test built, and refuses to run unless the installer asked for
https only. Nothing touches the network or your real home directory.

## The required check

main's ruleset requires one check, `ci-ok`: a job that needs every other job, runs
`if: always()`, and passes only when every needed job's result is `success`
(`tools/ci-ok.py`), or `skipped` for a job that is off while the repo is private (next
section). `tools/lint-skills.py` fails if a job is missing from its `needs`, so a new
job can't skip the required check.

## History scrub

`tools/scrub.sh --history` runs the scrub's rules over every commit reachable from any ref:
every blob (each version of each file, binary ones too); every full path in every commit's tree,
and in any tree a ref or tag points at directly (so a renamed file's old name, a path that
shares its content with another, a submodule entry and a name with a newline are all read);
every commit or tag header other than a well-formed tree, parent, author, committer, object,
type, tag or tagger line (a `mergetag` carries a whole tag); commit and annotated-tag messages (tags on any
ref, tags of tags followed); author, committer and tagger identities; and ref and tag names. It
prints rule, place and count only: a file's content is named by its blob SHA
(`history:blob <sha>`), never by a path that could hold a term. A full SHA of one of the repo's
own objects and GitHub's merge identity (exactly `noreply@github.com`) are allowed; a
path-based exemption (a pin file, `tools/scrub-known-versions.txt`) applies to a blob only if
every path it ever had qualifies. Versions of `tools/scrub.sh` itself are exempt from its own
rules only when their blob SHA is in `tools/scrub-known-versions.txt` (the lint checks the
current one is). A denylist with an invalid pattern, or none, fails the scan, and so does a git
command that fails mid-scan (exit 1). Not covered: reflog-only objects, such as a stash that was
never pushed (they aren't reachable from a ref), and text in UTF-16 (grep reads bytes). The
history is extracted in the C locale, so a name or header in Latin-1 or any other encoding
that isn't valid UTF-8 is still read, and a header holding a NUL byte is read as text.
`tests/scrub-history.bats` plants a canary in each place in a throwaway repo.

The tree scan reads tracked files by NUL-separated name (so non-ASCII names are read too), scans
their paths, and doesn't print a path that matches the denylist or any rule. On a line marked
`scrub:pinned-hash`, only a sha256-length value (64 hex) is exempt from the long-hex rule.

## Jobs that are off while the repo is private

Actions minutes are billed on a private repo (macOS at 10x) and free on a public one. A job
whose own `if:` is exactly `${{ !github.event.repository.private }}` is skipped while the repo
is private: today `macos` and the `mutants` matrix (run the mutation checks locally, see below).
`ci-ok` accepts `skipped` from such a job only when `github.event.repository.private` is true;
it reads the guarded jobs from `ci.yml` itself, so a skip of any other job, or of a guarded job
on a public repo, still fails. `tools/check-workflows.py` fails a macOS job without the guard.

## Mutation check

`tools/mutate.sh` breaks one key line of `install.sh` at a time (accept any sha256, allow
links in an archive, source the pin file, and so on) and runs the suite against each mutant.
Every mutant must fail the suite. It runs the unmutated suite first and stops if that fails, so
a broken suite can't count as "every mutant killed", and it rejects a mutant that doesn't parse
(`bash -n`), which would fail every test for the wrong reason. `tools/mutate-check-workflows.py`
does the same for the workflow lint.

New scripts use `tools/mutate.py` with a spec in `tests/mutants/<name>.json` (target, suite,
and mutants as exact old/new text, which may span lines). It copies the tracked tree to a temp
directory, so the real tree is never changed, and applies the same rules: a passing baseline,
each mutant's text found exactly once, and mutants that parse. When you add a safety line, add its
mutant too.

In CI each spec runs as its own job (the `mutants` matrix in `.github/workflows/ci.yml`), so a
slow suite can't time out the others. The matrix is off while the repo is private: run the specs
locally before pushing. The required check's own specs (`ci-ok.json`, `lint-ci-ok.json`) also
run in the `lint` job, so they run either way. `tools/lint-skills.py` fails when a spec in
`tests/mutants/` is missing from that matrix, so add each new spec there. A bats suite always
passes `--abort` (`["bats", "--abort", "tests/x.bats"]`), so a killed mutant stops at its first
failing test; the lint fails a spec without it. The lint also fails a mutant whose `old` text
doesn't occur exactly once in its target, so editing a guarded line shows the mutant to update
at lint time, not after a mutation run. Keep each spec well inside the job's
`timeout-minutes`: when one grows past about ten minutes, split its mutants into specs by area,
with the same target and suite, as lane-land's `-checks`, `-config`, `-gates`, `-verdict` and
`-merge` specs do. `tools/mutate.sh` (install.sh's mutants) runs in a job
of its own too, against `tests/install.bats` only, the suite that runs `install.sh`.

## The checks invariant

`tests/checks_invariant.py` checks `lib/checks.py`'s answer against an oracle written from its
rule (an allow-list: green only when everything that decides says "success"). Its states aren't
hand labels: they come from GitHub's documented run, job and commit-status values, held as tables
in the file with links to the docs, plus one undocumented value and a missing field. Three grids
(the required run x its required job x another job; another workflow's run x its job x the status
contexts; histories of older and newer runs) and a list of named cells, the situations reviews
found, each with its answer written down so the oracle is checked as well. `tests/checks.bats`
runs it, so every mutant in `tests/mutants/checks.json` has to get past all of it. To cover a new
situation, add a named cell; when GitHub documents a new value, add it to the tables.

## Conflict markers

`tools/lint-skills.py` fails on merge-conflict markers in any tracked file: a `<<<<<<<` or
`>>>>>>>` line, and a `=======` line in a file that has one (alone, that line is also a Markdown
heading underline). Suites that never parse a file can't catch a merge that left markers in it, so
the lint does. A fixture that needs markers goes in `tools/conflict-markers-allowed.txt`.

## Workflow lint

`tools/check-workflows.py` reads `.github/workflows/*.yml` (or the files you pass) and fails on
a `runs-on` that isn't a GitHub-hosted label (`ubuntu-*`, `macos-*`, `windows-*`), on
`pull_request_target`, on a `uses:` not pinned to a full commit SHA (docker images need a
digest), and on a job that can run on `macos-*` without the job-level guard
`if: ${{ !github.event.repository.private }}`. It resolves `${{ matrix.X }}` from the workflow's matrix and refuses any other
expression or runner group rather than guess. It is stdlib Python in one file, so another repo
can vendor it and pin it by sha256.

## Performance budgets

Tooling sits on hot paths (memory-notices runs at every session start and every prompt), so
`perf-budgets.json` sets a p95 budget per scenario and `tools/perf.py` enforces it:
`shared-index` over 150 notes, the guarded change hook when claude-memsync is absent (its cost
over a bare `sh`), the installer's dry run, a no-op `--yes --only plugins` re-run with a
stub `claude`, and land-batch's eligibility checks over one PR with the stub gh (the checks it
repeats before every merge). Each scenario runs `runs` times; in CI every budget is multiplied by
`ci_headroom`, because shared runners are noisier. A scenario without a budget, or a budget
without a scenario, fails too. Tighten a budget when a path gets faster; loosening one is a
reviewed change with a reason.

```bash
python3 tools/perf.py
```

## Coverage ratchet

`coverage-floors.json` holds a line-coverage floor per file. CI fails when a file drops below
its floor, when a floored file is missing from the report, or when a change lowers or removes
a floor: a pull request is compared with its merge base and a push with the commit it
replaced.

Coverage runs in CI, in its own job. The pinned kcov image has no git or jq, which the plugin
suites need, so the job builds a derived image on the GitHub-hosted runner: the same digest plus
git and jq from a dated snapshot of the Debian archive. The image is never pushed anywhere.
`tools/coverage.sh` prints each covered file's percentage. A new script's first floor is the
value CI first measures for it; take it from that log.

The plugins' Python tools (`lane-state`, `lane-verdict`, `shared-index`) are covered by
coverage.py in the same job: `tools/coverage-py.sh` runs every bats suite and the Python unit
tests with a startup hook in a venv, so each tool they start is measured, and `tools/coverage-py-report.py` writes its
report in kcov's shape. coverage.py comes from `tools/requirements-coverage.txt`, pinned by
version and sha256 (`pip install --require-hashes`), and is installed only on the runner.
`tools/coverage-floors.py` takes both reports (`--report` twice), so one ratchet file holds the
floors for bash and Python. To raise floors after adding tests:

```bash
tools/coverage-floors.py --report .cache/coverage/bats.*/coverage.json --update
```

That needs a local report, from `KCOV_IMAGE=<an image with git and jq> tools/coverage.sh`;
without one, raise the floors by hand from the CI log. Commit the floors change on its own so it
is easy to see.

## Skills

Skills are tested with the behaviour evals in [evals/](../evals/README.md). The RED step for a
skill is the eval run without the plugin: the baseline should miss what the skill teaches.

## RED records

[docs/tdd/](tdd/) keeps the failing runs that came before each change.
