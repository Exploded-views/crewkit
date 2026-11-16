#!/usr/bin/env python3
"""token-prefix-scan.py DIR: scan a tree for provider token prefixes, the export checklist's second net.

GitHub's secret scanning flags tokens by provider prefix. gitleaks's default ruleset (v8.30.1,
222 rules, the one tools/secrets-scan.sh and the push gate use) lacks some of them: Tailscale
(`tskey-`) is the one this was written for. This scan covers the providers GitHub documents under
"Supported secret scanning patterns" for the prefixes below; body lengths and charsets come from
those docs and from the gitleaks v8.30.1 rule regexes (config/gitleaks.toml). The Tailscale rule is
modelled on GitHub's pattern and kept loose: the two test fixtures are `tskey-auth-` plus 13 and 17
mixed-case alphanumerics. Each rule is a distinctive prefix plus a minimum body, so prose that only
names a prefix does not fire.
Age keys are left to gitleaks's default age-secret-key rule, so this scan has no rule for them.

Usage: python3 -I tools/token-prefix-scan.py DIR

Scans every regular file under DIR (not symlinks, not `.git`; files with a NUL byte are binary and
skipped). Each hit prints `path:line: rule-id (N chars)`; a token's value is never printed. Paths
listed in DIR/.github/secret_scanning.yml (GitHub's `paths-ignore:` list) print as
`exempt: path:line: rule-id` and do not fail the run; with the file absent nothing is exempt, and a
file that holds anything but a `paths-ignore:` list of `- "glob"` lines is a usage error.
In a glob, `*` and `?` stop at `/` and `**` crosses it.

A file or directory it can't read prints `unreadable: path` and fails the run (exit 2) whatever else it
found, so a token behind a mode 000 file is not a silent pass.

Exit 0 = clean, 1 = a hit outside the exempt paths, 2 = usage error or an unreadable file or directory.

This runs only at the export checklist (docs/public-export.md), not in tools/scrub.sh or the push gate.
"""
import os
import re
import sys

# (id, regex). A prefix is not a hit unless the body after it is long enough, and a word character
# before the prefix means it is the end of some other word.
_B = r"(?<![A-Za-z0-9])"
RULES = [
    ("tailscale", _B + r"tskey-[a-z]+-[A-Za-z0-9-]{12,}"),
    ("github-classic", _B + r"gh[pousr]_[A-Za-z0-9]{36,}"),
    ("github-pat", _B + r"github_pat_[A-Za-z0-9_]{82,}"),
    ("gitlab", _B + r"glpat-[A-Za-z0-9_-]{20,}"),
    ("slack-token", _B + r"xox[abposr]-[A-Za-z0-9-]{20,}"),
    ("slack-app", _B + r"xapp-[A-Za-z0-9-]{20,}"),
    ("npm", _B + r"npm_[A-Za-z0-9]{36,}"),
    ("pypi", _B + r"pypi-AgEI[A-Za-z0-9_-]{50,}"),
    ("openai", _B + r"sk-(?:proj|svcacct)-[A-Za-z0-9_-]{40,}"),
    ("anthropic", _B + r"sk-ant-[A-Za-z0-9_-]{80,}"),
    ("stripe", _B + r"[sr]k_live_[A-Za-z0-9]{24,}"),
    ("huggingface", _B + r"hf_[A-Za-z]{34,}"),
    ("digitalocean", _B + r"do[por]_v1_[a-f0-9]{64,}"),
    ("doppler", _B + r"dp\.pt\.[A-Za-z0-9]{43,}"),
    ("linear", _B + r"lin_api_[A-Za-z0-9]{40,}"),
    ("shopify", _B + r"shp(?:at|ss|ca|pa)_[a-fA-F0-9]{32,}"),
    ("sendgrid", _B + r"SG\.[A-Za-z0-9=_.-]{66,}"),
    ("postman", _B + r"PMAK-[A-Fa-f0-9]{24}-[A-Fa-f0-9]{34}"),
    ("pulumi", _B + r"pul-[a-f0-9]{40,}"),
    ("planetscale", _B + r"pscale_tkn_[A-Za-z0-9=._-]{32,}"),
    ("grafana-service-account", _B + r"glsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8}"),
    ("grafana-cloud", _B + r"glc_[A-Za-z0-9+/]{32,}"),
    ("vault", _B + r"hv[sb]\.[A-Za-z0-9_-]{90,}"),
    ("sourcegraph", _B + r"sgp_(?:[a-fA-F0-9]{16}_)?[a-fA-F0-9]{40,}"),
    ("prefect", _B + r"pnu_[A-Za-z0-9]{36,}"),
    ("rubygems", _B + r"rubygems_[a-f0-9]{48,}"),
    ("databricks", _B + r"dapi[a-f0-9]{32,}"),
]
COMPILED = [(rid, re.compile(rx)) for rid, rx in RULES]

