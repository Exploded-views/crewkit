# Push gate

`push-gate/push-gate.sh` is a host-wide pre-push hook. It refuses a push whose new commits or
pushed tree hold a term from your private denylist or a secret (gitleaks). It runs for every
repository on the machine through a global `core.hooksPath`, and it fails closed.

## Install on a node that has nothing else from crewkit

The gate stands alone: it needs bash, git, `curl`, `tar` and `sha256sum` (or `shasum`), on Linux
or macOS, amd64 or arm64. Nothing else from crewkit is installed or run. Run these on the node
itself, as the user who pushes.

INPUTS

- `CREWKIT` = `$HOME/<path for the crewkit clone>`: where to clone crewkit.
- `REPOS` = `$HOME/<directory holding your repositories>`: the gate's `push_gate.root`.
- The private denylist: one case-insensitive extended regex per line, put at
  `~/.config/crewkit/denylist.txt` by the owner (never pasted into a session or a message).

```bash
CREWKIT="$HOME/<path for the crewkit clone>"
REPOS="$HOME/<directory holding your repositories>"
git clone https://github.com/Exploded-views/crewkit.git "$CREWKIT"
"$CREWKIT/push-gate/push-gate.sh" --doctor                 # before: lists what is missing (exit 1)
```

Then, as the owner: put the denylist at `~/.config/crewkit/denylist.txt` (`chmod 600`), and set
the root in `~/.claude/crewkit.md`. If that file already exists, add the key inside its
frontmatter instead:

```bash
mkdir -p ~/.claude && [ ! -e ~/.claude/crewkit.md ] && printf -- '---\npush_gate.root: %s\n---\n' "$REPOS" > ~/.claude/crewkit.md
```

Then install gitleaks and the gate (each command without `--yes` first prints what it will do):

```bash
"$CREWKIT/install.sh" --only gitleaks --yes                # the pinned gitleaks, verified
"$CREWKIT/push-gate/push-gate.sh" install                  # dry run
"$CREWKIT/push-gate/push-gate.sh" install --yes
"$CREWKIT/push-gate/push-gate.sh" --doctor                 # after: every line ok, exit 0
```

A `repo:… FAIL` line names a checkout whose `core.hooksPath` isn't the gate; shim it with
`"$CREWKIT/push-gate/push-gate.sh" shim <that repo> --yes`, then run `--doctor` again.

Last, schedule the doctor, so a repository whose hook tool (`husky install`) drops the shim later
is noticed within the hour. Optionally set `push_gate.notify_command` first, for example a
notice command that posts to the owner's phone:

```bash
"$CREWKIT/push-gate/push-gate.sh" schedule          # dry run: prints the unit and the command
"$CREWKIT/push-gate/push-gate.sh" schedule --yes    # macOS: a launch agent; Linux: a user timer
```

