#!/usr/bin/env python3
"""export.py: build the public export of one commit (the dev repo's docs/public-export.md).

  tools/export.py --ref <commit> --out <empty dir> [--repo <dev repo>] [--keep-design]
                  [--require-denylist] [--require-private-repos]

The public repo is a fresh one-commit export of the reviewed tree, never the dev repo's
history. This writes that tree: `git archive` of the commit into the empty --out directory, then
the export transforms, then `git init` + `git add -A` there and prints the tree hash the owner
approves ("export tree: <40 hex>"). Committing and pushing is the publish step's job.

The transforms keep the dev repo's references intact and drop them from the public copy:
- lesson citations, `([lesson N](PLAYBOOK_LESSONS_URL#N))`, `See [lesson N](...)` and
  `[lessons N and M](...)`: removed, with the text around them closed up, and a citation that
  wrapped onto its own line folded back into the line before;
- the lines that define the placeholder (a table row or a `key: value` line naming it);
- prose between a drop-start and a drop-end marker (START and END below, each alone on its line).
A link to a repo that isn't on the public list (PUBLIC_REPOS), the dev repo's name, a short
`<repo>#N` reference to one, a bare PR number in prose, a lesson cited by number in plain text, a
local clone path (`<home>/projects/<clone>`), or a line of the private denylist (when one is
present: see tools/scrub.sh; its contents are never printed; a missing one is warned about, and an
empty or unreadable one refuses; --require-denylist refuses a missing one), left
outside a dropped region fails too. So does a name from the private-repos list: one repo name per
line (# comments and blank lines skipped), read from $EXPORT_PRIVATE_REPOS, default
~/.config/crewkit/private-repos.txt (beside the denylist), never in the tree. A name matches as a
whole word in any case (`org/name`, `name#N` and `name.git` hit; `my-name-notes` doesn't), in a file's
text and in its path, and is never printed. A name on PUBLIC_REPOS, or the dev repo's own, is exempt
even if listed. A line is a repo name or `owner/name` (the bare name is what counts); any other line refuses the
whole list, naming its number only. A missing list at the default path is warned about; one named by
EXPORT_PRIVATE_REPOS, or --require-private-repos (every public-bound run passes it), refuses it. A list
that holds no name to check (empty, comments only, every name exempt) refuses too. A list that exists but isn't a regular file (a symlink included), isn't owned by
the user running the export or is open to group or other (mode 600 or stricter) refuses, flag or not.
The text checks read the folded copy (see scannable) and a
percent-decoded copy as well as the raw text, and cover file names and symlink targets. This tool, its lint and their tests (MAY_NAME) are copied
verbatim, with no transform: they may name the placeholder, but a drop marker in any of them
fails the export, since nothing would be dropped (their fixtures spell markers in parts). Files
marked `export-ignore` in .gitattributes are left out by `git archive` itself.
`--keep-design` is for the public development repo's export, design docs included: it adds
the KEEP_DESIGN directories (docs/superpowers/, docs/plans/) from the same commit: it lifts only
those two exact export-ignore rules (see design_tree), so a more specific rule, in the root
.gitattributes or one inside those directories, still leaves its files out, and so does everything
else export-ignored (docs/public-export.md). Every check above applies to the added files.
The root .gitattributes must hold both exact rules (`docs/superpowers/ export-ignore`,
`docs/plans/ export-ignore`), else the export refuses; the exported .gitattributes is the
commit's own, with them. Without the flag the export is the install mirror, unchanged. A file that isn't
UTF-8 text (or holds NUL bytes) must be marked `binary` or `-text` there, and is still scanned.
Accepted gaps: a dev commit SHA isn't recognized (it looks like any hex string), and a compressed
binary (an archive, a deflated stream) isn't unpacked, so what is inside it isn't scanned.
Anything left that names the placeholder (outside this tool, the lint and their tests), a marker
left open, one left behind, or a line or comment that looks like one fails the export. Exit 0 =
written, 1 = a transform failed (nothing to publish), 2 = usage. The export is built in a temp
dir beside --out and renamed into place only on success; a SIGKILL mid-run can leave that temp
dir (.export-*) behind, holding private text. Stdlib only.
"""
import argparse
import functools
import html
import io
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import urllib.parse

