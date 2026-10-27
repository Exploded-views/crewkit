#!/usr/bin/env bash
# install.sh: one-prompt setup for crewkit on this machine.
#
# Steps, in order:
#   1. bitc        fetch the pinned release for this OS/arch, verify its sha256, install it.
#   2. memsync     fetch the pinned claude-utils release, verify its sha256 (and that its
#                  SHA256SUMS agrees), then run its scripts/bootstrap.sh --prebuilt-dir, which
#                  installs the binaries and writes host config and memsync routes.
#   3. plugins     add this repo as the `crewkit` marketplace and install its plugins, and
#                  copy the agent-practice rules fragment into ~/.claude/rules/.
#
# Usage:
#   ./install.sh                 # dry run: print what would happen, change nothing
#   ./install.sh --yes           # do it
#   ./install.sh --only plugins  # one step: bitc, memsync or plugins (repeatable)
#   ./install.sh --yes -- <bootstrap flags>   # flags after -- go to memsync's bootstrap.sh
#
# Pins live in pins/<tool>.env: a URL, a tag and one sha256 per OS/arch. A download whose hash
# doesn't match its pin is refused before it is unpacked or run. There is no "latest".
#
# Exit (docs/exit-codes.md) 0 = done (or dry run printed), 1 = a step failed, 3 = paused, needs a
# human (passed through from bootstrap.sh), 64 = usage.
set -Eeuo pipefail
# Any command that fails outside a die is a failed step: exit 1, never its own code (which
# could read as 2 "usage" or 3 "paused").
trap 'exit 1' ERR

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
yes=0
tmp=''
steps=()
bootstrap_args=()

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "install.sh: $*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --only)
      [[ ${2:-} =~ ^(bitc|memsync|plugins)$ ]] || { usage >&2; exit 64; }
      steps+=("$2"); shift ;;
    --) shift; bootstrap_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done
((${#steps[@]})) || steps=(bitc memsync plugins)

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
# target. Returns 1 when the tool is not pinned yet (no tag, or TODO). A pinned tool with a
# bad URL or no valid hash for this target is an error. The file is parsed as KEY=value
# lines, never sourced, so nothing in it runs.
load_pin() {
  # In a UTF-8 locale, bash's [0-9A-Za-z] ranges match thousands of non-ASCII lookalikes; the
  # pin checks below must mean ASCII. Local, so the bootstrap still gets the user's locale.
  local LC_ALL=C
  local file="$here/pins/$1.env" key value line
  [[ -r $file ]] || die "missing pin file pins/$1.env"
  pin_url='' pin_tag='' pin_sha=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Za-z0-9_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case $key in
      "$2_URL") pin_url=$value ;;
      "$2_TAG") pin_tag=$value ;;
      "$2_SHA256_${os}_${arch}") pin_sha=$value ;;
    esac
  done < "$file"
  [[ -n $pin_tag && $pin_tag != TODO* ]] || return 1
  # An optional pre-release suffix (v0.3.0-ev.1): letters, digits, dots and hyphens only, since
  # the tag goes into download URLs and file names.
  [[ $pin_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
    || die "pins/$1.env: tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-PRERELEASE"
  [[ $pin_url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9./_-]+$ ]] || die "pins/$1.env: $2_URL must be an https URL"
  [[ -n $pin_sha ]] || die "pins/$1.env: no sha256 pinned for $os/$arch"
  [[ $pin_sha =~ ^[0-9a-f]{64}$ ]] || die "pins/$1.env: the $os/$arch sha256 is not 64 hex characters"
}

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
  mkdir -p "$bin"
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
  mv -f "$bin/.bitc.new" "$bin/bitc"
  echo "  installed bitc $pin_tag ($reported)"
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
  echo "  then: scripts/bootstrap.sh --prebuilt-dir <unpacked $top> (+${#bootstrap_args[@]} flag(s) after --)"
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
  local reported
  reported=$("$dir/claude-memsync" version 2>&1) || reported=""
  reported=${reported%%$'\n'*}
  [[ $reported == "claude-memsync $pin_tag" ]] \
    || die "the downloaded claude-memsync reports '$reported' to claude-memsync version, not claude-memsync $pin_tag"
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

step_plugins() {
  echo "plugins:"
  if ! command -v claude >/dev/null; then
    ((yes)) && die "claude (Claude Code) is not on PATH"
    echo "  note: claude (Claude Code) is not on PATH; --yes will fail here"
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
  for p in agent-practice memory-notices; do
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

detect_target
((yes)) || echo "Dry run for $os/$arch: nothing is changed. Re-run with --yes to apply."
for s in "${steps[@]}"; do "step_$s"; done
if ((${#bootstrap_args[@]})) && [[ " ${steps[*]} " != *" memsync "* ]]; then
  echo "note: ${#bootstrap_args[@]} flag(s) after -- ignored: the memsync step wasn't run"
fi
