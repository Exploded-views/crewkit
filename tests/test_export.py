"""Tests for tools/export.py: build the public export of a commit (the dev repo's docs/public-export.md).

The public repo is a fresh one-commit export of the reviewed tree. The dev repo keeps its
private lesson citations; the export drops them: each citation link, the lines that define its
placeholder, and prose between export:drop markers. Anything it can't handle fails the export.
"""
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXPORT = ROOT / "tools" / "export.py"
URL = "PLAYBOOK_" + "LESSONS_URL"   # assembled, so this file's own text isn't a citation


def repo(files):
    d = pathlib.Path(tempfile.mkdtemp())
    subprocess.run(["git", "init", "-q", "-b", "main", str(d)], check=True)
    for rel, text in files.items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text).replace("URL", URL))
    (d / "run.sh").write_text("#!/bin/sh\necho hi\n")
    (d / "run.sh").chmod(0o755)
    subprocess.run(["git", "-C", str(d), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(d), "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "x"], check=True)
    return d


def export(src, *args):
    out = pathlib.Path(tempfile.mkdtemp()) / "out"
    r = subprocess.run([sys.executable, str(EXPORT), "--repo", str(src), "--ref", "HEAD", "--out", str(out), *args],
                       capture_output=True, text=True)
    return r, out


SKILL = """\
    # Skill

    Keep the lock while you write ([lesson 34](URL#34)).
    Hold the answer until the step is done. See [lesson 5](URL#5).
    A long line about pipefail that wraps before its citation, and its full stop
      ([lesson 51](URL#51)).
    Two at once ([lessons 35 and 39](URL#35)), mid-sentence.

    | Don't | Why |
    |---|---|
    | Load generators | They aren't time-boxed ([lesson 71](URL#71)). |
    """
README = """\
    # Plugin

    | Key | Default |
    |---|---|
    | `page_command` | none |
    | `lessons_url` | `URL` |

    ## Next
    """
SETTINGS = """\
    ---
    page_command: ""
    lessons_url: URL
    ---
    """


class Export(unittest.TestCase):
    def test_citations_are_removed_and_the_text_reads_cleanly(self):
        r, out = export(repo({"skills/a/SKILL.md": SKILL}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        text = (out / "skills/a/SKILL.md").read_text()
        self.assertNotIn(URL, text)
        self.assertIn("Keep the lock while you write.\n", text)
        self.assertIn("Hold the answer until the step is done.\n", text)
        self.assertIn("A long line about pipefail that wraps before its citation, and its full stop.\n", text)
        self.assertIn("Two at once, mid-sentence.\n", text)
        self.assertIn("| Load generators | They aren't time-boxed. |\n", text)
        self.assertNotIn("\n  .\n", text)

    def test_placeholder_definitions_and_marked_prose_are_dropped(self):
        r, out = export(repo({"README.md": README, "settings.example.md": SETTINGS}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        readme = (out / "README.md").read_text()
        self.assertNotIn("lessons_url", readme)
        self.assertNotIn("Lessons links", readme)
        self.assertNotIn("export:drop", readme)
        self.assertIn("| `page_command` | none |\n\n## Next", readme)
        self.assertNotIn("\n\n\n", readme)
        settings = (out / "settings.example.md").read_text()
        self.assertEqual(settings, '---\npage_command: ""\n---\n')

    def test_files_without_citations_are_unchanged_and_modes_kept(self):
        src = repo({"docs/x.md": "plain text\n"})
        r, out = export(src)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((out / "docs/x.md").read_text(), "plain text\n")
        self.assertTrue((out / "run.sh").stat().st_mode & 0o111)

    def test_a_citation_shape_it_does_not_know_fails_the_export(self):
        r, _ = export(repo({"a.md": "Odd form [see lesson 9]( URL#9 ).\n"}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("a.md", r.stdout + r.stderr)
        # No lesson number in the text, so only the placeholder check can catch it.
        r, _ = export(repo({"b.md": "Odd form [see this](URL#9).\n"}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("b.md", r.stdout + r.stderr)

    def test_a_link_to_the_dev_repos_prs_or_issues_fails_the_export(self):
        # Built at runtime, so this file holds no such link itself.
        for kind in ("pull", "issues"):
            link = "https://github.com/OWNER/crew" + f"kit/{kind}/7"
            r, _ = export(repo({"a.md": f"Landed in [#7]({link}).\n"}))
            self.assertEqual(r.returncode, 1, kind)
            self.assertIn("a.md", r.stdout)
        link = "https://github.com/OWNER/crew" + "kit-dev/pull/7"
        r, _ = export(repo({"a.md": f"See {link}.\n"}))
        self.assertEqual(r.returncode, 1)

    def test_a_dev_repo_link_inside_a_drop_region_is_fine(self):
        link = "https://github.com/OWNER/crew" + "kit/pull/7"
        r, out = export(repo({"a.md": f"Kept.\n<!-- export:drop-start -->\n[#7]({link})\n<!-- export:drop-end -->\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((out / "a.md").read_text(), "Kept.\n")

    def test_files_marked_export_ignore_are_left_out(self):
        r, out = export(repo({".gitattributes": "docs/plans/ export-ignore\nprivate.md export-ignore\n",
                              "docs/plans/plan.md": "internal\n", "private.md": "internal\n", "a.md": "kept\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((out / "a.md").exists())
        self.assertFalse((out / "private.md").exists())
        self.assertFalse((out / "docs" / "plans").exists())

    def test_a_plain_text_lesson_citation_fails_the_export(self):
        for text in ("Not adopted yet (lesson 65).\n", "As lessons 3 and 4 say.\n"):
            r, _ = export(repo({"a.md": text}))
            self.assertEqual(r.returncode, 1, text)
            self.assertIn("a.md", r.stdout)

    def test_the_word_lesson_without_a_number_is_fine(self):
        r, _ = export(repo({"a.md": "A lesson learned the hard way.\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_local_clone_path_fails_the_export(self):
        # Built at runtime, so this file holds no such path itself.
        for path in ("<home>/" + "projects/my-clone/lib/checks.py", "<home>/" + "projects/x/tests/a.bats"):
            r, _ = export(repo({"a.txt": f"File \"{path}\", line 3\n"}))
            self.assertEqual(r.returncode, 1, path)
            self.assertIn("a.txt", r.stdout)

    def test_the_tool_itself_may_describe_the_clone_path_form(self):
        r, _ = export(repo({"tools/export.py": "# fails on <home>/" + "projects/<clone>\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_repo_and_home_placeholders_are_fine(self):
        r, _ = export(repo({"a.txt": "File \"<repo>/lib/checks.py\"; config in <home>/.config/x\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_an_unclosed_drop_marker_fails_the_export(self):
        r, _ = export(repo({"a.md": "<!-- export:drop-start -->\nkept?\n"}))
        self.assertEqual(r.returncode, 1)

    def test_it_prints_the_export_tree_hash_and_it_is_deterministic(self):
        src = repo({"skills/a/SKILL.md": SKILL, "README.md": README})
        r1, out1 = export(src)
        r2, out2 = export(src)
        h1 = [l for l in r1.stdout.splitlines() if l.startswith("export tree:")]
        h2 = [l for l in r2.stdout.splitlines() if l.startswith("export tree:")]
        self.assertEqual(len(h1), 1, r1.stdout)
        self.assertEqual(h1, h2)
        tree = h1[0].split()[-1]
        self.assertRegex(tree, r"^[0-9a-f]{40}$")
        got = subprocess.run(["git", "-C", str(out1), "write-tree"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(got, tree)

    def test_a_non_empty_out_dir_is_refused(self):
        src = repo({"a.md": "x\n"})
        out = pathlib.Path(tempfile.mkdtemp())
        (out / "stray").write_text("x")
        r = subprocess.run([sys.executable, str(EXPORT), "--repo", str(src), "--ref", "HEAD", "--out", str(out)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def test_prose_about_the_markers_is_fine_but_an_inline_marker_fails(self):
        r, out = export(repo({"a.md": "Prose marked `export:drop` is dropped.\n"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r, _ = export(repo({"b.md": "text <!-- export:drop-start --> more\n"}))
        self.assertEqual(r.returncode, 1)

    def test_the_tool_and_its_lint_may_name_the_placeholder(self):
        src = repo({"tools/export.py": f"# handles {URL} citations\n", "tools/lint-skills.py": f"X = ('{URL}',)\n"})
        r, _ = export(src)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
