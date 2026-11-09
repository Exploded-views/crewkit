#!/usr/bin/env python3
"""A test shim for grep and sed that behaves like BSD's under a UTF-8 locale.

BSD grep skips a match on a line holding an invalid UTF-8 byte, and BSD sed stops at the first
such line ("illegal byte sequence"); GNU tools read past it. The scrub's C-locale hardening only
matters where the tools behave the BSD way, so the suite puts this shim first on PATH for the
invalid-byte tests, and they then fail without the hardening on Linux as well as macOS.

When the effective locale (LC_ALL, else LC_CTYPE, else LANG) is not UTF-8, or under -v for grep,
the real tool is run unchanged. Otherwise grep drops each input line that isn't valid UTF-8
before the real tool sees it, and sed drops that line and all after it. Pattern files (-f) and
scripts are never filtered. Only the input is.

It is stricter than the real BSD tools in two ways: it drops the whole line that holds an invalid
byte (BSD grep can still match the valid part of such a line in some cases), and it passes through
the real tool's exit code, so a grep whose only match was dropped exits 1 as for any other no-match.
A test that passes with the shim therefore passes with real BSD tools too.
"""
import os
import re
import subprocess
import sys
import tempfile

GREP_SHORT_ARG = "efmABC"   # grep's short options that take a value
SED_SHORT_ARG = "ef"
LONG_ARG = {"--regexp": True, "--file": True, "--expression": True, "--max-count": False}   # value: gives the pattern?


def utf8_locale():
    for var in ("LC_ALL", "LC_CTYPE", "LANG"):
        v = os.environ.get(var)
        if v:
            return bool(re.search(r"utf-?8", v, re.I))
    return False


def real_tool(name):
    here = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.path.realpath(d) != here:
            p = os.path.join(d, name)
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
    sys.exit(f"shim: no real {name} on PATH")


def valid(line):
    try:
        line.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def filtered(data, tool):
    out = []
    for line in data.split(b"\n"):
        if valid(line):
            out.append(line)
        elif tool == "sed":
            break
    return b"\n".join(out) + (b"\n" if out and data.endswith(b"\n") else b"")


def split_args(tool, args):
    """(args, indexes of the input files in args). Positionals are [pattern or script] then
    files, unless -e/-f gave the pattern or script."""
    short_arg = GREP_SHORT_ARG if tool == "grep" else SED_SHORT_ARG
    out, pos, have_pattern, i, dashdash = [], [], False, 0, False
    while i < len(args):
        a = args[i]
        out.append(a)
        if dashdash or not a.startswith("-") or a == "-":
            pos.append(len(out) - 1)
        elif a == "--":
            dashdash = True
        elif a.startswith("--"):
            if a in LONG_ARG and i + 1 < len(args):
                have_pattern = have_pattern or LONG_ARG[a]
                i += 1; out.append(args[i])
        elif a[-1] in short_arg and i + 1 < len(args):
            have_pattern = have_pattern or a[-1] in "ef"
            i += 1; out.append(args[i])
        i += 1
    return out, pos[0 if have_pattern else 1:]


def main():
    tool = os.environ["SHIM_TOOL"]
    real = real_tool(tool)
    args = sys.argv[1:]
    invert = tool == "grep" and any(a.startswith("-") and not a.startswith("--") and "v" in a[1:] for a in args)
    if not utf8_locale() or invert:
        os.execv(real, [real] + args)
    out, file_slots = split_args(tool, args)
    tmps = []
    try:
        if file_slots:
            for idx in file_slots:
                try:
                    with open(out[idx], "rb") as f:
                        data = f.read()
                except OSError:
                    continue
                t = tempfile.NamedTemporaryFile(delete=False)
                t.write(filtered(data, tool)); t.close()
                tmps.append(t.name); out[idx] = t.name
            r = subprocess.run([real] + out, close_fds=False)
        else:
            data = sys.stdin.buffer.read()
            r = subprocess.run([real] + out, input=filtered(data, tool), close_fds=False)
        sys.exit(r.returncode)
    finally:
        for t in tmps:
            os.unlink(t)


if __name__ == "__main__":
    main()
