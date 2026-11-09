#!/usr/bin/env bash
# install.sh: one-prompt setup for crewkit on this machine.
#
# Steps, in order:
#   1. bitc        fetch the pinned release for this OS/arch, verify its sha256, install it.
#   2. gitleaks    the same for the push gate's pinned gitleaks, into
#                  ~/.local/share/crewkit/gitleaks/, with its binary's sha256 recorded beside
#                  it (the gate refuses a gitleaks that no longer matches).
#   3. memsync     fetch the pinned claude-utils release, verify its sha256 (and that its
#                  SHA256SUMS agrees), then run its scripts/bootstrap.sh --prebuilt-dir, which
#                  installs the binaries and writes host config and memsync routes.
#   4. herdr       fetch the pinned fork release (a tarball holding `herdr`), verify its sha256
#                  (and that its .sha256 file agrees) and that the binary reports the pinned
#                  version, install it, then run `herdr integration install <agent>` for each
#                  agent CLI on PATH (none is fine).
#   5. rtk         fetch the pinned release, verify its sha256 (and that its checksums.txt
#                  agrees), install it, then run `rtk init -g --auto-patch` unless its hook and
#                  the @RTK.md line are already there. Your other settings.json hooks must
#                  survive it, or the step restores them and fails. Needs jq.
#   6. plugins     add this repo as the `crewkit` marketplace and install its plugins
#                  (crew-nodes, agent-practice, memory-notices), and copy the agent-practice
#                  rules fragment into ~/.claude/rules/. Skipped, with a note, when claude
#                  isn't on PATH.
#   6. cli         link ~/.local/bin/crewkit to this tree's bin/crewkit. A crewkit there that
#                  isn't that link is refused (exit 1) and left alone.
#
# Usage:
#   ./install.sh                 # dry run: print what would happen, change nothing
#   ./install.sh --yes           # do it
#   ./install.sh --only plugins  # one step: bitc, gitleaks, memsync, herdr, rtk, plugins or cli (repeatable)
#   ./install.sh --yes -- <bootstrap flags>   # flags after -- go to memsync's bootstrap.sh
#
# Pins live in pins/<tool>.env: a URL, a tag and one sha256 per OS/arch. A download whose hash
# doesn't match its pin is refused before it is unpacked or run. There is no "latest".
#
# With nothing after --, the memsync step still downloads and checks the pinned release but does
# not run bootstrap (it needs flags: a host name, the org, a recovery recipient, a token source).
# It prints a note with the command to finish, the other steps still run, and the exit is 3. The
# dry run shows the same note.
#
# Exit (docs/exit-codes.md) 0 = done (or dry run printed), 1 = a step failed, 3 = paused, needs a
# human (bootstrap.sh's own pause, or the memsync step paused for want of bootstrap flags),
# 64 = usage.
set -Eeuo pipefail
# Any command that fails outside a die is a failed step: exit 1, never its own code (which
# could read as 2 "usage" or 3 "paused").
trap 'exit 1' ERR

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
yes=0
tmp=''
steps=()
bootstrap_args=()
paused=()
# The finishing command names this script the way it was run, so it works from any directory
# (`bash install.sh` gives a bare name, which a shell wouldn't find: run it as ./install.sh).
self=$0
[[ $self == */* ]] || self=./$self
printf -v self '%q' "$self"
# pause_note VERB: the note for the memsync step ("paused" in a real run, "would pause" in a dry run).
pause_note() {
  echo "$1: claude-memsync's bootstrap needs flags (a host name, the org, a recovery recipient and a token source); finish with: $self --yes --only memsync -- <bootstrap flags> (see claude-memsync's docs/bootstrap.md)"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "install.sh: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --only)
      [[ ${2:-} =~ ^(bitc|gitleaks|memsync|herdr|rtk|plugins|cli)$ ]] || { usage >&2; exit 64; }
      steps+=("$2"); shift ;;
    --) shift; bootstrap_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done
((${#steps[@]})) || steps=(bitc gitleaks memsync herdr rtk plugins cli)

# run CMD...: print it, and run it only with --yes.
run() {
  printf '  %s\n' "$*"
  if ((yes)); then "$@"; fi
}

detect_target() {
  case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported OS $(uname -s) (linux and darwin are supported)" ;;
  esac
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m) (amd64 and arm64 are supported)" ;;
  esac
}

# load_pin TOOL PREFIX: read pins/TOOL.env and set pin_url, pin_tag and pin_sha for this
# target, and pin_version from an optional PREFIX_VERSION line (empty when absent; only the herdr
# step uses it). Returns 1 when the tool is not pinned yet (no tag, or TODO). A pinned tool with a
# bad URL or no valid hash for this target is an error. The file is parsed as KEY=value
# lines, never sourced, so nothing in it runs.
load_pin() {
  # In a UTF-8 locale, bash's [0-9A-Za-z] ranges match thousands of non-ASCII lookalikes; the
  # pin checks below must mean ASCII. Local, so the bootstrap still gets the user's locale.
  local LC_ALL=C
  local file="$here/pins/$1.env" key value line
  [[ -r $file ]] || die "missing pin file pins/$1.env"
  pin_url='' pin_tag='' pin_sha='' pin_version=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Za-z0-9_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case $key in
      "$2_URL") pin_url=$value ;;
      "$2_TAG") pin_tag=$value ;;
      "$2_VERSION") pin_version=$value ;;
      "$2_SHA256_${os}_${arch}") pin_sha=$value ;;
    esac
  done < "$file"
  [[ -n $pin_tag && $pin_tag != TODO* ]] || return 1
  # An optional pre-release suffix (v0.3.0-ev.1): letters, digits, dots and hyphens only, since
  # the tag goes into download URLs and file names.
  [[ $pin_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
    || die "pins/$1.env: tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-PRERELEASE"
  [[ $pin_url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9./_-]+$ ]] || die "pins/$1.env: $2_URL must be an https URL"
  [[ -z $pin_version || $pin_version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
    || die "pins/$1.env: $2_VERSION must be MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-PRERELEASE"
  [[ -n $pin_sha ]] || die "pins/$1.env: no sha256 pinned for $os/$arch"
  [[ $pin_sha =~ ^[0-9a-f]{64}$ ]] || die "pins/$1.env: the $os/$arch sha256 is not 64 hex characters"
}

# The jq filter for every hook command in a settings.json.
hook_commands='[..|.command? // empty | strings]'

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch_verified URL SHA DEST: download over https only, then refuse it unless its sha256
# is exactly SHA. Nothing is unpacked or run before this returns.
# fetch URL DEST: download over https only (redirects included).
fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 30 --max-time 600 --retry 3 \
    -o "$2" "$1" || die "download failed: $1"
}

fetch_verified() {
  fetch "$1" "$3"
  local got
  got=$(sha256 "$3")
  [[ $got == "$2" ]] || die "sha256 mismatch for ${1##*/}: refusing it (pinned $2, got $got)"
}

