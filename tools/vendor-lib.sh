#!/usr/bin/env bash
# vendor-lib.sh: copy every file in lib/ into every plugin that has a lib/ directory.
# Plugins install on their own, so each carries its own copies; tools/lint-skills.py fails if a
# copy differs from the canonical one in lib/. A plugin may also keep its own files in lib/
# (any name not in the repo's lib/); those are its own code and are never touched. Run this
# after changing anything in lib/.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
for p in "$root"/plugins/*/; do
  [[ -d $p/lib ]] || continue   # a plugin opts in by having lib/
  for f in "$root"/lib/*; do
    cp "$f" "$p/lib/${f##*/}"
  done
  echo "vendored lib/ into ${p#"$root"/}lib/"
done
