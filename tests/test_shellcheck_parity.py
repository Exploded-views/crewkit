"""The local Linux gate's shellcheck step checks what ci.yml's shellcheck job checks.

tools/linux-gate.sh keeps its own list (the gate runs its trusted copy, never a list read from the
branch under test), so this test is what stops the two lists drifting apart. It extracts each
shellcheck command from ci.yml's `shell` job and from linux-gate.sh's run_native: the dialect
(-s), whether -x is set, and the set of file arguments (order is ignored; --norc is the gate's
own addition and is ignored). It also compares the mapfile lines that build the plugin and
libexec arrays. A path dropped or added on either side fails, and the failure names it.
"""
import pathlib
import re
import shlex
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CI = ROOT / ".github" / "workflows" / "ci.yml"
GATE = ROOT / "tools" / "linux-gate.sh"


def ci_region(text):
    """The lines of ci.yml's `shell` job."""
    out, inside = [], False
    for line in text.splitlines():
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            inside = m.group(1) == "shell"
            continue
        if inside:
            out.append(line)
    return "\n".join(out)


def gate_region(text):
    """The body of linux-gate.sh's run_native function."""
    m = re.search(r"^run_native\(\) \{\n(.*?)^\}", text, re.S | re.M)
    return m.group(1) if m else ""


VALUE_FLAGS = {"-S", "-e", "-i", "-o", "-P", "-W", "-C"}   # options that take a value (-s is the dialect)


WORD = r"(?<![\w./-])shellcheck(?![\w./-])"


def scan(region):
    """(line, [words after `shellcheck` of each command parsed on it], how many shellcheck words the line
    holds) for every line that has one. A command starts a line or follows &&, || ; or |. Comments, step
    names, `printf` labels and the gate's `limited shellcheck` label hold none that count."""
    for line in region.splitlines():
        line = re.sub(r"^\s*(-\s+)?(run:\s*\|?\s*)?", "", line)
        if line.startswith("#") or line.startswith("name:") or line.startswith("printf "):
            continue
        line = re.sub(r"\s#(\s.*)?$", "", line)   # a trailing comment
        words = []
        for seg in re.split(r"&&|\|\||;|\|", line):
            m = re.match(r"\s*shellcheck(?:\s+(.*))?$", seg)
            if m:
                rest = (m.group(1) or "").split("'")[0]
                try:
                    words.append(shlex.split(rest))
                except ValueError:
                    words.append(rest.split())
        count = len(re.findall(WORD, line.replace("limited shellcheck bash -c", "")))
        if count:
            yield line.strip(), words, count


def segments(region):
    for _, words, _ in scan(region):
        yield from words


def unparsed(region):
    """The lines holding more shellcheck words than commands parsed (find -exec, xargs, timeout, if !, $(...))."""
    return [line for line, words, count in scan(region) if count > len(words)]


def commands(region):
    """{(dialect, x): set of file arguments} for every shellcheck command in region."""
    found = {}
    for words in segments(region):
        dialect, x, paths, i = "", False, set(), 0
        while i < len(words):
            w = words[i]
            if w == "--norc":
                pass
            elif w == "-x":
                x = True
            elif w == "-s" and i + 1 < len(words):
                dialect = words[i + 1]
                i += 1
            elif w in VALUE_FLAGS and i + 1 < len(words):
                dialect += f" {w} {words[i + 1]}"
                i += 1
            elif w.startswith("-"):
                dialect += " " + w
            else:
                paths.add(w)
            i += 1
        found.setdefault((dialect, x), set()).update(paths)
    return found


def arrays(region):
    """{array name: its mapfile source command, quotes and the || true tail dropped}."""
    found = {}
    for m in re.finditer(r"mapfile -t (\w+) < <\((.*?)\)", region):
        cmd = re.sub(r"\s*2>/dev/null", "", m.group(2))
        cmd = re.sub(r"\s*\|\|\s*true\s*$", "", cmd).replace('"', "").replace("'", "")
        found[m.group(1)] = cmd.strip()
    return found


