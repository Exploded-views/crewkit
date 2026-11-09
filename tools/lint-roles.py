#!/usr/bin/env python3
"""lint-roles.py: check the front matter and the layout of every file under roles/.

    tools/lint-roles.py [ROOT]        # ROOT defaults to roles/ next to tools/

roles/<kind>/kind.md is the base of a kind; roles/<kind>/<variant>/role.md is one variant.
roles/_template/ holds the two skeletons: its keys must be there, its placeholder values are
not checked. The text below the front matter must have a blank line around each heading and each
list (the repo's markdown lint, rules MD022 and MD032), so that a role file is clean before it is
pushed. layout() is a line-based approximation of those two rules, built for the plain headings,
lists and fences role files use; markdownlint stays the authority and the hosted lint job runs it.
Known differences (none occurs in roles/). It also reports: a fence inside a list item, a lazy
continuation line followed by another item, headings or items inside a multi-line HTML comment,
`2.`, a bare `-` or `- - -` right after text, a one-line HTML comment between text and a list, and
fences that differ in type or length. It does not report: a setext heading with no blank line below
it, a list ended by a thematic break, a quote or an HTML block, or an indented line after text
followed by a list. Every problem is printed, one per line, as `FILE: MESSAGE` or
`FILE:LINE: MESSAGE`.
Exit 0 = clean, 1 = problems, 64 = ROOT is not a directory.
"""
import re
import sys
from pathlib import Path

MODES = {"plan", "dontAsk", "manual", "acceptEdits", "auto", "none"}
RUNS_AS = {"session", "subsession", "cron", "service", "timer", "on-demand"}
BASE_KEYS = ("kind", "lead", "model", "permission_mode", "runs_as")
VARIANT_KEYS = ("kind", "variant", "permission_mode")
KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(.*)$")
HEADING = re.compile(r"^ {0,3}#{1,6}( +|$)")
LIST_ITEM = re.compile(r"^ {0,3}([-*+]|\d{1,9}[.)])( +|$)")
FENCE = re.compile(r"^ {0,3}(```|~~~)")


def front_matter(text):
    """The top-level keys of the leading --- block as ({key: value}, [keys given twice]); None if it is absent or open."""
    lines = text.split("\n")
    if not lines or lines[0].rstrip() != "---":
        return None
    keys, twice = {}, []
    for line in lines[1:]:
        if line.rstrip() == "---":
            return keys, twice
        m = KEY.match(line)
        if m:
            value = re.sub(r"\s+#.*$", "", m.group(2)).strip()
            if m.group(1) in keys:
                twice.append(m.group(1))
            keys[m.group(1)] = value
    return None


def layout(text, label):
    """Blank lines around headings and lists below the front matter, as `FILE:LINE: MESSAGE`.

    Code fences are skipped. A line right below a list item that is not a blank, a heading or a
    fence is a continuation of the item, as in markdown.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    start = next(i for i in range(1, len(lines)) if lines[i].rstrip() == "---") + 1
    kinds, fenced = [], False
    for i, line in enumerate(lines):
        if i < start:
            kinds.append("front")
        elif FENCE.match(line):
            fenced = not fenced
            kinds.append("fence")
        elif fenced:
            kinds.append("fence")
        elif not line.strip():
            kinds.append("blank")
        elif HEADING.match(line):
            kinds.append("heading")
        elif LIST_ITEM.match(line):
            kinds.append("item")
        elif line[0] in " \t":
            kinds.append("cont")
        else:
            kinds.append("text")
    out = []
    for i, kind in enumerate(kinds):
        before = kinds[i - 1] if i > start else "blank"
        after = kinds[i + 1] if i + 1 < len(kinds) else "blank"
        if kind == "heading":
            if before not in ("blank", "front"):
                out.append(f"{label}:{i + 1}: heading needs a blank line above it")
            if after not in ("blank", "front"):
                out.append(f"{label}:{i + 1}: heading needs a blank line below it")
        elif kind == "item":
            if before in ("text", "heading", "fence"):
                out.append(f"{label}:{i + 1}: list needs a blank line above it")
        if kind in ("item", "cont") and after == "fence":
            out.append(f"{label}:{i + 1}: list needs a blank line below it")
    return out


def check(path, label, required, folder_kind, folder_variant, template):
    """Problems of one file, as strings."""
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError) as e:
        return [f"{label}: cannot read ({e.__class__.__name__})"]
    parsed = front_matter(text)
    if parsed is None:
        return [f"{label}: no front matter (a leading --- block that is closed by ---)"]
    fm, twice = parsed
    out = [f"{label}: missing required key: {k}" for k in required if k not in fm]
    out += [f"{label}: required key has no value: {k}" for k in required if k in fm and not fm[k]]
    out += [f"{label}: key given twice: {k}" for k in dict.fromkeys(twice)]
    out += layout(text, label)
    if template:
        return out
    if fm.get("kind") and fm["kind"] != folder_kind:
        out.append(f"{label}: kind is {fm['kind']!r} but the folder is {folder_kind!r}")
    if folder_variant and fm.get("variant") and fm["variant"] != folder_variant:
        out.append(f"{label}: variant is {fm['variant']!r} but the folder is {folder_variant!r}")
    mode = fm.get("permission_mode")
    if mode and mode not in MODES:
        out.append(f"{label}: permission_mode {mode!r} is not one of {', '.join(sorted(MODES))}")
    runs = fm.get("runs_as")
    if runs and runs not in RUNS_AS:
        out.append(f"{label}: runs_as {runs!r} is not one of {', '.join(sorted(RUNS_AS))}")
    if runs in ("cron", "timer") and "schedule" not in fm:
        out.append(f"{label}: runs_as {runs} needs a schedule")
    if mode == "dontAsk" and "permission_detail" not in fm:
        out.append(f"{label}: permission_mode dontAsk needs permission_detail")
    if "remove" in fm and not fm.get("ruling"):
        out.append(f"{label}: remove needs a ruling")
    return out


def lint(root):
    problems = []
    kinds = sorted(p for p in root.iterdir() if p.is_dir())
    if not kinds:
        return [f"{root.name}: no kind folders"]
    for kdir in kinds:
        template = kdir.name == "_template"
        base = kdir / "kind.md"
        if base.is_file():
            problems += check(base, f"{kdir.name}/kind.md", BASE_KEYS, kdir.name, None, template)
        else:
            problems.append(f"{kdir.name}: no kind.md")
        if template:
            variant = kdir / "role.md"
            if variant.is_file():
                problems += check(variant, f"{kdir.name}/role.md", VARIANT_KEYS, None, None, True)
            else:
                problems.append(f"{kdir.name}: no role.md")
            continue
        for vdir in sorted(p for p in kdir.iterdir() if p.is_dir()):
            role = vdir / "role.md"
            label = f"{kdir.name}/{vdir.name}/role.md"
            if role.is_file():
                problems += check(role, label, VARIANT_KEYS, kdir.name, vdir.name, False)
            else:
                problems.append(f"{kdir.name}/{vdir.name}: no role.md")
    return problems


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent / "roles"
    if not root.is_dir():
        print(f"lint-roles: {root.name} is not a directory", file=sys.stderr)
        return 64
    problems = lint(root)
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
