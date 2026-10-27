#!/usr/bin/env bash
# Install the scrub and the skills lint as this clone's git pre-commit hook
# (for clones that don't use the pre-commit framework).
set -euo pipefail
root=$(git rev-parse --show-toplevel)
hook="$root/.git/hooks/pre-commit"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
"$root/tools/scrub.sh"
python3 "$root/tools/lint-skills.py"
HOOK
chmod +x "$hook" "$root/tools/scrub.sh"
echo "installed pre-commit hook (scrub + lint-skills)"
