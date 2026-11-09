"""Tests for tools/token-prefix-scan.py.

The scanner is the export checklist's second net for provider token prefixes that gitleaks's
default ruleset lacks (Tailscale for one). Every token below is built at run time from pieces,
so this file holds no literal the scanner would match, and no test prints a token value.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCAN = ROOT / "tools" / "token-prefix-scan.py"

HEX = "0123456789abcdef"
ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
URLSAFE = ALNUM + "_-"


def fill(n, alphabet):
    return (alphabet * (n // len(alphabet) + 1))[:n]


# id -> (list of (sample builder, shorter builder)). The builder takes no argument; the "short"
# one is a near miss: the prefix with a body one char too short.
def simple(prefix, alphabet, n):
    return (lambda: prefix + fill(n, alphabet), lambda: prefix + fill(n - 1, alphabet))


CASES = {
    "tailscale": [simple("tsk" + "ey-auth-", ALNUM, 12), simple("tsk" + "ey-api-", ALNUM, 12)],
    "github-classic": [simple(p + "_", ALNUM, 36) for p in ("gh" + "p", "gh" + "o", "gh" + "u", "gh" + "s", "gh" + "r")],
    "github-pat": [simple("github" + "_pat_", URLSAFE.replace("-", ""), 82)],
    "gitlab": [simple("glp" + "at-", URLSAFE, 20)],
    "slack-token": [simple("xo" + "x" + c + "-", ALNUM, 20) for c in "abposr"],
    "slack-app": [simple("xa" + "pp-", ALNUM, 20)],
    "npm": [simple("np" + "m_", ALNUM, 36)],
    "pypi": [simple("py" + "pi-AgEI", URLSAFE, 50)],
    "openai": [simple("sk-" + "proj-", URLSAFE, 40), simple("sk-" + "svcacct-", URLSAFE, 40)],
    "anthropic": [simple("sk-" + "ant-", URLSAFE, 80)],
    "stripe": [simple("sk_" + "live_", ALNUM, 24), simple("rk_" + "live_", ALNUM, 24)],
    "huggingface": [simple("h" + "f_", ALPHA, 34)],
    "digitalocean": [simple(p + "_v1_", HEX, 64) for p in ("do" + "p", "do" + "o", "do" + "r")],
    "doppler": [simple("d" + "p.pt.", ALNUM, 43)],
    "linear": [simple("lin" + "_api_", ALNUM, 40)],
    "shopify": [simple("sh" + p + "_", HEX, 32) for p in ("pat", "pss", "pca", "ppa")],
    "sendgrid": [simple("S" + "G.", URLSAFE, 66)],
    "postman": [(lambda: "PM" + "AK-" + fill(24, HEX) + "-" + fill(34, HEX),
                 lambda: "PM" + "AK-" + fill(24, HEX) + "-" + fill(33, HEX))],
    "pulumi": [simple("pu" + "l-", HEX, 40)],
    "planetscale": [simple("pscale" + "_tkn_", URLSAFE, 32)],
    "grafana-service-account": [(lambda: "gl" + "sa_" + fill(32, ALNUM) + "_" + fill(8, HEX),
                                 lambda: "gl" + "sa_" + fill(32, ALNUM) + "_" + fill(7, HEX))],
    "grafana-cloud": [simple("gl" + "c_", ALNUM, 32)],
    "vault": [simple("h" + "vs.", URLSAFE, 90), simple("h" + "vb.", URLSAFE, 90)],
    "sourcegraph": [simple("sg" + "p_", HEX, 40),
                    (lambda: "sg" + "p_" + fill(16, HEX) + "_" + fill(40, HEX),
                     lambda: "sg" + "p_" + fill(16, HEX) + "_" + fill(39, HEX))],
    "prefect": [simple("pn" + "u_", ALNUM, 36)],
    "rubygems": [simple("ruby" + "gems_", HEX, 48)],
    "databricks": [simple("da" + "pi", HEX, 32)],
}

# Prefix-only prose must not fire either.
PREFIX_ONLY = [
    "gh" + "p_", "gh" + "o_", "github" + "_pat_", "glp" + "at-", "xo" + "xb-", "xa" + "pp-", "np" + "m_",
    "py" + "pi-AgEI", "sk-" + "proj-", "sk-" + "ant-", "sk_" + "live_", "h" + "f_", "do" + "p_v1_",
    "d" + "p.pt.", "lin" + "_api_", "sh" + "pat_", "S" + "G.", "PM" + "AK-", "pu" + "l-",
    "pscale" + "_tkn_", "gl" + "sa_", "gl" + "c_", "h" + "vs.", "sg" + "p_", "pn" + "u_", "ruby" + "gems_",
    "da" + "pi", "tsk" + "ey-", "tsk" + "ey-auth-",
]

CONFIG = "paths-ignore:\n  - \"tools/holder-image-test.sh\"\n  - \"tests/crewkit-holder.bats\"\n"


def scan(directory, *extra):
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    return subprocess.run([sys.executable, "-I", str(SCAN), str(directory), *extra],
                          capture_output=True, text=True, env=env)


class Tree(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def put(self, rel, text, binary=False):
        p = self.dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if binary:
            p.write_bytes(text)
        else:
            p.write_text(text, encoding="utf-8")
        return p

    def config(self, text):
        self.put(".github/secret_scanning.yml", text)


class EveryRule(Tree):
    def test_one_hit_per_rule_and_prefix(self):
        for rule, samples in CASES.items():
            for i, (hit, _short) in enumerate(samples):
                with self.subTest(rule=rule, sample=i):
                    d = tempfile.TemporaryDirectory()
                    self.addCleanup(d.cleanup)
                    token = hit()
                    pathlib.Path(d.name, "f.txt").write_text("a\nkey = " + token + "\n", encoding="utf-8")
                    r = scan(d.name)
                    self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                    self.assertIn(f"f.txt:2: {rule} ({len(token)} chars)", r.stdout.splitlines())
                    self.assertNotIn(token, r.stdout + r.stderr)

    def test_a_body_one_char_short_does_not_fire(self):
        for rule, samples in CASES.items():
            for i, (_hit, short) in enumerate(samples):
                with self.subTest(rule=rule, sample=i):
                    d = tempfile.TemporaryDirectory()
                    self.addCleanup(d.cleanup)
                    pathlib.Path(d.name, "f.txt").write_text("key = " + short() + "\n", encoding="utf-8")
                    r = scan(d.name)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_prefix_named_in_prose_does_not_fire(self):
        for prefix in PREFIX_ONLY:
            with self.subTest(prefix=len(prefix)):
                d = tempfile.TemporaryDirectory()
                self.addCleanup(d.cleanup)
                pathlib.Path(d.name, "f.md").write_text(f"Tokens start with `{prefix}` and a body.\n", encoding="utf-8")
                self.assertEqual(scan(d.name).returncode, 0)

    def test_the_two_known_fixture_shapes_match_tailscale(self):
        for n in (24, 28):
            with self.subTest(length=n):
                token = ("tsk" + "ey-auth-" + fill(n - 11, ALNUM)).replace("A", "a", 1)
                self.assertEqual(len(token), n)
                self.put(f"{n}.sh", f"x={token}\n")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(r.stdout.splitlines()), 3)  # two hits and the summary

    def test_a_word_char_before_the_prefix_does_not_fire(self):
        self.put("f.txt", "x" + "np" + "m_" + fill(36, ALNUM) + "\n")
        self.assertEqual(scan(self.dir).returncode, 0)

    def test_two_hits_on_one_line_are_both_reported(self):
        a = "np" + "m_" + fill(36, ALNUM)
        b = "h" + "f_" + fill(34, ALPHA)
        self.put("f.txt", f"{a} {b}\n")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertIn("f.txt:1: npm (40 chars)", r.stdout)
        self.assertIn("f.txt:1: huggingface (37 chars)", r.stdout)


    def test_two_hits_of_one_rule_on_one_line_are_both_reported(self):
        a = "np" + "m_" + fill(36, ALNUM)
        self.put("f.txt", f"{a} {a}\n")
        r = scan(self.dir)
        self.assertEqual(r.stdout.count("f.txt:1: npm (40 chars)"), 2, r.stdout)


class Output(Tree):
    def test_clean_tree_exit_0_and_says_so(self):
        self.put("a.txt", "nothing here\n")
        self.put("sub/b.txt", "or here\n")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "token-prefix-scan: 2 file(s), clean")

    def test_hit_exit_1_with_path_line_rule_and_length_only(self):
        token = "sk-" + "ant-" + fill(100, URLSAFE)
        self.put("deep/dir/x.env", "\n\nK=" + token + "\n")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.splitlines()[0], f"deep/dir/x.env:3: anthropic ({len(token)} chars)")
        self.assertNotIn(token[:12], r.stdout + r.stderr)
        self.assertNotIn("clean", r.stdout)

    def test_usage_errors_exit_2(self):
        for argv in ([], ["a", "b"]):
            r = subprocess.run([sys.executable, "-I", str(SCAN), *argv], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, argv)
        f = self.put("file.txt", "x\n")
        for arg in (self.dir / "missing", f):
            r = scan(arg)
            self.assertEqual(r.returncode, 2, arg)
            self.assertIn("usage: token-prefix-scan.py DIR", r.stderr)
            self.assertNotIn("unreadable", r.stdout)

    def test_the_removed_exempt_option_is_a_usage_error(self):
        self.put("a.txt", "x\n")
        self.assertEqual(scan(self.dir, "--exempt", "x").returncode, 2)


class Skips(Tree):
    def test_dot_git_is_skipped(self):
        token = "np" + "m_" + fill(36, ALNUM)
        self.put(".git/config", token + "\n")
        self.put("a.txt", "ok\n")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("1 file(s)", r.stdout)

    def test_binary_files_are_skipped(self):
        token = "np" + "m_" + fill(36, ALNUM)
        self.put("blob.bin", b"\x00\x01" + token.encode() + b"\n", binary=True)
        r = scan(self.dir)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_a_symlink_is_not_followed(self):
        token = "np" + "m_" + fill(36, ALNUM)
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        pathlib.Path(outside.name, "t.txt").write_text(token + "\n", encoding="utf-8")
        (self.dir / "link.txt").symlink_to(pathlib.Path(outside.name, "t.txt"))
        self.assertEqual(scan(self.dir).returncode, 0)

    def test_non_utf8_text_is_still_scanned(self):
        token = "np" + "m_" + fill(36, ALNUM)
        self.put("l1.txt", b"\xff\xfe caf\xe9 " + token.encode() + b"\n", binary=True)
        self.assertEqual(scan(self.dir).returncode, 1)


class Exemptions(Tree):
    def hit_file(self, rel):
        token = "tsk" + "ey-auth-" + fill(17, ALNUM)
        self.put(rel, "a\nb\nc=" + token + "\n")
        return token

    def test_a_listed_path_is_reported_as_exempt_and_passes(self):
        self.config(CONFIG)
        token = self.hit_file("tools/holder-image-test.sh")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("exempt: tools/holder-image-test.sh:3: tailscale", r.stdout.splitlines())
        self.assertNotIn(token, r.stdout + r.stderr)
        self.assertIn("clean", r.stdout)

    def test_a_hit_outside_the_listed_paths_still_fails_with_the_file_present(self):
        self.config(CONFIG)
        self.hit_file("tools/holder-image-test.sh")
        self.hit_file("tools/other.sh")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("tools/other.sh:3: tailscale (28 chars)", r.stdout.splitlines())
        self.assertIn("exempt: tools/holder-image-test.sh:3: tailscale", r.stdout.splitlines())

    def test_an_absent_file_exempts_nothing(self):
        self.hit_file("tools/holder-image-test.sh")
        self.assertEqual(scan(self.dir).returncode, 1)

    def test_the_path_must_match_whole_not_by_suffix_or_prefix(self):
        self.config(CONFIG)
        self.hit_file("x/tools/holder-image-test.sh")
        self.hit_file("tools/holder-image-test.sh.bak")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(sum(1 for l in r.stdout.splitlines() if l.startswith("exempt:")), 0)

    def test_globs(self):
        self.config('paths-ignore:\n  - "docs/*.md"\n  - "gen/**"\n')
        self.hit_file("docs/a.md")
        self.hit_file("docs/deep/b.md")
        self.hit_file("gen/x/y/z.txt")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 1)
        lines = r.stdout.splitlines()
        self.assertIn("exempt: docs/a.md:3: tailscale", lines)
        self.assertIn("exempt: gen/x/y/z.txt:3: tailscale", lines)
        self.assertIn("docs/deep/b.md:3: tailscale (28 chars)", lines)

    def test_a_comment_and_blank_lines_are_allowed(self):
        self.config("# the owner signs off on changes\n\npaths-ignore:\n  - \"a.txt\"\n")
        self.hit_file("a.txt")
        self.assertEqual(scan(self.dir).returncode, 0)

    def test_a_config_that_is_not_text_exits_2(self):
        self.put(".github/secret_scanning.yml", b"\xff\xfe\x00", binary=True)
        self.hit_file("a")
        self.assertEqual(scan(self.dir).returncode, 2)

    def test_malformed_or_extra_content_exits_2(self):
        bad = {
            "extra key": CONFIG + "other-key:\n  - \"x\"\n",
            "wrong key": "paths:\n  - \"a\"\n",
            "no items": "paths-ignore:\n",
            "unquoted item": "paths-ignore:\n  - a.txt\n",
            "single quotes": "paths-ignore:\n  - 'a.txt'\n",
            "stray text": CONFIG + "junk\n",
            "empty file": "",
            "item before key": "  - \"a\"\npaths-ignore:\n",
            "two keys": CONFIG + CONFIG,
            "empty glob": "paths-ignore:\n  - \"\"\n",
            "trailing text on item": "paths-ignore:\n  - \"a\" # why\n",
        }
        for name, text in bad.items():
            with self.subTest(name):
                self.config(text)
                self.hit_file("a")
                r = scan(self.dir)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertNotIn("clean", r.stdout)


    def test_the_list_is_indented_with_spaces_only(self):
        for name, text in {"tab": "paths-ignore:\n\t- \"a\"\n", "tab after spaces": "paths-ignore:\n \t- \"a\"\n",
                           "no indent": "paths-ignore:\n- \"a\"\n"}.items():
            with self.subTest(name):
                self.config(text)
                self.hit_file("a")
                r = scan(self.dir)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertNotIn("clean", r.stdout)
        self.config("paths-ignore:\n    - \"a\"\n")
        self.hit_file("a")
        self.assertEqual(scan(self.dir).returncode, 0)

    def test_a_backslash_in_a_glob_exits_2(self):
        for glob in ("a\\\\b", "a\\*", "\\u0061", "dir\\/x"):
            with self.subTest(glob):
                self.config("paths-ignore:\n  - \"" + glob + "\"\n")
                self.hit_file("a")
                r = scan(self.dir)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertNotIn("clean", r.stdout)


class Unreadable(Tree):
    """The scan fails closed: a file or directory it can't read is counted, printed as
    `unreadable: path`, and exits 2, so a token behind a mode 000 file is not a silent pass."""

    def setUp(self):
        super().setUp()
        if os.geteuid() == 0:
            self.skipTest("root reads mode 000 files")

    def lock(self, path):
        path.chmod(0o000)
        self.addCleanup(lambda: path.chmod(0o700))

    def test_an_unreadable_file_exits_2_and_is_named(self):
        f = self.put("docs/secret.txt", "x\n")
        self.lock(f)
        r = scan(self.dir)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("unreadable: docs/secret.txt", r.stdout.splitlines())
        self.assertNotIn("clean", r.stdout)

    def test_an_unreadable_directory_exits_2_and_is_named(self):
        self.put("locked/a.txt", "x\n")
        self.lock(self.dir / "locked")
        r = scan(self.dir)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("unreadable: locked", r.stdout.splitlines())
        self.assertNotIn("clean", r.stdout)

    def test_hits_are_still_reported_beside_an_unreadable_file(self):
        token = "tsk" + "ey-auth-" + fill(17, ALNUM)
        self.put("a.txt", "k=" + token + "\n")
        self.lock(self.put("b.txt", "x\n"))
        r = scan(self.dir)
        self.assertEqual(r.returncode, 2)
        self.assertIn("a.txt:1: tailscale (28 chars)", r.stdout)
        self.assertIn("unreadable: b.txt", r.stdout)
        self.assertNotIn(token, r.stdout + r.stderr)


class RepoOwnFiles(unittest.TestCase):
    def test_the_repos_secret_scanning_yml_lists_exactly_the_two_fixtures(self):
        text = (ROOT / ".github" / "secret_scanning.yml").read_text(encoding="utf-8")
        self.assertEqual(text, CONFIG)

    def test_the_file_is_not_export_ignored(self):
        if not (ROOT / ".git").exists():
            self.skipTest("not a git checkout (the export has no .git)")
        r = subprocess.run(["git", "-C", str(ROOT), "check-attr", "export-ignore", "--", ".github/secret_scanning.yml"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), ".github/secret_scanning.yml: export-ignore: unspecified")

    def test_the_repos_tracked_files_hit_only_the_two_exempt_fixtures(self):
        # The owner approved an exemption for exactly these two fixtures (.github/secret_scanning.yml).
        # A change to this expected list needs the owner's ruling; it records today's state.
        if not (ROOT / ".git").exists():
            self.skipTest("not a git checkout (the export has no .git)")
        listing = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "-co", "--exclude-standard"], capture_output=True)
        if listing.returncode != 0:
            self.skipTest("git ls-files failed")
        with tempfile.TemporaryDirectory() as tmp:
            for rel in listing.stdout.decode().split("\0"):
                src = ROOT / rel
                if rel and src.is_file() and not src.is_symlink():
                    dst = pathlib.Path(tmp, rel)
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(src.read_bytes())
            r = scan(tmp)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        hits = sorted(l for l in r.stdout.splitlines() if ": " in l and not l.startswith("token-prefix-scan"))
        self.assertEqual(hits, [
            "exempt: tests/crewkit-holder.bats:35: tailscale",
            "exempt: tools/holder-image-test.sh:39: tailscale",
        ])


if __name__ == "__main__":
    unittest.main()
