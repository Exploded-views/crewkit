"""Tests for tools/ci-ok.py and check_ci_ok in tools/lint-skills.py.

main's ruleset requires a check named ci-ok. ci.yml's ci-ok job needs every other job, runs
always, and passes only if every needed job's result is "success", or "skipped" for a job
guarded off while the repo is private and only while it is (tools/ci-ok.py). The lint
fails a workflow whose ci-ok job is missing, isn't run always, or leaves a job out of its needs,
so a new job can't skip the required check.
"""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CI_OK = ROOT / "tools" / "ci-ok.py"


def ci_ok(results, private=None, workflow=None):
    env = {k: v for k, v in os.environ.items() if k not in ("PRIVATE", "WORKFLOW")}
    env["RESULTS"] = json.dumps(results) if not isinstance(results, str) else results
    if private is not None:
        env["PRIVATE"] = private
    if workflow is not None:
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "ci.yml").write_text(workflow)
        env["WORKFLOW"] = str(d / "ci.yml")
    return subprocess.run([sys.executable, str(CI_OK)], env=env, capture_output=True, text=True)


# toJSON(needs): each needed job by name, with its result.
def needs(**results):
    return {job: {"result": r, "outputs": {}} for job, r in results.items()}


GUARDED = """jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: true
  macos:
    if: ${{ !github.event.repository.private }}
    runs-on: macos-latest
    steps:
      - run: true
"""


class CiOkScript(unittest.TestCase):
    def test_all_success_passes(self):
        self.assertEqual(ci_ok(["success", "success"]).returncode, 0)

    def test_any_failure_skip_or_cancel_fails_and_is_named(self):
        for bad in ("failure", "skipped", "cancelled", ""):
            out = ci_ok(["success", bad])
            self.assertEqual(out.returncode, 1, bad)
            self.assertIn(bad or "''", out.stdout + out.stderr)

    def test_no_results_fails(self):
        self.assertEqual(ci_ok([]).returncode, 1)

    def test_unreadable_results_fail(self):
        self.assertEqual(ci_ok("{not json").returncode, 1)
        # A dict whose keys read as results must not pass for a list of them.
        self.assertEqual(ci_ok('{"success": "success"}').returncode, 1)

    def test_needs_object_all_success_passes(self):
        self.assertEqual(ci_ok(needs(lint="success", macos="success"), "false", GUARDED).returncode, 0)

    def test_needs_object_failure_fails_and_names_the_job(self):
        out = ci_ok(needs(lint="failure", macos="success"), "false", GUARDED)
        self.assertEqual(out.returncode, 1)
        self.assertIn("lint", out.stdout)

    def test_a_guarded_job_skipped_on_a_private_repo_passes(self):
        out = ci_ok(needs(lint="success", macos="skipped"), "true", GUARDED)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("macos", out.stdout)

    def test_a_guarded_job_skipped_on_a_public_repo_fails(self):
        out = ci_ok(needs(lint="success", macos="skipped"), "false", GUARDED)
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("macos", out.stdout)

    def test_a_skip_when_privacy_is_unknown_fails(self):
        self.assertEqual(ci_ok(needs(lint="success", macos="skipped"), None, GUARDED).returncode, 1)
        self.assertEqual(ci_ok(needs(lint="success", macos="skipped"), "", GUARDED).returncode, 1)

    def test_an_unguarded_job_skipped_on_a_private_repo_fails(self):
        out = ci_ok(needs(lint="skipped", macos="success"), "true", GUARDED)
        self.assertEqual(out.returncode, 1)
        self.assertIn("lint", out.stdout)

    def test_a_guarded_job_that_failed_or_was_cancelled_fails_even_when_private(self):
        for bad in ("failure", "cancelled"):
            self.assertEqual(ci_ok(needs(lint="success", macos=bad), "true", GUARDED).returncode, 1, bad)

    def test_a_skip_with_an_unreadable_workflow_fails(self):
        env = dict(os.environ, RESULTS=json.dumps(needs(lint="success", macos="skipped")), PRIVATE="true",
                   WORKFLOW="/nonexistent/ci.yml")
        out = subprocess.run([sys.executable, str(CI_OK)], env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 1)

    def test_a_guarded_job_that_failed_fails_while_another_is_skipped(self):
        two = GUARDED + "  mutants:\n    if: ${{ !github.event.repository.private }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"
        out = ci_ok(needs(lint="success", macos="skipped", mutants="failure"), "true", two)
        self.assertEqual(out.returncode, 1, out.stdout)
        self.assertIn("mutants", out.stdout)

    def test_results_that_are_neither_a_list_nor_an_object_fail(self):
        for bad in ('"success"', "1", "null"):
            self.assertEqual(ci_ok(bad).returncode, 1, bad)

    def test_a_list_of_results_never_allows_a_skip(self):
        self.assertEqual(ci_ok(["success", "skipped"], "true", GUARDED).returncode, 1)

    def test_a_needs_entry_without_a_result_fails(self):
        self.assertEqual(ci_ok({"lint": {"outputs": {}}}, "false", GUARDED).returncode, 1)

    def test_the_real_ci_yml_lets_only_macos_and_mutants_skip_while_private(self):
        real = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        jobs = dict.fromkeys(["scrub", "lint", "install-mutants", "shell", "tests", "coverage", "bash32"], "success")
        self.assertEqual(ci_ok(needs(**jobs, mutants="skipped", macos="skipped"), "true", real).returncode, 0)
        self.assertEqual(ci_ok(needs(**jobs, mutants="skipped", macos="skipped"), "false", real).returncode, 1)
        out = ci_ok(needs(**dict(jobs, bash32="skipped"), mutants="success", macos="success"), "true", real)
        self.assertEqual(out.returncode, 1)
        self.assertIn("bash32", out.stdout)

    def test_a_workflow_with_a_job_key_ci_ok_cannot_follow_fails_a_skip(self):
        out = ci_ok(needs(lint="success", macos="skipped"), "true", GUARDED + '  "odd":\n    runs-on: ubuntu-latest\n')
        self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
        self.assertIn("can't follow", out.stdout)

    def test_the_guarded_jobs_in_the_real_ci_yml_are_exactly_macos_and_mutants(self):
        # Guarding another job means editing this test, so a reviewer sees it.
        import importlib.util
        spec = importlib.util.spec_from_file_location("ci_ok", CI_OK)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(mod.guarded_jobs(ROOT / ".github" / "workflows" / "ci.yml"), {"macos", "mutants"})

    def test_missing_variable_fails(self):
        env = {k: v for k, v in os.environ.items() if k != "RESULTS"}
        self.assertEqual(subprocess.run([sys.executable, str(CI_OK)], env=env, capture_output=True).returncode, 1)


