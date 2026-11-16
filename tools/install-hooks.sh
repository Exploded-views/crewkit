#!/usr/bin/env bash
# Install the scrub, the skills lint and markdownlint (staged Markdown) as this clone's git pre-commit hook
# (for clones that don't use the pre-commit framework). Works from the main checkout or any
# linked worktree: the hook goes in the clone's common hooks directory, shared by all of them.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
# With a core.hooksPath of the clone's own (husky, lefthook), git runs hooks from there, not the
# common hooks directory. That's git's own reading: local, config.worktree, include.path, or an
# includeIf in the global config. The plain global one is the push-gate dispatcher, which chains
# to the clone's own hooks.
hp=$(git config core.hooksPath || true)
if [[ -n $hp && $hp != "$(git config --global core.hooksPath || true)" ]]; then
  echo "install-hooks: core.hooksPath is set for this clone ($hp); not installing over it" >&2
  exit 1
fi
hooks="$(git rev-parse --path-format=absolute --git-common-dir)/hooks"
mkdir -p "$hooks"
hook="$hooks/pre-commit"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
"$root/tools/scrub.sh"
python3 "$root/tools/lint-skills.py"
"$root/tools/lint-markdown.sh"
HOOK
chmod +x "$hook" "$root/tools/scrub.sh"
echo "installed pre-commit hook (scrub + lint-skills + markdownlint on staged Markdown)"
