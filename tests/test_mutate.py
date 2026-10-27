"""Tests for tools/mutate.py, the generic mutation runner."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "mutate.py"

TARGET = """#!/usr/bin/env bash
check() { [[ $1 -gt 10 ]] || return 1; echo ok; }
check "$1"
"""
SUITE = """#!/usr/bin/env bash
set -e
bash t.sh 11 >/dev/null
! bash t.sh 5 >/dev/null
"""


class Mutate(unittest.TestCase):
    def repo(self, mutants, suite=SUITE, target=TARGET):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "t.sh").write_text(target)
        (d / "suite.sh").write_text(suite)
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
        subprocess.run(["git", "add", "."], cwd=d, check=True)
        spec = d / "m.json"
        spec.write_text(json.dumps({"target": "t.sh", "suite": ["bash", "suite.sh"], "mutants": mutants}))
        return d, spec

    def run_tool(self, d, spec):
        return subprocess.run([sys.executable, str(SCRIPT), str(spec)], cwd=d, capture_output=True, text=True)

    def test_a_guarded_line_is_killed(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed", r.stdout)

    def test_a_survivor_fails_the_run(self):
        d, spec = self.repo([{"name": "harmless", "old": "echo ok", "new": "echo fine"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("SURVIVED", r.stdout)

    def test_an_old_string_that_isnt_unique_fails(self):
        d, spec = self.repo([{"name": "ambiguous", "old": "1", "new": "2"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NOT APPLIED", r.stdout)

    def test_a_mutant_that_doesnt_parse_is_invalid_not_killed(self):
        d, spec = self.repo([{"name": "broken", "old": "echo ok; }", "new": "echo ok; ( }"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("INVALID", r.stdout)

    def test_a_failing_baseline_stops_everything(self):
        d, spec = self.repo([{"name": "x", "old": "echo ok", "new": "echo no"}], suite="exit 1\n")
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("unmutated suite fails", r.stdout)

    def test_the_real_tree_is_never_changed(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        self.run_tool(d, spec)
        self.assertEqual((d / "t.sh").read_text(), TARGET)

    def test_multi_line_old_strings_work(self):
        target = TARGET.replace("check \"$1\"\n", "check \"$1\"\nexit $?\n")
        d, spec = self.repo([{"name": "two lines", "old": "check \"$1\"\nexit $?", "new": "exit 0"}], target=target)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
