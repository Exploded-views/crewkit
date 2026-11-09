#!/usr/bin/env bash
# mutate.sh: mutation check for install.sh's key lines.
#
# Each mutant below breaks one safety line. The bats suite must fail on every one ("killed").
# A mutant the suite still passes ("survived") means a key line has no test that guards it.
# Exit 0 = all killed, 1 = a mutant survived or didn't apply.
set -euo pipefail
# A mutation run is a heavy job: refuse without the heavy lock (tools/heavy_lock.py).
python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/heavy_lock.py" tools/mutate.sh || exit 1
root=$(git rev-parse --show-toplevel)
src="$root/install.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# name@@exact text in install.sh@@replacement
# shellcheck disable=SC2016  # the mutants are literal code, not expansions
mutants=(
  'sha256 compare always passes@@[[ $got == "$2" ]] ||@@true ||'
  'curl without https-only@@--proto '"'"'=https'"'"' --tlsv1.2 @@--tlsv1.2 '
  'TODO tag counts as pinned@@[[ -n $pin_tag && $pin_tag != TODO* ]]@@[[ -n $pin_tag ]]'
  'blank hash allowed@@[[ -n $pin_sha ]] ||@@true ||'
  'hash format unchecked@@[[ $pin_sha =~ ^[0-9a-f]{64}$ ]] ||@@true ||'
  'URL scheme unchecked@@[[ $pin_url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9./_-]+$ ]] ||@@true ||'
  'special files allowed in archives@@if grep -qv '"'"'^[-d]'"'"' <<<"$listing"; then@@if false; then'
  '.. allowed in archive paths@@if [[ $member == /* || $member =~ (^|/)\.\.(/|$) ]]; then@@if [[ $member == /* ]]; then'
  'absolute archive paths allowed@@if [[ $member == /* || $member =~ (^|/)\.\.(/|$) ]]; then@@if [[ $member =~ (^|/)\.\.(/|$) ]]; then'
  'tag format unchecked@@  [[ $pin_tag =~ ^v[0-9]+@@  true || [[ $pin_tag =~ ^v[0-9]+'
  'bitc binary presence unchecked@@[[ -f $tmp/bitc/bitc ]] || die@@true || die'
  'inherited tmp honoured@@tmp='"''"'@@:'
  'ERR trap removed@@trap '"'"'exit 1'"'"' ERR@@:'
  'earlier backup overwritten@@while [[ -e $bak ]]; do@@while false; do'
  'bootstrap flags echoed@@(+${#bootstrap_args[@]} flag(s) after --)@@${bootstrap_args[*]}'
  'gitleaks checksums cross-check skipped@@grep -qxF "$pin_sha  $asset" "$tmp/$sums"@@true'
  'gitleaks version not checked@@if [[ $reported != "$ver" && $reported != "v$ver" ]]; then@@if false; then'
  'gitleaks sha256 not recorded@@  sha256 "$dir/.gitleaks.new" > "$dir/.gitleaks.sha256.new"@@  echo x > "$dir/.gitleaks.sha256.new"'
  'gitleaks x64 naming dropped@@[[ $arch == amd64 ]] && garch=x64@@:'
  'bitc checksums.txt cross-check skipped@@grep -qxF "$pin_sha  $asset" "$tmp/checksums.txt"@@true'
  'bitc version not checked@@if [[ $reported != *"\"version\":\"${pin_tag#v}\""* ||@@if [[ -z x ||'
  'bitc version prefix accepted@@*"\"version\":\"${pin_tag#v}\""*@@*"\"version\":\"${pin_tag#v}"*'
  'bitc release flag not checked@@ || $reported != *'"'"'"release":true'"'"'* ]]; then@@ ]]; then'
  'bitc replaced before the version check@@install -m 0755 "$tmp/bitc/bitc" "$bin/.bitc.new"@@install -m 0755 "$tmp/bitc/bitc" "$bin/.bitc.new"; cp "$bin/.bitc.new" "$bin/bitc"'
  'bootstrap pause becomes a failure@@    exit 3@@    exit 1'
  'edited rules not backed up@@    run cp "$rules" "$bak"@@    :'
  'pre-release suffix allows any character@@  [[ $pin_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]@@  [[ $pin_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]'
  'pin checks follow the locale@@  local LC_ALL=C@@  :'
  'version check reads every line@@  reported=${reported%%$'"'"'\n'"'"'*}@@  :'
  'SHA256SUMS cross-check skipped@@grep -qxF "$pin_sha  $asset" "$tmp/SHA256SUMS"@@true'
  'bootstrap not given --prebuilt-dir@@--prebuilt-dir "$dir" ${bootstrap_args[@]+@@${bootstrap_args[@]+'
  'release layout unchecked@@[[ -f $dir/$f ]] || die@@true || die'
  'already-added marketplace not detected@@if grep -Eq '"'"'"name": *"crewkit"'"'"' <<<"$markets"; then@@if false; then'
  'installed plugins not detected@@    if grep -Eq "\"id\": *\"$p@crewkit\"" <<<"$plugins"; then@@    if false; then'
  'current rules fragment rewritten@@  if cmp -s "$fragment" "$rules" 2>/dev/null; then@@  if false; then'
  'dry run queries claude@@  if ((yes)); then
    markets=@@  if true; then
    markets='
  'usage errors exit 0@@    *) usage >&2; exit 64 ;;@@    *) usage >&2; exit 0 ;;'
  'bootstrap failure ignored@@((rc == 0)) || die "bootstrap failed@@true || die "bootstrap failed'
  'memsync version not checked@@  check_version "claude-memsync $pin_tag" "$dir/claude-memsync" version@@  true'
  'version prefix accepted@@  [[ $reported == "$want" ]] ||@@  [[ $reported == "$want"* ]] ||'
  'herdr sha compare skipped@@  fetch_verified "$pin_url/$pin_tag/$asset" "$pin_sha" "$tmp/$asset"
  # The release'"'"'s own .sha256@@  fetch "$pin_url/$pin_tag/$asset" "$tmp/$asset"
  # The release'"'"'s own .sha256'
  'herdr .sha256 cross-check skipped@@  grep -qxF "$pin_sha  $asset" "$tmp/$asset.sha256"@@  true'
  'herdr archive unpacked without safe_extract@@  safe_extract "$tmp/$asset" "$tmp/herdr"@@  mkdir -p "$tmp/herdr"; tar -xzf "$tmp/$asset" -C "$tmp/herdr"'
  'herdr binary presence unchecked@@  [[ -f $tmp/herdr/herdr && ! -L $tmp/herdr/herdr ]] || die@@  true || die'
  'herdr version not checked@@  check_version "herdr ${pin_version:-${pin_tag#v}}" "$tmp/herdr/herdr" --version@@  true'
  'herdr HERDR_VERSION ignored@@  check_version "herdr ${pin_version:-${pin_tag#v}}" "$tmp/herdr/herdr" --version@@  check_version "herdr ${pin_tag#v}" "$tmp/herdr/herdr" --version'
  'herdr HERDR_VERSION not read@@      "$2_VERSION") pin_version=$value ;;@@      "$2_VERSION") : ;;'
  'herdr HERDR_VERSION format unchecked@@  [[ -z $pin_version ||@@  [[ true ||'
  'herdr replaced before the version check@@  check_version "herdr ${pin_version:-${pin_tag#v}}" "$tmp/herdr/herdr" --version@@  mkdir -p "$bin"; cp "$tmp/herdr/herdr" "$bin/herdr"
  check_version "herdr ${pin_version:-${pin_tag#v}}" "$tmp/herdr/herdr" --version'
  'herdr claude integration not installed@@      guard_hooks "$HOME/.claude/settings.json" "herdr integration install claude" herdr_integration claude || rc=$?@@      :'
  'herdr other integrations not installed@@      herdr_integration "$kind" || rc=$?@@      :'
  'herdr integration failure always a note@@    elif [[ $integration_out == *"directory not found at "* ]]; then@@    elif true; then'
  'herdr integration hooks unguarded@@      guard_hooks "$HOME/.claude/settings.json" "herdr integration install claude" herdr_integration claude || rc=$?@@      herdr_integration claude || rc=$?'
  'hook backup failure unchecked@@ || die "could not back up $settings to $backup; $label was not run"@@ || true'
  'hook restore failure unchecked@@ || die "$label changed $settings and it could not be put back; your original is at $backup"@@ || true'
  'stale hook backup overwritten@@  if [[ -e $backup ]]; then@@  if false; then'
  'hook backup left behind@@    rm -f "$backup"@@    :'
  'rtk version not checked@@  check_version "rtk ${pin_tag#v}" "$tmp/rtk/rtk" --version@@  true'
  'rtk init without --auto-patch@@  guard_hooks "$settings" "rtk init -g" "$bin/rtk" init -g --auto-patch </dev/null@@  guard_hooks "$settings" "rtk init -g" "$bin/rtk" init -g </dev/null'
  'cursor-agent integration named after the command@@    if command -v "$a" >/dev/null; then echo "${a%-agent}"; fi@@    if command -v "$a" >/dev/null; then echo "$a"; fi'
  'rtk checksums.txt cross-check skipped@@  grep -qxF "$pin_sha  $asset" "$tmp/rtk-checksums.txt"@@  true'
  'rtk binary presence unchecked@@  [[ -f $tmp/rtk/rtk ]] || die@@  true || die'
  'rtk hooks not compared after init@@      grep -qxF -- "$c" <<<"$after" || lost="$lost [$c]"@@      true'
  'rtk backup not restored@@    if ((rc != 0)) || [[ -n $lost ]]; then@@    if false; then'
  'rtk init failure ignored@@  ((rc == 0)) || die "rtk init -g failed@@  true || die "rtk init -g failed'
  'rtk init re-run guard removed@@  if [[ -f $settings ]] && jq -e@@  if false && jq -e'
  'rtk invalid settings.json not refused@@ || die "$settings is not valid JSON; fix it, then re-run"@@ || true'
  'rtk jq presence unchecked@@  command -v jq >/dev/null || die@@  true || die'
  'crew-nodes not installed@@  for p in crew-nodes agent-practice memory-notices; do@@  for p in agent-practice memory-notices; do'
  'plugins step fails without claude@@    echo "  skipped: claude (Claude Code) is not on PATH; install it, then re-run with --only plugins"
    return 0@@    die "claude is not on PATH"'
  'memsync pause skipped (bootstrap runs anyway)@@  if ((${#bootstrap_args[@]} == 0)); then
    echo "  $(pause_note paused)"@@  if false; then
    echo "  $(pause_note paused)"'
  'paused exit 3 dropped (exits 0)@@  exit 3
fi@@  exit 0
fi'
  'dry-run pause note missing@@    ((yes)) || echo "  $(pause_note "would pause")"@@    :'
  'bare script name left unrunnable@@[[ $self == */* ]] || self=./$self@@:'
  'later steps not run after a pause@@    paused+=(memsync)
    return 0@@    paused+=(memsync)
    echo "install.sh: paused" >&2; exit 3'
  'pin file sourced@@  done < "$file"@@  done < "$file"; source "$file"'
  'existing crewkit overwritten@@  if [[ -e $dest || -L $dest ]]; then
    die "$dest exists and is not a link to $src: not replacing it (move it away, then re-run with --only cli)"
  fi
  run mkdir -p "$HOME/.local/bin"
  run ln -s "$src" "$dest"@@  run mkdir -p "$HOME/.local/bin"
  run ln -sf "$src" "$dest"'
  'cli: any link counts as current@@  if [[ -L $dest && $(readlink "$dest") == "$src" ]]; then@@  if [[ -L $dest ]]; then'
)


