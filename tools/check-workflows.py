#!/usr/bin/env python3
"""check-workflows.py: GitHub Actions hygiene that a repo taking fork PRs needs.

Fails on:
  - a `runs-on` that isn't a GitHub-hosted label (ubuntu-*, macos-*, windows-*). Lists,
    block lists and `${{ matrix.X }}` are resolved; a runner group or any other expression is
    refused, never guessed;
  - a `pull_request_target` trigger, in any `on:` form;
  - a `uses:` not pinned to a full 40-hex commit SHA (local `./` actions are fine; docker
    images need an `@sha256:` digest);
  - a job that can run on macOS (macos-*, directly, in a list or through a matrix) without the
    job-level guard `if: ${{ !github.event.repository.private }}`: macOS minutes are billed at
    10x on a private repo and free on a public one. The guard must be the job's whole `if:`.
  - a line it can't follow: a quoted, anchored or flow-style job key, or a flow mapping
    in a matrix (`- {os: ...}`), which would otherwise hide a job or a matrix value.

Usage: check-workflows.py [workflow files...]   (default: .github/workflows/*.yml|*.yaml)
Exit 0 = clean, 1 = findings (printed as file:line: message), 2 = usage.

Stdlib only and self-contained, so other repos can vendor this one file (pin it by sha256).
It reads workflows line by line rather than as full YAML; constructs it can't follow are
reported, not skipped.
"""
import pathlib
import re
import sys

HOSTED = re.compile(r"^(ubuntu|macos|windows)-[A-Za-z0-9.-]+$")
PINNED = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
DIGEST = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
MATRIX_REF = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")
PRIVATE_GUARD = re.compile(r"^\s*if:\s*([\"']?)\$\{\{\s*!\s*github\.event\.repository\.private\s*\}\}\1\s*$")


def strip_comment(line):
    """Drop a trailing # comment (outside quotes)."""
    out, quote = [], None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).rstrip()


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


def indent(line):
    return len(line) - len(line.lstrip(" "))


def flow_list(v):
    return [unquote(x) for x in v.strip()[1:-1].split(",") if x.strip()]


def block(lines, i):
    """Lines (index, text) indented deeper than lines[i], until the indentation returns."""
    base, out = indent(lines[i]), []
    for j in range(i + 1, len(lines)):
        if not lines[j].strip():
            continue
        if indent(lines[j]) <= base:
            break
        out.append((j, lines[j]))
    return out


def matrix_values(lines, bad=None):
    """{key: [values]} from every matrix: block in the file, including include: entries.
    Flow mappings ({os: ...}) aren't followed: their line indexes go to bad."""
    vals = {}
    for i, line in enumerate(lines):
        if not re.match(r"^\s*matrix:\s*$", line):
            continue
        body = block(lines, i)
        for k, (j, text) in enumerate(body):
            if re.search(r"(^\s*-\s*|\[\s*)\{", text):
                if bad is not None:
                    bad.append(j)
                continue
            m = re.match(r"^\s*(?:-\s+)?([A-Za-z0-9_-]+):\s*(.*)$", text)
            if not m or m.group(1) in ("include", "exclude"):
                continue
            key, v = m.group(1), m.group(2).strip()
            if v.startswith("["):
                vals.setdefault(key, []).extend(flow_list(v))
            elif v:
                vals.setdefault(key, []).append(unquote(v))
            else:
                for _, item in block(lines, j):
                    im = re.match(r"^\s*-\s+(.+)$", item)
                    if im:
                        vals.setdefault(key, []).append(unquote(im.group(1)))
    return vals


def jobs(lines, bad=None):
    """[(name, first body line, end)] for each job under the top-level jobs: key. A line at the
    job keys' indent that isn't a bare `name:` (quoted, anchored, flow-style) isn't followed:
    its index goes to bad, and the lines under it fold into the job above."""
    start = next((i for i, l in enumerate(lines) if re.match(r"^jobs:\s*$", l)), None)
    if start is None:
        return []
    keys, key_indent = [], None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if not lines[i].strip():
            continue
        if indent(lines[i]) == 0:
            end = i
            break
        if key_indent is None:
            key_indent = indent(lines[i])
        if indent(lines[i]) != key_indent:
            continue
        m = re.match(r"^\s*([A-Za-z0-9_-]+):\s*$", lines[i])
        if m:
            keys.append((m.group(1), i))
        elif bad is not None:
            bad.append(i)
    return [(name, i + 1, keys[k + 1][1] if k + 1 < len(keys) else end) for k, (name, i) in enumerate(keys)]


