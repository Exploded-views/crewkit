# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-09

The first tagged release. Its earlier draft was first exported, untagged, to the public repo on 2026-10-24.

### Changed

- `tools/heavy_lock.py`: `proof()` also accepts a hold verified through bitc: `BITC_JOB` must name a holder in the heavy,
  gate or bench pool (per `bitc status --json`) whose pid is this process or one of its ancestors; any doubt falls through to
  the unchanged flock checks. The bitc binary is only `~/.local/bin/bitc`, checked for ownership and mode, hashed against
  the record `install.sh` now writes to `~/.local/share/crewkit/bitc.sha256`, and run with explicit `--state-dir` and
  `--config` and a scrubbed environment; `BITC`, `PATH` and `BITC_DIR` count only behind the test switch. `--config` is always passed, and an absent or unsafe bitc host file refuses the hold with a reason; `install.sh` fixes the record's and a new `~/.local/bin`'s modes whatever the umask. This lets the heavy-job wrapper drop its exclusive `heavy.lock`, so bitc's pools give the concurrency.
- `tools/export.py`: the Exploded-views fork of herdr is on the public repo list, so the README and `pins/herdr.env` links to it pass the export check.
- `install.sh` installs herdr from the Exploded-views fork release `v0.9.5-ev.2`: a per-target tarball checked against the pin and the release's `.sha256` file (the bare-binary path is gone). `pins/herdr.env` gains an optional `HERDR_VERSION` (the fork's binary still prints `herdr 0.9.5`), and `tools/lint-skills.py` allows it.
- `crewkit owner send`: the sender `mc-notify` runs for owner pushes. It delivers
  through `yo-human notify --json` (a Bark form with a rule, level and optional note, and an ntfy
  form with the entry alone), reads only the configured channel's result, and prints one line for
  `mc-notify`: `sent -`, `unknown -`, `failed -`, `refused config`, or `sent - config` and
  `unknown - config` for a yo-human config problem (exit 78); an outcome that may have sent is
  `unknown -`, so mc-notify never resends. New file-only `owner_send.*` settings (the yo-human binary, the level
  names, the channels read and `owner_send.ask`), a new `owner` group word in the dispatcher.
- `pins/bitc.env`: bitc v0.1.0 to v0.1.4, the release the heavy-pool cutover installs. Each of the four
  tarballs was downloaded and hashed here, and the hashes match the release's own `checksums.txt`.
- `pane-ask` is bridge to bridge only (exit 45, NOT-A-BRIDGE, new in `docs/exit-codes.md`): it
  refuses, before calling the node, a caller that isn't this host's bridge, a target that isn't
  the other node's configured bridge, and any local target. On one host, sessions use
  `SendMessage`; the one local case is a watch daemon (a caller with no `HERDR_PANE_ID`) waking
  its own host's bridge. `--read` follows the same rule. New per-node setting `nodes.<name>.this_host: true` (this host's own nodes; a local node runs the local herdr with no ssh). A guard rail,
  not enforcement: a caller can claim another pane or unset the variable; real enforcement waits
  on a herdr feature. The docs, the `herdr` skill (a started session is briefed with
  `SendMessage`) and the front-door design say the same.