# The suite is tests/install.bats, the one that runs install.sh (the whole bats run takes
# minutes per mutant). --abort stops a killed mutant at its first failing test.
bats=$("$root/tools/get-bats.sh")
suite() { "$bats" --abort "$root/tests/install.bats" >/dev/null 2>&1; }

# Baseline: a broken suite would "kill" every mutant, so it must pass unmutated first.
suite || { echo "mutate: the unmutated suite fails; fix it first"; exit 1; }

survived=0
for m in "${mutants[@]}"; do
  name=${m%%@@*}; rest=${m#*@@}; old=${rest%%@@*}; new=${rest#*@@}
  python3 - "$src" "$tmp/install.sh" "$old" "$new" <<'PY' || { echo "  NOT APPLIED  $name"; survived=1; continue; }
import sys
src, dst, old, new = sys.argv[1:]
text = open(src).read()
if text.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(text.replace(old, new))
PY
  chmod +x "$tmp/install.sh"
  # A mutant that doesn't parse "fails" every test for the wrong reason.
  if ! bash -n "$tmp/install.sh" 2>/dev/null; then
    echo "  INVALID      $name (not valid bash; fix the mutant)"; survived=1; continue
  fi
  if INSTALL_SH="$tmp/install.sh" suite; then
    echo "  SURVIVED     $name"; survived=1
  else
    echo "  killed       $name"
  fi
done
((survived)) && { echo "mutate: a mutant survived or didn't apply"; exit 1; }
echo "mutate: all ${#mutants[@]} mutants killed"