PLACEHOLDER = "PLAYBOOK_" + "LESSONS_URL"
LINK = r"\[(?:lessons?|see lessons?) [^\]]*\]\(" + PLACEHOLDER + r"#\d+\)"
# Files that may name the placeholder: this tool, the lint that allows it, and their tests.
# They are copied verbatim (see transform).
MAY_NAME = {"tools/export.py", "tools/lint-skills.py", "tests/test_export.py", "tests/test_lint_settings.py"}
# What --keep-design adds to `git archive`'s tree: the design docs, which .gitattributes marks export-ignore.
KEEP_DESIGN = ("docs/superpowers/", "docs/plans/")
# Spelled in parts, so this file holds no marker: a verbatim file may hold none (see transform).
# Only an exact marker alone on its line opens or closes a region; anything else that looks like
# one refuses rather than leaks, since a mistyped comment renders invisibly (marker_problem).
START, END = "<" "!-- export:drop-" "start -->", "<" "!-- export:drop-" "end -->"
# Cyrillic, Greek and Armenian letters that look alike, folded to the Latin ones the checks read.
# No fold covers every lookalike: HIDDEN below refuses non-ASCII in a comment instead.
# The Unicode hyphens, dashes and the minus sign fold to a hyphen-minus.
LOOKALIKES = {**str.maketrans("\u0430\u0435\u043e\u0440\u0441\u0445\u0442\u0501\u0410\u0415\u041e\u0420\u0421\u0425\u0422"
                              "\u03bf\u03c1\u03c4\u03b5\u039f\u03a1\u03a4\u0395\u03a7\u0585\u0578\u057d",
                              "aeopcxtdAEOPCXTopteOPTEXonu"),
              **{ord(c): "-" for c in "\u2010\u2011\u2012\u2013\u2014\u2015\u2212"}}
# Default-ignorable characters that aren't format (Cf) or combining marks: the combining grapheme
# joiner, Hangul fillers, Khmer vowels, Mongolian selectors, variation selectors.
IGNORABLE = re.compile("[\u034f\u115f\u1160\u17b4\u17b5\u180b-\u180f\u3164\ufe00-\ufe0f\uffa0\U000e0100-\U000e01ef]")
# A line that looks like a drop marker in any syntax (a typo, another comment form, no "export"):
# outside the verbatim files, only an exact START or END line may name a drop start or end.
MARKER_LIKE = re.compile(r"drop[\W_]*(?:start|end)", re.IGNORECASE)
# What renders invisibly: an HTML comment (to its end, or the text's end when never closed), a
# bogus comment (<!x ...>), a processing instruction (<?...?>), and a Markdown link reference
# definition, also inside a blockquote or a list item. One that names export and drop, or a drop
# start or end, refuses; so does one holding any non-ASCII character.
HIDDEN = re.compile(r"<!--.*?(?:-->|\Z)|<!(?!--).*?(?:>|\Z)|<\?.*?(?:\?>|\Z)"
                    r"|^[ \t]*(?:[>*+-][ \t]*)*\[[^\]\n]*\]:[^\n]*", re.DOTALL | re.MULTILINE)


def scannable(text):
    """The text the marker check reads: NUL bytes, format and default-ignorable characters and
    combining marks removed, compatibility forms decomposed (NFKD), and lookalike letters folded,
    so neither UTF-16's NULs, an accent nor a lookalike can slip past the marker checks."""
    text = unicodedata.normalize("NFKD", IGNORABLE.sub("", text.replace("\x00", "")))
    text = "".join(c for c in text if unicodedata.category(c) not in ("Cf", "Mn", "Me"))
    return text.translate(LOOKALIKES)


def line_of(m, text):
    return text.count("\n", 0, m.start()) + 1


def marker_problem(text, verbatim, ascii_comments=True):
    """Where TEXT holds something that could hide a drop marker, as "<line>: <what>", or None.
    ASCII_COMMENTS is off for a binary file's bytes, where comment openers and non-ASCII come by chance."""
    seen = scannable(text)
    for m in HIDDEN.finditer(seen):
        body = m.group(0)
        if (re.search("export", body, re.IGNORECASE) and re.search("drop", body, re.IGNORECASE)) \
                or MARKER_LIKE.search(body):
            return f"{line_of(m, seen)}: an export:drop marker in a comment"
    for m in HIDDEN.finditer(text.replace("\x00", "") if ascii_comments else ""):
        if not m.group(0).isascii():
            return f"{line_of(m, text)}: a comment holding non-ASCII characters (they can hide a marker); write it in ASCII"
    if not verbatim:
        for n, line in enumerate(seen.split("\n"), 1):
            if MARKER_LIKE.search(line):
                return f"{n}: a line that looks like a drop marker; only {START} or {END}, alone on its line, may name one"
    return None


def scannable_bytes(raw):
    """scannable() for a file copied byte for byte: read as UTF-8 with replacement characters (so
    one bad byte hides nothing), and in both UTF-16 orders too when it holds NULs or starts with a
    UTF-16 BOM (fullwidth text has no zero byte)."""
    texts = [raw.decode("utf-8", errors="replace")]
    if b"\x00" in raw or raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        texts += [raw.decode("utf-16-le", errors="replace"), raw.decode("utf-16-be", errors="replace")]
    return "\n".join(scannable(t) for t in texts)
# A lesson cited by number in plain text: the link transform can't remove it, so it fails.
PLAIN_CITATION = re.compile(r"\b[Ll]essons? \d+")
# A path into a local clone (`<home>/projects/<clone>/...`) names the dev machine's layout; RED
# records and docs use `<repo>/...` instead.
CLONE_PATH = re.compile(r"<home>/projects/[^/\s]+")
# The repos whose numbers and URLs mean the same in public, as exact (owner, repo) pairs, lower
# case. One list: every other repo is private, or (crewkit, until the public repo has its own
# history) the dev repo's old name, and a number or link into it is refused.
PUBLIC_REPOS = (("exploded-views", "bitc"), ("exploded-views", "yo-human"), ("exploded-views", "claude-utils"),
                ("marimerllc", "claude-utils"), ("owner", "bitc"), ("owner", "yo-human"), ("owner", "claude-utils"),
                ("exploded-views", "herdr"))