- README: a theme-aware banner, a quickstart verified against the installer (dry run, then
  `--only bitc --only plugins`; claude-memsync's bootstrap flags are in `docs/install.md`), the
  installer's guarantees, Mermaid diagrams of the installer and of a crew on one host, a
  roadmap and the project family. The contributing rules and repo layout move to
  `CONTRIBUTING.md`, and the rtk notes to `docs/rtk.md`.
- The scrub's default denylist path is `~/.config/crewkit/denylist.txt`.
- Manifests and skills no longer link to a hosting org; docs use placeholders.
- `host-safety`: bitc's exit 64 is "refused, fix the call" and 69 is "unavailable, stop and
  report" (it said 69 meant refused).
- `session-bootstrap` is folded into `orchestrator` as `orchestrator/new-session.md`; the plugin
  has one skill fewer.
- Estimates: the rules fragment and the `orchestrator` skill base estimates on measured
  merge velocity (`velocity_file`), quoted in hours with gating waits listed separately.
  New eval `orch-estimate-hours`.

### Security

- Denylist class tags: a line whose tag keyword was spelled `#CLASS=`, `#Class=`, `# class=`,
  `#class =`, with a VT, FF, NBSP or U+2003 inside it, or with nothing before it (`term#class=x`),
  was read as no tag, so the whole line became the regex and its term went unchecked while the
  scrub printed "clean". Both `tools/scrub.sh` and `tools/export.py` now refuse any `#`, spaces,
  tabs or non-printable-ASCII characters, `class` in any case, the same again, `=` that isn't
  exactly a well-formed tag, as a malformed class tag naming the line number only. Well-formed tags
  and unknown classes are unchanged.

Hardening from the Opus review of the gate stack (linux-gate@d9834b4), before any of it shipped:

- Push gate: gitleaks runs on `git log -p` piped to `gitleaks stdin`, with the gate's own config
  (`push-gate/gitleaks-rules.toml`, default rules, nothing allowed), every `GITLEAKS_*` variable unset
  and `gitleaks:allow` ignored, so a repository's `.gitleaks.toml`/`.gitleaksignore` can't switch
  it off. Both scans read diffs as text (no textconv, no external diff, `-diff` attributes
  ignored), merges' own changes, annotated tags (nested too), non-ASCII paths unquoted, and
  replace refs and the log encoding have no effect. A new branch is scanned down to what the push
  URL lists (`git ls-remote`), not the local tracking refs. The effective `core.hooksPath`
  (includes, `includeIf`, `config.worktree`, each linked worktree; empty is a FAIL) is what the
  doctor and `install-hooks.sh` read. The log drops a URL's credential; install switches in
  atomically and restores the old gate on failure; gitleaks's sha256 is also recorded inside the
  gate; doctor-watch treats a crash as an error; `--doctor` gains an `exempt` line (counts and a
  fingerprint, never patterns). Local-path pushes skip the gate only on `$HOME`'s device outside
  synced folders. sha256 repositories, receive-side hooks and escaped schedule templates are
  handled.
- No-bypass hook: also refuses unsetting or hiding the global `core.hooksPath` (`--unset`,
  `--remove-section`, `GIT_CONFIG_GLOBAL`/`HOME`/`XDG_CONFIG_HOME`… for git, `env -i`/`-u`), an
  alias that runs a refused command, `commit-tree`/`send-pack`/`http-push`, `SKIP=`, writes to a
  git config file naming `hooksPath` or `[include`, a command it can't parse (a nested
  word only when it could run git: prose like `echo "don't (x)"` passes), and nesting deeper
  than three. It reads commands as bash does (line continuations, `$'…'`, comments, heredocs
  checked as commands unless they are a git/gh message), and no longer refuses `-am`, `-F`,
  `--message=`, heredoc commit messages, `gh --body`, `git log --grep commit -n` or a redirected
  `git config` read.
- CI secrets scan: the config and ignore file come from `tools/secrets-scan.sh`, never the
  scanned tree (a tree holding either fails); history is read as text, merges included (`-m`).
  gitleaks is pinned (v8.30.1, the four hashes unchanged).
- `tools/linux-gate.sh`: the whole run is bounded by `LINUX_GATE_TIMEOUT` (default 7200 s; the
  running step's container is killed by name, summary.txt gets `timeout STEP`, and the gate
  fails). The native checks run first, on the clone as cloned; the host writes summary.txt from
  the container's own step lines and confirms the head line; the scrub records its rc; images
  run with `--pull never` (the `IMAGE` override is gone); a relative OUTDIR works.
