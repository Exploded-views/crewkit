#!/usr/bin/env python3
"""mutate.py: mutation check for one file's safety lines.

Usage: tools/mutate.py SPEC.json [SPEC.json ...]

A spec names the target, the suite that guards it, and the mutants:

  {"target": "lib/settings.sh",
   "suite": ["bats", "tests/settings.bats"],
   "mutants": [{"name": "...", "old": "exact text, may span lines", "new": "replacement"}]}

The tracked tree is copied to a temp directory and every run happens there, so the real tree
is never changed. The unmutated suite must pass first. Each `old` must occur exactly once in
the target, and the mutated file must still parse (bash -n for shell, compile() for Python),
or the mutant is reported instead of counted. A mutant is killed when the suite fails.
"bats" as the suite's first word runs the pinned bats-core from tools/get-bats.sh.

Exit 0 = every mutant killed, 1 = a mutant survived, didn't apply, was invalid, or the
baseline failed, 2 = usage.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile


def parses(path, text):
    if path.suffix == ".py" or text.startswith("#!/usr/bin/env python"):
        try:
            compile(text, str(path), "exec")
            return True
        except SyntaxError:
            return False
    if path.suffix in (".sh", ".bash", "") or text.startswith("#!"):
        return subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True).returncode == 0
    return True


def copy_tree(root):
    dest = pathlib.Path(tempfile.mkdtemp(prefix="crewkit-mutate-"))
    files = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=root,
                           capture_output=True, text=True, check=True).stdout.splitlines()
    for rel in files:
        src = root / rel
        if src.is_file():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest / rel)
    return dest


def suite_cmd(root, suite):
    if suite and suite[0] == "bats":
        bats = subprocess.run([str(root / "tools" / "get-bats.sh")], cwd=root,
                              capture_output=True, text=True, check=True).stdout.strip()
        return [bats] + suite[1:]
    return suite


def run_spec(root, spec_path):
    spec = json.loads(spec_path.read_text())
    tree = copy_tree(root)
    try:
        target = tree / spec["target"]
        original = target.read_text()
        cmd = suite_cmd(root, spec["suite"])

        def suite():
            return subprocess.run(cmd, cwd=tree, capture_output=True, text=True).returncode

        print(f"{spec['target']}:")
        if suite() != 0:
            print("  the unmutated suite fails; fix it first")
            return 1
        bad = 0
        for m in spec["mutants"]:
            n = original.count(m["old"])
            if n != 1:
                print(f"  NOT APPLIED  {m['name']} (old text found {n} times)")
                bad = 1
                continue
            mutated = original.replace(m["old"], m["new"])
            if not parses(target, mutated):
                print(f"  INVALID      {m['name']} (the mutant doesn't parse; fix it)")
                bad = 1
                continue
            target.write_text(mutated)
            killed = suite() != 0
            target.write_text(original)
            print(("  killed       " if killed else "  SURVIVED     ") + m["name"])
            bad |= not killed
        total = len(spec["mutants"])
        print(f"  {'a mutant survived, did not apply or was invalid' if bad else f'all {total} mutants killed'}")
        return bad
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def main(argv):
    if not argv or any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip(), file=sys.stderr if not argv else sys.stdout)
        return 2 if not argv else 0
    root = pathlib.Path(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                       capture_output=True, text=True, check=True).stdout.strip())
    return max(run_spec(root, pathlib.Path(a)) for a in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
