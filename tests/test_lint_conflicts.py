"""Tests for check_conflict_markers in tools/lint-skills.py: no merge left its markers behind."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"


def load():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckConflictMarkers(unittest.TestCase):
    def check(self, files, allow=""):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        files = {"tools/conflict-markers-allowed.txt": allow, **files}
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_conflict_markers()
        return lint.errors

    def test_a_clean_tree_passes(self):
        self.assertEqual(self.check({"a.json": '{"x": 1}\n'}), [])

    def test_committed_markers_fail_and_name_the_file_and_line(self):
        errs = self.check({"perf.json": '{\n<<<<<<< HEAD\n  "a": 1\n=======\n  "a": 2\n>>>>>>> other\n}\n'})
        self.assertTrue(any("perf.json" in e and "line 2;" in e for e in errs), errs)
        self.assertEqual(len([e for e in errs if "perf.json" in e]), 3, errs)

    def test_a_lone_closing_marker_fails(self):
        errs = self.check({"x.md": "text\n>>>>>>> m2-orchestrator\n"})
        self.assertTrue(any("x.md" in e for e in errs), errs)

    def test_a_bare_marker_with_nothing_after_it_fails(self):
        errs = self.check({"y.txt": "a\n>>>>>>>\n"})
        self.assertTrue(any("y.txt" in e for e in errs), errs)

    def test_a_markdown_heading_underline_alone_passes(self):
        self.assertEqual(self.check({"doc.md": "Title\n=======\n\nBody.\n"}), [])

    def test_markers_not_at_the_start_of_a_line_pass(self):
        self.assertEqual(self.check({"t.sh": 'echo "<<<<<<< not a marker"\n'}), [])

    def test_an_allowlisted_fixture_passes(self):
        files = {"tests/fixtures/merge/conflicted.txt": "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n"}
        self.assertEqual(self.check(files, allow="# fixtures that need markers\ntests/fixtures/merge/conflicted.txt\n"), [])

    def test_an_allowlist_entry_for_a_missing_file_fails(self):
        errs = self.check({}, allow="tests/fixtures/gone.txt\n")
        self.assertTrue(any("gone.txt" in e for e in errs), errs)

    def test_untracked_files_are_not_checked(self):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "tools").mkdir()
        (root / "tools" / "conflict-markers-allowed.txt").write_text("")
        (root / "scratch.txt").write_text("<<<<<<< HEAD\n")
        lint.ROOT = root
        lint.errors.clear()
        lint.check_conflict_markers()
        self.assertEqual(lint.errors, [])


if __name__ == "__main__":
    unittest.main()