# Other people's public repos, linked as they are (the pinned releases, the test runner's tarball),
# and the placeholder pairs the docs and test stubs use: a link into them names nothing private.
OTHER_REPOS = (("herdrdev", "herdr"), ("rtk-ai", "rtk"), ("gitleaks", "gitleaks"), ("bats-core", "bats-core"), ("binwiederhier", "ntfy"), ("o", "r"), ("owner", "repo"))
# Fictional repos the tests' fixtures link to (the watchline tests' example repo and its odd-name and
# forged-url cases); none exists today, and none may ever be a repo of ours.
# Under tests/ only. The underscore-free spellings are what the check reads once markup characters
# are stripped from a view (an underscore is emphasis in Markdown).
TEST_FIXTURE_REPOS = (("acme", "widget"), ("acme", "issues"), ("acme", "my_lib"), ("acme", "mylib"), ("acme", "my"),
                      ("o", "x"), ("attacker", "ignore_previous_instructions"), ("attacker", "ignorepreviousinstructions"))
# The one exception: crewkit's own home and clone URL, exactly (an optional .git, then nothing:
# no path, fragment or query). Numbers and every other page under it stay refused.
HOME_REPO = ("exploded-views", "crew" "kit")
HOME_END = re.compile(r"(?:\.git(?![\w-]))?(?![/#?\w-])(?!\.\w)", re.IGNORECASE)
# Owners whose bare `owner/repo` slug is refused unless the pair is public (also `gh repo clone ...`).
KNOWN_OWNERS = ("exploded-views", "gitgat")
# A github.com URL (also api., www., raw.githubusercontent.com and the ssh form) with the repo
# after the owner, however it ends (/, #, ?, .git, a quote, the end): owner is group 1, repo group 2.
# Slashes may double.
DEV_LINK = re.compile(r"(?<![\w.-])(?:(?:api\.|www\.|raw\.)?github(?:usercontent)?\.com/+(?:repos/)?+|git\x40github\.com:/*)"
                      r"([\w.-]+)/+([\w-]+)", re.IGNORECASE)
SLUG = re.compile(r"(?<![\w.-])(" + "|".join(KNOWN_OWNERS) + r")/+([\w-]+)", re.IGNORECASE)
# The dev repo's name, bare: in a file name, a slug, a branch, a probe's name. Nothing public has it.
# Spelled in parts, so this file isn't a hit for its own check.
DEV_REF = re.compile(r"\bcrew" r"kit-dev\b", re.IGNORECASE)
# A short reference to a repo: its name with a number (a name with a dot is a file's link fragment).
# `PR#12` and its kin are bare numbers, left to BARE_REF; a name ending in URL is a placeholder
# (the lesson-link one). Under the top-level tests/ (tests_path) the names in TEST_FIXTURE_REFS are not read.
REPO_REF = re.compile(r"(?<![\w.-])([A-Za-z0-9][\w-]*[A-Za-z0-9])#\d+(?![\w-])")
NOT_REPOS = ("pr", "prs", "issue", "issues", "pull", "pulls", "gh")
# The fictional source names the tests' fixtures use with a number (the watchline tool's own
# `name#number` output). Under the top-level tests/ only these pass; any other name, a private
# repo's included, is refused there as everywhere else. Add a name here only if it is made up.
TEST_FIXTURE_REFS = ("widget", "my-lib")
# A bare PR or issue number. Refused only in history prose (history() below), where it cites a
# private PR; elsewhere (tests, evals) numbers are data, and GitHub doesn't autolink them in
# repository files. A heading anchor, a fragment, an entity or ${#x} isn't one: an anchor is spared
# by its shape (`#12-setup`, `](#12)`), never by what comes before it, which an opening paren or a
# slash would let a real citation hide behind. Two lookbehinds, split so this file holds no comment opener.
BARE_REF = re.compile(r"(?<" r"![\w&#$\{])(?<" r"!\]\()#\d+(?![\w-])|\b(?:PRs?|issues?|pulls?|gh)#\d+(?![\w-])", re.IGNORECASE)
# Fenced blocks and code spans are test output and commands, not citations. A backtick fence's
# info string holds no backtick (else it's not an opener); bats' failure quote (a backtick closed by
# an apostrophe), which RED records copy, is exempt on its own `#   `...'` lines in docs/tdd/*.txt only.
FENCE = re.compile(r"^[ \t]*(?:(`{3,})[^`\n]*|(~{3,})[^\n]*)\n.*?^[ \t]*(?:\1`*|\2~*)[ \t]*$", re.MULTILINE | re.DOTALL)
CODE_SPAN = re.compile(r"`[^`\n]*`")
BATS_QUOTE = re.compile(r"^#[ \t]*`[^`\n]*'", re.MULTILINE)
# What the history() check reads as prose, and where numbers are test data instead.
PROSE = (".md", ".markdown", ".txt", ".rst")
TEST_DATA = ("tests", "evals")
POSIX_CLASSES = {"[:alpha:]": "a-zA-Z", "[:digit:]": "0-9", "[:alnum:]": "a-zA-Z0-9", "[:upper:]": "A-Z",
                 "[:lower:]": "a-z", "[:space:]": r"\s", "[:blank:]": r" \t", "[:xdigit:]": "0-9a-fA-F",
                 "[:punct:]": r"!-/:-@\[-`{-~"}