def drift(ci_text, gate_text):
    """A list of lines naming each difference between the two shellcheck lists (empty if none)."""
    problems = []
    c, g = commands(ci_region(ci_text)), commands(gate_region(gate_text))
    for name, region in (("ci.yml", ci_region(ci_text)), ("linux-gate.sh", gate_region(gate_text))):
        for line in unparsed(region):
            problems.append(f"{name}: unparsed shellcheck invocation (shellcheck is not the first word of a command): {line}")
    if not c:
        problems.append("no shellcheck command found in ci.yml's shell job")
    if not g:
        problems.append("no shellcheck command found in linux-gate.sh's run_native")
    for key in sorted(set(c) | set(g)):
        label = f"shellcheck{' -s ' + key[0] if key[0] else ''}{' -x' if key[1] else ''}"
        if key not in g:
            problems.append(f"{label}: in ci.yml, not run by linux-gate.sh" + (f" ({', '.join(sorted(c[key]))})" if c[key] else ""))
        elif key not in c:
            problems.append(f"{label}: run by linux-gate.sh, not in ci.yml" + (f" ({', '.join(sorted(g[key]))})" if g[key] else ""))
        else:
            for p in sorted(c[key] - g[key]):
                problems.append(f"{label}: {p} is checked by ci.yml, missing from linux-gate.sh")
            for p in sorted(g[key] - c[key]):
                problems.append(f"{label}: {p} is checked by linux-gate.sh, missing from ci.yml")
    ca, ga = arrays(ci_region(ci_text)), arrays(gate_region(gate_text))
    for name in sorted(set(ca) | set(ga)):
        if ca.get(name) != ga.get(name):
            problems.append(f"array {name}: ci.yml builds it with {ca.get(name)!r}, linux-gate.sh with {ga.get(name)!r}")
    return problems


CI_FIXTURE = """jobs:
  lint:
    steps:
      - run: shellcheck lint-only.sh
  shell:
    steps:
      - run: |
          mapfile -t plugin_sh < <(grep -l '^#!/usr/bin/env bash' plugins/crew-*/bin/* 2>/dev/null || true)
          shellcheck -x a.sh b.sh "${plugin_sh[@]}"
          shellcheck -s sh shim.sh
          shellcheck -s bash t/*.bash
  other:
    steps:
      - run: shellcheck -x elsewhere.sh
"""

GATE_FIXTURE = """before() { :; }
run_native() {
  limited shellcheck bash -c 'mapfile -t plugin_sh < <(grep -l "^#!/usr/bin/env bash" plugins/crew-*/bin/* 2>/dev/null || true)
    shellcheck --norc -x b.sh a.sh "${plugin_sh[@]}" &&
    shellcheck --norc -s sh shim.sh &&
    shellcheck --norc -s bash t/*.bash' > "$out/shellcheck.log" 2>&1 || return 0
}
after() { shellcheck -x not-here.sh; }
"""