`install` copies the gate to `~/.local/share/crewkit/gate/` and sets
`git config --global core.hooksPath ~/.local/share/crewkit/gate/push-gate/hooks`. It changes
nothing and exits 78 while the denylist or the verified gitleaks is missing, and it refuses
(exit 1) to replace a global `core.hooksPath` that isn't its own. Re-run it after updating
crewkit: `--doctor`'s `dispatcher` check fails while the installed copy is older. The new copy
is built beside the old one, then switched in with two renames; a failure between them puts the
old copy back. That matters: git runs no hooks at all from a `core.hooksPath` that doesn't
exist, so a missing gate directory is no gate (`--doctor`'s `global-gate` check fails).

### The exempt file

`~/.config/crewkit/push-gate-exempt` (`push_gate.exempt`) holds extended regexes matched against
the whole push URL: a plain line skips the denylist for matching remotes (gitleaks still runs),
and a `skip-all <regex>` line skips every check. It is a bypass any process running as you can
edit, so anchor each pattern to a host and an owner, in each URL form you push to, for example
`^https://github\.com/client-org/` and `^git@github\.com:client-org/`; an unanchored
`client-org` also matches `https://evil.example/client-org/`. `--doctor` reports it as one
`exempt` line (pattern counts and a fingerprint), and the scheduled doctor notifies when it
changes.

## Claude Code: refuse commands that skip the hooks

`push-gate/no-bypass-hook.py` is a Claude Code PreToolUse hook for Bash. It refuses a command that
would skip git's hooks, and with them this gate and the pre-commit scrub:

- `-c core.hooksPath=…`, or `-c include.path=` / `includeIf.*` (a config file that could set it),
  in any form: quoted, joined, `--config-env` and its abbreviations;
- the same keys in `GIT_CONFIG_PARAMETERS` or `GIT_CONFIG_KEY_<n>`;
- `git config <those keys> <value>`, `--unset`, `--unset-all` or `unset` of them, and
  `--remove-section` / `--rename-section` of `core`, `include` or `includeIf` (reading them
  passes);
- an alias whose command would be refused here: `-c alias.c='commit -n'`, `--config-env alias.*`,
  `git config alias.c 'commit -n'`, or one in `GIT_CONFIG_PARAMETERS`;
- `--no-verify` and the abbreviations git accepts (`--no-veri`), and `-n` among `git commit`'s
  short flags;
- `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG`, `GIT_CONFIG_NOSYSTEM`, `HOME`,
  `XDG_CONFIG_HOME` or pre-commit's `SKIP` set for a command that runs git, and `env -i` or
  `env -u <one of them>` in front of git (`HOME=/tmp ls` passes);
- `git commit-tree`, `git send-pack` and `git http-push`, which commit or push with no hooks;
- a write (`>`, `>>`, `tee`, `sed -i`, `perl -i`) to `.gitconfig`, `.git/config`, `git/config` or
  `config.worktree` in a command that mentions `hooksPath` or `[include`;
- any of these inside `$(…)`, backticks, a subshell, or a word that is a command of its own
  (`bash -c "…"`, `ssh host '…'`), up to three levels deep; deeper nesting is refused;
- a command it can't parse (unbalanced quotes): refused, not guessed at.

It says why, and that only the owner may bypass. It reads the command the way bash does: a
backslash-newline joins the lines, a `#` that starts a word starts a comment, and `$'…'` is
decoded. A heredoc's body is checked as a command of its own (`bash <<'X'`, `ssh host <<'X'`,
`cat <<'X' | sh`), except a message's. So a commit message that mentions `--no-verify`, in `-m`,
`-am`, `--message=`, `-F` or the usual `-m "$(cat <<'EOF' … EOF)"` (or `-F - <<'EOF'`), passes, as
does a `gh` `--body`, `--title`, `-b` or `-t`; only when `git commit`, `tag`, `notes` or `merge`,
or `gh`, is the command itself (an argument of `bash -c`, `ssh`, `eval` or `xargs` is a command
whatever flag comes before it), and with no other `$(` before the heredoc. A variable set on a
heredoc's line (`HOME=/tmp bash <<'X'`) counts for its body. A word inside the command that can't
be parsed is refused if it holds a shell metacharacter and could run git: it names git (quotes and
backslashes taken out) or holds `$`, a backquote, a glob (`? * [ ]`) or a brace, which could build the name
(`bash -c "$G commit $F -m it's (x)"` is refused; to run such a command, put it in a script file).
Otherwise, like a heredoc body that can't be parsed (prose: `echo "don't (x)"`), it is searched as
plain text, without its quotes and backslashes, for these forms. `-n` counts only in `git commit`'s own flags:
`git push -n` (`--dry-run`), `git log --grep commit -n 5` and `grep commit f -n` pass, and a
redirection (`git config core.hooksPath 2>/dev/null`) is not a value. It runs beside other Bash
hooks, such as rtk's.

It is a guard against habit, not a sandbox; the push gate is what enforces. Out of its scope:

- a flag or key hidden in a variable (`$X`), a script, a Makefile, or any other program that runs
  git for it;
- a variable set for later commands (`export HOME=/tmp; git push`, or the assignment form `HOME=/tmp; git push`), or `unset HOME`;
- a shell function or alias that runs git (`git() { command git "$@" --no-verify; }`), defined before the command;
- an alias already in a config file (`git ci -n`, where `ci` is `commit`), and `hub` or other
  git wrappers;
- a config file replaced, copied, moved or deleted (`cp`, `mv`, `ln`, `rm`), edited in an editor
  (`git config --edit`), or written by any means but those above; a write whose content it can't
  see (a variable, a file);
- `git update-ref` and other plumbing that moves a ref to a commit made elsewhere, and
  `git push` through another tool's transport.