def guarded_jobs(lines):
    """Names of the jobs whose own `if:` is exactly the private-repo guard. Raises ValueError
    on a job key it can't follow, so a caller fails closed."""
    out, bad = set(), []
    found = jobs(lines, bad)
    if bad:
        raise ValueError(f"line {bad[0] + 1}: can't follow this job key; write it as a bare `name:`")
    for name, first, end in found:
        body = [l for l in lines[first:end] if l.strip()]
        if body and any(indent(l) == indent(body[0]) and PRIVATE_GUARD.match(l) for l in body):
            out.add(name)
    return out


def check_label(label, matrix, report, guarded=True):
    m = MATRIX_REF.match(label)
    if m:
        values = matrix.get(m.group(1))
        if not values:
            report(f"runs-on {label}: can't resolve matrix.{m.group(1)}; list its values in strategy.matrix")
            return
        for v in values:
            check_label(v, {}, report, guarded)
        return
    if "${{" in label:
        report(f"runs-on {label}: can't resolve this expression; use a GitHub-hosted label")
    elif not HOSTED.match(label):
        report(f"runs-on {label}: not a GitHub-hosted label (ubuntu-*, macos-*, windows-*); self-hosted runners are not allowed")
    elif label.startswith("macos-") and not guarded:
        report(f"runs-on {label}: macOS bills 10x on a private repo; give the job "
               "`if: ${{ !github.event.repository.private }}`")


def check(path):
    findings = []
    lines = [strip_comment(l) for l in path.read_text(encoding="utf-8").splitlines()]
    unfollowed = []
    matrix = matrix_values(lines, unfollowed)
    found = jobs(lines, unfollowed)
    for n in unfollowed:
        findings.append(f"{path}:{n + 1}: can't follow this line (a quoted, anchored or flow-style "
                        "key, or a flow mapping in a matrix); write it in block style")
    guarded = guarded_jobs(lines) if not unfollowed else set()
    job_at = {i: name for name, first, end in found for i in range(first, end)}

    for i, line in enumerate(lines):
        def report(msg, n=i):
            findings.append(f"{path}:{n + 1}: {msg}")

        # Triggers: the top-level on: key, inline or as a block.
        m = re.match(r"^[\"']?on[\"']?:\s*(.*)$", line)
        if m:
            region = [m.group(1)] + [t for _, t in block(lines, i)]
            if any(re.search(r"(^|[\s\[,'\"-])pull_request_target([\s\]:,'\"]|$)", t) for t in region):
                report("pull_request_target runs fork code with this repo's secrets; use pull_request")

        m = re.match(r"^\s*(?:-\s+)?uses:\s*(.+)$", line)
        if m:
            ref = unquote(m.group(1))
            if ref.startswith("./"):
                pass
            elif ref.startswith("docker://"):
                if not DIGEST.match(ref):
                    report(f"uses {ref}: pin the image by digest (@sha256:<64 hex>)")
            elif not PINNED.match(ref):
                report(f"uses {ref}: not pinned to a full commit SHA")

        m = re.match(r"^\s*runs-on:\s*(.*)$", line)
        if m:
            ok = job_at.get(i) in guarded
            v = m.group(1).strip()
            if v.startswith("{"):
                report("runs-on uses a runner group or mapping; only GitHub-hosted labels are allowed")
            elif v.startswith("["):
                for label in flow_list(v):
                    check_label(label, matrix, report, ok)
            elif v:
                check_label(unquote(v), matrix, report, ok)
            else:
                body = block(lines, i)
                if not body:
                    report("runs-on is empty")
                for j, text in body:
                    im = re.match(r"^\s*-\s+(.+)$", text)
                    if im:
                        check_label(unquote(im.group(1)), matrix, lambda msg, n=j: findings.append(f"{path}:{n + 1}: {msg}"), ok)
                    else:
                        report("runs-on uses a runner group or mapping; only GitHub-hosted labels are allowed")
                        break
    return findings


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    paths = [pathlib.Path(a) for a in argv] or sorted(
        p for p in pathlib.Path(".github/workflows").glob("*") if p.suffix in (".yml", ".yaml"))
    if not paths:
        print("check-workflows: no workflow files found (pass paths, or run at the repo root)", file=sys.stderr)
        return 2
    findings = []
    for p in paths:
        try:
            findings += check(p)
        except OSError as e:
            print(f"check-workflows: cannot read {p} ({e.__class__.__name__})", file=sys.stderr)
            return 2
    for f in findings:
        print(f)
    print(f"check-workflows: {len(paths)} file(s), {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
