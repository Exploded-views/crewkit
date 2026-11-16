#!/usr/bin/env bash
# secrets-scan.sh: gitleaks over every commit on every ref of this repository, for CI on every
# push and pull request. It runs the build `install.sh --only gitleaks` pinned, verified and
# installed (~/.local/share/crewkit/gitleaks/gitleaks, with its sha256 beside it), and redacts
# what it finds. Fails closed: no gitleaks (install.sh's gitleaks step didn't run), a binary
# that no longer matches its recorded sha256, a gitleaks error, or a shallow clone (history
# missing) all fail; only a full scan that finds nothing passes.
#
# What gitleaks is told comes from this script, never from the tree it scans, so a change can't
# allowlist its own leak: the config is gitleaks' own default rules (written below), the ignore
# file is empty, gitleaks:allow comments are ignored, and a tree holding a .gitleaks.toml or
# .gitleaksignore fails. git log reads every change as text, without textconv or an external
# diff, so a .gitattributes (-diff, binary, diff=<driver>) can't hide one.
#
# Exit 0 = clean, 1 = leaks found or the scan couldn't run.
set -uo pipefail
g=$HOME/.local/share/crewkit/gitleaks/gitleaks
fail() { echo "secrets: $*"; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

[[ -x $g ]] || fail "gitleaks isn't installed (./install.sh --yes --only gitleaks; pins/gitleaks.env must pin it); nothing was scanned"
[[ -r $g.sha256 ]] || fail "gitleaks has no recorded sha256 (./install.sh --yes --only gitleaks); not scanning with it"
[[ $(sha256 "$g") == "$(head -c 64 "$g.sha256")" ]] || fail "gitleaks doesn't match the sha256 recorded at install; not scanning with it"
[[ $(git rev-parse --is-shallow-repository 2>/dev/null) == false ]] ||
  fail "this is a shallow clone (or not a repository): its history isn't all there (checkout with fetch-depth: 0)"
# Tracked anywhere, or on disk at the top (where gitleaks would look for them).
in_tree=$({ git ls-files -- .gitleaks.toml .gitleaksignore '*/.gitleaks.toml' '*/.gitleaksignore'
  for f in .gitleaks.toml .gitleaksignore; do [[ ! -e $f ]] || echo "$f"; done; } | sort -u | paste -sd ' ' -) ||
  fail "git ls-files failed"
[[ -z $in_tree ]] ||
  fail "the tree holds a gitleaks config or ignore file ($in_tree); the scan uses only its own, so remove it"
commits=$(git rev-list --all --count) || fail "git rev-list failed"
cfg=$(mktemp -d) || fail "mktemp failed"
trap 'rm -rf "$cfg"' EXIT
printf '%s\n' '# gitleaks config for tools/secrets-scan.sh: the pinned build'"'"'s default rules, nothing allowed.' \
  '[extend]' 'useDefault = true' > "$cfg/gitleaks.toml"
: > "$cfg/gitleaksignore"
# Every GITLEAKS_* variable maps to a flag (report paths, rules, baselines, ...): none may reach it.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep '^GITLEAKS_' || true)
# -m: a merge's own changes (a resolution that adds a line) are diffed against each parent;
# plain `git log -p` shows a merge with no diff at all.
"$g" git --no-banner --redact --config "$cfg/gitleaks.toml" --gitleaks-ignore-path "$cfg/gitleaksignore" \
  --ignore-gitleaks-allow --log-opts="--all -m --text --no-textconv --no-ext-diff" .; rc=$?
case $rc in
  0) echo "secrets: clean (gitleaks over $commits commit(s), every ref)" ;;
  1) fail "gitleaks found leaks (redacted above); remove them from history, and rotate any real secret" ;;
  *) fail "gitleaks failed (exit $rc); the scan did not complete" ;;
esac