- `tools/linux-gate.sh`, trust and interruption: the secrets step now runs the gate's own
  `tools/secrets-scan.sh` (the pinned, sha256-checked gitleaks, the gate's config, every ref and
  merges' changes, `gitleaks:allow` ignored, every `GITLEAKS_*` variable unset, a clone holding a
  `.gitleaks.toml` or `.gitleaksignore` refused) instead of a bare `gitleaks git`, which took its
  config from the branch under test. The scrub, `coverage.sh` and `coverage-floors.py` are also
  the gate's copies, run against the clone (`LINUX_GATE_TOOLS` names another directory for them,
  for the tests, and it must be absolute); no code of the branch runs on the host: `coverage.sh`
  finds bats through its own `get-bats.sh` and runs python with `-I`, shellcheck ignores the
  clone's rc file, and the scrub exempts `tools/scrub.sh` only when it is byte-identical to the
  running scrub or a known reviewed version (read from the running script's directory). On exit,
  and on INT, TERM or HUP, the gate kills its named containers (`docker kill`, errors ignored)
  before removing its work directory, instead of leaving them running outside the heavy lock.
  A branch that tracks anything under `.cache` (a committed symlink there could steer the gate's
  host-side writes and an `rm -rf` outside its work directory) is refused with a `cache rc=1`
  summary line, and `coverage.sh` refuses a `.cache`, `.cache/coverage` or log that is a symlink.
- `tools/linux-gate.sh`, interface: `LINUX_GATE_TEST_TIMEOUT` (default 300 s; reaches the
  container's bats and kcov as `BATS_TEST_TIMEOUT`); `LINUX_GATE_MUTANTS_ONLY=1` with
  `LINUX_GATE_BASE=<summary.txt of a passed full run of the same head>` runs only the mutation
  specs. A mutants-only summary has `mode mutants-only base-sha256=HASH` as its second line: a
  reader of a summary (the lander) must check line 2, and a `mode` line there means it is not a
  full run. `tools/coverage.sh` now covers `push-gate/`, takes `KCOV_NAME` (the container's
  name, so the gate can kill it) and passes `BATS_TEST_TIMEOUT` through; CI's shellcheck covers
  `push-gate/` too.
- `tools/mutate.py` gives every suite run a short `BATS_TEST_TIMEOUT` (`MUTATE_BATS_TEST_TIMEOUT`,
  default 45 s), so a mutant that hangs a test costs seconds, not the file's 120 s or the gate's
  300 s (the watcher specs' mutant phase was about 1h45m on the heavy lock). It refuses a
  symlinked target or a link leaving the tree; the heavy-lock check
  takes home from the password database and is documented as advisory. The markdown lint checks
  the staged copies, every path literal.
- Heavy lock: `tools/heavy_lock.py` is the one guard for the mutation runners and the Linux gate,
  and it now accepts a `crew-heavy run` hold (heavy.lock shared plus a held heavy.slot1/2 beside
  it) as well as an exclusive one (`bench`, a raw flock); before, a run with the other slot busy
  was refused. It never calls flock on an inherited descriptor (that converts a held lock, and on
  Linux a failed attempt can drop it): it opens fresh descriptors to probe, and releases each
  probe at once. It applies only where `~/.local/state/crew` exists (CI, containers and public
  installs pass as unguarded), so the CI and gate-token acceptances are gone; the lock path is the
  user-only `heavy_lock` setting, which moves the lock but can't disable the check;
  `CREWKIT_HEAVY_LOCK` works only with `CREWKIT_HEAVY_LOCK_TEST=1`. New launcher tests prove
  `tools/linux-gate.sh` starts its container only under a crew-heavy, bench or raw-flock hold.
  The `heavy_lock` lookup runs `/bin/bash --noprofile --norc` with a minimal environment (the
  caller's `BASH_ENV`, exported functions and `PATH` can't redirect the lock), reads only the last
  output line, and any failed lookup or bad value refuses instead of passing as unguarded. The
  refusal names the lock it checked; the container no longer gets the unused
  `CREWKIT_HEAVY_LOCK_HELD` token.
  A user file that settings.sh would skip (writable by others, not yours) refuses instead of
  passing as unguarded; a user file without a `heavy_lock` key needs no bash; the shell callers
  run the check as `python3 -I`. A symlinked `~/.claude/crewkit.md` is checked as the link and as its target, so
  a link settings.sh would skip refuses too.
  Any `heavy.slotN` counts as a slot (a `crew-heavy run` in slot 3 is accepted), not just the first two.

### Added

- `tools/linux-gate.sh` and the local-gate holds (`tests/mutants/local-gate.txt`, the mutation specs
  that left CI's matrix for its time limit). Each hold is its own mutants-only claim:
  `LINUX_GATE_MUTANTS_ONLY=1 LINUX_GATE_HOLD=N tools/linux-gate.sh BRANCH OUTDIR` (no SPEC) runs
  the tokens of the Nth hold (blank and `#` lines not counted) as the SPECs, one step
  `mutants-NAME` each (`NAME.json@KofN` passed on to `tools/mutate.py` as it is), and ends the
  summary's mode line with `hold=N/M`; a bad N, a SPEC beside it, `FULL=1` or no
  `LINUX_GATE_MUTANTS_ONLY` is exit 64 (N past M also leaves a failing `holds` line in
  `summary.txt`). A plain or `FULL=1` summary gets a `holds M` second line, which is what a
  lander takes M from (docs/testing.md has its check). `tools/linux-gate.sh --holds BRANCH` (a
  branch, tag or full SHA) prints M and runs nothing. The list is read at the gated head by git
  (no replace refs, no caller pathspec or object-directory settings), never from the caller's
  tree, and checked in every run: the lint's grammar; each `NAME.json` a regular file under
  `tests/mutants`; no entry there with an `@` in its name; without the file, `tests` and
  `tests/mutants` plain directories; no NUL byte or CR. A failure exits 1 before anything runs,
  naming the line number of the file only and leaving a failing summary. A plain run given SPECs
  notes on stderr that a non-empty list was skipped. A clone whose work tree is not the head
  (two paths that differ only in case collide on a case-folding filesystem) fails closed
  (`checkout rc=1`); a mutants-only run needs a base with exactly one `holds M` line equal to the
  head's M, and a base that is its own OUTDIR's `summary.txt` is refused before any refusal can
  overwrite it. The holds tests moved into
  `tests/linux-gate-holds.bats` (setup shared in `tests/linux-gate-helpers.bash`), with their
  mutants in `tests/mutants/linux-gate-holds.json` and `linux-gate-holds-run.json` (two specs,
  so each fits a CI job).

- `tools/scrub.sh` denylist classes: a line may end in a space and `#class=<name>`, and `--private-infra`
  skips only `class=crew-host` lines while every other line and all secret and personal rules still
  run. It refuses (exit 2, fixed message, no URL) unless every git remote is on the user's
  private-remote file (`~/.config/crewkit/private-remotes.txt`; `@no-remote` allows no remote). An
  untagged or unknown-class line applies everywhere; a malformed tag fails the scrub by line
  number. See docs/testing.md.

- `tools/scrub.sh` now refuses (exit 2, fixed message) a denylist or private-remote list whose real
  path is inside the repository being scanned, in a plain scrub and in the pre-commit hook too,
  since the change being scanned could edit the list. A home directory that is itself a git repo and
  holds the list will hit this: keep the lists outside any repository you scan.

- `tools/linux-gate.sh` and `docker/`: the local CI-equivalent gate moves into the repository
  (from a shared, unreviewed script), with its three image recipes (bases pinned by digest; the
  kcov one is now the file CI builds). It runs as the caller's uid, needs the heavy lock, checks
  the image's locale, and exits 1 naming any failed step.

- CI job `secrets`: gitleaks over every commit on every ref with the pinned, sha256-checked
  build (`./install.sh --only gitleaks`, then `tools/secrets-scan.sh`), on every push and pull
  request, next to the scrub's secret rules. It fails closed: if the pinned binary is missing or
  changed (`pins/gitleaks.env` pins v8.30.1), or the clone is shallow, it fails rather than pass.

- `push-gate/no-bypass-hook.py`: a Claude Code PreToolUse Bash hook that refuses `-c
  core.hooksPath=…` (any form), `GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_KEY_<n>` naming it,
  `--no-verify`, and `git commit -n`, and says that only the owner may bypass; `--install [--yes]`
  adds it to `~/.claude/settings.json` beside existing hooks, once, with a backup.

- The push gate (`push-gate/push-gate.sh`, [docs/push-gate.md](docs/push-gate.md)): a host-wide
  pre-push hook, installed through a global `core.hooksPath` dispatcher that chains each
  repository's own hooks. It refuses a push whose new commits, pushed tree, paths or branch name
  hold a private denylist term, or whose commits hold a secret (gitleaks, which must match the
  sha256 recorded at install). It fails closed: any git or grep error refuses the push ("gate
  error: refusing push"), and every place where an empty result could read as clean is listed
  with its own test. `install [--yes]`, `status --json`, `--doctor` (one `<check-id> <ok|FAIL>
  <detail>` line per check), `gate-check [REPO]`, and `shim REPO [--yes]` for repositories with
  their own `core.hooksPath`. Settings `push_gate.*`, all user-only.
- The pre-commit hook (and the pre-commit framework config) runs markdownlint-cli2 0.18.1 on
  staged Markdown (`tools/lint-markdown.sh`), so a doc can't land lint-red; with staged
  Markdown and no `npx` it refuses the commit.
- `install.sh` step `gitleaks`: the push gate's pinned gitleaks, verified like bitc (pin,
  the release's checksums file, `gitleaks version`), into `~/.local/share/crewkit/gitleaks/`
  with the binary's sha256 recorded beside it. `pins/gitleaks.env` pins no release yet.

- Mutation specs may carry `"local_gate_only": "<reason>"` to leave CI's `mutants` matrix when
  they take too long for its time limit. The spec must be held in the new
  `tests/mutants/local-gate.txt` (whole, or as `NAME.json@KofN` slices that together cover it), and
  `tools/lint-skills.py` checks the tag, the hold list and the matrix against each other.
- `tools/scrub.sh` exact-value allowlist: `.scrub-allow` at the repo root lists
  `sha256:<64 hex>  <rule>  <reason>` lines, and a finding is exempt only when the hash of its exact
  matched value is listed for that rule (per match, never per path or pattern). The denylist can't
  be allowlisted, and a malformed line fails the scrub closed, naming its line number only.
  Only the `long-hex` and `uuid` rules can be listed. `--history` honours the file at HEAD; a tree
  scan reads the index. Changes to `.scrub-allow` need human review. See docs/testing.md.

- `public-watch` (crew-orchestrator) and `tools/check-watcher-settings.py`: a public-repo watcher
  that reads no stranger's text. GET-only, field-selecting reads; one content-free line per item,
  with URLs built from validated numbers and a sanitized title only for OWNER, MEMBER or
  COLLABORATOR items; and a check that a watcher's settings allow no write tool.
  `tests/watcher-injection.bats` runs both against injection fixtures for any list of repositories.

- The `crew-nodes` plugin (a preview the installer doesn't install): cross-node tooling layered
  over herdr. Its first tool, `pane-ask`, sends one message to an agent session on another
  machine, where `SendMessage` can't reach, with `herdr agent prompt --wait` (over ssh, or a saved
  herdr machine profile), then prints only the reply; `--read` prints a session's tail. It never
  sends to a node's lead panes (as typed or as herdr resolves the target), and never resends
  after a timeout. Settings `nodes.*`, all user-only: read from `~/.claude/crewkit.md` alone
  (a new `CREW_USER_ONLY` list in `lib/settings.sh`), never from a project or `CREWKIT_*`. `tools/lint-skills.py` accepts a plugin whose only content is an executable in `bin/`.
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

### Fixed

- `lane-land`'s merge-pause gate fails closed: an empty, null, non-list or unreadable `mergePauseExempt` no longer
  exempts the PR (jq 1.6 exits 0 on `-e` with empty input), and a failed read of `mergePaused` is
  STATE-UNREADABLE (39), not "not paused".
- The Linux gate images (`docker/*.Dockerfile`) install openssh-client: `crewkit doctor` needs
  `ssh` and `ssh-keygen`, and without them its tests failed in every container run. The gate
  and kcov containers also get a passwd entry for the host uid, which `ssh-keygen` needs and
  the images lack.
- `tools/mutate.py`: a per-mutant timeout (optional spec key `mutant_timeout`, default max(60 s, 3x the
  baseline); a hung mutant, its process group ended TERM then KILL, is reported `TIMEOUT`, counted apart from
  the kills and fails the run. Every line is flushed. A kill names the first failing test
  (`[by: <test>]`, from bats TAP or unittest output).
- `tools/install-hooks.sh` works from a linked worktree, and refuses only a `core.hooksPath` set
  in the clone itself (`--local`); a global one (the push-gate dispatcher) chains to its hook.
- The Linux gate's shellcheck step checks what ci.yml's shellcheck job checks (`bin/crewkit`, `libexec/`,
  `push-gate/` and the shim as `sh`), so a hosted shellcheck failure can't pass locally;
  `tests/test_shellcheck_parity.py` fails when the two lists drift.
- Test fixtures, docs and a RED record no longer carry a private host label, a machine's temp path
  or a private note name.
- The push gate's gitleaks config is now `push-gate/gitleaks-rules.toml`.
