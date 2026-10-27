#!/usr/bin/env python3
"""export.py: build the public export of one commit (the dev repo's docs/public-export.md).

  tools/export.py --ref <commit> --out <empty dir> [--repo <dev repo>]

The public repo is a fresh one-commit export of the reviewed tree, never the dev repo's
history. This writes that tree: `git archive` of the commit into the empty --out directory, then
the export transforms, then `git init` + `git add -A` there and prints the tree hash the owner
approves ("export tree: <40 hex>"). Committing and pushing is the publish step's job.

The transforms keep the dev repo's references intact and drop them from the public copy:
- lesson citations, `([lesson N](PLAYBOOK_LESSONS_URL#N))`, `See [lesson N](...)` and
  `[lessons N and M](...)`: removed, with the text around them closed up, and a citation that
  wrapped onto its own line folded back into the line before;
- the lines that define the placeholder (a table row or a `key: value` line naming it);
- prose between `<!-- export:drop-start -->` and `<!-- export:drop-end -->`.
A link to the dev repo's PRs or issues, or a lesson cited by number in plain text, or a
local clone path (`<home>/projects/<clone>`), left
outside a dropped region fails too. Files marked `export-ignore` in .gitattributes are left
out by `git archive` itself. Anything
left that names the placeholder (outside this tool, the lint and their tests), a
marker left open, or one left behind fails the export. Exit 0 = written, 1 = a transform
failed (nothing to publish), 2 = usage. Stdlib only.
"""
import argparse
import io
import pathlib
import re
import subprocess
import sys
import tarfile

PLACEHOLDER = "PLAYBOOK_" + "LESSONS_URL"
LINK = r"\[(?:lessons?|see lessons?) [^\]]*\]\(" + PLACEHOLDER + r"#\d+\)"
# Files that may name the placeholder: this tool, the lint that allows it, and their tests.
MAY_NAME = {"tools/export.py", "tools/lint-skills.py", "tests/test_export.py", "tests/test_lint_settings.py"}
START, END = "<!-- export:drop-start -->", "<!-- export:drop-end -->"
# A link to the dev repo's PRs or issues: those numbers don't exist in the public repo, and the
# link names the org. Keep such links inside export:drop regions.
# A lesson cited by number in plain text: the link transform can't remove it, so it fails.
PLAIN_CITATION = re.compile(r"\b[Ll]essons? \d+")
# A path into a local clone (`<home>/projects/<clone>/...`) names the dev machine's layout; RED
# records and docs use `<repo>/...` instead.
CLONE_PATH = re.compile(r"<home>/projects/[^/\s]+")
DEV_LINK = re.compile(r"github\.com/[^/\s]+/crewkit(?:-dev)?/(?:pull|issues)/\d+")


def transform(rel, text):
    """The public text of one file, or raise ValueError naming what couldn't be handled."""
    lines, out, dropping, squeeze = text.split("\n"), [], False, False
    for n, line in enumerate(lines, 1):
        if line.strip() == START:
            if dropping:
                raise ValueError(f"{rel}:{n}: a drop-start inside a dropped region")
            dropping = True
            continue
        if line.strip() == END:
            if not dropping:
                raise ValueError(f"{rel}:{n}: a drop-end without a drop-start")
            dropping, squeeze = False, True
            continue
        if squeeze:
            squeeze = False
            if not line.strip() and out and not out[-1].strip():
                continue  # the dropped region sat between blank lines: keep only one
        if dropping:
            continue
        if PLACEHOLDER in line and (line.lstrip().startswith("|") or re.match(r"^\s*[a-z_.]+:\s", line)) \
                and not re.search(LINK, line):
            continue  # the placeholder's own definition: a settings-table row or a settings line
        out.append(line)
    if dropping:
        raise ValueError(f"{rel}: an export:drop-start is never closed")
    text = "\n".join(out)
    text = re.sub(r"[ \t]*See " + LINK + r"\.", "", text)
    text = re.sub(r"[ \t]*\(" + LINK + r"\)", "", text)
    text = re.sub(r"\s*" + LINK, "", text)
    # A citation that wrapped onto its own line leaves only its punctuation there: fold it back.
    text = re.sub(r"\n[ \t]*([.,;:])[ \t]*(?=\n)", r"\1", text)
    if rel not in MAY_NAME and (START in text or END in text):
        raise ValueError(f"{rel}: an export marker is left in the text (it must be alone on its line)")
    if rel not in MAY_NAME and PLAIN_CITATION.search(text):
        raise ValueError(f"{rel}: cites a lesson by number in plain text; reword it or move it into an export:drop region")
    if rel not in MAY_NAME and CLONE_PATH.search(text):
        raise ValueError(f"{rel}: names a local clone path (<home>/projects/...); write <repo>/... instead")
    if DEV_LINK.search(text):
        raise ValueError(f"{rel}: links to a dev-repo PR or issue; move it into an export:drop region")
    if PLACEHOLDER in text and rel not in MAY_NAME:
        raise ValueError(f"{rel}: names {PLACEHOLDER} in a form the export can't remove")
    return text


def main(argv):
    p = argparse.ArgumentParser(prog="export.py", description="Build the public export of a commit.")
    p.add_argument("--repo", default=".")
    p.add_argument("--ref", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args(argv)
    out = pathlib.Path(a.out)
    if out.exists() and any(out.iterdir()):
        print(f"export: {out} is not empty", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)
    tar = subprocess.run(["git", "-C", a.repo, "archive", "--format=tar", a.ref], capture_output=True)
    if tar.returncode != 0:
        print(f"export: git archive {a.ref} failed: {tar.stderr.decode().strip()}", file=sys.stderr)
        return 2
    with tarfile.open(fileobj=io.BytesIO(tar.stdout)) as t:
        t.extractall(out, filter="data")
    failed, changed = [], 0
    for path in sorted(f for f in out.rglob("*") if f.is_file() and not f.is_symlink()):
        rel = path.relative_to(out).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        try:
            new = transform(rel, text)
        except ValueError as e:
            failed.append(str(e))
            continue
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    if failed:
        for f in failed:
            print(f"export: {f}")
        print(f"export: {len(failed)} file(s) the export can't handle; nothing to publish")
        return 1
    git = ["git", "-C", str(out), "-c", "init.defaultBranch=main"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    tree = subprocess.run(git + ["write-tree"], capture_output=True, text=True, check=True).stdout.strip()
    print(f"export: {changed} file(s) transformed from {a.ref}")
    print(f"export tree: {tree}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
