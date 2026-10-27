"""Tests for tools/check-workflows.py: GitHub-hosted runners only, no pull_request_target,
every action pinned to a full commit SHA, and every macOS job guarded off on a private repo."""
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "check-workflows.py"
SHA = ("0123456789abcdef" * 3)[:40]  # a well-formed commit SHA, built so no hex literal sits here

GOOD = f"""
name: ci
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@{SHA} # v7.0.1
      - uses: ./.github/actions/local
      - uses: docker://alpine@sha256:{"a" * 64}
      - run: echo hi
  b:
    if: ${{{{ !github.event.repository.private }}}}
    runs-on: ${{{{ matrix.os }}}}
    strategy:
      matrix:
        os: [ubuntu-24.04, macos-14, windows-2022]
    steps:
      - uses: "actions/setup-python@{SHA}"
  c:
    runs-on:
      - ubuntu-24.04-arm
    steps:
      - run: true
"""


class CheckWorkflows(unittest.TestCase):
    def run_on(self, text, name="ci.yml"):
        d = pathlib.Path(tempfile.mkdtemp())
        f = d / name
        f.write_text(textwrap.dedent(text))
        return subprocess.run([sys.executable, str(SCRIPT), str(f)], capture_output=True, text=True)

    def assertFails(self, text, needle):
        r = self.run_on(text)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(needle, r.stdout)

    def test_good_workflow_passes(self):
        r = self.run_on(GOOD)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_self_hosted_label_fails(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on: self-hosted"), "runs-on")

    def test_self_hosted_in_a_flow_list_fails(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on: [self-hosted, linux]"), "self-hosted")

    def test_self_hosted_in_a_block_list_fails(self):
        self.assertFails(GOOD.replace("- ubuntu-24.04-arm", "- self-hosted"), "self-hosted")

    def test_custom_label_fails(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on: my-big-box"), "my-big-box")

    def test_runner_group_fails(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on:\n      group: private"), "group")

    def test_inline_runner_group_fails(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on: { group: private, labels: big }"), "group")

    def test_matrix_value_that_is_self_hosted_fails(self):
        self.assertFails(GOOD.replace("windows-2022", "self-hosted"), "self-hosted")

    def test_matrix_include_value_is_checked(self):
        text = GOOD.replace("        os: [ubuntu-24.04, macos-14, windows-2022]",
                            "        include:\n          - os: ubuntu-24.04\n          - os: build-farm")
        self.assertFails(text, "build-farm")

    def test_unresolvable_expression_is_refused(self):
        self.assertFails(GOOD.replace("runs-on: ubuntu-latest", "runs-on: ${{ inputs.runner }}"), "resolve")

    def test_pull_request_target_fails_in_every_form(self):
        self.assertFails(GOOD.replace("  pull_request:", "  pull_request_target:"), "pull_request_target")
        self.assertFails(GOOD.replace("on:\n  push:\n    branches: [main]\n  pull_request:",
                                      "on: [push, pull_request_target]"), "pull_request_target")
        self.assertFails(GOOD.replace("on:\n  push:\n    branches: [main]\n  pull_request:",
                                      "on: pull_request_target"), "pull_request_target")

    def test_pull_request_target_in_a_comment_or_run_is_fine(self):
        text = GOOD.replace("      - run: echo hi", "      - run: echo pull_request_target  # not a trigger")
        self.assertEqual(self.run_on(text).returncode, 0)

    def test_tag_ref_fails(self):
        self.assertFails(GOOD.replace(f"actions/checkout@{SHA}", "actions/checkout@v4"), "SHA")

    def test_branch_ref_fails(self):
        self.assertFails(GOOD.replace(f"actions/checkout@{SHA}", "actions/checkout@main"), "SHA")

    def test_short_sha_fails(self):
        self.assertFails(GOOD.replace(f"actions/checkout@{SHA}", f"actions/checkout@{SHA[:12]}"), "SHA")

    def test_reusable_workflow_must_be_pinned(self):
        text = GOOD + "  d:\n    uses: org/repo/.github/workflows/x.yml@main\n"
        self.assertFails(text, "SHA")

    def test_docker_tag_fails(self):
        self.assertFails(GOOD.replace(f"docker://alpine@sha256:{'a' * 64}", "docker://alpine:3"), "digest")

    def test_reports_file_and_line(self):
        r = self.run_on(GOOD.replace(f"actions/checkout@{SHA}", "actions/checkout@v4"))
        self.assertRegex(r.stdout, r"ci\.yml:\d+:")

    MAC = """
        on: [pull_request]
        jobs:
          linux:
            runs-on: ubuntu-latest
            steps:
              - run: true
          mac:
            runs-on: macos-latest
            steps:
              - run: true
    """
    GUARD = "    if: ${{ !github.event.repository.private }}\n"

    def guard(self, text, job="mac", line=GUARD):
        return textwrap.dedent(text).replace(f"\n  {job}:\n", f"\n  {job}:\n{line}", 1)

    def test_macos_job_without_the_private_guard_fails(self):
        self.assertFails(self.MAC, "github.event.repository.private")

    def test_macos_job_with_the_private_guard_passes(self):
        r = self.run_on(self.guard(self.MAC))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_quoted_guard_passes(self):
        r = self.run_on(self.guard(self.MAC, line="    if: \"${{ !github.event.repository.private }}\"\n"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_guard_on_another_job_does_not_count(self):
        self.assertFails(self.guard(self.MAC, job="linux"), "github.event.repository.private")

    def test_guard_on_a_step_does_not_count(self):
        text = self.MAC.replace("        runs-on: macos-latest\n            steps:\n              - run: true",
                                "        runs-on: macos-latest\n            steps:\n              - run: true\n                if: ${{ !github.event.repository.private }}")
        self.assertIn("    if:", text)
        self.assertFails(text, "github.event.repository.private")

    def test_a_different_condition_does_not_count(self):
        self.assertFails(self.guard(self.MAC, line="    if: ${{ github.event.repository.private }}\n"),
                         "github.event.repository.private")

    def test_macos_from_a_matrix_without_the_guard_fails(self):
        self.assertFails(GOOD.replace("    if: ${{ !github.event.repository.private }}\n", ""), "macos-14")

    def test_macos_in_a_block_list_without_the_guard_fails(self):
        self.assertFails(self.MAC.replace("runs-on: macos-latest", "runs-on:\n              - macos-14"), "macos-14")

    def test_linux_job_needs_no_guard(self):
        r = self.run_on(self.guard(self.MAC))
        self.assertNotIn("linux", r.stdout)

    def test_guarded_jobs_lists_jobs_by_name(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("check_workflows", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        lines = textwrap.dedent(self.guard(self.MAC)).splitlines()
        self.assertEqual(mod.guarded_jobs(lines), {"mac"})

    def test_a_job_key_the_lint_cannot_follow_is_reported(self):
        for key in ('"mac-arm":', "mac-arm: &linux", "mac-arm: {runs-on: macos-14}"):
            text = self.guard(self.MAC) + f"  {key}\n" + ("" if "{" in key else "    runs-on: macos-14\n    steps:\n      - run: true\n")
            self.assertFails(text, "can't follow")

    def test_guarded_jobs_refuses_a_job_key_it_cannot_follow(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("check_workflows", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        lines = (textwrap.dedent(self.guard(self.MAC)) + '  "x":\n    runs-on: ubuntu-latest\n').splitlines()
        with self.assertRaises(ValueError):
            mod.guarded_jobs(lines)

    def test_a_flow_mapping_in_a_matrix_is_reported(self):
        for item in ("          - {os: macos-14}", "        include: [{os: macos-14}]"):
            text = GOOD.replace("        os: [ubuntu-24.04, macos-14, windows-2022]",
                                "        os: [ubuntu-24.04]\n" + ("        include:\n" + item if item.startswith("          -") else item))
            self.assertFails(text, "can't follow")

    def test_default_scans_github_workflows(self):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / ".github" / "workflows").mkdir(parents=True)
        (d / ".github" / "workflows" / "x.yaml").write_text(textwrap.dedent(GOOD).replace("ubuntu-latest", "self-hosted", 1))
        r = subprocess.run([sys.executable, str(SCRIPT)], cwd=d, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_no_workflows_is_a_usage_error(self):
        d = pathlib.Path(tempfile.mkdtemp())
        r = subprocess.run([sys.executable, str(SCRIPT)], cwd=d, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