def load_lint():
    spec = importlib.util.spec_from_file_location("lint_skills", ROOT / "tools" / "lint-skills.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GOOD = """jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: true
  tests:
    runs-on: ubuntu-latest
    steps:
      - run: true
  ci-ok:
    name: ci-ok
    if: always()
    needs: [lint, tests]
    runs-on: ubuntu-latest
    steps:
      - run: true
"""


class CheckCiOk(unittest.TestCase):
    def check(self, ci):
        lint = load_lint()
        root = pathlib.Path(tempfile.mkdtemp())
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "ci.yml").write_text(ci)
        lint.ROOT = root
        lint.errors.clear()
        lint.check_ci_ok()
        return lint.errors

    def test_every_job_needed_passes(self):
        self.assertEqual(self.check(GOOD), [])

    def test_trigger_keys_under_on_are_not_jobs(self):
        self.assertEqual(self.check("on:\n  push:\n    branches: [main]\n  pull_request:\n\n" + GOOD), [])

    def test_a_block_list_of_needs_passes(self):
        self.assertEqual(self.check(GOOD.replace("needs: [lint, tests]", "needs:\n      - lint\n      - tests")), [])

    def test_a_job_left_out_of_needs_fails_and_is_named(self):
        errs = self.check(GOOD.replace("needs: [lint, tests]", "needs: [lint]"))
        self.assertTrue(any("tests" in e for e in errs), errs)

    def test_needs_naming_a_missing_job_fails(self):
        errs = self.check(GOOD.replace("needs: [lint, tests]", "needs: [lint, tests, gone]"))
        self.assertTrue(any("gone" in e for e in errs), errs)

    def test_without_if_always_fails(self):
        errs = self.check(GOOD.replace("    if: always()\n", ""))
        self.assertTrue(any("always()" in e for e in errs), errs)

    def test_a_check_name_other_than_ci_ok_fails(self):
        errs = self.check(GOOD.replace("    name: ci-ok\n", "    name: all green\n"))
        self.assertTrue(any("name" in e for e in errs), errs)

    def test_a_job_key_with_a_comment_or_quotes_still_counts(self):
        extra = "  sneaky:  # added later\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1\n" \
                "  \"quoted\":\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 1\n"
        errs = self.check(GOOD.replace("  ci-ok:", extra + "  ci-ok:"))
        self.assertTrue(any("sneaky" in e for e in errs), errs)
        self.assertTrue(any("quoted" in e for e in errs), errs)

    def test_a_job_line_the_lint_cannot_read_fails(self):
        errs = self.check(GOOD.replace("  ci-ok:", "  {weird: job}\n  ci-ok:"))
        self.assertTrue(any("can't follow" in e for e in errs), errs)

    def test_a_job_key_the_lint_cannot_follow_fails(self):
        # A quoted key is a job (test above); an anchor or a flow mapping isn't followed.
        for key in ("odd: &anchor", "odd: {runs-on: ubuntu-latest}"):
            errs = self.check(GOOD.replace("  ci-ok:\n", f"  {key}\n    runs-on: ubuntu-latest\n  ci-ok:\n"))
            self.assertTrue(any("can't follow" in e for e in errs), (key, errs))

    def test_a_comment_at_the_job_key_indent_is_fine(self):
        self.assertEqual(self.check(GOOD.replace("  ci-ok:\n", "  # the required check\n  ci-ok:\n")), [])

    def test_no_ci_ok_job_fails(self):
        self.assertTrue(self.check(GOOD.split("  ci-ok:")[0]))


if __name__ == "__main__":
    unittest.main()
