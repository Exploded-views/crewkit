#!/usr/bin/env python3
"""watchline.py: the one grammar for watcher lines, used to produce them and to check them.

A watcher reads public repositories, where anyone can write. Its lines carry numbers and fixed
words only, plus a sanitized title for trusted authors:

  public:<repo>#<N> <issue|pr|comment> author=<ASSOCIATION> https://github.com/<owner>/<repo>/...
  ... the same, then " title: <text>"   only for OWNER, MEMBER or COLLABORATOR, never a comment

public-watch builds its lines with issue_line() and comment_line(); the orchestrator side
filters what arrives with check(). Nothing else declares these patterns.

  python3 watchline.py check OWNER/REPO...
                                stdin: lines; stdout: the lines that match the grammar exactly
                                and point at one of the watched repositories (a forged line for
                                another owner's same-named repository is dropped);
                                stderr: "watchline: dropped N line(s)" when any were dropped.
                                Exit 0, whatever was dropped; 2 if stdin can't be read; 64 for
                                no repositories or a malformed one.
"""
import re
import sys
import unicodedata

ASSOCIATIONS = ("OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR",
                "FIRST_TIMER", "MANNEQUIN", "NONE")
TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
MAX_WORDS = 15
WITHHELD = "(withheld: addresses agents)"

NUM_RE = re.compile(r"\A[0-9]{1,12}\Z")
REPO_RE = re.compile(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
_ANSI_RE = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|.)", re.S)
_URL_RE = re.compile(r"\b(?:https?|ftp|file|ssh|git)://\S+|\bwww\.\S+", re.I)
_FIELD_RE = re.compile(r"\b(public|private|author|title)[:=]", re.I)
_AGENT_RE = re.compile(
    r"ignore (all |any )?(previous|prior|above|earlier) (instructions|prompts?)|"
    r"system prompt|you are (now )?(an? |in )|disregard (all |the )?(previous|prior|above)|"
    r"\b(approve|merge|release|deploy|push)\b.*\b(now|immediately)\b|owner says|"
    r"new instructions|act as\b", re.I)

_BASE = (r"public:(?P<label>[a-z0-9-]+)#(?P<n>[0-9]{1,12}) "
         r"(?:(?P<kind>issue|pr) author=(?P<a>[A-Z_]+) https://github\.com/(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?P<path>issues|pull)/(?P=n)"
         r"|comment author=(?P<ca>[A-Z_]+) https://github\.com/(?P<crepo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(?P=n)#issuecomment-[0-9]{1,12})")
LINE_RE = re.compile(r"\A" + _BASE + r"(?: title: (?P<title>.+))?\Z")


def label_of(repo):
    """public:<label>: the repository's name, lower-cased, with . and _ as -."""
    return repo.split("/")[1].lower().replace(".", "-").replace("_", "-")


def association(a):
    return a if a in ASSOCIATIONS else "UNKNOWN"


def sanitize_title(raw):
    t = _ANSI_RE.sub("", raw)
    # Control, format (bidi overrides, zero-width) and separator characters become spaces.
    t = "".join(" " if unicodedata.category(c)[0] in "CZ" else c for c in t)
    t = _URL_RE.sub("[link]", t).replace("@", "")
    # Text shaped like this line's own fields can't pose as them.
    t = _FIELD_RE.sub(lambda m: m.group(1) + " ", t)
    words = t.split()
    if _AGENT_RE.search(" ".join(words)):
        return WITHHELD
    return " ".join(words[:MAX_WORDS]) or "(empty)"


def issue_line(repo, n, kind, assoc, title=None):
    """The line for an issue or PR; title only matters for a trusted author."""
    a = association(assoc)
    line = f"public:{label_of(repo)}#{n} {kind} author={a} https://github.com/{repo}/{'pull' if kind == 'pr' else 'issues'}/{n}"
    if a in TRUSTED and title is not None:
        line += " title: " + sanitize_title(title)
    return line


def comment_line(repo, n, cid, assoc):
    return f"public:{label_of(repo)}#{n} comment author={association(assoc)} https://github.com/{repo}/issues/{n}#issuecomment-{cid}"


def valid(line, repos):
    """True only for a line the producer could have written for one of REPOS (owner/name)."""
    m = LINE_RE.match(line)
    if not m:
        return False
    a = m.group("a") or m.group("ca")
    repo = m.group("repo") or m.group("crepo")
    if repo.lower() not in {r.lower() for r in repos}:
        return False
    if a not in ASSOCIATIONS + ("UNKNOWN",) or label_of(repo) != m.group("label"):
        return False
    if m.group("kind") and (m.group("path") == "pull") != (m.group("kind") == "pr"):
        return False
    title = m.group("title")
    if title is None:
        return True
    # A title only on a trusted issue or PR, and only one sanitize_title() could have produced.
    return bool(m.group("kind")) and a in TRUSTED and sanitize_title(title) == title


def check(lines, repos):
    """(kept, dropped): the lines that are valid for REPOS, and how many weren't."""
    kept = [line for line in lines if valid(line, repos)]
    return kept, len(lines) - len(kept)


def main(argv):
    if len(argv) < 2 or argv[0] != "check" or not all(REPO_RE.match(r) and ".." not in r for r in argv[1:]):
        print(__doc__.split("\n\n")[-1], file=sys.stderr)
        return 64
    try:
        if sys.stdin is None:  # stdin closed
            raise OSError("closed")
        data = sys.stdin.buffer.read()
    except OSError as e:
        print(f"watchline: can't read stdin ({e.__class__.__name__})", file=sys.stderr)
        return 2
    lines = data.decode("utf-8", "replace").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    kept, dropped = check(lines, argv[1:])
    for line in kept:
        print(line)
    if dropped:
        print(f"watchline: dropped {dropped} line(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