DENYLIST_HIT = "matches the private denylist"


class DenylistError(Exception):
    pass


# A class tag on a denylist line (tools/scrub.sh reads them the same way): ASCII spaces or tabs, then
# "#class=<name>", at the end of the line. Any "#", then spaces, tabs or characters that aren't
# printable ASCII (a Unicode space, VT, FF), then "class" in any case, then the same again, then "=",
# anywhere in the line, that isn't exactly a well-formed tag makes the line malformed ("T#class=x",
# "T #CLASS=x", "T # class=x", "T #class =x"). There is no "not a tag, so a whole pattern" case. The
# export's target is public, so it never skips a class: a tagged line is as active as an untagged one.
# The classes this tool knows. The export applies all of them: its target is public, so no class is skipped.
KNOWN_CLASSES = ("crew-host", "firm")
SKIPPED_CLASSES = ()
# A comment or blank line is ASCII spaces and tabs, then "#" or the end (as in tools/scrub.sh): any
# other space before "#" makes a pattern.
COMMENT = re.compile(r"[ \t]*(#|\Z)")
CLASS_TRIGGER = re.compile(r"#([ \t]|[^ -~])*[cC][lL][aA][sS][sS]([ \t]|[^ -~])*=")
CLASS_STRIP = re.compile(r"([^ \t])[ \t]+#class=[a-z][a-z0-9-]{0,31}\Z")


def strip_class_tag(line):
    """LINE without its class tag, or None when the tag is malformed."""
    if "#" not in line or not CLASS_TRIGGER.search(line):
        return line
    out = CLASS_STRIP.sub(r"\1", line, count=1)
    if out == line or CLASS_TRIGGER.search(out):
        return None
    return out


@functools.lru_cache(maxsize=None)
def load_denylist(path):
    """The private denylist's patterns (tools/scrub.sh's file: one extended regex per line, blank
    lines and # lines skipped, case-insensitive), or [] when there is no such file: CI has none.
    A line this tool can't read raises DenylistError naming its number and never its text."""
    try:
        # Lines end at "\n" only, as scrub.sh reads them: no universal newlines, no \r, \x0c or U+2028 splits.
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            lines = f.read().split("\n")
        if lines and lines[-1] == "":
            lines.pop()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise DenylistError(f"the private denylist can't be read ({e.strerror})") from None
    patterns = []
    for n, line in enumerate(lines, 1):
        if COMMENT.match(line):
            continue
        if line.endswith("\r"):
            raise DenylistError(f"line {n} of the private denylist: CR (a trailing carriage return); strip it") from None
        pattern = strip_class_tag(line)
        if pattern is None:
            raise DenylistError(f"line {n} of the private denylist has a malformed class tag") from None
        for k, v in POSIX_CLASSES.items():
            pattern = pattern.replace(k, v)
        try:
            patterns.append(re.compile(pattern.replace("\\<", r"\b").replace("\\>", r"\b"), re.IGNORECASE | re.MULTILINE))
        except re.error:
            raise DenylistError(f"line {n} of the private denylist isn't a regular expression this tool can read") from None
    if not patterns:
        raise DenylistError("the private denylist has no patterns, so it would check nothing")
    return patterns


def denylist_path():
    return os.environ.get("SCRUB_DENYLIST") or os.path.expanduser("~/.config/crewkit/denylist.txt")


def denylist():
    """The patterns, or [] when the file is missing (main() has warned or refused by then)."""
    return load_denylist(denylist_path()) or []


NOT_CHECKED = "export: private denylist not checked"
PRIVATE_NOT_CHECKED = "export: private-repos list missing, so its names are unchecked"
PRIVATE_HIT = "names a private repo (from the private-repos list); move it into an export:drop region"


# A list line: a repo name or `owner/name` (what `gh repo list` prints with --json name, or with the owner).
PRIVATE_LINE = re.compile(r"(?:[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+")


class PrivateReposError(Exception):
    """The private-repos list exists but can't be trusted or read; the message names no repo."""


def private_repos_path():
    return os.environ.get("EXPORT_PRIVATE_REPOS") or os.path.expanduser("~/.config/crewkit/private-repos.txt")


