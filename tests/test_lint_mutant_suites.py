"""Tests for check_mutant_suites in tools/lint-skills.py: a bats suite in a mutation spec runs
with --abort, so a killed mutant stops at its first failing test instead of running the rest
(lane-land's 32 mutants took 25 minutes without it, past CI's 20-minute job limit)."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"


def load():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckMutantSuites(unittest.TestCase):
    def check(self, suites):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        for name, suite in suites.items():
            (root / "tests" / "mutants" / name).write_text(json.dumps({"target": "x", "suite": suite, "mutants": []}))
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutant_suites()
        return lint.errors

    def test_a_bats_suite_with_abort_passes(self):
        self.assertEqual(self.check({"a.json": ["bats", "--abort", "tests/a.bats"]}), [])

    def test_a_bats_suite_without_abort_fails_and_is_named(self):
        errs = self.check({"a.json": ["bats", "--abort", "tests/a.bats"], "b.json": ["bats", "tests/b.bats"]})
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("b.json", errs[0])
        self.assertIn("--abort", errs[0])

    def test_abort_only_as_a_file_name_does_not_count(self):
        errs = self.check({"a.json": ["bats", "tests/--abort.bats"]})
        self.assertTrue(errs)

    def test_a_suite_that_is_not_bats_is_left_alone(self):
        self.assertEqual(self.check({"a.json": ["bash", "-c", "python3 -m unittest tests.x"]}), [])

    def test_a_spec_that_is_not_readable_json_fails(self):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        (root / "tests" / "mutants" / "bad.json").write_text("{not json")
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutant_suites()
        self.assertTrue(any("bad.json" in e for e in lint.errors), lint.errors)


class CheckMutantsApply(unittest.TestCase):
    """check_mutants_apply: every mutant's old text occurs exactly once in its target, so an edit
    that breaks a mutant fails the lint, not a 20-minute mutation run later."""

    def check(self, target_text, mutants):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        (root / "t.sh").write_text(target_text)
        spec = {"target": "t.sh", "suite": ["bats", "--abort", "x"], "mutants": mutants}
        (root / "tests" / "mutants" / "a.json").write_text(json.dumps(spec))
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutants_apply()
        return lint.errors

    def test_old_text_found_once_passes(self):
        self.assertEqual(self.check("a\nb\n", [{"name": "m", "old": "b", "new": "c"}]), [])

    def test_old_text_missing_fails_naming_the_mutant(self):
        errs = self.check("a\n", [{"name": "gone", "old": "b", "new": "c"}])
        self.assertTrue(any("gone" in e for e in errs), errs)

    def test_old_text_found_twice_fails(self):
        errs = self.check("b\nb\n", [{"name": "twice", "old": "b", "new": "c"}])
        self.assertTrue(any("twice" in e for e in errs), errs)

    def test_a_missing_target_fails(self):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        (root / "tests" / "mutants" / "a.json").write_text(json.dumps({"target": "nope.sh", "suite": ["x"], "mutants": []}))
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutants_apply()
        self.assertTrue(any("nope.sh" in e for e in lint.errors), lint.errors)


if __name__ == "__main__":
    unittest.main()


class CheckScrubKnownVersion(unittest.TestCase):
    """tools/scrub.sh's current blob SHA is listed in tools/scrub-known-versions.txt, so the history
    scan's self-exemption covers the version in the tree (and only reviewed versions)."""

    def check(self, listed):
        import subprocess
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tools").mkdir()
        (root / "tools" / "scrub.sh").write_text("#!/bin/sh\necho scrub\n")
        sha = subprocess.run(["git", "hash-object", str(root / "tools" / "scrub.sh")], capture_output=True, text=True).stdout.strip()
        (root / "tools" / "scrub-known-versions.txt").write_text("# reviewed\n" + (sha + "\n" if listed else "0" * 40 + "\n"))
        lint.ROOT = root
        lint.errors.clear()
        lint.check_scrub_known_version()
        return lint.errors

    def test_the_current_version_listed_passes(self):
        self.assertEqual(self.check(True), [])

    def test_an_unlisted_current_version_fails(self):
        errs = self.check(False)
        self.assertTrue(any("scrub-known-versions" in e for e in errs), errs)
