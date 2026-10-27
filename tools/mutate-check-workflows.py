#!/usr/bin/env python3
"""Mutation check for tools/check-workflows.py: break each safety line once and require the
unit tests to fail. Exit 0 = all killed, 1 = a mutant survived or didn't apply."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = (ROOT / "tools" / "check-workflows.py").read_text()
MUTANTS = [
    ("hosted-label check removed", "    elif not HOSTED.match(label):", "    elif False:"),
    ("expression refusal removed", '    if "${{" in label:', "    if False:"),
    ("matrix resolution skipped", "        for v in values:\n            check_label(v, {}, report, guarded)", "        pass"),
    ("pull_request_target check removed", "            if any(re.search(", "            if False and any(re.search("),
    ("unpinned uses allowed", "            elif not PINNED.match(ref):", "            elif False:"),
    ("docker tag allowed", "                if not DIGEST.match(ref):", "                if False:"),
    ("runner group allowed", '            if v.startswith("{"):\n                report(',
     '            if v.startswith("{"):\n                (lambda *a: None)('),
    ("macOS guard check removed", '    elif label.startswith("macos-") and not guarded:', "    elif False:"),
    ("every job counts as guarded", "            ok = job_at.get(i) in guarded", "            ok = True"),
    ("a guard anywhere in the file counts", "            ok = job_at.get(i) in guarded", "            ok = bool(guarded)"),
    ("a step-level guard counts", "indent(l) == indent(body[0]) and PRIVATE_GUARD", "PRIVATE_GUARD"),
    ("matrix values skip the guard", "            check_label(v, {}, report, guarded)", "            check_label(v, {}, report)"),
    ("block-list labels skip the guard", 'findings.append(f"{path}:{n + 1}: {msg}"), ok)', 'findings.append(f"{path}:{n + 1}: {msg}"))'),
    ("an unfollowable job key is ignored", "        elif bad is not None:\n            bad.append(i)", "        elif False:\n            pass"),
    ("guarded_jobs ignores an unfollowable job key", "    if bad:\n        raise ValueError(", "    if False:\n        raise ValueError("),
    ("a matrix flow mapping is skipped silently", "                if bad is not None:\n                    bad.append(j)\n", ""),
    ("any private condition counts", r"\$\{\{\s*!\s*github", r"\$\{\{\s*!?\s*github"),
]


def suite(tree):
    return subprocess.run([sys.executable, "-m", "unittest", "tests.test_check_workflows"],
                          cwd=tree, capture_output=True, text=True).returncode


def main():
    tree = pathlib.Path(tempfile.mkdtemp())
    shutil.copytree(ROOT / "tests", tree / "tests")
    (tree / "tools").mkdir()
    target = tree / "tools" / "check-workflows.py"
    target.write_text(SRC)
    if suite(tree) != 0:
        print("mutate-check-workflows: the unmutated tests fail; fix them first")
        return 1
    bad = 0
    for name, old, new in MUTANTS:
        if SRC.count(old) != 1:
            print(f"  NOT APPLIED  {name}")
            bad = 1
            continue
        mutated = SRC.replace(old, new)
        try:
            compile(mutated, "check-workflows.py", "exec")
        except SyntaxError:
            # A mutant that doesn't parse "fails" every test for the wrong reason.
            print(f"  INVALID      {name} (not valid Python; fix the mutant)")
            bad = 1
            continue
        target.write_text(mutated)
        if suite(tree) == 0:
            print(f"  SURVIVED     {name}")
            bad = 1
        else:
            print(f"  killed       {name}")
    target.write_text(SRC)
    shutil.rmtree(tree)
    print("mutate-check-workflows: " + ("a mutant survived or didn't apply" if bad else f"all {len(MUTANTS)} mutants killed"))
    return bad


if __name__ == "__main__":
    sys.exit(main())
