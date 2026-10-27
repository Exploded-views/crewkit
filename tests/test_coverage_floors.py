"""Tests for tools/coverage-floors.py. Run: python3 -m unittest discover -s tests -p 'test_*.py'"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "coverage-floors.py"


class CoverageFloors(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())

    def write(self, name, data):
        path = self.dir / name
        path.write_text(json.dumps(data))
        return path

    def report(self, files):
        """A kcov coverage.json with {path: (covered, total)}."""
        return self.write("coverage.json", {"files": [
            {"file": f"/src/{f}", "covered_lines": str(c), "total_lines": str(t),
             "percent_covered": f"{100 * c / t:.2f}"} for f, (c, t) in files.items()]})

    def run_tool(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                              capture_output=True, text=True)

    def test_two_reports_are_read_together(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 90.0}, "plugins/p/bin/tool": {"lines": 80.0}})
        kcov = self.report({"install.sh": (95, 100)})
        py = self.write("py.json", {"files": [{"file": "plugins/p/bin/tool", "covered_lines": "9",
                                               "total_lines": "10", "percent_covered": "90.00"}]})
        r = self.run_tool("--report", kcov, "--report", py, "--floors", floors)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("plugins/p/bin/tool", r.stdout)

    def test_a_floor_in_neither_report_fails(self):
        floors = self.write("floors.json", {"plugins/p/bin/tool": {"lines": 80.0}})
        kcov = self.report({"install.sh": (95, 100)})
        r = self.run_tool("--report", kcov, "--report", kcov, "--floors", floors)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not in the coverage report", r.stdout)

    def test_at_or_above_floor_passes(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"install.sh": (95, 100)}), "--floors", floors)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_below_floor_fails_and_names_the_file(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"install.sh": (80, 100)}), "--floors", floors)
        self.assertEqual(r.returncode, 1)
        self.assertIn("install.sh", r.stdout)
        self.assertIn("below", r.stdout)

    def test_floored_file_missing_from_report_fails(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"other.sh": (10, 10)}), "--floors", floors)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not in the coverage report", r.stdout)

    def test_lowered_floor_against_base_fails(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 80.0}})
        base = self.write("base.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"install.sh": (95, 100)}),
                          "--floors", floors, "--base-floors", base)
        self.assertEqual(r.returncode, 1)
        self.assertIn("lowered", r.stdout)

    def test_removed_floor_against_base_fails(self):
        floors = self.write("floors.json", {})
        base = self.write("base.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"install.sh": (95, 100)}),
                          "--floors", floors, "--base-floors", base)
        self.assertEqual(r.returncode, 1)
        self.assertIn("removed", r.stdout)

    def test_raised_floor_against_base_passes(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 93.0}})
        base = self.write("base.json", {"install.sh": {"lines": 90.0}})
        r = self.run_tool("--report", self.report({"install.sh": (95, 100)}),
                          "--floors", floors, "--base-floors", base)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_update_raises_floors_to_current_never_lowers(self):
        floors = self.write("floors.json", {"install.sh": {"lines": 90.0}, "b.sh": {"lines": 99.0}})
        r = self.run_tool("--report", self.report({"install.sh": (957, 1000), "b.sh": (50, 100)}),
                          "--floors", floors, "--update")
        self.assertEqual(r.returncode, 1)  # b.sh is still below its floor
        data = json.loads(floors.read_text())
        self.assertEqual(data["install.sh"]["lines"], 95.7)
        self.assertEqual(data["b.sh"]["lines"], 99.0)

    def test_missing_report_is_a_usage_error(self):
        floors = self.write("floors.json", {})
        r = self.run_tool("--report", self.dir / "nope.json", "--floors", floors)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