@functools.lru_cache(maxsize=None)
def load_private_repos(path):
    """The listed repo names, lower case, or None when there is no such file. Opened without
    following a symlink (and without blocking on a FIFO), and judged on the open descriptor: it must
    be a regular file owned by the user running the export with no group or other permission bits.
    Anything else raises PrivateReposError. Names are never put in a message."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as e:
        raise PrivateReposError(f"the private-repos list can't be opened ({e.strerror}; a symlink is refused)") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise PrivateReposError("the private-repos list is not a regular file")
        if st.st_uid != os.getuid():
            raise PrivateReposError("the private-repos list is not owned by the user running the export")
        if st.st_mode & 0o077:
            raise PrivateReposError("the private-repos list is open to group or other; chmod 600 it")
        chunks = []
        while chunk := os.read(fd, 65536):
            chunks.append(chunk)
        raw = b"".join(chunks)
    except OSError as e:
        raise PrivateReposError(f"the private-repos list can't be read ({e.strerror})") from None
    finally:
        os.close(fd)
    names = set()
    for n, line in enumerate(raw.decode("utf-8", errors="replace").removeprefix("\ufeff").split("\n"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # A line that isn't a name fails the whole list, never skipped: a half-read list would pass for a working one.
        if not PRIVATE_LINE.fullmatch(line):
            raise PrivateReposError(f"line {n} of the private-repos list isn't a repo name") from None
        names.add(line.rsplit("/", 1)[-1].lower())  # owner/name protects the bare name
    return frozenset(names)


@functools.lru_cache(maxsize=None)
def private_pattern(names):
    """One regex over NAMES (frozenset), or None. A name is a hit as a whole word: not inside a longer
    name, so not after or before a letter, digit, underscore or hyphen. A dot ends a name (a file
    extension, `.git`, a full stop), so `name.md` is a hit. The names on PUBLIC_REPOS and the home
    repo are left out: a stale list can't block crewkit's own name."""
    exempt = {r for _, r in PUBLIC_REPOS} | {HOME_REPO[1]}
    live = sorted((n for n in names or () if n not in exempt), key=len, reverse=True)
    if not live:
        return None
    return re.compile(r"(?<" r"![A-Za-z0-9_-])(?:" + "|".join(re.escape(n) for n in live) + r")(?![A-Za-z0-9_-])", re.IGNORECASE)


def name_views(text):
    """The views of TEXT the checks read, as (raw, folded, percent-decoded, markup-stripped, kept): the
    first four are what dev_problem reads; the private-repos check reads the fifth too, one that keeps `_` and `*` (only a backslash removed), so `zork\\_vault` and `zork&#95;vault`
    read as the name."""
    seen = scannable(text)
    decoded = scannable(urllib.parse.unquote(seen))
    unmarked = scannable(MARKUP_CHARS.sub("", NEWLINES_KEPT(html.unescape(seen))))
    kept = scannable(NEWLINES_KEPT(html.unescape(seen)).replace("\\", ""))
    return (text, seen, decoded, unmarked, kept)


def private_hit(text):
    """The line of the first listed name in TEXT, in any view, or None."""
    pattern = private_repos()
    for view in dict.fromkeys(name_views(text)) if pattern else ():
        m = pattern.search(view)
        if m:
            return line_of(m, view)
    return None


def denylist_hit(text):
    """Whether any line of the private denylist matches TEXT in any view."""
    return any(p.search(view) for view in dict.fromkeys(name_views(text)) for p in denylist())


def private_repos():
    """The compiled pattern, or None when the list is missing or holds no name (main() has warned or refused)."""
    return private_pattern(load_private_repos(private_repos_path()))


# What hides a name or number from the other views: markup. Entities decoded, tags and comments
# removed (their newlines kept, so line numbers hold), and the Markdown escape and emphasis characters.
MARKUP_CHARS = re.compile(r"[\\*_]")
TAGS = re.compile(r"<" r"!--.*?--\s*>|<[^>\n]*>", re.DOTALL)


def NEWLINES_KEPT(text):
    return TAGS.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def test_data(rel):
    """Whether REL sits under the top-level tests/ or evals/, where numbers are data."""
    return rel.lower().split("/")[0] in TEST_DATA and "/" in rel


def tests_path(rel):
    """Whether REL sits under the top-level tests/ (a path rule, not a guess about content)."""
    return rel.lower().split("/")[0] == "tests" and "/" in rel


def history(rel):
    """History prose: the files that cite what happened, where a bare number means a dev PR.
    Every Markdown, text and reStructuredText file but test data (tests/, evals/, fixtures/)."""
    low = rel.lower()
    return low.endswith(PROSE) and not test_data(rel)


def without_code(text, rel=""):
    """TEXT with fenced blocks and code spans blanked, line numbers kept."""
    text = FENCE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    if re.fullmatch(r"docs/tdd/[^/]*\.txt", rel, re.IGNORECASE):
        text = BATS_QUOTE.sub("", text)
    return CODE_SPAN.sub("", text)


def dev_problem(rel, text, prose=None):
    """What in TEXT (file REL's, or a file name or symlink target) names the private side, as
    (line, what), or None: a denylist match (never quoted), a link to or a short reference to a repo
    that isn't public, the dev repo's name, and in prose a bare number. Read raw, folded and
    percent-decoded, so a disguise or an encoding hides none. PROSE defaults to history(REL)."""
    if prose is None:
        prose = history(rel)
    found = private_hit(text)  # every view first, so a name is not left to a later view's other hit
    if found:
        return found, PRIVATE_HIT
    for view in dict.fromkeys(name_views(text)[:4]):
        homes = []  # spans of the allowed home URLs: their slug is not a hit either
        for pattern in denylist():
            m = pattern.search(view)
            if m:
                return line_of(m, view), DENYLIST_HIT
        for m in DEV_LINK.finditer(view):
            pair = (m.group(1).lower(), m.group(2).lower())
            if pair == HOME_REPO and HOME_END.match(view, m.end()):
                homes.append(m.span())
            elif pair not in PUBLIC_REPOS + OTHER_REPOS + (TEST_FIXTURE_REPOS if tests_path(rel) else ()):
                return line_of(m, view), "links to a repo that isn't public; move it into an export:drop region"
        for m in SLUG.finditer(view):
            if any(a <= m.start() < b for a, b in homes):
                continue
            if (m.group(1).lower(), m.group(2).lower()) not in PUBLIC_REPOS:
                return line_of(m, view), "names a repo that isn't public; move it into an export:drop region"
        m = DEV_REF.search(view)
        if m:
            return line_of(m, view), "names the dev repo; reword it or move it into an export:drop region"
        for m in REPO_REF.finditer(view):
            name = m.group(1)
            if name.lower() in tuple(r for _, r in PUBLIC_REPOS) + NOT_REPOS or name.endswith("URL"):
                continue
            if test_data(rel) and name.lower() == "crewkit" and view[max(0, m.start(1) - 7):m.start(1)] == "public:":
                continue  # the watcher fixtures' label
            if tests_path(rel) and name.lower() in TEST_FIXTURE_REFS:
                continue  # a fixture may carry the tool's own `name#number` output for these names only
            return line_of(m, view), ("cites a repo that isn't public by number; reword it, cite a public repo "
                                      "(bitc, yo-human, claude-utils), or move it into an export:drop region")
        if prose:
            bare = without_code(view, rel)
            m = BARE_REF.search(bare)
            if m:
                return line_of(m, bare), ("cites a dev-repo number; reword it, or move it into an export:drop region "
                                          "(a public repo's number is written <repo>#N)")
    return None


def refuse_dev_links(rel, text):
    found = dev_problem(rel, text)
    if found:
        raise ValueError(f"{rel}:{found[0]}: {found[1]}")


def transform(rel, text):
    """The public text of one file, or raise ValueError naming what couldn't be handled."""
    if rel in MAY_NAME:
        # The tool, its lint and their tests are copied verbatim: their fixtures hold the very
        # forms the transforms remove, and transforming them would weaken the public tests.
        refuse_dev_links(rel, text)
        # A marker in a verbatim file, anywhere in its text, would keep its "dropped" region
        # public. Their fixtures spell markers in parts, so none of them holds one.
        problem = marker_problem(text, verbatim=True)
        if problem:
            raise ValueError(f"{rel}:{problem} (in a file copied verbatim; nothing would be dropped)")
        return text
    lines, out, dropping, squeeze = text.split("\n"), [], False, False
    for n, line in enumerate(lines, 1):
        if line.strip() == START:
            if dropping:
                raise ValueError(f"{rel}:{n}: a region opened inside a dropped region")
            dropping = True
            continue
        if line.strip() == END:
            if not dropping:
                raise ValueError(f"{rel}:{n}: a region closed that was never opened")
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
        raise ValueError(f"{rel}: a dropped region is never closed")
    text = "\n".join(out)
    text = re.sub(r"[ \t]*See " + LINK + r"\.", "", text)
    text = re.sub(r"[ \t]*\(" + LINK + r"\)", "", text)
    text = re.sub(r"\s*" + LINK, "", text)
    # A citation that wrapped onto its own line leaves only its punctuation there: fold it back.
    text = re.sub(r"\n[ \t]*([.,;:])[ \t]*(?=\n)", r"\1", text)
    problem = marker_problem(text, verbatim=False)
    if problem:
        raise ValueError(f"{rel}:{problem}")
    if PLAIN_CITATION.search(text):
        raise ValueError(f"{rel}: cites a lesson by number in plain text; reword it or move it into an export:drop region")
    if CLONE_PATH.search(text):
        raise ValueError(f"{rel}: names a local clone path (<home>/projects/...); write <repo>/... instead")
    refuse_dev_links(rel, text)  # after the drop regions are gone
    if PLACEHOLDER in text:
        raise ValueError(f"{rel}: names {PLACEHOLDER} in a form the export can't remove")
    return text


def main(argv):
    p = argparse.ArgumentParser(prog="export.py", description="Build the public export of a commit.")
    p.add_argument("--repo", default=".")
    p.add_argument("--ref", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--require-denylist", action="store_true",
                   help="fail when the private denylist (SCRUB_DENYLIST, as in tools/scrub.sh) is missing")
    p.add_argument("--require-private-repos", action="store_true",
                   help="fail when the private-repos list (EXPORT_PRIVATE_REPOS) is missing; every public-bound run passes it")
    p.add_argument("--keep-design", action="store_true",
                   help="also export " + " and ".join(KEEP_DESIGN) + " (the public dev repo's export, design docs included)")
    a = p.parse_args(argv)
    out = pathlib.Path(a.out)
    if out.is_symlink() or (out.exists() and not out.is_dir()):
        print(f"export: {out} exists and is not a directory", file=sys.stderr)
        return 2
    if out.exists() and any(out.iterdir()):
        print(f"export: {out} is not empty", file=sys.stderr)
        return 2
    try:
        # Read once, up front: a list this tool can't read, or that holds no pattern, refuses before any work.
        unchecked = load_denylist(denylist_path()) is None
    except DenylistError as e:
        print(f"export: {e}; nothing to publish")
        return 1
    if unchecked and (a.require_denylist or os.environ.get("SCRUB_DENYLIST")):
        print("export: no private denylist at the path given (--require-denylist or SCRUB_DENYLIST); nothing to publish")
        return 1
    if unchecked:
        print(NOT_CHECKED, file=sys.stderr)
    try:
        # Read once, up front, like the denylist: a list that can't be trusted refuses, flag or not.
        no_list = load_private_repos(private_repos_path()) is None
    except PrivateReposError as e:
        print(f"export: {e}; nothing to publish", file=sys.stderr)
        return 1
    if no_list and (a.require_private_repos or os.environ.get("EXPORT_PRIVATE_REPOS")):
        print("export: no private-repos list at the path given (--require-private-repos or EXPORT_PRIVATE_REPOS); "
              "nothing to publish", file=sys.stderr)
        return 1
    if not no_list and private_repos() is None:
        print("export: the private-repos list holds no name to check, so it would check nothing; nothing to publish",
              file=sys.stderr)
        return 1
    if no_list:
        print(PRIVATE_NOT_CHECKED, file=sys.stderr)
    # Resolved once: the archive, the design tree and the attribute reads all see this commit.
    sha = subprocess.run(["git", "-C", a.repo, "rev-parse", "--verify", "-q", a.ref + "^{commit}"], capture_output=True, text=True)
    if sha.returncode != 0:
        print(f"export: git archive {a.ref} failed: {a.ref} is not a commit", file=sys.stderr)
        return 2
    sha = sha.stdout.strip()
    treeish, attributes = sha, None
    try:
        if a.keep_design:
            treeish, attributes = design_tree(a.repo, sha)
    except ValueError as e:
        print(f"export: {e}; nothing to publish")
        return 1
    except subprocess.CalledProcessError as e:
        print(f"export: reading the design dirs at {a.ref} failed: git {e.cmd[3] if len(e.cmd) > 3 else ''}", file=sys.stderr)
        return 2
    tar = subprocess.run(["git", "-C", a.repo, "archive", "--format=tar", treeish], capture_output=True)
    if tar.returncode != 0:
        print(f"export: git archive {a.ref} failed: {tar.stderr.decode().strip()}", file=sys.stderr)
        return 2
    # Built next to --out and moved there only when it succeeds: a refused export leaves no
    # private text on disk.
    out.parent.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix=".export-", dir=out.parent))
    try:
        rc = build(a.ref, tar.stdout, work, binary_paths(a.repo, sha, tar.stdout), unchecked, attributes)
        if rc == 0:
            if out.exists():
                out.rmdir()  # empty, checked above
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(work, 0o777 & ~umask)  # mkdtemp made it 0700; --out gets the usual mode
            os.rename(work, out)
        return rc
    finally:
        shutil.rmtree(work, ignore_errors=True)


