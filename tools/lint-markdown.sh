#!/usr/bin/env bash
# lint-markdown.sh: markdownlint-cli2, pinned, with the repo's .markdownlint-cli2.yaml, on the
# staged Markdown files (added, copied, modified or renamed). Run by the pre-commit hook
# (tools/install-hooks.sh) and the pre-commit framework, so a doc can't land lint-red.
# It lints the staged copies (with the staged config), not the working tree, so what is linted
# is what is committed; every path is passed literally (markdownlint-cli2's : prefix), never as a
# glob or a negation (a name starting with ! or #, or holding * or [).
# npx fetches the pinned version, not a lockfile: its dependencies resolve at run time.
# Fails closed: staged Markdown and no npx (Node.js) refuses the commit; no staged Markdown
# needs nothing. Exit 0 = clean or nothing to lint, 1 = findings or no npx.
set -euo pipefail
pin=markdownlint-cli2@0.18.1
staged() { git diff --cached --name-only -z --diff-filter=ACMR -- '*.md'; }
n=$(staged | tr -cd '\0' | wc -c | tr -d ' ')
((n > 0)) || exit 0
if ! command -v npx >/dev/null; then
  echo "lint-markdown: $n staged Markdown file(s) and no npx to run $pin; install Node.js (docs/install.md lists what each part needs), then commit again" >&2
  exit 1
fi
cd "$(git rev-parse --show-toplevel)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{ staged; git ls-files -z -- '.markdownlint*' '*/.markdownlint*'; } | while IFS= read -r -d '' f; do
  mkdir -p "$tmp/$(dirname "$f")"
  git cat-file blob ":$f" > "$tmp/$f"
done
paths=()
while IFS= read -r -d '' f; do paths+=(":$f"); done < <(staged)
(cd "$tmp" && npx -y "$pin" "${paths[@]}")