class Parity(unittest.TestCase):
    def test_the_gate_checks_what_ci_checks(self):
        problems = drift(CI.read_text(encoding="utf-8"), GATE.read_text(encoding="utf-8"))
        self.assertEqual(problems, [], "\n" + "\n".join(problems))

    def test_the_real_files_yield_the_three_commands(self):
        for text, region in ((CI, ci_region), (GATE, gate_region)):
            found = commands(region(text.read_text(encoding="utf-8")))
            self.assertEqual(sorted(found), [("", True), ("bash", False), ("sh", False)], str(text))
        ci = commands(ci_region(CI.read_text(encoding="utf-8")))
        self.assertIn("push-gate/shim.sh", ci[("sh", False)])
        self.assertIn("libexec/ck/*.sh", ci[("bash", False)])

    def test_the_fixtures_agree_in_any_argument_order(self):
        self.assertEqual(drift(CI_FIXTURE, GATE_FIXTURE), [])

    def test_a_dropped_path_is_named(self):
        gate = GATE_FIXTURE.replace(" t/*.bash", "")
        self.assertEqual(drift(CI_FIXTURE, gate), ["shellcheck -s bash: t/*.bash is checked by ci.yml, missing from linux-gate.sh"])

    def test_an_added_path_is_named(self):
        gate = GATE_FIXTURE.replace("shim.sh", "shim.sh extra.sh")
        self.assertEqual(drift(CI_FIXTURE, gate), ["shellcheck -s sh: extra.sh is checked by linux-gate.sh, missing from ci.yml"])

    def test_a_dropped_command_is_named(self):
        gate = GATE_FIXTURE.replace("    shellcheck --norc -s sh shim.sh &&\n", "")
        self.assertEqual(drift(CI_FIXTURE, gate), ["shellcheck -s sh: in ci.yml, not run by linux-gate.sh (shim.sh)"])

    def test_a_dialect_change_is_a_drift(self):
        gate = GATE_FIXTURE.replace("-s sh shim.sh", "-s bash shim.sh")
        problems = drift(CI_FIXTURE, gate)
        self.assertIn("shellcheck -s sh: in ci.yml, not run by linux-gate.sh (shim.sh)", problems)

    def test_a_dropped_x_flag_is_a_drift(self):
        gate = GATE_FIXTURE.replace("--norc -x b.sh", "--norc b.sh")
        self.assertTrue(drift(CI_FIXTURE, gate))

    def test_a_changed_array_source_is_named(self):
        gate = GATE_FIXTURE.replace("plugins/crew-*/bin/*", "plugins/crew-*/bin/x*")
        problems = drift(CI_FIXTURE, gate)
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("array plugin_sh:"))

    def test_a_command_without_a_leading_flag_is_seen(self):
        # A fourth ci.yml command whose first argument is a file, not a flag, is not invisible.
        ci = CI_FIXTURE.replace("          shellcheck -s bash t/*.bash\n", "          shellcheck -s bash t/*.bash\n          shellcheck libexec/new-tool\n")
        problems = drift(ci, GATE_FIXTURE)
        self.assertTrue(any("libexec/new-tool" in p for p in problems), problems)
        ci = CI_FIXTURE.replace("          shellcheck -s bash t/*.bash\n", "          shellcheck -s bash t/*.bash\n          shellcheck extra.sh -x\n")
        self.assertTrue(any("extra.sh" in p for p in drift(ci, GATE_FIXTURE)))

    def test_a_flagless_command_in_the_gate_is_seen_too(self):
        gate = GATE_FIXTURE.replace("    shellcheck --norc -s sh shim.sh &&\n", "    shellcheck --norc -s sh shim.sh &&\n    shellcheck --norc only-here.sh &&\n")
        self.assertTrue(any("only-here.sh" in p for p in drift(CI_FIXTURE, gate)))

    def test_labels_comments_and_step_names_are_not_commands(self):
        ci = CI_FIXTURE.replace("      - run: |\n", "      - name: shellcheck (preinstalled)\n        run: |\n          # shellcheck is on the runner\n")
        gate = GATE_FIXTURE.replace("  limited shellcheck bash -c", "  # shellcheck disable=SC2016\n  limited shellcheck bash -c")
        self.assertEqual(drift(ci, gate), [])

    def test_an_option_value_is_not_a_path(self):
        ci = CI_FIXTURE.replace("shellcheck -x a.sh", "shellcheck -x -S warning a.sh")
        gate = GATE_FIXTURE.replace("--norc -x b.sh", "--norc -x -S warning b.sh")
        self.assertEqual(drift(ci, gate), [])
        problems = drift(ci, GATE_FIXTURE)
        self.assertFalse(any("warning is checked" in p for p in problems), problems)

    FORMS = [
        "find libexec/ck -name '*.sh' -exec shellcheck -s bash {} +",
        "xargs shellcheck < list",
        "timeout 60 shellcheck new.sh",
        "if ! shellcheck new.sh; then exit 1; fi",
        'echo "$(shellcheck new.sh)"',
    ]

    def test_a_shellcheck_that_is_not_the_first_word_is_reported_in_ci(self):
        for form in self.FORMS:
            with self.subTest(form=form):
                ci = CI_FIXTURE.replace("          shellcheck -s bash t/*.bash\n", "          shellcheck -s bash t/*.bash\n          " + form + "\n")
                problems = drift(ci, GATE_FIXTURE)
                self.assertTrue(any("unparsed shellcheck invocation" in p and form in p for p in problems), problems)

    def test_a_shellcheck_that_is_not_the_first_word_is_reported_in_the_gate(self):
        for form in self.FORMS:
            with self.subTest(form=form):
                gate = GATE_FIXTURE.replace("    shellcheck --norc -s sh shim.sh &&\n", "    shellcheck --norc -s sh shim.sh &&\n    " + form + " &&\n")
                problems = drift(CI_FIXTURE, gate)
                self.assertTrue(any("unparsed shellcheck invocation" in p and form in p for p in problems), problems)

    def test_the_real_files_have_no_unparsed_invocation(self):
        for p in drift(CI.read_text(encoding="utf-8"), GATE.read_text(encoding="utf-8")):
            self.assertNotIn("unparsed", p)

    def test_a_trailing_comment_is_not_a_path(self):
        ci = CI_FIXTURE.replace("shellcheck -s sh shim.sh", "shellcheck -s sh shim.sh  # the shim is sh")
        self.assertEqual(drift(ci, GATE_FIXTURE), [])

    def test_other_jobs_and_other_functions_do_not_count(self):
        # lint-only.sh (another ci job), elsewhere.sh and not-here.sh (outside run_native) never appear.
        self.assertEqual(drift(CI_FIXTURE, GATE_FIXTURE), [])
        self.assertNotIn("elsewhere.sh", commands(ci_region(CI_FIXTURE)).get(("", True), set()))
        self.assertNotIn("not-here.sh", commands(gate_region(GATE_FIXTURE)).get(("", True), set()))


if __name__ == "__main__":
    unittest.main()