CONFIG = os.path.join(".github", "secret_scanning.yml")


class Usage(Exception):
    pass


def read_exempt(root):
    """The globs in DIR/.github/secret_scanning.yml's `paths-ignore:` list; [] when absent."""
    path = os.path.join(root, CONFIG)
    if not os.path.isfile(path):
        return []
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except (OSError, UnicodeDecodeError):
        raise Usage(f"{CONFIG} is not readable text")
    globs, seen_key = [], False
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line == "paths-ignore:":
            if seen_key:
                raise Usage(f"{CONFIG}:{n}: paths-ignore: appears twice")
            seen_key = True
            continue
        m = re.fullmatch(r' +- "([^"\n\\]+)"', line)
        if not seen_key or not m:
            raise Usage(f"{CONFIG}:{n}: only a `paths-ignore:` list of space-indented `- \"glob\"` lines (no backslash) is allowed")
        globs.append(m.group(1))
    if not globs:
        raise Usage(f"{CONFIG}: no paths-ignore entries")
    return globs


def glob_regex(glob):
    out, i = [], 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        out.append("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c))
        i += 1
    return re.compile("".join(out))


def files(root, unreadable):
    """Every regular file under ROOT as (full, rel); a directory os.walk can't list goes in UNREADABLE."""
    def on_error(e):
        unreadable.append(os.path.relpath(e.filename, root).replace(os.sep, "/"))
    for dirpath, dirnames, names in os.walk(root, onerror=on_error):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for name in sorted(names):
            if name == ".git":
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            yield full, os.path.relpath(full, root).replace(os.sep, "/")


def scan_file(full):
    try:
        with open(full, "rb") as f:
            data = f.read()
    except OSError:
        return False
    if b"\0" in data[:8192]:
        return None
    hits = []
    for n, line in enumerate(data.decode("latin-1").split("\n"), 1):
        for rid, rx in COMPILED:
            for m in rx.finditer(line):
                hits.append((n, rid, len(m.group(0))))
    return hits


def main(argv):
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        raise Usage("usage: token-prefix-scan.py DIR")
    root = argv[0]
    exempt = [glob_regex(g) for g in read_exempt(root)]
    scanned = failed = skipped_exempt = 0
    unreadable = []
    for full, rel in files(root, unreadable):
        hits = scan_file(full)
        if hits is False:
            unreadable.append(rel)
            continue
        if hits is None:
            continue
        scanned += 1
        is_exempt = any(rx.fullmatch(rel) for rx in exempt)
        for n, rid, length in hits:
            if is_exempt:
                print(f"exempt: {rel}:{n}: {rid}")
                skipped_exempt += 1
            else:
                print(f"{rel}:{n}: {rid} ({length} chars)")
                failed += 1
    for rel in sorted(unreadable):
        print(f"unreadable: {rel}")
    if unreadable:
        print(f"token-prefix-scan: {scanned} file(s), {failed} hit(s), {len(unreadable)} unreadable")
        return 2
    if failed:
        print(f"token-prefix-scan: {scanned} file(s), {failed} hit(s)")
        return 1
    note = f" ({skipped_exempt} exempt)" if skipped_exempt else ""
    print(f"token-prefix-scan: {scanned} file(s), clean{note}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as e:
        print(f"token-prefix-scan: {e}", file=sys.stderr)
        sys.exit(2)