Install it (owner step) from the gate's installed copy, after `install --yes`, so the path stays
the same when crewkit updates:

```bash
python3 ~/.local/share/crewkit/gate/push-gate/no-bypass-hook.py --install          # dry run
python3 ~/.local/share/crewkit/gate/push-gate/no-bypass-hook.py --install --yes    # backup first
```

## How it runs

- **The dispatcher** (`push-gate/hooks/_dispatch`, one symlink per hook name) runs the gate for
  `pre-push`, then chains every hook to the repository's own `<git-common-dir>/hooks/<name>`, so
  per-repo hooks keep working. If the gate refuses, the repository's own pre-push doesn't run.
  The receive-side names are there too (`pre-receive`, `update`, `proc-receive`,
  `post-receive`, `post-update`, and git-p4's), so a local bare repository you push to still
  runs its own server hooks.
- **A repository with its own `core.hooksPath`** (husky, lefthook) bypasses the global one.
  `push-gate.sh shim REPO --yes` adds one line to that repository's pre-push, which runs the gate
  first and hands the same stdin to the rest of the hook. A hook that isn't a shell script is
  moved to `pre-push.chained` and run after the shim. Running it twice changes nothing. The
  shim counts only as line 2 under a shell shebang: anything before it (an `exit 0`) would skip
  the gate, so the doctor fails such a hook, and `shim` adds the line again.
  `--doctor` lists every checkout under `push_gate.root` (each linked worktree too) whose
  `core.hooksPath` isn't the global one, and fails while one lacks the shim. It reads the value
  git itself uses there: a local one, `config.worktree`, an `include.path`, or an `includeIf` in
  `~/.gitconfig` (how a client tree often gets hooks of its own). A `core.hooksPath` set to
  empty, or none at all, means git runs no gate: a FAIL. A tool that regenerates its hooks
  (`husky install`) drops the shim; run `shim` again.
- **What it scans,** for each pushed ref: the branch name; an annotated tag's message, tagger
  and signature (and those of any tag it points to); every new commit's author, committer,
  message and diff; every file and path in the pushed tree; and gitleaks over the tags and the
  new commits' headers, messages and added lines (a merge's own changes included; a line a hunk
  removes isn't a new leak, as with `gitleaks git`). A remote matching an exempt regex skips
  the denylist but not gitleaks; `skip-all` skips everything. A push to a local path isn't
  gated, since nothing leaves the machine, but only when the path (symlinks resolved) is on the
  same device as `$HOME` and not in a synced folder (iCloud Drive, Dropbox, Google Drive,
  OneDrive, `~/Library/CloudStorage`, matched in any letter case, as APFS is case-insensitive).
  Any other mount (`/Volumes`, NFS, SMB, `//server`, a USB disk), and a path that can't be
  resolved, is gated: the check fails closed. On Linux a `/tmp` on its own tmpfs is gated too.
- **Which commits are new:** for an update, those after the remote's old sha. For a new branch
  or tag, everything down to the commits the push URL already has, as `git ls-remote` lists them
  (what `git push` itself leaves out), not down to local tracking refs: any process can move
  one (`git update-ref`), and with a `pushurl` they track a different remote. When the URL
  can't be listed, the whole history is scanned. The listing is a second connection to the
  remote; it never prompts for an HTTP password (`GIT_TERMINAL_PROMPT=0`).
- **What it prints:** commits, paths and counts, never the matched text. A path or branch name
  that itself holds a term is printed as a placeholder. Every run appends one line (time,
  PASS/BLOCKED/SKIP, repository, URL) to `push_gate.log`; a log failure never blocks. The URL
  is logged without its userinfo (a user and token before an `@` in the host part, where an
  https URL often carries a token).

### What a repository can't switch off

The scans read what git stores, not what the repository asks to be shown, and gitleaks runs on
the gate's terms:

- Diffs are read with `--text --no-textconv --no-ext-diff`, so a `binary` or `-diff` attribute
  (in `.gitattributes`, `.git/info/attributes` or `core.attributesFile`), a textconv driver or an
  external diff can't turn a diff into "Binary files differ" or nothing.
- Every scan's git runs with `--no-replace-objects` and no grafts, so a replace ref can't swap a
  clean commit in for the pushed one; with `i18n.logOutputEncoding=UTF-8`, so the repository's
  output encoding can't garble the text; with `core.quotePath=false`, so a non-ASCII term in a
  path isn't escaped; and with `log.showRoot`, `log.showSignature`, `diff.noprefix`,
  `diff.mnemonicPrefix`, `diff.renames`, `diff.relative`, `color.ui` and git grep's output keys
  pinned.
- gitleaks drops only the lines a diff hunk removes: the header lines are `Author:` and
  `Commit:` and the message is indented, so an author name that starts with `-` still reaches
  it.
- gitleaks reads the commits on stdin (`git log -p … | gitleaks stdin`) with the gate's own
  `push-gate/gitleaks-rules.toml` (`[extend] useDefault = true`: gitleaks's default rules, nothing
  else), from an empty directory of its own that is also its ignore path, with every
  `GITLEAKS_*` variable unset and `--ignore-gitleaks-allow`. So a repository's `.gitleaks.toml`
  (tracked or not), its `.gitleaksignore`, an inline `gitleaks:allow`, and `GITLEAKS_CONFIG` or
  `GITLEAKS_CONFIG_TOML` change nothing. A finding that is a false positive is for the owner to
  bypass, not for the repository to allow.

Settings: the `push_gate.*` keys in [settings.md](settings.md), all user-only. Exit codes:
[exit-codes.md](exit-codes.md#push-gate).

## For other tools

- `push-gate.sh status --json` prints `{"installed":bool,"denylist":bool}`.
- `push-gate.sh --doctor`: see [Doctor output](#doctor-output); `doctor-watch` and `schedule`:
  see [The scheduled doctor](#the-scheduled-doctor).
- `push-gate.sh gate-check [REPO]` runs the checks that decide whether pushes from one
  repository are gated, in the same format, for that repository's own local `make ci`. It fails
  on a machine without the gate, such as a hosted CI runner, so don't call it there.

## The scheduled doctor

`push-gate.sh schedule --yes` installs an hourly job that runs the installed gate's
`doctor-watch`: a launch agent (`~/Library/LaunchAgents/com.crewkit.push-gate-doctor.plist`) on
macOS, a systemd user timer (`crewkit-push-gate-doctor.timer`) on Linux; the templates are in
`push-gate/templates/`, and each value is escaped for its file (XML for the plist; for systemd,
quoted, with `%` and, in `ExecStart`, `$` doubled). The job's `PATH` is yours at `schedule`
time, without its relative entries. Re-running replaces the job. On Linux a user timer runs
only while you are logged in, unless lingering is on for you (`loginctl enable-linger`, an
owner step). `doctor-watch` runs `--doctor` and keeps the
last set of FAIL checks in `~/.local/state/crewkit/push-gate-doctor.state`. Only a change sends
a pointer, check ids only: `push-gate: 2 FAIL: dispatcher global-gate`, `push-gate: ok`, or
`push-gate: doctor error (exit 2)`. So a FAIL is reported once, not every hour, and again when
it changes or clears. `doctor-watch` exits 0 healthy, 1 on a FAIL, 2 on the doctor's own
error: only `--doctor`'s 0, and its 1 with FAIL lines, are results, and any other exit (its own
error 2, 127 for a missing command, 137 or 143 for a signal, 1 with no FAIL line) is an error,
never ok. The `exempt` line is compared too: a changed exempt file (a `skip-all` line added)
sends `push-gate: the exempt file changed: 1 exempt, 2 skip-all`, counts only.

A repository's own hook tool can drop the shim (`husky install` rebuilds `.husky/_/`); the
scheduled doctor is what notices. If the gate's installed copy is removed, the shim refuses the
push and says why.

## Out of scope

- The gate scans what is pushed, as git stores it. It doesn't stop a process running as you from
  editing the exempt file, the denylist, the gate's installed copy or its gitleaks: those are
  yours, and the doctor (with the scheduled doctor's notices) is how a change is seen, not
  prevented.
- A finding that is a false positive is for the owner to bypass; nothing a repository holds can
  allow it.
- The dispatcher runs a repository's own hooks from `<git-common-dir>/hooks`; it never builds
  that path when no repository is found.

## Doctor output

`push-gate.sh --doctor` is the contract for `crewkit doctor`'s push-gate check. It takes no
arguments and reads only the user's settings.

- **Lines:** one per check on stdout, `<check-id> <ok|FAIL> <detail>`: the id has no spaces, then
  exactly one space, `ok` or `FAIL`, one space, and free text to the end of the line. Nothing else
  goes to stdout; its own errors go to stderr.
- **Ids, in this order:** `global-gate` (the global `core.hooksPath` is the installed
  dispatcher), `dispatcher` (the installed copy matches this crewkit, or, run from the installed
  copy as the scheduled doctor is, the clone it was installed from, which `install` records;
  detail: its 12-hex version), `denylist` (present, readable, at least one valid pattern; detail: its path only),
  `gitleaks` (matches the sha256 `install.sh` recorded beside it and, once the gate is
  installed, the copy of it the gate recorded at its own install; detail: path and the first 12
  hex),
  `exempt` (always `ok` unless unreadable or holding an invalid pattern; detail: the counts of
  exempt and `skip-all` patterns and the file's first 12 sha256 hex, or `none (every remote
  gated)`; never a pattern), `root`
  (`push_gate.root` is set and a directory; detail: how many repositories), then
  `repo:~/<path>`, one for each checkout under the root (linked worktrees included) whose
  `core.hooksPath`, as git reads it there, isn't the global one: `ok` with the shim, `FAIL`
  without, or when it is empty. Checkouts on the global one get no line: `global-gate` covers
  them.
- **Exit:** 0 when every line is `ok`; 1 when any is `FAIL`; 2 on its own error (the settings
  can't be read, the root can't be listed), possibly after some lines.
- **What it never prints:** a denylist term, a secret, or a path outside `~/` (such a path
  prints as `(outside ~)/<last part>`).

## Audit: where an empty result could read as clean

A gate that scans command output passes a push when that output is empty. Each place below
used to, or could, read a failed command's empty output as "nothing found". Now each one tells
an error from an empty result and refuses the push on an error ("gate error: refusing push").
Every row has its own test in `tests/push-gate.bats` and a mutant in `tests/mutants/push-gate.json`, `push-gate-2.json` or `push-gate-3.json` (one spec split in three so each Linux-gate claim stays under the heavy lock's 3600 s cap).

| Where | Empty when it fails because | Now | Test |
|---|---|---|---|
| `git rev-list` for the pushed range | `$(…)` of a failed command is empty: no commits scanned | its exit status is checked | fail-open (a): git rev-list failing |
| `git show` of each commit | piped into `grep -c`, the count came from grep alone | captured first, its status checked | git show failing on a commit |
| `grep -c` over each commit | exit 2 (an error) prints nothing; `(( n > 0 ))` read that as zero | 0 and 1 are results; anything else refuses | fail-open (b): grep exiting 2 on a commit |
| `git grep` over the pushed tree | stderr discarded and status ignored: no file hits | 0 and 1 are results; anything else refuses | git grep failing on the pushed tree |
| `git ls-tree` of the pushed tree | piped into `grep -c`: no path hits | captured first, its status checked | git ls-tree failing on the pushed tree |
| `grep -c` over the path list | as for commits | as for commits | grep exiting 2 on the path list |
| `grep` over the branch name | exit 2 read as "no term" | exit 2 refuses | grep exiting 2 on the branch name |
| `grep` over a hit's path, deciding whether to print it | exit 2 read as "no term": a path holding a term printed | exit 2 refuses, printing nothing | grep exiting 2 on a hit's path |
| The pushed sha | a sha missing from the repository gave an empty range | `git cat-file -e` on it, and the line's shape, are checked | a pushed sha that isn't in the repository |
| The denylist | missing, unreadable, comment-only or holding an invalid regex: no patterns, no hits | each refuses every push to a gated remote | a missing, comment-only or invalid denylist |
| The exempt file | an invalid regex made `grep -q` exit 2, read as "not exempt" (safe) or, for `skip-all`, could mask an error | an invalid pattern or an unreadable file refuses | an unreadable exempt file, or an invalid exempt pattern |
| gitleaks | missing, replaced, or erroring | must exist, match the sha256 recorded at install, and exit 0; any other exit refuses | no gitleaks, no recorded sha256…; gitleaks erroring |
| The settings | an empty setting, or a project or `CREWKIT_*` value, pointing the gate at an empty denylist | `push_gate.*` is user-only; a user file that fails the ownership checks falls back to the defaults | the settings are user-only…; a user settings file that fails the ownership checks… |
| The dispatcher | the gate script missing (`command not found`) | its non-zero exit refuses the push | the dispatcher fails closed when the gate script is missing |
| A repo's own `core.hooksPath` | the global dispatcher never runs: nothing scanned | `shim`, and `--doctor` fails while a repository lacks it | a local core.hooksPath bypasses the global gate; shim… |
| The same, from `config.worktree`, `include.path` or an `includeIf` | reading `--local` or `--global` alone sees none of these, so the doctor said ok | the doctor, `gate-check`, `shim` and `install-hooks.sh` read git's own value in each checkout | --doctor reads the effective core.hooksPath…; --doctor checks each linked worktree… |
| An empty `core.hooksPath` | read as "not set", so ok, while git runs no hooks at all | a FAIL | --doctor: a core.hooksPath set to empty… |
| Diff attributes, textconv, `log.showRoot` | "Binary files differ", or an empty diff, in both scans | `--text --no-textconv --no-ext-diff`, `-c log.showRoot=true` | a -diff attribute can't hide…; a textconv driver…; log.showRoot=false… |
| Replace refs, grafts, the output encoding, `core.quotePath` | a replace ref swapped a clean commit in; an EBCDIC `i18n.logOutputEncoding` garbled the text; a non-ASCII path was escaped | every scan's git runs with `--no-replace-objects`, no grafts, UTF-8 output and the output keys pinned | a replace ref can't swap…; the repository's log output encoding…; a non-ASCII term in a path… |
| A header line starting with `-` | dropped with the removed lines before gitleaks | only a hunk's removed lines are dropped | an author name that starts with '-'… |
| A new branch's range | `--not --remotes=<remote>` trusted local tracking refs, which `git update-ref` moves, and a `pushurl`'s fetch-side refs | down to what `git ls-remote <push URL>` lists | a new branch: a forged tracking ref…; with a pushurl… |
| An annotated tag | only the commits under it were scanned | its message and tagger, and nested tags', go to both scans | an annotated tag's message and tagger… |
| `install` failing partway | the old copy moved aside, no new one: `core.hooksPath` pointed at nothing, no hooks ran | the old copy is put back | an install that fails partway… |
| A local push URL | every local path skipped; then a case-sensitive list of mounts and synced folders | skipped only on `$HOME`'s device and outside the synced folders, in any letter case | a push to a local path on a mount…; a synced folder in any letter case…; a local path on another device… |
| gitleaks's sidecar | the `.sha256` beside the binary could be rewritten with it, and `push_gate.gitleaks` can name any binary and sidecar | the binary must also match the gate's own copy of that sha256, written by `install` | a gitleaks swapped together with its sidecar… |
| `doctor-watch` | any exit but 2 with no FAIL line (127, 137) read as ok | only 0, and 1 with FAIL lines, are results; the rest is an error | doctor-watch: a doctor that crashes… |
| gitleaks's own config files and variables | a repository's `.gitleaks.toml` or `.gitleaksignore`, `gitleaks:allow`, `GITLEAKS_CONFIG*`: no findings | the gate's own config, an empty directory, no `GITLEAKS_*`, `--ignore-gitleaks-allow` | a repo's own .gitleaks.toml…can't switch gitleaks off; the end-to-end test |

Two empty results are clean by design: an empty pre-push stdin (nothing pushed) and a branch
deletion (the all-zero sha: 40 zeros, or 64 in a sha256 repository). Neither publishes
anything. Every other pre-push line must hold a local and a remote sha of the right shape, or
the push is refused.

The tests run gitleaks as a stub that also does what the real one lets a repository do (its own
config and ignore files, `gitleaks:allow`, `GITLEAKS_CONFIG*`). One test runs the real binary
end to end, opt-in, with nothing downloaded: point `CREWKIT_E2E_GITLEAKS` at the pinned release
(`pins/gitleaks.env`), for example the one `install.sh --only gitleaks` installed:

```bash
CREWKIT_E2E_GITLEAKS=~/.local/share/crewkit/gitleaks/gitleaks "$(tools/get-bats.sh)" tests/push-gate.bats
```
