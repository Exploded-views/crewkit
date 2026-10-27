"""Tests for the Inputs-first rule in tools/lint-skills.py (check_inputs)."""
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"
FENCE = "```"

GOOD = f"""# Install

## Inputs

- `CREWKIT_DIR` = `$HOME/<path to your crewkit clone>`: where you cloned crewkit.
- `HOST` = `<host name>`: this machine's name in memsync.

### Already set

- `--yes` is off: the installer dry-runs unless you pass it.

## Steps

{FENCE}bash
CREWKIT_DIR="$HOME/<path to your crewkit clone>"
HOST="<host name>"
{FENCE}

{FENCE}bash
"$CREWKIT_DIR/install.sh" --yes -- --host "$HOST"
{FENCE}

{FENCE}text
MEMSYNC_TAG=<a tag>
{FENCE}
"""


def load_lint():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckInputs(unittest.TestCase):
    def check(self, text):
        lint = load_lint()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / "page.md").write_text(text)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_inputs(["page.md"])
        return lint.errors

    def test_good_page_passes(self):
        self.assertEqual(self.check(GOOD), [])

    def test_undeclared_placeholder_in_shell_block_fails(self):
        errs = self.check(GOOD.replace('--host "$HOST"', "--host <other host>"))
        self.assertTrue(any("<other host>" in e and "Inputs" in e for e in errs), errs)

    def test_text_blocks_are_exempt(self):
        self.assertEqual(self.check(GOOD.replace("<a tag>", "<anything>")), [])

    def test_shell_placeholders_without_an_inputs_section_fail(self):
        page = f"# P\n\n{FENCE}bash\nrun <thing>\n{FENCE}\n"
        errs = self.check(page)
        self.assertTrue(any("## Inputs" in e for e in errs), errs)

    def test_malformed_inputs_bullet_fails(self):
        errs = self.check(GOOD.replace("- `HOST` = `<host name>`: this machine's name in memsync.",
                                       "- HOST: this machine's name"))
        self.assertTrue(any("NAME" in e and "format" in e for e in errs), errs)

    def test_input_never_used_in_the_steps_fails(self):
        errs = self.check(GOOD.replace('--host "$HOST"', ""))
        self.assertTrue(any("HOST" in e and "never used" in e for e in errs), errs)

    def test_bare_path_to_or_owner_in_shell_block_fails(self):
        errs = self.check(GOOD.replace('"$CREWKIT_DIR/install.sh"', "/path/to/crewkit/install.sh"))
        self.assertTrue(any("/path/to/" in e for e in errs), errs)
        errs = self.check(GOOD.replace('"$CREWKIT_DIR/install.sh"', "git clone OWNER/crewkit"))
        self.assertTrue(any("OWNER" in e for e in errs), errs)

    def test_description_on_the_next_line_passes(self):
        page = GOOD.replace("- `HOST` = `<host name>`: this machine's name in memsync.",
                            "- `HOST` = `<host name>`\n  This machine's name in memsync.")
        self.assertEqual(self.check(page), [])

    def test_placeholder_outside_its_assignment_fails(self):
        errs = self.check(GOOD.replace('--host "$HOST"', '--host "<host name>"'))
        self.assertTrue(any("$HOST" in e for e in errs), errs)

    def test_long_literal_repeated_on_a_page_fails(self):
        sha = "0123456789abcdef" * 3
        page = GOOD + f"\nPinned at `{sha}`.\n\n{FENCE}bash\ngit checkout {sha}\n{FENCE}\n"
        errs = self.check(page)
        self.assertTrue(any("more than once" in e for e in errs), errs)

    def test_repeated_command_line_fails(self):
        page = GOOD + f"\n{FENCE}bash\n\"$CREWKIT_DIR/install.sh\" --yes -- --host \"$HOST\"\n{FENCE}\n"
        errs = self.check(page)
        self.assertTrue(any("repeated" in e for e in errs), errs)

    def test_inputs_as_a_subsection_passes(self):
        page = GOOD.replace("## Inputs", "## Getting started\n\n### Inputs").replace("### Already set", "#### Already set")
        self.assertEqual(self.check(page), [])

    def test_quoted_assignment_passes(self):
        self.assertEqual(self.check(GOOD), [])

    def test_unquoted_assignment_of_a_spaced_placeholder_fails(self):
        errs = self.check(GOOD.replace('HOST="<host name>"', "HOST=<host name>"))
        self.assertTrue(any("quote" in e for e in errs), errs)

    def test_quoted_path_input_without_home_fails(self):
        # "~/x" inside quotes is not expanded: a path input must be written "$HOME/<...>".
        page = (GOOD.replace("`$HOME/<path to your crewkit clone>`", "`<path to your crewkit clone>`")
                    .replace('CREWKIT_DIR="$HOME/<path to your crewkit clone>"', 'CREWKIT_DIR="<path to your crewkit clone>"'))
        errs = self.check(page)
        self.assertTrue(any("CREWKIT_DIR" in e and "$HOME" in e for e in errs), errs)

    def test_path_input_under_home_passes(self):
        self.assertEqual(self.check(GOOD), [])

    def test_page_without_placeholders_passes(self):
        self.assertEqual(self.check(f"# P\n\n{FENCE}bash\nls\n{FENCE}\n"), [])


if __name__ == "__main__":
    unittest.main()
