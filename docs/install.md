# Installing crewkit

`install.sh` sets up one machine: your user's `~/.claude`, `~/.local/bin` and `~/.config`.
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
- All three steps run unless you pass `--only`.
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
To run one step, add `--only bitc`, `--only memsync` or `--only plugins` (repeatable), for
example `crewkit_install --yes --only plugins`.

## What it does

1. **bitc.** Downloads `bitc_<version>_<os>_<arch>.tar.gz` and the release's `checksums.txt`,
   checks the archive's sha256 against the pin and that `checksums.txt` lists the same hash,
   then runs the new binary's `bitc version --json`: it must report the pinned version with
   `"release":true` before it replaces any existing `bitc` in `~/.local/bin`. On macOS, bitc
   0.1.0 runs local pools only: a pool with a memory floor or any `[providers.*]` table is
   refused (exit 78) until a later release adds them.
2. **claude-memsync.** Downloads `claude-utils-<tag>-<os>-<arch>.tar.gz` and the release's
   `SHA256SUMS`, checks the archive's sha256 against the pin and that `SHA256SUMS` lists the
   same hash, and unpacks it in a private temp directory. The unpacked `claude-memsync version`
   must print exactly `claude-memsync <pinned tag>`. Then it runs that release's
   `scripts/bootstrap.sh --prebuilt-dir <unpacked dir>` with any flags you passed after `--`.
   The bootstrap installs the binaries under `~/.local/lib/claude-memsync/<version>/`, links
   them into `~/.local/bin`, and writes host config and memory routes. Its exit 3 (paused,
   needs a human) stops the installer with exit 3. The plan shows how many flags you passed,
   not their values, since they can name keys.
3. **Plugins.** Adds this clone as the `crewkit` marketplace, installs `agent-practice` and
   `memory-notices` (the marketplace also lists `crew-lanes` and `crew-orchestrator`, previews this
   installer doesn't install), and copies the agent-practice rules fragment to
   `~/.claude/rules/agent-practice.md`. If you edited that file, your copy is saved first as
   `agent-practice.md.bak` (or `.bak.1`, `.bak.2`, … so an earlier backup is never
   overwritten). With `--yes` it first asks Claude Code once what is already added and
   installed (two read-only calls) and skips those, so a re-run installs nothing twice; a
   rules file that is already current is left alone. A dry run makes no Claude Code calls at
   all and lists every step as "skipped if already added or installed".

A tool whose pin file still says `TAG=TODO` is skipped. bitc is pinned at v0.1.0 and
claude-memsync at v0.3.0-ev.1 (a pre-release of the fork its pin's URL names).

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

The installer never fetches "latest", and it refuses an archive whose hash doesn't match the
pin before unpacking or running anything from it. To move to a new release, change the tag and
every hash in one commit, taking the hashes from that release's `SHA256SUMS`. An unpinned file
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
