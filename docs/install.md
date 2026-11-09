# Installing crewkit

`install.sh` sets up one machine: your user's `~/.claude`, `~/.local/bin`,
`~/.local/share/crewkit` and `~/.config`.
It needs no admin rights and writes no org-managed settings.

## Before you start

- Linux or macOS, on amd64 or arm64. Stock macOS bash (3.2) works.
- Claude Code (`claude`) on your `PATH`.
- `bash`, `curl`, `tar` and `sha256sum` (or `shasum` on macOS).
- For the crew-orchestrator landers only: bash 4.4 or later (stock macOS bash is 3.2, so on a
  Mac run `brew install bash`), plus `gh`, `git`, `jq` and `flock`. The installer itself doesn't
  need them.
- For claude-memsync: a private git repo for your memory, and the details its bootstrap asks
  for (see claude-memsync's own docs).

## Inputs

- `CREWKIT_DIR` = `$HOME/<path to your crewkit clone>`: the clone you are installing from,
  under your home directory (written with `$HOME`, because a `~` inside quotes isn't
  expanded).
- `MEMSYNC_HOST` = `<name for this machine>`: the name claude-memsync's bootstrap gives this
  machine.

### Already set, for reference (no action needed)

- A dry run is the default: without `--yes`, nothing is changed.
- All seven steps run unless you pass `--only`.
- `BOOTSTRAP_FLAGS` holds the flags for claude-memsync's bootstrap. It starts with
  `--host "$MEMSYNC_HOST"`; add others to it (see claude-memsync's docs), never after a second
  `--`.

## Usage

Set your inputs once, then define the run once, with everything but the flag that differs:

```bash
CREWKIT_DIR="$HOME/<path to your crewkit clone>"
MEMSYNC_HOST="<name for this machine>"
BOOTSTRAP_FLAGS=(--host "$MEMSYNC_HOST")
crewkit_install() { "$CREWKIT_DIR/install.sh" "$@" -- "${BOOTSTRAP_FLAGS[@]}"; }
```

To pass another bootstrap flag, add it to the list before you run, for example
`BOOTSTRAP_FLAGS+=(--role personal-dev)`.

Look at the plan, then run it:

```bash
crewkit_install          # dry run: print what would happen
crewkit_install --yes    # do it, once the plan looks right
```

Flags after `--` go to claude-memsync's bootstrap; the plan shows how many, not their values.
To run one step, add `--only bitc`, `--only gitleaks`, `--only memsync`, `--only herdr`,
`--only rtk`, `--only plugins` or `--only cli` (repeatable), for example
`crewkit_install --yes --only plugins`. The installer exits 0 when everything is done, 1
when a step failed, and 3 when it paused for a human (see [exit-codes.md](exit-codes.md)).

## What it does

1. **bitc.** Downloads `bitc_<version>_<os>_<arch>.tar.gz` and the release's `checksums.txt`,
   checks the archive's sha256 against the pin and that `checksums.txt` lists the same hash,
   then runs the new binary's `bitc version --json`: it must report the pinned version with
   `"release":true` before it replaces any existing `bitc` in `~/.local/bin`. On macOS, the pinned
   bitc runs local pools only: any `[providers.*]` table is refused (exit 78) until a later
   release adds remote providers there. bitc 0.1.0 also refused a pool with a memory floor on
   macOS; the release notes since then don't say whether that changed.
2. **gitleaks,** for the [push gate](push-gate.md). Downloads
   `gitleaks_<version>_<os>_<x64|arm64>.tar.gz` and the release's
   `gitleaks_<version>_checksums.txt`, checks the archive's sha256 against the pin and that the
   checksums file lists the same hash; `gitleaks version` must print the pinned version. It goes
   in `~/.local/share/crewkit/gitleaks/`, with the binary's own sha256 in `gitleaks.sha256`
   beside it: the gate refuses every push while the binary doesn't match it. Skipped while
   `pins/gitleaks.env` pins no release.
3. **claude-memsync.** Downloads `claude-utils-<tag>-<os>-<arch>.tar.gz` and the release's
   `SHA256SUMS`, checks the archive's sha256 against the pin and that `SHA256SUMS` lists the
   same hash, and unpacks it in a private temp directory. The unpacked `claude-memsync version`
   must print exactly `claude-memsync <pinned tag>`. Then it runs that release's
   `scripts/bootstrap.sh --prebuilt-dir <unpacked dir>` with any flags you passed after `--`.
   The bootstrap installs the binaries under `~/.local/lib/claude-memsync/<version>/`, links
   them into `~/.local/bin`, and writes host config and memory routes. Its exit 3 (paused,
   needs a human) stops the installer with exit 3. The plan shows how many flags you passed,
   not their values, since they can name keys.

   With nothing after `--`, bootstrap would only fail (it needs a host name, the org, a
   recovery recipient and a token source), so the step does everything above except run it:
   it prints `paused: claude-memsync's bootstrap needs flags ...` with the command to finish
   (this installer's own path, as you ran it, then `--yes --only memsync -- <bootstrap flags>`),
   and the other steps still run. The
   installer then exits 3 (paused, needs a human) instead of 0, naming the paused step. The dry
   run shows the note (as "would pause") in its memsync plan. A re-run of a machine whose
   memsync is already set up, without flags, also exits 3 for this reason. Run the finishing command with your flags (see
   claude-memsync's `docs/bootstrap.md`); the steps already done are skipped or re-checked as
   on any re-run.
4. **herdr.** Downloads the Exploded-views fork's release tarball
   `herdr-<tag>-<triple>.tar.gz` (triple `x86_64-unknown-linux-musl`,
   `aarch64-unknown-linux-musl`, `x86_64-apple-darwin` or `aarch64-apple-darwin`) and checks its
   sha256 against the pin. It then fetches the release's `<asset>.sha256` file, which must
   contain the line `<pinned sha256>  <asset>`, or the step stops. Only then is the tarball
   unpacked (links, `..` and absolute paths are refused); it must hold a plain file `herdr`.
   That binary is run before it replaces any existing `herdr` in `~/.local/bin`: the first line
   of `herdr --version` must be exactly `herdr <version>`, where `<version>` is the pin's
   optional `HERDR_VERSION` and otherwise the tag without its `v`. The fork's binary still
   reports its base version (`herdr 0.9.5`), not the tag, so the pin sets `HERDR_VERSION=0.9.5`.
   Upstream prints the same line, so until fork issue 20 is fixed the pinned tarball sha256 is
   the real identity check, not the version line; drop `HERDR_VERSION` with the first pin after
   that fix.
   Then, for each agent CLI on PATH (`claude`, `codex`, `opencode`, `copilot`, `cursor-agent`,
   `droid`, `qwen`, `kimi`, `pi`), it runs `herdr integration install <agent>` (`cursor` for
   `cursor-agent`). With none of them on PATH it installs herdr only; that is not a failure. An
   agent that is installed but has never been run has no config directory, so herdr refuses its
   integration ("directory not found"); the step prints a note and carries on. Run the agent
   once and re-run `--only herdr`. Any other integration failure fails the step. The claude
   integration adds a hook to `~/.claude/settings.json`, so it gets the same guard as rtk
   (below): your other hooks must survive it or the file is restored and the step fails; this
   needs `jq`.
5. **rtk.** Downloads `rtk-<triple>.tar.gz` (`x86_64-unknown-linux-musl`,
   `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin` or `aarch64-apple-darwin`) and the
   release's `checksums.txt`, checks the hash the way the bitc step does, and requires
   `rtk --version` to print exactly `rtk <pinned version>` before replacing any existing `rtk`.
   Then it runs `rtk init -g --auto-patch`, which registers the `rtk hook claude` PreToolUse hook
   in `~/.claude/settings.json` and adds `@RTK.md` to `~/.claude/CLAUDE.md`. Without
   `--auto-patch` a non-interactive rtk leaves an existing settings.json alone. The step needs
   `jq`: it lists every hook command in settings.json first, and if any is missing afterwards it
   puts the file back and fails (a backup, `settings.json.crewkit-before`, sits next to it only
   while rtk runs). A re-run where the hook and `@RTK.md` are already there does
   not call `rtk init`. The hook runs `rtk` by name, so `~/.local/bin` must be on PATH.
6. **Plugins.** Skipped, with a note, when `claude` isn't on PATH. Otherwise adds this clone as
   the `crewkit` marketplace, installs `crew-nodes`, `agent-practice` and `memory-notices` (the
   marketplace also lists `crew-lanes` and `crew-orchestrator`, previews this installer doesn't
   install), and copies the agent-practice rules fragment to
   `~/.claude/rules/agent-practice.md`. If you edited that file, your copy is saved first as
   `agent-practice.md.bak` (or `.bak.1`, `.bak.2`, … so an earlier backup is never
   overwritten). With `--yes` it first asks Claude Code once what is already added and
   installed (two read-only calls) and skips those, so a re-run installs nothing twice; a
   rules file that is already current is left alone. A dry run makes no Claude Code calls at
   all and lists every step as "skipped if already added or installed".
7. **CLI.** Links `~/.local/bin/crewkit` to this clone's `bin/crewkit`. A `crewkit` already
   there that is not that link is refused (exit 1) and left alone.

A tool whose pin file still says `TAG=TODO` is skipped. bitc is pinned at v0.1.4, gitleaks at
v8.30.1, herdr at v0.9.5-ev.2 (the Exploded-views fork), rtk at v1.1.0 and claude-memsync at v0.3.0-ev.1 (a pre-release of the fork its pin's URL names).

### What it refuses

- Downloads over anything but https (`curl --proto =https`).
- An archive whose sha256 doesn't match the pin, before it is unpacked or run, and a
  claude-memsync archive its own `SHA256SUMS` disagrees with.
- A pinned tool with no hash for your OS and architecture, a malformed hash, a non-https URL
  or a tag that isn't `vMAJOR.MINOR.PATCH`, optionally with a pre-release suffix of ASCII
  letters, digits, dots and hyphens (`v0.3.0-ev.1`). Every pin check is ASCII-only, whatever
  your locale.
- Archive members with absolute paths or `..` parts, and anything but plain files and
  directories (links, devices, FIFOs).
- A claude-memsync release without `claude-memsync`, `claude-memmerge` and
  `scripts/bootstrap.sh` in its `claude-utils-<tag>-<os>-<arch>/` directory, or whose
  `claude-memsync version` isn't the pinned tag (its bootstrap never runs).
- A herdr or rtk binary whose `--version` isn't exactly the pinned version (see step 4 for
  herdr's `HERDR_VERSION`), a herdr tarball without a plain `herdr` file or whose `.sha256`
  file disagrees with the pin or lacks the asset, an rtk archive its `checksums.txt`
  disagrees with or lacks, and an `rtk init` that drops a hook from your settings.json (the
  file is restored).

Pin files are read as `KEY=value` lines; they are never sourced, so nothing in them runs.

## Pins

Each file in `pins/` names a download URL, one release tag and one sha256 per supported
target (Linux and macOS, amd64 and arm64):

```text
MEMSYNC_URL=https://github.com/OWNER/claude-utils/releases/download
MEMSYNC_TAG=v0.1.0
MEMSYNC_SHA256_linux_amd64=<64 hex characters>
MEMSYNC_SHA256_linux_arm64=<64 hex characters>
MEMSYNC_SHA256_darwin_amd64=<64 hex characters>
MEMSYNC_SHA256_darwin_arm64=<64 hex characters>
```

A pin file may also carry one optional `<PREFIX>_VERSION=X.Y.Z[-pre]` line (only herdr's is
read): the version the binary prints when that is not the tag. It is blank or absent in an
unpinned file; `tools/lint-skills.py` rejects a malformed or duplicate one.

The installer never fetches "latest", and it refuses an archive whose hash doesn't match the
pin before unpacking or running anything from it. To move to a new release, change the tag and
every hash in one commit. Download each asset and hash it yourself (`shasum -a 256`), then
compare with the release's `SHA256SUMS` or `checksums.txt` (herdr: each asset's own `.sha256` file). An unpinned file
keeps `TAG=TODO` with a blank URL and blank hashes; `tools/lint-skills.py` rejects anything in
between.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done, or the dry run printed its plan. |
| 1 | A step failed. Nothing after it ran. A failing command never leaks its own exit code. |
| 64 | Usage error (the codes are shared by every crewkit script; see [exit-codes.md](exit-codes.md)). |
| 3 | Paused: claude-memsync's bootstrap needs a human. Do what it says, then re-run. |

## Cloud sessions and containers

Don't run `install.sh` there. Commit a `.claude/settings.json` with the hooks you want to the
repo, and have the environment's setup script fetch the same pinned releases (or point
`CLAUDE_CODE_PLUGIN_SEED_DIR` at a prepared plugin directory). Cloud sessions are for
experiments: pull memory only, and give them no private keys.