def design_rule(line):
    """Whether LINE is one of the two export-ignore rules --keep-design lifts: exactly a
    KEEP_DESIGN directory, then export-ignore. A more specific rule is another line."""
    f = line.split()
    return len(f) == 2 and f[0] in KEEP_DESIGN and f[1] == "export-ignore"


def design_tree(repo, sha):
    """The tree of commit SHA with the KEEP_DESIGN rules removed from the root .gitattributes, as a
    tree id to `git archive`, with the original .gitattributes bytes (build() writes them back, so the
    export holds the commit's own file). Every KEEP_DESIGN directory must have its exact rule there:
    ValueError names the missing ones, since an export without the design docs would pass for the
    dev repo's. Git then applies every
    other rule itself (a more specific one in the root file, a .gitattributes inside the design
    dirs, docs/public-export.md), so only those two directories are lifted. It writes a few
    unreferenced objects into REPO's object store; the index it uses is a temporary one."""
    attrs = subprocess.run(["git", "-C", repo, "cat-file", "blob", f"{sha}:.gitattributes"], capture_output=True)
    lines = attrs.stdout.decode("utf-8", errors="surrogateescape").split("\n") if attrs.returncode == 0 else []
    missing = [d for d in KEEP_DESIGN if not any(design_rule(l) and l.split()[0] == d for l in lines)]
    if missing:
        raise ValueError("--keep-design lifts the export-ignore rule of " + " and ".join(KEEP_DESIGN)
                         + " and the root .gitattributes at the ref has no exact line `"
                         + "`, `".join(d + " export-ignore" for d in missing) + "`")
    kept = [l for l in lines if not design_rule(l)]
    blob = subprocess.run(["git", "-C", repo, "hash-object", "-w", "--stdin"], input="\n".join(kept).encode("utf-8", errors="surrogateescape"),
                          capture_output=True, check=True).stdout.decode().strip()
    with tempfile.TemporaryDirectory() as d:
        env = {**os.environ, "GIT_INDEX_FILE": os.path.join(d, "index")}
        def indexed(*args):
            return subprocess.run(["git", "-C", repo, *args], capture_output=True, check=True, env=env).stdout.decode().strip()
        indexed("read-tree", sha)
        indexed("update-index", "--add", "--cacheinfo", f"100644,{blob},.gitattributes")
        return indexed("write-tree"), attrs.stdout


