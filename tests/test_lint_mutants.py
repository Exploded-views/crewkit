"""Tests for check_mutant_matrix in tools/lint-skills.py: CI runs every mutation spec."""
import importlib.util
import json
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
    def check(self, specs, listed, ci=None, gate=None):
        lint, root = self.setup_root(specs, listed, ci, gate)
        return self.run_lint(lint, root)

    def run_lint(self, lint, root):
        lint.ROOT = root
        lint.errors.clear()
        lint.check_mutant_matrix()
        return lint.errors

    def setup_root(self, specs, listed, ci=None, gate=None):
        """specs: names (written as `{}`) or {name: content}, content a dict (JSON) or a raw string;
        gate: the text of tests/mutants/local-gate.txt, or None for no file."""
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "tests" / "mutants").mkdir(parents=True)
        if not isinstance(specs, dict):
            specs = {name: {} for name in specs}
        for name, content in specs.items():
            text = content if isinstance(content, str) else json.dumps(content)
            (root / "tests" / "mutants" / name).write_text(text)
        if gate is not None:
            (root / "tests" / "mutants" / "local-gate.txt").write_text(gate)
        (root / ".github" / "workflows").mkdir(parents=True)
        items = "\n".join(f"          - {n}" for n in listed)
        (root / ".github" / "workflows" / "ci.yml").write_text(ci if ci is not None else CI.format(items=items))
        return lint, root

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

    # local_gate_only: a spec may leave CI's matrix only with a reason and a local-gate.txt hold.
    def tagged(self, reason="takes hours"):
        return {"local_gate_only": reason}

    def test_a_tagged_spec_held_by_the_local_gate_passes(self):
        self.assertEqual(self.check({"a.json": {}, "h.json": self.tagged()}, ["a.json"], gate="h.json\n"), [])

    def test_a_tagged_spec_not_in_the_gate_file_fails_naming_the_file(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="# only a header\n\n")
        self.assertTrue(any("h.json" in e and "local-gate.txt" in e for e in errs), errs)

    def test_a_tagged_spec_with_no_gate_file_fails_as_not_covered(self):
        errs = self.check({"h.json": self.tagged()}, [])
        self.assertTrue(any("h.json" in e and "local-gate.txt" in e for e in errs), errs)

    def test_an_untagged_spec_outside_the_matrix_still_fails_with_the_old_text(self):
        errs = self.check({"h.json": {}}, [], gate="h.json\n")
        self.assertTrue(any("h.json is not in the `mutants` job's spec matrix, so CI never runs it" in e
                            for e in errs), errs)

    def test_a_missing_gate_file_is_fine_when_no_spec_is_tagged(self):
        self.assertEqual(self.check(["a.json"], ["a.json"]), [])

    def test_a_tagged_spec_in_the_ci_matrix_fails(self):
        errs = self.check({"h.json": self.tagged()}, ["h.json"], gate="h.json\n")
        self.assertTrue(any("h.json" in e and "local_gate_only" in e for e in errs), errs)

    def test_an_empty_reason_fails(self):
        errs = self.check({"h.json": self.tagged("")}, [], gate="h.json\n")
        self.assertTrue(any("h.json" in e and "local_gate_only" in e for e in errs), errs)

    def test_a_blank_reason_fails(self):
        errs = self.check({"h.json": self.tagged("  \t")}, [], gate="h.json\n")
        self.assertTrue(any("h.json" in e and "local_gate_only" in e for e in errs), errs)

    def test_a_non_string_reason_fails(self):
        for bad in (True, 5, ["x"], None):
            errs = self.check({"h.json": self.tagged(bad)}, [], gate="h.json\n")
            self.assertTrue(any("h.json" in e and "local_gate_only" in e for e in errs), (bad, errs))

    def test_all_slices_of_one_n_cover_a_spec(self):
        gate = "h.json@1of3 h.json@2of3\nh.json@3of3\n"
        self.assertEqual(self.check({"h.json": self.tagged()}, [], gate=gate), [])

    def test_slices_may_sit_among_other_tokens_and_comments(self):
        gate = "# header\n\n  \nh.json@2of2 g.json\n# note\nh.json@1of2\n"
        specs = {"h.json": self.tagged(), "g.json": self.tagged()}
        self.assertEqual(self.check(specs, [], gate=gate), [])

    def test_a_partial_set_of_slices_fails_naming_the_missing_ones(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of3 h.json@3of3\n")
        self.assertTrue(any("h.json" in e and "2of3" in e for e in errs), errs)

    def test_a_missing_last_slice_is_named(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of3 h.json@2of3\n")
        self.assertTrue(any("3of3" in e for e in errs), errs)

    def test_a_broken_hold_leaves_the_spec_uncovered_in_ci_yml_too(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of2\n")
        self.assertTrue(any(e.startswith(".github") and "h.json" in e and "cover" in e for e in errs), errs)

    def test_a_tagged_spec_missing_from_the_gate_file_gets_the_exact_message(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="# none\n")
        self.assertTrue(any("tests/mutants/h.json is tagged local_gate_only but is not in "
                            "tests/mutants/local-gate.txt, so neither CI nor the local gate runs it" in e
                            for e in errs), errs)

    def test_an_unreadable_gate_file_is_reported_and_covers_nothing(self):
        for write in (lambda p: p.write_bytes(b"\xff\xfe h.json\n"), lambda p: p.mkdir()):
            lint, root = self.setup_root({"h.json": self.tagged()}, [])
            write(root / "tests" / "mutants" / "local-gate.txt")
            errs = self.run_lint(lint, root)
            self.assertTrue(any("local-gate.txt" in e and "not a readable hold list" in e for e in errs), errs)
            self.assertTrue(any("h.json" in e and "local_gate_only" in e and not e.startswith("tests/mutants/local-gate.txt")
                                for e in errs), errs)

    def test_a_reason_of_invisible_characters_fails(self):
        for bad in ("\u200b", "\ufeff", "\u00a0 \u200b", "\u2028", "\x07"):
            errs = self.check({"h.json": self.tagged(bad)}, [], gate="h.json\n")
            self.assertTrue(any("h.json" in e and "local_gate_only must be" in e for e in errs), (bad, errs))

    def test_a_real_reason_with_a_zero_width_character_inside_is_accepted(self):
        self.assertEqual(self.check({"h.json": self.tagged("takes\u200b hours")}, [], gate="h.json\n"), [])

    def test_a_bad_gate_file_fails_with_no_tagged_spec(self):
        errs = self.check({"a.json": {}}, ["a.json"], gate="a.json nope.json bad\n")
        self.assertTrue(any("nope.json" in e for e in errs), errs)
        self.assertTrue(any("'bad'" in e for e in errs), errs)
        self.assertTrue(any("a.json" in e and "local_gate_only" in e for e in errs), errs)

    def test_a_stale_gate_file_fails_with_no_specs_at_all(self):
        errs = self.check({}, [], gate="gone.json\n")
        self.assertTrue(any("gone.json" in e and "does not exist" in e for e in errs), errs)

    def test_no_specs_and_no_gate_file_is_fine(self):
        self.assertEqual(self.check({}, []), [])

    def test_a_plain_token_mixed_with_slices_fails(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json h.json@1of2 h.json@2of2\n")
        self.assertTrue(any("h.json is listed both whole and as slices" in e for e in errs), errs)

    def test_two_different_n_fail(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of2 h.json@2of2 h.json@1of3 h.json@2of3 h.json@3of3\n")
        self.assertTrue(any("h.json is sliced into different N (2, 3)" in e for e in errs), errs)

    def test_n_above_the_cap_is_rejected_quickly(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of30000000\n")
        self.assertTrue(any("h.json@1of30000000" in e and "100" in e for e in errs), errs)
        self.assertTrue(all(len(e) < 500 for e in errs), errs)

    def test_n_at_the_cap_is_accepted(self):
        gate = " ".join(f"h.json@{k}of100" for k in range(1, 101))
        self.assertEqual(self.check({"h.json": self.tagged()}, [], gate=gate), [])

    def test_many_missing_slices_are_truncated(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of100\n")
        e = next(e for e in errs if "are missing" in e)
        self.assertIn("@2of100", e)
        self.assertIn("@11of100", e)
        self.assertNotIn("@12of100", e)
        self.assertIn("and 89 more", e)

    def test_ten_missing_slices_are_all_named(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@11of20 h.json@12of20 h.json@13of20 "
                          "h.json@14of20 h.json@15of20 h.json@16of20 h.json@17of20 h.json@18of20 h.json@19of20 "
                          "h.json@20of20\n")
        e = next(e for e in errs if "are missing" in e)
        self.assertIn("@10of20", e)
        self.assertNotIn("more", e)

    def test_a_spec_listed_plain_twice_fails(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json\nh.json\n")
        self.assertTrue(any("h.json" in e and "twice" in e for e in errs), errs)

    def test_the_same_slice_twice_fails(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json@1of2 h.json@2of2 h.json@2of2\n")
        self.assertTrue(any("h.json@2of2" in e and "twice" in e for e in errs), errs)

    def test_a_token_that_is_not_valid_syntax_fails(self):
        for bad in ("h", "h.json@", "h.json@1", "h.json@0of2", "h.json@3of2", "h.json@1of0", "h.json@aofb",
                    "H.json@1of2 extra!", "../h.json", "h.json@1of2@1of2", "h.json@01of2"):
            errs = self.check({"h.json": self.tagged()}, [], gate=bad + "\n")
            self.assertTrue(any("local-gate.txt" in e and bad.split()[-1] in e for e in errs), (bad, errs))

    def test_a_gate_token_naming_no_spec_fails(self):
        errs = self.check({"h.json": self.tagged()}, [], gate="h.json nope.json\n")
        self.assertTrue(any("nope.json" in e for e in errs), errs)

    def test_a_gate_token_naming_an_untagged_spec_fails(self):
        errs = self.check({"a.json": {}, "h.json": self.tagged()}, ["a.json"], gate="h.json a.json\n")
        self.assertTrue(any("a.json" in e and "local_gate_only" in e for e in errs), errs)

    def test_an_unreadable_spec_is_reported_not_a_crash(self):
        for raw in ("not json", "[]", "5"):
            errs = self.check({"a.json": raw}, ["a.json"])
            self.assertTrue(any("a.json" in e and "not a readable mutation spec" in e for e in errs), (raw, errs))

    def test_an_unreadable_spec_outside_the_matrix_is_still_reported(self):
        errs = self.check({"a.json": "not json"}, [])
        self.assertTrue(any("a.json" in e for e in errs), errs)

    def test_a_gate_file_does_not_count_as_a_spec(self):
        self.assertEqual(self.check({"h.json": self.tagged()}, [], gate="h.json\n"), [])


if __name__ == "__main__":
    unittest.main()
