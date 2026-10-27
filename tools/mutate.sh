#!/usr/bin/env bash
# mutate.sh: mutation check for install.sh's key lines.
#
# Each mutant below breaks one safety line. The bats suite must fail on every one ("killed").
# A mutant the suite still passes ("survived") means a key line has no test that guards it.
# Exit 0 = all killed, 1 = a mutant survived or didn't apply.
set -euo pipefail
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
  'bitc checksums.txt cross-check skipped@@grep -qxF "$pin_sha  $asset" "$tmp/checksums.txt"@@true'
  'bitc version not checked@@if [[ $reported != *"\"version\":\"${pin_tag#v}\""* ||@@if [[ -z x ||'
  'bitc version prefix accepted@@*"\"version\":\"${pin_tag#v}\""*@@*"\"version\":\"${pin_tag#v}"*'
  'bitc release flag not checked@@ || $reported != *'"'"'"release":true'"'"'* ]]; then@@ ]]; then'
  'bitc replaced before the version check@@install -m 0755 "$tmp/bitc/bitc" "$bin/.bitc.new"@@install -m 0755 "$tmp/bitc/bitc" "$bin/.bitc.new"; cp "$bin/.bitc.new" "$bin/bitc"'
  'bootstrap pause becomes a failure@@    exit 3@@    exit 1'
  'bootstrap failure ignored@@((rc == 0)) || die@@true || die'
  'edited rules not backed up@@    run cp "$rules" "$bak"@@    :'
  'memsync version not checked@@  [[ $reported == "claude-memsync $pin_tag" ]]@@  true'
  'pre-release suffix allows any character@@(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]@@(-.*)?$ ]]'
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
  'pin file sourced@@  done < "$file"@@  done < "$file"; source "$file"'
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
