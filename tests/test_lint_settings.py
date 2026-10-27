"""Tests for check_settings in tools/lint-skills.py: docs/settings.md is the schema."""
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "lint-skills.py"
SCHEMA = """# Settings

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `repo` | none | landers | The GitHub repo. |
| `gates.<name>` | none | lane-gates | A gate command. Never gates a merge. |
| `high_risk_areas.<area>.paths` | none | landers | Path globs for an area. |
"""


LISTS = """# reader
CREW_FILE_ONLY='repo high_risk_areas.*'
CREW_ENV_OK='gates.*'
"""


def load():
    spec = importlib.util.spec_from_file_location("lint_skills", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class CheckSettings(unittest.TestCase):
    def check(self, files):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        files = {"docs/settings.md": SCHEMA, "lib/settings.sh": LISTS, **files}
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_settings()
        return lint.errors

    def test_documented_keys_pass(self):
        errs = self.check({"plugins/p/bin/x": 'r=$(crew_require repo)\nt=$(crew_keys gates.)\n'
                                              'h=$(crew_setting high_risk_areas.billing.paths)\n'})
        self.assertEqual(errs, [])

    def test_an_undocumented_key_in_a_script_fails(self):
        errs = self.check({"plugins/p/bin/x": 'v=$(crew_setting reqired_check ci-ok)\n'})
        self.assertTrue(any("reqired_check" in e for e in errs), errs)

    def test_a_key_outside_a_documented_prefix_shape_fails(self):
        errs = self.check({"plugins/p/bin/x": 'v=$(crew_setting high_risk_areas.billing.colour)\n'})
        self.assertTrue(any("high_risk_areas.billing.colour" in e for e in errs), errs)

    def test_an_undocumented_key_in_an_example_settings_file_fails(self):
        errs = self.check({"plugins/p/crewkit.example.md": "---\nrepo: o/r\nlables.x: y\n---\n", "plugins/p/settings.example.md": "---\nowner_name: x\n---\n"})
        self.assertTrue(any("lables.x" in e for e in errs), errs)

    def test_a_non_literal_key_without_a_tag_fails(self):
        errs = self.check({"plugins/p/bin/x": 'for k in a b; do v=$(crew_setting "$k"); done\n'})
        self.assertTrue(any("not a literal" in e for e in errs), errs)

    def test_a_tagged_non_literal_key_passes_when_the_tagged_keys_are_documented(self):
        errs = self.check({"plugins/p/bin/x":
            'v=$(crew_setting "$k")  # settings-keys: high_risk_areas.<name>.paths repo\n'})
        self.assertEqual(errs, [])

    def test_a_tagged_key_that_isnt_documented_fails(self):
        errs = self.check({"plugins/p/bin/x": 'v=$(crew_setting "$k")  # settings-keys: nope.<name>\n'})
        self.assertTrue(any("nope" in e for e in errs), errs)

    def test_a_wrapper_hiding_a_literal_key_is_caught_at_its_call(self):
        errs = self.check({"plugins/p/bin/x": 'int_setting() { crew_setting "$1" "$2"; }\nv=$(int_setting poll_secs 60)\n'})
        self.assertTrue(any("not a literal" in e for e in errs), errs)

    def test_a_retired_key_anywhere_in_a_plugin_fails(self):
        errs = self.check({"plugins/p/skills/s/SKILL.md": "Write it to `decisions_log`.\n"})
        self.assertTrue(any("decisions_log" in e and "state_dir" in e for e in errs), errs)

    def test_a_vendored_reader_that_differs_fails(self):
        errs = self.check({"plugins/p/lib/settings.sh": "# reader, edited\n"})
        self.assertTrue(any("plugins/p/lib/settings.sh" in e and "lib/settings.sh" in e for e in errs), errs)

    def test_any_vendored_lib_file_that_differs_fails(self):
        errs = self.check({"lib/verdict.py": "# canonical\n", "plugins/p/lib/settings.sh": LISTS,
                           "plugins/p/lib/verdict.py": "# edited\n"})
        self.assertTrue(any("plugins/p/lib/verdict.py" in e for e in errs), errs)

    def test_a_plugin_private_lib_file_passes(self):
        # A plugin's own library (no root lib/ file of that name) is not a vendored copy.
        self.assertEqual(self.check({"plugins/p/lib/settings.sh": LISTS,
                                     "plugins/p/lib/landing.sh": "own code\n"}), [])

    def test_a_stale_copy_of_a_canonical_file_fails(self):
        errs = self.check({"lib/verdict.py": "# v2\n", "plugins/p/lib/settings.sh": LISTS,
                           "plugins/p/lib/verdict.py": "# v1\n"})
        self.assertTrue(any("plugins/p/lib/verdict.py" in e and "differs" in e for e in errs), errs)

    def test_an_identical_vendored_reader_passes(self):
        self.assertEqual(self.check({"plugins/p/lib/settings.sh": LISTS}), [])


if __name__ == "__main__":
    unittest.main()


class CheckSettingsClassified(unittest.TestCase):
    """Every documented key is in exactly one of lib/settings.sh's CREW_FILE_ONLY and CREW_ENV_OK, so a
    new key can't be left unclassified (and a gate setting can't quietly take CREWKIT_*)."""

    def check(self, lists, schema=SCHEMA):
        lint = load()
        root = pathlib.Path(tempfile.mkdtemp())
        for rel, text in {"docs/settings.md": schema, "lib/settings.sh": "# reader\n" + lists}.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_settings()
        return lint.errors

    def test_every_key_classified_passes(self):
        self.assertEqual(self.check("CREW_FILE_ONLY='repo high_risk_areas.*'\nCREW_ENV_OK='gates.*'\n"), [])

    def test_lists_may_span_lines(self):
        self.assertEqual(self.check("CREW_FILE_ONLY='repo\n  high_risk_areas.*'\nCREW_ENV_OK='gates.*'\n"), [])

    def test_an_unclassified_key_fails_and_is_named(self):
        errs = self.check("CREW_FILE_ONLY='repo'\nCREW_ENV_OK='gates.*'\n")
        self.assertTrue(any("high_risk_areas.<area>.paths" in e for e in errs), errs)

    def test_a_key_in_both_lists_fails(self):
        errs = self.check("CREW_FILE_ONLY='repo high_risk_areas.* gates.*'\nCREW_ENV_OK='gates.*'\n")
        self.assertTrue(any("gates" in e and "both" in e for e in errs), errs)

    def test_an_exact_entry_beats_a_prefix(self):
        schema = SCHEMA + "| `labels.do_not_merge` | none | landers | x |\n| `labels.<name>` | none | lanes | x. Never gates a merge. |\n"
        self.assertEqual(self.check("CREW_FILE_ONLY='repo high_risk_areas.* labels.do_not_merge'\n"
                                    "CREW_ENV_OK='gates.* labels.*'\n", schema), [])

    def test_an_entry_matching_no_documented_key_fails(self):
        errs = self.check("CREW_FILE_ONLY='repo high_risk_areas.* retired_key'\nCREW_ENV_OK='gates.*'\n")
        self.assertTrue(any("retired_key" in e for e in errs), errs)

    def test_missing_lists_fail(self):
        self.assertTrue(self.check(""))


class CheckEnvOkPrefixes(unittest.TestCase):
    """A CREW_ENV_OK prefix may only cover placeholder families documented "Never gates a merge"; a
    documented exact key is listed exactly (or covered by a file-only prefix), so a new key under a
    broad env-OK prefix can't skip classification."""

    def check(self, lists, extra_rows=""):
        return CheckSettingsClassified().check(lists, SCHEMA + extra_rows)

    def test_an_exact_key_under_an_env_ok_prefix_must_be_listed_exactly(self):
        errs = self.check("CREW_FILE_ONLY='repo high_risk_areas.*'\nCREW_ENV_OK='gates.* labels.*'\n",
                          "| `labels.<name>` | none | lanes | A label. Never gates a merge. |\n"
                          "| `labels.new_gate` | none | landers | A new label. |\n")
        self.assertTrue(any("labels.new_gate" in e and "exactly" in e for e in errs), errs)

    def test_listing_it_exactly_passes(self):
        self.assertEqual(self.check("CREW_FILE_ONLY='repo high_risk_areas.* labels.new_gate'\nCREW_ENV_OK='gates.* labels.*'\n",
                                    "| `labels.<name>` | none | lanes | A label. Never gates a merge. |\n"
                                    "| `labels.new_gate` | none | landers | A new label. |\n"), [])

    def test_an_env_ok_prefix_over_a_family_not_marked_never_gating_fails(self):
        errs = self.check("CREW_FILE_ONLY='repo high_risk_areas.*'\nCREW_ENV_OK='gates.* hooks.*'\n",
                          "| `hooks.<name>` | none | lanes | A hook. |\n")
        self.assertTrue(any("hooks.*" in e and "Never gates a merge" in e for e in errs), errs)

    def test_a_file_only_prefix_may_cover_exact_keys(self):
        self.assertEqual(self.check("CREW_FILE_ONLY='repo high_risk_areas.* ci.*'\nCREW_ENV_OK='gates.*'\n",
                                    "| `ci.workflow` | none | landers | The workflow. |\n"), [])


class CheckCodeKeysUnderEnvOkPrefixes(unittest.TestCase):
    """A literal key read in code that only an env-OK prefix covers needs its own row (and an exact
    classification), so a gating key added only in code can't take CREWKIT_* unclassified."""

    LISTS = "# reader\nCREW_FILE_ONLY='repo high_risk_areas.*'\nCREW_ENV_OK='gates.* labels.* labels.fixed'\n"
    ROWS = ("| `labels.<name>` | none | lanes | A label. Never gates a merge. |\n"
            "| `labels.fixed` | none | lanes | A label. |\n")

    def check(self, code, extra_rows=""):
        return CheckSettings().check({"docs/settings.md": SCHEMA + self.ROWS + extra_rows, "lib/settings.sh": self.LISTS,
                                      "plugins/p/bin/x": code})

    def test_a_code_key_under_an_env_ok_prefix_without_its_own_row_fails(self):
        errs = self.check('v=$(crew_setting labels.hold "")\n')
        self.assertTrue(any("labels.hold" in e and "own row" in e for e in errs), errs)

    def test_a_code_key_with_its_own_classified_row_passes(self):
        self.assertEqual(self.check('v=$(crew_setting labels.fixed "")\n'), [])

    def test_a_code_key_under_a_file_only_prefix_needs_no_row(self):
        self.assertEqual(self.check('v=$(crew_setting high_risk_areas.billing.paths "")\n'), [])