# safe_extract ARCHIVE DIR: unpack a verified tarball, refusing absolute paths, .. parts and
# anything but plain files and directories (links, devices, FIFOs), so it can't write outside
# DIR.
safe_extract() {
  local member listing
  listing=$(tar -tvzf "$1") || die "cannot read ${1##*/}"
  if grep -qv '^[-d]' <<<"$listing"; then
    die "unsafe entry in ${1##*/}: only files and directories are allowed (no links, devices or FIFOs)"
  fi
  while IFS= read -r member; do
    if [[ $member == /* || $member =~ (^|/)\.\.(/|$) ]]; then
      die "unsafe path in ${1##*/}: $member"
    fi
  done < <(tar -tzf "$1")
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" --no-same-owner
}

workdir() {
  if [[ -z ${tmp:-} ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
  fi
}

# check_version WANT CMD...: run CMD (a downloaded binary's version command); the first line of
# its output must be exactly WANT, or the step dies. Every binary runs this before it replaces
# anything.
check_version() {
  local want=$1 reported
  shift
  reported=$("$@" 2>&1) || reported=""
  reported=${reported%%$'\n'*}
  [[ $reported == "$want" ]] || die "the downloaded ${want%% *} reports '$reported' to ${want%% *} ${*:2}, not '$want'"
}

# need_jq WHY: die naming jq unless it is on PATH.
need_jq() {
  command -v jq >/dev/null || die "jq is not on PATH; $1"
}

# guard_hooks SETTINGS LABEL CMD...: run CMD (LABEL names it in messages), which edits SETTINGS (a
# Claude Code settings.json), and return its exit status. Every hook command SETTINGS had
# before must still be there after, or the file is put back and this dies; a failed CMD puts it
# back too. The backup sits next to the file and is gone on return, unless a restore failed or
# an earlier run left one: then this dies naming it and never touches it. A user's hook is
# never lost. (Called in a `||` list, so set -e is off in here: every step is checked.)
guard_hooks() {
  local settings=$1 label=$2 before='' after='' c lost='' rc=0 backup="$1.crewkit-before"
  shift 2
  if [[ -e $backup ]]; then
    die "$backup exists: a run that was interrupted left it. Compare it with $settings, keep the one you want, delete the backup, then re-run"
  fi
  if [[ -f $settings ]]; then
    before=$(jq -r "$hook_commands | .[]" "$settings") || die "$settings is not valid JSON; fix it, then re-run"
    cp -p "$settings" "$backup" || die "could not back up $settings to $backup; $label was not run"
  fi
  "$@" || rc=$?
  if [[ -f $backup ]]; then
    after=$(jq -r "$hook_commands | .[]" "$settings" 2>/dev/null) || after=''
    while IFS= read -r c; do
      [[ -n $c ]] || continue
      grep -qxF -- "$c" <<<"$after" || lost="$lost [$c]"
    done <<<"$before"
    if ((rc != 0)) || [[ -n $lost ]]; then
      cp -p "$backup" "$settings" || die "$label changed $settings and it could not be put back; your original is at $backup"
      echo "  $settings restored from its backup"
    fi
    rm -f "$backup" || die "could not remove $backup"
  fi
  [[ -z $lost ]] || die "$label dropped hook command(s) from $settings:$lost"
  return "$rc"
}

step_bitc() {
  echo "bitc:"
  if ! load_pin bitc BITC; then
    echo "  skipped: pins/bitc.env has no release pinned yet"
    return 0
  fi
  local asset="bitc_${pin_tag#v}_${os}_${arch}.tar.gz" bin="$HOME/.local/bin"
  echo "  $pin_url/$pin_tag/$asset (sha256 $pin_sha) -> $bin/bitc"
  ((yes)) || return 0
  workdir
  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release's own checksums.txt must agree with the pin: it catches a pin copied wrong.
  fetch "$pin_url/$pin_tag/checksums.txt" "$tmp/checksums.txt"
  grep -qxF "$pin_sha  $asset" "$tmp/checksums.txt" \
    || die "checksums.txt for $pin_tag does not list $asset with the pinned sha256"
  safe_extract "$tmp/$asset" "$tmp/bitc"
  [[ -f $tmp/bitc/bitc ]] || die "$asset has no bitc binary"
  # Fixed modes whatever the umask: tools/heavy_lock.py refuses a group-writable binary, directory or record.
  (umask 022; mkdir -p "$bin")
  install -m 0755 "$tmp/bitc/bitc" "$bin/.bitc.new"
  # The binary itself must say it is the pinned release before it replaces anything.
  # `bitc version --json` is the stable form (the plain line is for humans). Its output is
  # compact, so plain matching needs no JSON parser; the closing quote rules out 0.1.0-rc1.
  local reported
  reported=$("$bin/.bitc.new" version --json 2>&1) || reported=""
  if [[ $reported != *"\"version\":\"${pin_tag#v}\""* || $reported != *'"release":true'* ]]; then
    rm -f "$bin/.bitc.new"
    die "the downloaded bitc reports '$reported' to bitc version --json, not version ${pin_tag#v} with release true"
  fi
  # The binary's sha256 goes beside gitleaks'; tools/heavy_lock.py refuses a bitc hold unless
  # ~/.local/bin/bitc still hashes to it.
  local share="$HOME/.local/share/crewkit"
  (umask 022; mkdir -p "$share")
  sha256 "$bin/.bitc.new" > "$share/.bitc.sha256.new"
  chmod 0644 "$share/.bitc.sha256.new"
  mv -f "$bin/.bitc.new" "$bin/bitc"
  mv -f "$share/.bitc.sha256.new" "$share/bitc.sha256"
  echo "  installed bitc $pin_tag ($reported)"
}

step_gitleaks() {
  echo "gitleaks:"
  if ! load_pin gitleaks GITLEAKS; then
    echo "  skipped: pins/gitleaks.env has no release pinned yet (the push gate refuses every push without it)"
    return 0
  fi
  # gitleaks names its amd64 builds x64.
  local ver=${pin_tag#v} garch=$arch dir="$HOME/.local/share/crewkit/gitleaks"
  [[ $arch == amd64 ]] && garch=x64
  local asset="gitleaks_${ver}_${os}_${garch}.tar.gz" sums="gitleaks_${ver}_checksums.txt"
  echo "  $pin_url/$pin_tag/$asset (sha256 $pin_sha) -> $dir/gitleaks"
  ((yes)) || return 0
  workdir
  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release's own checksums file must agree with the pin: it catches a pin copied wrong.
  fetch "$pin_url/$pin_tag/$sums" "$tmp/$sums"
  grep -qxF "$pin_sha  $asset" "$tmp/$sums" \
    || die "$sums does not list $asset with the pinned sha256"
  safe_extract "$tmp/$asset" "$tmp/gitleaks"
  [[ -f $tmp/gitleaks/gitleaks ]] || die "$asset has no gitleaks binary"
  mkdir -p "$dir"
  install -m 0755 "$tmp/gitleaks/gitleaks" "$dir/.gitleaks.new"
  # The binary itself must say it is the pinned release before it replaces anything.
  local reported
  reported=$("$dir/.gitleaks.new" version 2>&1) || reported=""
  if [[ $reported != "$ver" && $reported != "v$ver" ]]; then
    rm -f "$dir/.gitleaks.new"
    die "the downloaded gitleaks reports '$reported' to gitleaks version, not $ver"
  fi
  sha256 "$dir/.gitleaks.new" > "$dir/.gitleaks.sha256.new"
  mv -f "$dir/.gitleaks.new" "$dir/gitleaks"
  mv -f "$dir/.gitleaks.sha256.new" "$dir/gitleaks.sha256"
  echo "  installed gitleaks $pin_tag (sha256 $(cat "$dir/gitleaks.sha256"))"
}

step_memsync() {
  echo "memsync:"
  if ! load_pin memsync MEMSYNC; then
    echo "  skipped: pins/memsync.env has no release pinned yet"
    ((${#bootstrap_args[@]} == 0)) || echo "  note: ${#bootstrap_args[@]} bootstrap flag(s) after -- ignored"
    return 0
  fi
  local top="claude-utils-$pin_tag-$os-$arch"
  local asset="$top.tar.gz"
  echo "  $pin_url/$pin_tag/$asset (sha256 $pin_sha)"
  # Flags may carry key commands or paths, so the plan shows how many, not what.
  if ((${#bootstrap_args[@]} == 0)); then
    echo "  then: no bootstrap (nothing after --)"
    # With --yes the note comes after the release has been checked, so a bad release dies first.
    ((yes)) || echo "  $(pause_note "would pause")"
  else
    echo "  then: scripts/bootstrap.sh --prebuilt-dir <unpacked $top> (+${#bootstrap_args[@]} flag(s) after --)"
  fi
  ((yes)) || return 0
  workdir
  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release's own SHA256SUMS must agree with the pin: it catches a pin copied wrong.
  fetch "$pin_url/$pin_tag/SHA256SUMS" "$tmp/SHA256SUMS"
  grep -qxF "$pin_sha  $asset" "$tmp/SHA256SUMS" \
    || die "SHA256SUMS for $pin_tag does not list $asset with the pinned sha256"
  safe_extract "$tmp/$asset" "$tmp/memsync"
  local dir="$tmp/memsync/$top" f
  for f in claude-memsync claude-memmerge scripts/bootstrap.sh; do
    [[ -f $dir/$f ]] || die "$asset has no $top/$f"
  done
  # The binary must be the pinned release: bootstrap's own check only wants a version-shaped
  # string, so a mispacked or wrong-tag archive would otherwise install.
  check_version "claude-memsync $pin_tag" "$dir/claude-memsync" version
  # Bootstrap needs flags (a host, the org, a recovery recipient, a token source); with none, it
  # would only fail. Pause instead, so the other steps still run. The pinned release was
  # downloaded and checked above exactly as for a real run.
  if ((${#bootstrap_args[@]} == 0)); then
    echo "  $(pause_note paused)"
    paused+=(memsync)
    return 0
  fi
  local rc=0
  # ${a[@]+...}: bash 3.2 (stock macOS) treats an empty array as unbound under set -u.
  bash "$dir/scripts/bootstrap.sh" --prebuilt-dir "$dir" ${bootstrap_args[@]+"${bootstrap_args[@]}"} || rc=$?
  if ((rc == 3)); then
    echo "install.sh: bootstrap paused: it needs a human. Do what it says, then re-run." >&2
    exit 3
  fi
  ((rc == 0)) || die "bootstrap failed (exit $rc)"
  echo "  installed claude-memsync $pin_tag"
}

# Agent CLIs herdr has an integration for: the command to look for on PATH. The integration's
# name is the command without a "-agent" suffix (cursor's CLI is cursor-agent).
agent_clis="claude codex opencode copilot cursor-agent droid qwen kimi pi"

# agent_kinds: print the herdr integration names of the agent CLIs found on PATH, one per line.
agent_kinds() {
  local a
  for a in $agent_clis; do
    if command -v "$a" >/dev/null; then echo "${a%-agent}"; fi
  done
}

# herdr_integration KIND: run herdr's integration install for KIND, show its output, and keep
# the output in integration_out for the caller.
integration_out=''
herdr_integration() {
  local rc=0
  integration_out=$("$HOME/.local/bin/herdr" integration install "$1" </dev/null 2>&1) || rc=$?
  if [[ -n $integration_out ]]; then printf '  %s\n' "${integration_out//$'\n'/$'\n'  }"; fi
  return "$rc"
}

step_herdr() {
  echo "herdr:"
  if ! load_pin herdr HERDR; then
    echo "  skipped: pins/herdr.env has no release pinned yet"
    return 0
  fi
  local triple
  case $os-$arch in
    linux-amd64) triple=x86_64-unknown-linux-musl ;;
    linux-arm64) triple=aarch64-unknown-linux-musl ;;
    darwin-amd64) triple=x86_64-apple-darwin ;;
    darwin-arm64) triple=aarch64-apple-darwin ;;
  esac
  local asset="herdr-$pin_tag-$triple.tar.gz" bin="$HOME/.local/bin" kinds
  kinds=$(agent_kinds | tr '\n' ' ')
  echo "  $pin_url/$pin_tag/$asset (sha256 $pin_sha, checked against $asset.sha256) -> $bin/herdr"
  echo "  then: herdr integration install <agent> for each agent CLI on PATH (now: ${kinds:-none})"
  ((yes)) || return 0
  # Before anything is downloaded: the claude integration is guarded with jq.
  if [[ $kinds == *claude* ]]; then need_jq "the herdr step needs it to check that the claude integration keeps your settings.json hooks"; fi
  workdir
  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release's own .sha256 file must agree with the pin: it catches a pin copied wrong.
  fetch "$pin_url/$pin_tag/$asset.sha256" "$tmp/$asset.sha256"
  grep -qxF "$pin_sha  $asset" "$tmp/$asset.sha256" \
    || die "$asset.sha256 for $pin_tag does not list $asset with the pinned sha256"
  safe_extract "$tmp/$asset" "$tmp/herdr"
  [[ -f $tmp/herdr/herdr && ! -L $tmp/herdr/herdr ]] || die "$asset has no herdr binary"
  # The binary itself must say it is the pinned release before it replaces anything. The fork's
  # binary prints its base version (HERDR_VERSION), not the tag, and upstream prints the same
  # line: until fork issue 20 is fixed the pinned tarball sha256 is the real identity check,
  # not this line. Drop HERDR_VERSION from the pin with the first pin after the fix.
  check_version "herdr ${pin_version:-${pin_tag#v}}" "$tmp/herdr/herdr" --version
  mkdir -p "$bin"
  install -m 0755 "$tmp/herdr/herdr" "$bin/.herdr.new"
  mv -f "$bin/.herdr.new" "$bin/herdr"
  echo "  installed herdr $pin_tag"
  local kind found=0 rc
  for kind in $kinds; do
    found=1
    rc=0
    # herdr edits the agent's own settings; for claude that is settings.json, whose other
    # hooks must survive.
    if [[ $kind == claude ]]; then
      guard_hooks "$HOME/.claude/settings.json" "herdr integration install claude" herdr_integration claude || rc=$?
    else
      herdr_integration "$kind" || rc=$?
    fi
    if ((rc == 0)); then
      echo "  herdr integration for $kind installed"
    elif [[ $integration_out == *"directory not found at "* ]]; then
      # An agent that is installed but has never run has no config directory yet, and herdr
      # says so: a note, since the step's job (herdr itself) is done.
      echo "  note: herdr integration install $kind failed (run $kind once, then re-run this step)"
    else
      die "herdr integration install $kind failed (exit $rc)"
    fi
  done
  ((found)) || echo "  no agent CLI on PATH: no herdr integration installed (herdr integration install <agent> adds one later)"
}

step_rtk() {
  echo "rtk:"
  if ! load_pin rtk RTK; then
    echo "  skipped: pins/rtk.env has no release pinned yet"
    return 0
  fi
  local triple
  case $os-$arch in
    linux-amd64) triple=x86_64-unknown-linux-musl ;;
    linux-arm64) triple=aarch64-unknown-linux-gnu ;;
    darwin-amd64) triple=x86_64-apple-darwin ;;
    darwin-arm64) triple=aarch64-apple-darwin ;;
  esac
  local asset="rtk-$triple.tar.gz" bin="$HOME/.local/bin"
  local settings="$HOME/.claude/settings.json"
  echo "  $pin_url/$pin_tag/$asset (sha256 $pin_sha) -> $bin/rtk"
  echo "  then: rtk init -g --auto-patch (skipped when its hook and @RTK.md are already set up)"
  ((yes)) || return 0
  need_jq "the rtk step needs it to check that rtk init keeps your settings.json hooks"
  workdir
  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release's own checksums.txt must agree with the pin: it catches a pin copied wrong.
  fetch "$pin_url/$pin_tag/checksums.txt" "$tmp/rtk-checksums.txt"
  grep -qxF "$pin_sha  $asset" "$tmp/rtk-checksums.txt" \
    || die "checksums.txt for $pin_tag does not list $asset with the pinned sha256"
  safe_extract "$tmp/$asset" "$tmp/rtk"
  [[ -f $tmp/rtk/rtk ]] || die "$asset has no rtk binary"
  check_version "rtk ${pin_tag#v}" "$tmp/rtk/rtk" --version
  mkdir -p "$bin"
  install -m 0755 "$tmp/rtk/rtk" "$bin/.rtk.new"
  mv -f "$bin/.rtk.new" "$bin/rtk"
  echo "  installed rtk $pin_tag"
  if [[ -f $settings ]] && jq -e "$hook_commands | index(\"rtk hook claude\") != null" "$settings" >/dev/null 2>&1 \
    && grep -qxF '@RTK.md' "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
    echo "  rtk's hook and @RTK.md are already set up"
    return 0
  fi
  # rtk init edits settings.json in place: every other hook there must survive it.
  local rc=0
  guard_hooks "$settings" "rtk init -g" "$bin/rtk" init -g --auto-patch </dev/null || rc=$?
  ((rc == 0)) || die "rtk init -g failed (exit $rc)"
  echo "  rtk init -g done: your other hooks are intact"
}

step_plugins() {
  echo "plugins:"
  if ! command -v claude >/dev/null; then
    echo "  skipped: claude (Claude Code) is not on PATH; install it, then re-run with --only plugins"
    return 0
  fi
  # Each claude call costs about half a second, so with --yes ask once what is already there
  # (two read-only calls) and skip it: a no-op re-run adds and installs nothing. A dry run
  # makes no claude calls at all, so it stays fast.
  local markets='' plugins='' p
  if ((yes)); then
    markets=$(claude plugin marketplace list --json 2>/dev/null || true)
    plugins=$(claude plugin list --json 2>/dev/null || true)
  else
    echo "  (each of these is skipped if already added or installed)"
  fi
  if grep -Eq '"name": *"crewkit"' <<<"$markets"; then
    echo "  marketplace crewkit already added"
  else
    run claude plugin marketplace add "$here"
  fi
  for p in crew-nodes agent-practice memory-notices; do
    if grep -Eq "\"id\": *\"$p@crewkit\"" <<<"$plugins"; then
      echo "  $p@crewkit already installed"
    else
      run claude plugin install "$p@crewkit"
    fi
  done
  local rules="$HOME/.claude/rules/agent-practice.md"
  local fragment="$here/plugins/agent-practice/rules/CLAUDE-fragment.md"
  if cmp -s "$fragment" "$rules" 2>/dev/null; then
    echo "  rules fragment already current"
    return 0
  fi
  run mkdir -p "$(dirname "$rules")"
  if [[ -f $rules ]]; then
    # Never overwrite an earlier backup: .bak, then .bak.1, .bak.2, ...
    local bak="$rules.bak" n=0
    while [[ -e $bak ]]; do n=$((n + 1)); bak="$rules.bak.$n"; done
    run cp "$rules" "$bak"
  fi
  run cp "$fragment" "$rules"
}

step_cli() {
  echo "cli:"
  local src="$here/bin/crewkit" dest="$HOME/.local/bin/crewkit"
  [[ -f $src && -x $src ]] || die "$src is missing or not executable"
  if [[ -L $dest && $(readlink "$dest") == "$src" ]]; then
    echo "  $dest already links to $src"
    return 0
  fi
  # Only our own link is ever accepted, and nothing is ever replaced: anything else at $dest stays.
  if [[ -e $dest || -L $dest ]]; then
    die "$dest exists and is not a link to $src: not replacing it (move it away, then re-run with --only cli)"
  fi
  run mkdir -p "$HOME/.local/bin"
  run ln -s "$src" "$dest"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  note: $HOME/.local/bin is not on your PATH; add it to run crewkit by name" ;;
  esac
}

detect_target
((yes)) || echo "Dry run for $os/$arch: nothing is changed. Re-run with --yes to apply."
for s in "${steps[@]}"; do "step_$s"; done
if ((${#bootstrap_args[@]})) && [[ " ${steps[*]} " != *" memsync "* ]]; then
  echo "note: ${#bootstrap_args[@]} flag(s) after -- ignored: the memsync step wasn't run"
fi
if ((${#paused[@]})); then
  echo "install.sh: paused at the ${paused[*]} step: it needs bootstrap flags. Any other steps ran; finish with: $self --yes --only ${paused[0]} -- <bootstrap flags>" >&2
  exit 3
fi
