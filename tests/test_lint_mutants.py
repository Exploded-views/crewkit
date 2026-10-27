"""Tests for check_mutant_matrix in tools/lint-skills.py: CI runs every mutation spec."""
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"
CI = """jobs:
  mutants:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        spec:
{items}
    steps:
      - run: python3 tools/mutate.py "tests/mutants/${{{{ matrix.spec }}}}"
"""


def load():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckMutantMatrix(unittest.TestCase):
    def check(self, specs, listed, ci=None):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        for name in specs:
            (root / "tests" / "mutants" / name).write_text("{}")
        (root / ".github" / "workflows").mkdir(parents=True)
        items = "\n".join(f"          - {n}" for n in listed)
        (root / ".github" / "workflows" / "ci.yml").write_text(ci if ci is not None else CI.format(items=items))
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutant_matrix()
        return lint.errors

    def test_every_spec_listed_passes(self):
        self.assertEqual(self.check(["a.json", "b.json"], ["a.json", "b.json"]), [])

    def test_a_spec_missing_from_the_matrix_fails_and_is_named(self):
        errs = self.check(["a.json", "b.json"], ["a.json"])
        self.assertTrue(any("b.json" in e for e in errs), errs)

    def test_a_matrix_entry_without_a_spec_fails(self):
        errs = self.check(["a.json"], ["a.json", "gone.json"])
        self.assertTrue(any("gone.json" in e for e in errs), errs)

    def test_no_mutants_job_fails_when_specs_exist(self):
        errs = self.check(["a.json"], [], ci="jobs:\n  lint:\n    runs-on: ubuntu-latest\n")
        self.assertTrue(errs)

    def test_a_spec_named_only_in_another_job_does_not_count(self):
        ci = "jobs:\n  mutants:\n    strategy:\n      matrix:\n        spec:\n          - a.json\n" \
             "  other:\n    strategy:\n      matrix:\n        spec:\n          - b.json\n"
        errs = self.check(["a.json", "b.json"], [], ci=ci)
        self.assertTrue(any("b.json" in e for e in errs), errs)


if __name__ == "__main__":
    unittest.main()
