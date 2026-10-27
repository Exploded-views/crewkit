"""Tests for tools/coverage-py-report.py: coverage.py's JSON as the per-file report kcov writes."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "coverage-py-report.py"


class CoveragePyReport(unittest.TestCase):
    def convert(self, data, root):
        d = pathlib.Path(tempfile.mkdtemp())
        src, out = d / "in.json", d / "out.json"
        src.write_text(json.dumps(data))
        r = subprocess.run([sys.executable, str(SCRIPT), str(src), str(out), root], capture_output=True, text=True)
        return r, (json.loads(out.read_text()) if out.exists() else None)

    def test_files_become_repo_relative_with_kcov_fields(self):
        data = {"files": {"/w/repo/plugins/p/bin/tool": {"summary": {
            "covered_lines": 9, "num_statements": 10, "percent_covered": 90.0}}}}
        r, out = self.convert(data, "/w/repo")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(out["files"], [{"file": "plugins/p/bin/tool", "covered_lines": "9",
                                         "total_lines": "10", "percent_covered": "90.00"}])

    def test_relative_paths_are_kept(self):
        data = {"files": {"plugins/p/bin/tool": {"summary": {
            "covered_lines": 1, "num_statements": 4, "percent_covered": 25.0}}}}
        r, out = self.convert(data, "/w/repo")
        self.assertEqual(out["files"][0]["file"], "plugins/p/bin/tool")

    def test_a_file_outside_the_repo_is_left_out(self):
        data = {"files": {"/usr/lib/python3/x.py": {"summary": {
            "covered_lines": 1, "num_statements": 1, "percent_covered": 100.0}}}}
        r, out = self.convert(data, "/w/repo")
        self.assertEqual(out["files"], [])

    def test_unreadable_input_is_exit_2(self):
        d = pathlib.Path(tempfile.mkdtemp())
        r = subprocess.run([sys.executable, str(SCRIPT), str(d / "missing.json"), str(d / "o.json"), "/w"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
