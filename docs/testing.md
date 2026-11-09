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
flock ~/.local/state/crew/heavy.lock python3 tools/mutate-check-workflows.py   # the workflow lint's mutants
flock ~/.local/state/crew/heavy.lock python3 tools/mutate.py tests/mutants/*.json   # mutation checks (heavy: under the lock)
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

## Denylist classes and `--private-infra`

A denylist line may end in a class tag after a space, `#class=<name>` (`[a-z][a-z0-9-]{0,31}`); the tag is
not part of the pattern. An untagged line, or one with a class the scrub doesn't know, applies
everywhere (it fails closed). A malformed tag (bad name, two tags) is a malformed line: the scrub
exits 1 naming the line number only. A line that is only whitespace and a tag is a comment. The
separator is ASCII spaces or tabs only (read as bytes, in the C locale); `#class=` after any other
character that isn't printable ASCII, such as a Unicode space, is malformed, not a tag. So is any
variant of the keyword, with or without something before it: `#`, then spaces, tabs or characters
that aren't printable ASCII (NBSP, U+2003, VT, FF), `class` in any case, the same again, then `=`
(`#CLASS=x`, `# class=x`, `#class =x`, `term#class=x`), that isn't exactly a well-formed tag, since
the line would otherwise silently check nothing. `tools/export.py` reads tags
the same way, strips them, and never skips a class: its target is public.
A comment or blank line is ASCII spaces and tabs then `#` (or nothing), in both tools; any other space
before `#` makes the line a pattern. A denylist line ending in a carriage return (a CRLF file) is
refused as `line N: CR` in both tools, since the CR would make it match nothing. A denylist or
private-remote list whose real path is inside the repository being scanned is refused (exit 2).

The known classes are `crew-host` and `firm`; `firm` is never skipped by anything in the scrub or the export.

`tools/scrub.sh --private-infra` skips only `class=crew-host` lines. Every other denylist line and
every secret and personal rule still runs, and findings still show a rule, place and count only. It
is allowed only when every remote of the repo (fetch and push URLs, as git resolves them) is listed
in the private-remote file, `~/.config/crewkit/private-remotes.txt` (tests set
`$SCRUB_PRIVATE_REMOTES`): one URL per line, a trailing `.git` or `/` ignored, `#` comments, and
the line `@no-remote` to allow a repo that has no remote at all. Anything else counts as public:
an unlisted remote, a missing file, no remote without `@no-remote`. The scrub then exits 2 with a
fixed message and prints no URL. No network call is made, because the scrub runs offline in hooks
and containers; the list is the user's own statement of which remotes are private. It must be a
regular file (not a symlink) that you own and no one else can write, and git's legacy
`.git/remotes/*` and `.git/branches/*` definitions are refused, since `git remote` doesn't list
them. The check is made at scan time against what git resolves then: it can't see a later
`git push <url>`, a remote added afterwards, push-time config, an ssh alias to a public host, or a
listed repo made public later. If `--private-infra` leaves no active denylist pattern the scrub
warns (`active=0 skipped=N`), and under `--require-denylist` it exits 2.

With `--secrets-only` the denylist is off anyway, but the remote check still applies. With
`--history` crew-host lines are skipped in every version. With `--require-denylist` the file must
still exist. `--self-test` can't be combined with it (exit 2). A path that matches any denylist
line, crew-host ones included, is still not printed.

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
that isn't valid UTF-8 is still read, and a header holding a NUL byte is read as text. A commit
stored in another encoding (an `encoding` header) is also read as git shows it, re-encoded to
UTF-8, so a non-ASCII term in its message or names is found. Still not covered: with Latin-1
bytes and no `encoding` header, only ASCII denylist terms match (the bytes can't be told from
other encodings); tag messages are not re-encoded; and a non-ASCII denylist term loses case
folding when the scan runs under `LC_ALL=C`. Unicode normalization (NFD), homoglyphs and
Turkish case folding are out of scope.
`tests/scrub-history.bats` plants a canary in each place in a throwaway repo.

The history scan fails closed. Before it reads anything, it runs each extraction (identities,
tagger, tree paths) on a known commit, tag and tree entry, and refuses to scan (exit 1) when
one gives the wrong answer: a GNU-only `sed` form on BSD sed (macOS) once matched no identity
at all, and the scan passed. `--self-test` also runs a history scan of a throwaway repo with a
denylisted author name and committer email, and fails unless both are found. It runs with
every `GIT_*` variable that selects a repository unset, so a hook or a `--git-dir` caller's
repository is never touched. The suite runs
those tests with a BSD-like `sed` first on `PATH` (GNU sed in `--posix` mode), so Linux CI
catches a GNU-only form too.

The tree scan reads tracked files by NUL-separated name (so non-ASCII names are read too), scans
their paths, and doesn't print a path that matches the denylist or any rule. On a line marked
`scrub:pinned-hash`, only a sha256-length value (64 hex) is exempt from the long-hex rule.
In a file named `Cargo.lock` (a lockfile can't carry the marker), a line that is exactly
`checksum = "<64 lowercase hex>"` is exempt from long-hex too; every other line and every other rule
still applies there.
A 64-hex value on an exact `checksum = "…"` line passes by design: a Cargo.lock has hundreds of them and
the scrub does not check that the package is a registry crate (the trade-off for not parsing TOML).

## The exact-value allowlist

A repo that has to commit a few non-secret identifiers as literals (an account id, a zone id, a
UUID) lists them in `.scrub-allow` at the repo root, one reviewed value per line:

```text
sha256:<64 lowercase hex>  <rule>  <short reason>
```

The columns are separated by exactly two spaces; `#` comment lines and blank lines are allowed. The
rule must be `long-hex` or `uuid`, the two whose values (128 bits or more) can't be recovered from a
published hash. Any other rule, credential or private (a phone number, an address, a path, an
email, a token), is refused with the reason code `rule-not-allowed`: a low-entropy value's hash
can be brute-forced back, and a credential must never be exemptible. A
finding is exempt only if the sha256 of the exact text the rule matched is listed for that rule.
There is no path, prefix or pattern exemption, so a new id still trips, and so does the same value
under another rule or one character changed. The denylist can never be allowlisted: a line naming
`denylist` is refused. A malformed line (bad prefix, a hash that isn't 64 lowercase hex, an unknown
rule, a missing reason, other separators, a NUL byte) fails the scrub with exit 1, naming the line
number and never printing the line.

Decisions:

- The unit is the match. `count_rule` has always counted matches (`grep -o`), not lines, and the
  allowlist is applied per match: a line with one allowed value and one other match of the same
  rule still counts the other, and the numbers reported keep meaning "matches".
- The value is the regex match. For `long-hex` that is the hex run itself (the delimiter the
  pattern needs before it isn't part of the value); for other rules it is the whole match, so
  `secret-assign` hashes the whole `key = "value"` text. The case is as written.
- A tree or pre-commit scan reads the file from the index (`git cat-file blob :.scrub-allow`), not
  the work tree, so an untracked or unstaged file exempts nothing: what is exempt is what is about
  to be committed. Only the root file counts; `sub/.scrub-allow` or any other name is an ordinary
  file.
- `--history` is about commits, not staged state, so it reads `HEAD:.scrub-allow` instead, and
  applies that one file to every text it scans, with the same per-rule exact-value rule: a value
  allowed today is not a finding in an old version. A malformed file fails a history scan too.
- The file is scanned like any file. Only the first hash of each line the loader would accept
  (the same regex, `long-hex` or `uuid` only) is exempt from `long-hex`, in the file named exactly
  `.scrub-allow` at the root; hex in a reason, a comment, elsewhere, or on a line with a refused
  rule or a bad shape (including in an old version in `--history`) trips.
- A hash line looks like any 64-hex secret, and the scrub can't tell the two apart in this file.
  A change to `.scrub-allow` therefore needs human review (consider a CODEOWNERS entry); the
  review is the control.
- Hashing uses `sha256sum`, else `shasum -a 256` (macOS), as `tools/get-bats.sh` does.

To compute a hash without putting the value in a log or your shell history, read it silently and
print only the hash (bash):

```bash
IFS= read -rs -p 'value: ' v; echo
printf %s "$v" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; unset v
```

`tests/scrub-allow.bats` and the `allow:` cases of `tools/scrub.sh --self-test` cover it;
`tests/mutants/scrub-allow.json` is its mutation check.

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

A mutation run is a heavy job, and `tools/mutate.py`, `tools/mutate.sh` and
`tools/mutate-check-workflows.py` refuse to start unless they hold the
machine's heavy lock: run it as `flock ~/.local/state/crew/heavy.lock python3 tools/mutate.py
<spec>` (or `crew-heavy run <secs> …`, which holds the lock shared plus a slot; `bench` and a raw
flock hold it exclusively). Where `~/.local/state/crew` doesn't exist (GitHub-hosted runs, the
Linux gate's container, public installs) nothing shares a lock and the check passes. The default
lock's `~` is the home directory in the password database, not `$HOME`; the user-only
`heavy_lock` setting moves it. The check is advisory: it stops a heavy job started by mistake
without the lock, not one meant to get past it (an open, unlocked descriptor passes while someone
else holds the lock; `CREWKIT_HEAVY_LOCK` works only with `CREWKIT_HEAVY_LOCK_TEST=1`, which the
tests set).

New scripts use `tools/mutate.py` with a spec in `tests/mutants/<name>.json` (target, suite,
and mutants as exact old/new text, which may span lines). It copies the tracked tree to a temp
directory, so the real tree is never changed (tracked links stay links, an absolute one into the
repo pointed into the copy; a link that leaves the tree, or a target that is a link, is refused),
and applies the same rules: a passing baseline,
each mutant's text found exactly once, and mutants that parse. When you add a safety line, add its
mutant too. Every suite run in a mutation check, the baseline included, gets
`BATS_TEST_TIMEOUT=$MUTATE_BATS_TEST_TIMEOUT` (default 45 seconds, 3x the slowest test measured): most mutants that change
behavior hang some test, and bats's watchdog then kills it in seconds instead of after a bats
file's own default or the gate's 300. A test too slow for the limit fails the baseline, which
stops the run; it never counts as a kill.

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
`-merge` specs and the landing-lib and land-batch specs do. Those run two bats suites per mutant,
about a minute each on CI's runners, so keep each of those specs to about ten mutants. `tools/mutate.sh` (install.sh's mutants) runs in a job
of its own too, against `tests/install.bats` only, the suite that runs `install.sh`.

A spec that can't finish inside the job's time limit (hours, not minutes) may leave the matrix
through an explicit tag, never a blanket exemption: it carries `"local_gate_only": "<reason>"` (a
non-empty string) and is held in `tests/mutants/local-gate.txt`, the local gate's hold list. The
file has one hold per line (blank lines and `#` lines are ignored), each line space-separated
tokens `NAME.json` or `NAME.json@KofN`, an interleaved slice (every Nth mutant from the Kth, so
one spec can be split across runs). A spec is held by its plain token, or by all of
`@1ofN` to `@NofN` for one N. `tools/lint-skills.py` fails a spec outside the matrix that is untagged
or not held, a tagged spec that is still in the matrix, an empty or non-string reason, a partial
or mixed set of slices, a repeated token, and a hold naming a missing or untagged spec.

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
stub `claude`, land-batch's eligibility checks over one PR with the stub gh (the checks it
repeats before every merge), and crew-nodes' `pane-ask --read` with the stub ssh and herdr (what
each of its herdr calls costs, before the network). Each scenario runs `runs` times; in CI every budget is multiplied by
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

Coverage runs in CI, in its own job. The pinned kcov image has no git, jq or ps, which the plugin
suites need, so the job builds a derived image on the GitHub-hosted runner: the same digest plus
git, jq and procps (bats needs ps for its test timeout) from a dated snapshot of the Debian
archive. The image is never pushed anywhere.
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

That needs a local report, from `KCOV_IMAGE=<an image with git, jq and procps> tools/coverage.sh`;
without one, raise the floors by hand from the CI log. Commit the floors change on its own so it
is easy to see.

## Hosted CI shards

The hosted `tests` job runs the bats files in 4 shards (`tests/run.sh --shard K/4`), and the hosted
coverage runs as 4 kcov shards (`tools/coverage.sh --shard K/4`), 4 coverage.py shards and one small job
that merges the kcov shards (`tools/coverage.sh --merge 4`, in the pinned base image only, which needs no
apt), combines the coverage.py ones and checks the floors (`coverage`). `ci-ok` needs all of them. The split is by measured time:
`tests/bats-times.json` holds each bats file's seconds, and `tools/bats-shards.py` deals the files
out heaviest first, each into the shard with the least time so far. A new bats file needs an entry
(`python3 tools/bats-shards.py check` fails, in CI too, until it has one). The table holds seconds
measured on a hosted Linux runner (the sum of each file's test times in a `tests` job log, which
carries them because the job passes `--timing`); a Mac's times differ a lot. Time a new file with
`time tests/run.sh tests/NEW.bats` on a Linux runner or the Linux gate. `python3 tools/bats-shards.py
totals 4` shows each shard's seconds.

The kcov shards need the derived image (git, jq, procps, openssh-client), built from a dated Debian
snapshot, which has timed out and stalled. So the recipe gives apt retries and timeouts, the hosted job
tries the build three times with a limit of its own, and keeps the built image in the Actions cache (keyed by
the recipe and the pinned base), so a run that finds it builds nothing. Locally,
`tools/coverage.sh --shard K/N` for each K, then `tools/coverage.sh --merge N`, give the same report as
the unsharded run (`.cache/coverage/bats.merged/coverage.json`); `--merge` refuses a missing, unfinished or
stale shard, or shards whose suites together are not `tests/*.bats` minus `docs.bats` and `settings.bats`.

The Python coverage run can be split across machines when one job would outrun a slot's time cap.
Run `tools/coverage-py.sh --shard K/N` for each K in 1..N (N at most 16), each with
`COVERAGE_VENV` set; shard K runs its share of `tests/*.bats`, split by measured file time (`tools/bats-shards.py` and the table `tests/bats-times.json`, the same split that `tests/run.sh --shard K/N` and the hosted bats job use),
and shard 1 also runs the Python unit tests. Each writes `.cache/coverage-py/shard-K/` (data, logs,
and a `done` marker on success) and no report. Gather all N directories into one checkout, then run
`tools/coverage-py.sh --combine N`: it refuses (exit 1) a missing or unfinished shard, a shard from
a run with another N or another commit than this checkout's HEAD, a shard directory holding data
files its run did not write (copy each directory over clean), and bats files that, taken together,
are not exactly this checkout's `tests/*.bats`. Otherwise it writes
`.cache/coverage-py/report.json` as the unsharded run does. (`tests/run.sh` given existing `.bats`
files runs only those; with none it runs the whole directory.) With no arguments the script runs everything
in one go, as CI does today.

## The crewkit command's suites

`tests/crewkit*.bats` test the `crewkit` command (`bin/crewkit`, `libexec/crewkit-*`,
`libexec/ck/*.sh`). Each one loads `tests/helpers.bash` and `tests/crewkit-helpers.bash`.
`ck_setup` builds a private tree the way a checkout looks to `bin/crewkit` (links to the real
`bin`, `libexec`, `lib`, `plugins`, `templates` and `install.sh`, a real copy of `pins/`, the push
gate fixture), points `$HOME` at an empty temp home, and puts the stub `ssh` first on `PATH`
(`herdr_session` adds the stub `herdr` the same way). `ck ARGS` runs the tree's command. Nothing touches a real host, key, settings file or
network.

| Suite | What it holds |
|---|---|
| `crewkit.bats` | The dispatcher: `--version`, usage (64), the verb and group-word rules. |
| `crewkit-registry.bats`, `crewkit-herdr.bats` | The registry store and its git sync; herdr discovery, sanitizing and tagging. |
| `crewkit-node-report.bats` | `crewkit node report`: the read-only report a node prints. |
| `crewkit-doctor.bats` | `crewkit doctor`: one line per check, with stub tools at the versions the pins name. |
| `crewkit-holder.bats`, `crewkit-pointer.bats`, `crewkit-spend.bats` | The registry holder, the outbox pointers and the spend cap. |
| `crewkit-watchline.bats` | The content-free watcher's lines. |
| `crewkit-usersettings.bats`, `crewkit-claudesettings.bats` | Reading and writing the user settings file and Claude's own settings. |
| `herdr-stub.bats`, `ssh-stub.bats` | The stubs themselves, so a stub cannot drift from what it stands in for. |
| `crewkit-acceptance.bats` | The v0.1.0 acceptance scenario (below). |

**The stubs.** `tests/stubs/herdr` answers the `herdr agent` commands in herdr's JSON shape from
state under `$PSTUB`, and logs every call. `tests/stubs/ssh` logs its arguments and runs the
remote command in a fake home (`fake_host`), under `env -i`, as sshd would. Helpers such as
`herdr_session`, `herdr_agent` and `user_setting` set up their state.

**The acceptance scenario.** `crewkit-acceptance.bats` is one node, offline, with stubs only. On a
fresh empty home it runs `install.sh --yes --only cli`, then `crewkit --version`, `crewkit doctor`
on a stubbed healthy node (exit 0, one `ok` or `warn` line per check, in order) and `crewkit node
report` (the agents, with no path, title or hostname), and checks that an unknown verb and
`node-report` as one word are usage (64). `ssh` and `curl` are stubs that record a call and fail,
and the suite ends by checking they were never called. It covers only what v0.1.0 ships; each later
verb (`init`, `join`, `status`, `open`, `ask`, `--json`) brings its own acceptance with its row.
Four mutant specs (`tests/mutants/crewkit-acceptance-*.json`) hold it to the code it walks.

## Skills

Skills are tested with the behaviour evals in [evals/](../evals/README.md). The RED step for a
skill is the eval run without the plugin: the baseline should miss what the skill teaches.

## RED records

[docs/tdd/](tdd/) keeps the failing runs that came before each change.

## The Linux gate

`tools/linux-gate.sh` runs what CI runs, on your machine, in a pinned Linux container, from a
fresh clone of a branch: `crew-heavy run <secs> tools/linux-gate.sh BRANCH OUTDIR
[SPEC.json...]`. It is the evidence for a branch while the repository has no CI runners. Its
images are built from `docker/` (`tools/linux-gate.sh --build-images`, once, and after any change
there): `crewkit-ubuntu` (ubuntu 24.04 by digest, with an en_US.UTF-8 locale, which the gate
checks as the container's first step), `crewkit-ubuntu-amd64` for coverage.py, and `crewkit-kcov` (the file
CI's coverage job builds too). The gate runs only those local builds: its containers run with
`--pull never`, there is no image override, and it checks that `crewkit-kcov` exists before
`tools/coverage.sh` (which would otherwise pull a missing image by that name). The ubuntu
images' apt packages aren't from a dated snapshot yet (the kcov image's are), and nothing
checks that a local image was built from the current recipe: rebuild after any change to
`docker/`. `FULL=1` adds install.sh's mutants, kcov, coverage.py and the
floors; coverage.py needs the pinned wheel in `LINUX_GATE_WHEELS` (default
`~/.cache/crewkit/wheels`). Every bats test in the container (and under kcov) stops after
`LINUX_GATE_TEST_TIMEOUT` seconds (default 300, as `BATS_TEST_TIMEOUT`; mutation runs use their own,
shorter one), so a hung test fails the
gate instead of holding the heavy lock. The whole run has a limit too, `LINUX_GATE_TIMEOUT`
seconds (default 7200), shared by every step after the clone: at the limit the running step is
stopped (a container is killed by its name, `docker kill`), summary.txt gets a `timeout STEP`
line, no further step starts, and the gate fails. The gate passes only if every step it started left a
passing line and the container exited 0, so a run that stopped early is a failure, not a pass:

```bash
python3 -m pip download coverage==7.16.2 --platform manylinux_2_17_x86_64 --platform manylinux2014_x86_64 \
  --python-version 3.12 --implementation cp --abi cp312 --only-binary :all: --no-deps -d ~/.cache/crewkit/wheels
```

pip checks it against `tools/requirements-coverage.txt` when the gate installs it. The gate exits 1
and names the failed steps when any step fails or the scrub isn't clean. Change it here, in review,
like any other gate: never a private copy.

A run can be split across heavy-lock claims: `LINUX_GATE_MUTANTS_ONLY=1` makes the container run
only `tools/mutate.py` for each SPEC (at least one; not with `FULL=1`, exit 64), after the same
native checks and with the same head line first in `summary.txt`. Each spec's baseline still
runs, and a failing one fails that spec's step. It needs `LINUX_GATE_BASE=<the base run's
summary.txt>` and checks it before it uses the clone: the file must exist, its first line must
be this run's head line (the same branch and full SHA), and it must record no failed step, no
step that never ran and no timeout, by the check that ends every run. Otherwise the gate exits
1 and prints why, and of the file only its head line. A summary with a `mode` line (a
mutants-only run's, whose line may end `hold=N/M`) is not a full run and is no base, and the base can't be the run's own
`summary.txt`. The base is trusted as named: the gate can't tell a forged summary from a real
one, but binds the one it used by writing `mode mutants-only base-sha256=HASH` as the new
summary's second line, so a reader (the lander) can tell a mutants-only summary from a full run
and see which base it stands on: anything that reads a summary as a full gate's must check line 2, and a `mode` line there means it is not a full run. The base is read once, into a copy, so the hash covers exactly the bytes the checks saw. A mutation run that stops a mutant by the test time limit
counts it as killed, so under heavy load a timeout can hide a survivor: rerun a surprising
kill-by-timeout alone.

The local gate's holds are the mutation specs that left CI's matrix for its time limit, listed in
`tests/mutants/local-gate.txt`: one hold per line (blank and `#` lines are not holds), each a line of
space-separated `NAME.json` or `NAME.json@KofN` tokens (the lint's grammar). The gate reads the list
from the clone's gated head by git, never from the caller's tree, and checks it in every run (plain,
`FULL=1` and mutants-only): the file must be a regular file with no NUL byte or CR, every line must
fit the grammar, every `NAME.json` must be a regular file in `tests/mutants` at the head, no entry
under `tests/mutants` may have an `@` in its name (it would alias a slice), and without the file
`tests` and `tests/mutants` must each be absent or a plain directory. Anything else exits 1 before
anything runs, naming the file's line number (never its text) and leaving a failing `holds` line in
`summary.txt`. A plain or `FULL=1` run writes `holds M` as its summary's second line, M being the
number of holds at that head (0 without the file). Each hold is its own claim:
`LINUX_GATE_MUTANTS_ONLY=1 LINUX_GATE_HOLD=N tools/linux-gate.sh BRANCH OUTDIR` (no SPEC; N counts
holds, not file lines) runs the Nth hold's tokens as the SPECs, steps `mutants-NAME` (the `.json`
dropped, `@KofN` kept, and passed to `tools/mutate.py` as it is), and ends the summary's mode line
with `hold=N/M`. N must be a whole number from 1 to M, else exit 64 (past M with a failing `holds`
line in `summary.txt`); `LINUX_GATE_HOLD` with a SPEC, without `LINUX_GATE_MUTANTS_ONLY=1` or with
`FULL=1` is exit 64 too. `tools/linux-gate.sh --holds BRANCH` (a branch, tag or full SHA of the
source repository) prints M and runs nothing, so it needs no lock. A plain run given SPECs says on
stderr that a non-empty list was skipped. A lander checks the holds like this: M is the `holds` line
of the base summary, and for every N in 1..M there must be a passing mutants-only summary whose head
line equals the base's and whose mode line ends `hold=N/M` (and names the base's hash); a missing N,
a different M or a different head means the holds did not all run. A mutants-only run refuses a base whose `holds` line (exactly one) is not this head's M, so the M in `hold=N/M` is the base's by construction.

The order, and which copy of each tool runs, keep the branch's own code from changing what the
host checks. The native checks run first, on the clone as cloned: shellcheck (which only reads
the branch's scripts), the scrub with the private denylist, and the secrets scan (the gate's own
`tools/secrets-scan.sh`: the pinned, sha256-checked gitleaks, the gate's config, every ref and
merges' changes, the branch's `.gitleaks.toml` refused). With `FULL=1`, kcov follows (its
container mounts the clone read-only); the floors' base (the merge base of the cloned head with
main) is taken before any container runs. The scrub, the secrets scan, `coverage.sh` and
`coverage-floors.py` are the gate's own copies, run against the clone, never the clone's, so no
branch code runs on the host: shellcheck only reads the scripts (`--norc`), the scrub exempts
`tools/scrub.sh` only when it is byte-identical to the running scrub or a known reviewed version,
and `coverage.sh` finds bats through its own `get-bats.sh` and runs python with `-I`. Because the
scan covers every ref in the clone, a leak on any other local branch of the source checkout
fails the gate too. A branch that tracks anything under `.cache` (the gate stages bats there, and
`coverage.sh` removes and writes under it on the host) is refused with a `cache rc=1` line before
anything is staged, and `coverage.sh` itself refuses a `.cache`, `.cache/coverage` or log that is a
symlink. Only then does the gate's container run, with the clone writable. It writes its step
lines to an out directory of its own; the host writes `OUTDIR/summary.txt`, whose first line is
`head BRANCH SHA` (checked again at the end), and copies in only the container's own steps'
lines and logs.
Whenever the gate exits, and on INT, TERM or HUP, it kills its named containers (`docker kill`,
errors ignored) before removing its work directory, so a step killed from outside can't leave a
container running outside the heavy lock.
