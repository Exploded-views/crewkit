#!/usr/bin/env bash
# leakcheck.sh DIR: fail if any eval output in DIR names a real shared-memory note or the real
# sync directory. Prints counts and file names only.
set -euo pipefail
dir=$1
pat=$(mktemp); trap 'rm -f "$pat"' EXIT
for d in "$HOME"/.claudesync.d/*/distilled "$HOME"/.claudesync/distilled; do
  [[ -d $d ]] || continue
  for f in "$d"/*.md; do
    n=$(basename "$f" .md); [[ $n == DISTILLED ]] || printf '%s\n' "$n"
  done
done | sort -u > "$pat"
printf '%s\n' '\.claudesync' >> "$pat"
echo "leakcheck: $(wc -l < "$pat") patterns"
hits=0
for f in "$dir"/*.txt; do
  n=$(grep -Ecf "$pat" "$f" || true)
  if (( n > 0 )); then echo "  leak  $(basename "$f")  $n line(s)"; hits=$((hits + n)); fi
done
(( hits == 0 )) && { echo "leakcheck: clean"; exit 0; }
echo "leakcheck: $hits line(s) name real notes or the real sync dir"; exit 1
