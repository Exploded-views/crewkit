"""Tests for the plugin check in tools/lint-skills.py (check_plugin): a plugin ships something."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"


def load_lint():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckPlugin(unittest.TestCase):
    def check(self, files):
        lint = load_lint()
        root = pathlib.Path(tempfile.mkdtemp())
        pdir = root / "plugins" / "p"
        (pdir / ".claude-plugin").mkdir(parents=True)
        (pdir / ".claude-plugin" / "plugin.json").write_text(json.dumps({"name": "p"}))
        for rel, (text, mode) in files.items():
            f = pdir / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(text)
            f.chmod(mode)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_plugin(pdir)
        return lint.errors

    def test_a_plugin_with_nothing_fails(self):
        errs = self.check({})
        self.assertTrue(any("found" in e for e in errs), errs)

    def test_a_plugin_with_only_an_executable_in_bin_passes(self):
        self.assertEqual(self.check({"bin/tool": ("#!/bin/sh\n", 0o755)}), [])

    def test_a_non_executable_file_in_bin_does_not_count(self):
        errs = self.check({"bin/notes.txt": ("text\n", 0o644)})
        self.assertTrue(any("found" in e for e in errs), errs)


if __name__ == "__main__":
    unittest.main()