def binary_paths(repo, ref, archive):
    """The archive's files that .gitattributes at REF marks `binary` or `-text`."""
    with tarfile.open(fileobj=io.BytesIO(archive)) as t:
        names = [m.name for m in t.getmembers() if m.isfile()]
    if not names:
        return set()
    r = subprocess.run(["git", "-C", repo, "check-attr", f"--source={ref}", "-z", "--stdin", "binary", "text"],
                       input="\0".join(names).encode(), capture_output=True, check=True)
    f = r.stdout.decode().split("\0")
    attrs = {}
    for path, attr, value in zip(f[0::3], f[1::3], f[2::3]):
        attrs.setdefault(path, {})[attr] = value
    return {p for p, a in attrs.items() if a.get("binary") == "set" or a.get("text") == "unset"}


def build(ref, archive, out, binary=frozenset(), unchecked=False, attributes=None):
    """Unpack, transform and git-add the export in OUT; print the result; 0 = done, 1 = refused."""
    with tarfile.open(fileobj=io.BytesIO(archive)) as t:
        try:
            t.extractall(out, filter="data")
        except tarfile.FilterError as e:
            # Not the error's text: it quotes a link's target, which may be what the denylist matches.
            print("export: the archive holds a link or path outside the tree; nothing to publish")
            return 1
    ga = out / ".gitattributes"
    if attributes is not None and ga.is_file() and not ga.is_symlink():
        ga.write_bytes(attributes)  # the commit's own file, not the copy edited to lift the design rules
    failed, changed = [], 0
    for path in sorted(f for f in out.rglob("*") if f.is_symlink() or f.is_file()):
        rel = path.relative_to(out).as_posix()
        # A name renders too (a file list, a link): it may not hold a marker or a private name
        # either. A path that matches the denylist can't be named in a message: the name is the match.
        found = dev_problem(rel, rel, prose=False)
        if path.is_symlink():
            found = found or dev_problem(rel, os.readlink(path), prose=False)
        if found:
            # Whatever check fired, a name found in any spelling of the path or target is not printed.
            # Only REL is printed (never a symlink's target), so only REL can leak a name.
            shown = rel
            if private_hit(rel):
                shown = "(a path naming a private repo)"
            if denylist_hit(rel):
                shown = "(a path matching the private denylist)"
            failed.append(f"{shown}: a file name or symlink target that {found[1]}")
            continue
        if MARKER_LIKE.search(scannable(rel)) or HIDDEN.search(rel):
            failed.append(f"{rel}: a file name that looks like a drop marker")
            continue
        if path.is_symlink():
            continue
        raw, text = path.read_bytes(), None
        # NUL bytes mean binary or UTF-16, which can also be valid UTF-8 (every byte below 0x80).
        if b"\x00" not in raw:
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                pass
        if text is None:
            # Not UTF-8 text, so copied byte for byte. Guessing its encoding misses some (GBK, a
            # UTF-16 shifted by a byte), so it must be marked binary; and it still gets scanned.
            if rel not in binary:
                failed.append(f"{rel}: not UTF-8 text; mark it `binary` in .gitattributes, or convert it to UTF-8")
                continue
            seen = scannable_bytes(raw)
            # Every check transform() makes on what's left, since nothing here can be dropped.
            if marker_problem(seen, verbatim=False, ascii_comments=False) or PLACEHOLDER in seen \
                    or CLONE_PATH.search(seen) or PLAIN_CITATION.search(seen) or dev_problem(rel, seen):
                failed.append(f"{rel}: copied byte for byte, and holds an export marker, the placeholder, a clone "
                              "path, a lesson cited by number, a private repo's link or number, the dev repo's name "
                              "or a private denylist match")
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
    print(f"export: {changed} file(s) transformed from {ref}" + (" (private denylist not checked)" if unchecked else ""))
    print(f"export tree: {tree}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
