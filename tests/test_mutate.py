"""Tests for tools/mutate.py, the generic mutation runner."""
import fcntl
import contextlib
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "tools" / "mutate.py"
sys.path.insert(0, str(SCRIPT.parent))
import mutate  # noqa: E402  (the pure helpers are tested directly)

TARGET = """#!/usr/bin/env bash
check() { [[ $1 -gt 10 ]] || return 1; echo ok; }
check "$1"
"""
SUITE = """#!/usr/bin/env bash
set -e
bash t.sh 11 >/dev/null
! bash t.sh 5 >/dev/null
"""


class Mutate(unittest.TestCase):
    def repo(self, mutants, suite=SUITE, target=TARGET, **spec_extra):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "t.sh").write_text(target)
        (d / "suite.sh").write_text(suite)
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
        subprocess.run(["git", "add", "."], cwd=d, check=True)
        spec = d / "m.json"
        spec.write_text(json.dumps({"target": "t.sh", "suite": ["bash", "suite.sh"], "mutants": mutants,
                                    **spec_extra}))
        return d, spec

    def env(self, lock, **extra):
        """The environment without any lock token, pointing mutate.py at LOCK."""
        e = {k: v for k, v in os.environ.items() if k not in ("CI", "GITHUB_ACTIONS") and not k.startswith("BITC")}
        e["CREWKIT_HEAVY_LOCK"] = str(lock)
        e["CREWKIT_HEAVY_LOCK_TEST"] = "1"
        e.update(extra)
        return e

    def test_the_outer_bitc_variables_are_not_passed_to_mutate(self):
        # The gate runs the suite inside a bitc job, which exports BITC_JOB, BITC_DIR and friends.
        with mock.patch.dict(os.environ, {"BITC_JOB": "cafe0001", "BITC_DIR": "/outer"}):
            e = self.env("/x/heavy.lock")
        self.assertEqual([k for k in e if k.startswith("BITC")], [])

    def run_tool(self, d, spec, hold=True, **extra):
        """Run mutate.py on SPEC; with HOLD, as a child that inherits a descriptor holding the lock
        (as `flock <lock> python3 tools/mutate.py ...` gives it)."""
        lock = d / "heavy.lock"
        fd = os.open(lock, os.O_RDWR | os.O_CREAT)
        try:
            if hold:
                fcntl.flock(fd, fcntl.LOCK_EX)
            return subprocess.run([sys.executable, str(SCRIPT), str(spec)], cwd=d, capture_output=True, text=True,
                                  pass_fds=(fd,) if hold else (), env=self.env(lock, **extra))
        finally:
            os.close(fd)

    def test_without_the_heavy_lock_it_refuses_and_runs_nothing(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        r = self.run_tool(d, spec, hold=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("heavy lock", r.stderr)
        self.assertIn("crew-heavy", r.stderr)
        self.assertNotIn("killed", r.stdout)

    def test_ci_is_no_way_round_a_guarded_host(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        self.assertEqual(self.run_tool(d, spec, hold=False, CI="true", GITHUB_ACTIONS="true").returncode, 1)

    def test_a_guarded_line_is_killed(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed", r.stdout)

    def test_a_survivor_fails_the_run(self):
        d, spec = self.repo([{"name": "harmless", "old": "echo ok", "new": "echo fine"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("SURVIVED", r.stdout)

    def test_an_old_string_that_isnt_unique_fails(self):
        d, spec = self.repo([{"name": "ambiguous", "old": "1", "new": "2"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NOT APPLIED", r.stdout)

    def test_a_mutant_that_doesnt_parse_is_invalid_not_killed(self):
        d, spec = self.repo([{"name": "broken", "old": "echo ok; }", "new": "echo ok; ( }"}])
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("INVALID", r.stdout)

    def test_a_symlink_to_the_target_runs_the_mutant(self):
        # The suite runs the target through a tracked symlink (as git hooks are): the copy must
        # keep it a link, or the suite runs an unmutated copy and every mutant survives.
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}],
                            suite=SUITE.replace("t.sh", "link.sh"))
        (d / "link.sh").symlink_to("t.sh")
        subprocess.run(["git", "add", "link.sh"], cwd=d, check=True)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed", r.stdout)

    def test_a_target_that_is_a_symlink_is_refused(self):
        # The mutant would be written through the link: into the real tree, if it is absolute.
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        (d / "link.sh").symlink_to(d / "t.sh")
        subprocess.run(["git", "add", "link.sh"], cwd=d, check=True)
        spec.write_text(spec.read_text().replace('"target": "t.sh"', '"target": "link.sh"'))
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("symlink", r.stdout)
        self.assertNotIn("killed", r.stdout)
        self.assertEqual((d / "t.sh").read_text(), TARGET)

    def test_an_absolute_link_into_the_repo_points_into_the_copy(self):
        # A copied absolute link would run the real, unmutated file: every mutant would survive.
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}],
                            suite=SUITE.replace("t.sh", "link.sh"))
        (d / "link.sh").symlink_to(d / "t.sh")
        subprocess.run(["git", "add", "link.sh"], cwd=d, check=True)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed", r.stdout)
        self.assertEqual((d / "t.sh").read_text(), TARGET)

    def test_a_link_that_leaves_the_tree_is_refused(self):
        for dest in ("../outside.sh", "/etc/hosts"):
            with self.subTest(dest=dest):
                d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
                (d / "out.sh").symlink_to(dest)
                subprocess.run(["git", "add", "out.sh"], cwd=d, check=True)
                r = self.run_tool(d, spec)
                self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                self.assertIn("out.sh", r.stdout)
                self.assertIn("leaves the tree", r.stdout)
                self.assertNotIn("killed", r.stdout)

    def test_a_failing_baseline_stops_everything(self):
        d, spec = self.repo([{"name": "x", "old": "echo ok", "new": "echo no"}], suite="exit 1\n")
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 1)
        self.assertIn("unmutated suite fails", r.stdout)

    def test_the_real_tree_is_never_changed(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        self.run_tool(d, spec)
        self.assertEqual((d / "t.sh").read_text(), TARGET)

    def test_multi_line_old_strings_work(self):
        target = TARGET.replace("check \"$1\"\n", "check \"$1\"\nexit $?\n")
        d, spec = self.repo([{"name": "two lines", "old": "check \"$1\"\nexit $?", "new": "exit 0"}], target=target)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


    # A bats file's own watchdog (BATS_TEST_TIMEOUT, as tests/watcher-injection.bats sets with
    # ${BATS_TEST_TIMEOUT:-120}) decides how long a hung mutant costs; mutate.py sets it short.
    WATCHDOG_SUITE = """#!/usr/bin/env bash
set -e
echo "${BATS_TEST_TIMEOUT:-unset}" >> seen
timeout "${BATS_TEST_TIMEOUT:-60}" bash t.sh 11 >/dev/null
! timeout "${BATS_TEST_TIMEOUT:-60}" bash t.sh 5 >/dev/null
"""

    def test_suites_get_a_short_bats_test_timeout_whatever_the_caller_set(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}],
                            suite=self.WATCHDOG_SUITE)
        seen = pathlib.Path(tempfile.mkdtemp()) / "seen"
        suite = (d / "suite.sh").read_text().replace(">> seen", f">> {seen}")
        (d / "suite.sh").write_text(suite)
        subprocess.run(["git", "add", "."], cwd=d, check=True)
        r = self.run_tool(d, spec, BATS_TEST_TIMEOUT="300")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # The baseline and the mutant both ran with the mutation-run default.
        self.assertEqual(seen.read_text().split(), ["45", "45"])
        seen.unlink()
        r = self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT="7")
        self.assertEqual(seen.read_text().split(), ["7", "7"])

    def test_a_bad_mutate_bats_test_timeout_is_usage(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        for bad in ("0", "soon", "-3", "1.5", ""):
            r = self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertIn("MUTATE_BATS_TEST_TIMEOUT", r.stderr)

    def test_a_hung_mutant_is_killed_at_the_short_limit_and_counts_as_killed(self):
        d, spec = self.repo([{"name": "hangs", "old": "echo ok;", "new": "sleep 600;"}], suite=self.WATCHDOG_SUITE)
        import time
        t0 = time.monotonic()
        r = self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT="2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed       hangs", r.stdout)
        # Not the file's own 60 s watchdog.
        self.assertLess(time.monotonic() - t0, 30)

    # Item 1 of the owner's issue: a per-mutant timeout.
    HANG = "echo $$ > {pidfile}; exec sleep 30;"

    def hanging_repo(self, **spec_extra):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "hangs", "old": "echo ok;", "new": self.HANG.format(pidfile=pidfile)}],
                            **spec_extra)
        return d, spec, pidfile

    def reap(self, pidfile):
        """Kill the recorded hung process (by exact pid) if the tool left it running."""
        try:
            pid = int(pidfile.read_text())
        except (OSError, ValueError):
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        os.kill(pid, signal.SIGKILL)
        return True

    def test_a_mutant_that_outlasts_mutant_timeout_is_a_timeout_not_a_kill(self):
        d, spec, pidfile = self.hanging_repo(mutant_timeout=2)
        t0 = time.monotonic()
        try:
            r = self.run_tool(d, spec)
        finally:
            left = self.reap(pidfile)
        took = time.monotonic() - t0
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("TIMEOUT      hangs (2 s)", r.stdout)
        self.assertNotIn("killed", r.stdout)
        self.assertIn("1 timed out", r.stdout)
        self.assertFalse(left, "the hung suite was left running")
        self.assertLess(took, 2 + 5)

    def test_a_suite_that_ignores_term_is_killed_after_two_seconds(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        stubborn = "echo $$ > %s; trap '' TERM; for i in $(seq 40); do sleep 1; done;" % pidfile
        d, spec = self.repo([{"name": "stubborn", "old": "echo ok;", "new": stubborn}], mutant_timeout=1)
        t0 = time.monotonic()
        try:
            r = self.run_tool(d, spec)
        finally:
            left = self.reap(pidfile)
        self.assertIn("TIMEOUT      stubborn (1 s)", r.stdout)
        self.assertFalse(left, "TERM was ignored and nothing sent KILL")
        self.assertLess(time.monotonic() - t0, 1 + 2 + 5)

    def test_a_timeout_run_fails_even_when_every_other_mutant_is_killed(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"},
                             {"name": "hangs", "old": "echo ok;", "new": self.HANG.format(pidfile=pidfile)}],
                            mutant_timeout=2)
        try:
            r = self.run_tool(d, spec)
        finally:
            self.reap(pidfile)
        self.assertEqual(r.returncode, 1)
        self.assertIn("killed       bound removed", r.stdout)
        self.assertIn("TIMEOUT      hangs", r.stdout)

    def test_the_default_mutant_timeout_comes_from_the_baseline(self):
        for secs, want in ((0.2, 60), (19.9, 60), (20, 60), (20.1, 61), (95, 285), (95.2, 286)):
            with self.subTest(baseline=secs):
                self.assertEqual(mutate.default_mutant_timeout(secs, 0), want)

    def test_the_default_mutant_timeout_leaves_room_for_two_watchdog_hits(self):
        self.assertEqual(mutate.default_mutant_timeout(0.2, 45), 60 + 90)
        self.assertEqual(mutate.default_mutant_timeout(95.2, 7), 286 + 14)

    def test_two_tests_that_hit_the_bats_watchdog_are_a_kill_not_a_timeout(self):
        # Each hung test costs the watchdog's 31 s; two of them (62 s) pass the 60 s floor, and the
        # default must still let that mutant end as a kill.
        suite = """#!/usr/bin/env bash
a=0
timeout "$BATS_TEST_TIMEOUT" bash t.sh 11 >/dev/null || a=1
timeout "$BATS_TEST_TIMEOUT" bash t.sh 11 >/dev/null || a=1
exit $a
"""
        d, spec = self.repo([{"name": "hangs two", "old": "echo ok;", "new": "sleep 600;"}], suite=suite)
        r = self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT="31")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("killed       hangs two", r.stdout)

    def test_a_bad_mutant_timeout_is_a_spec_error(self):
        for bad in (0, -5, 1.5, 2.0, "30", True, None, [3], 3601, 10 ** 30):
            with self.subTest(bad=bad):
                d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}],
                                    mutant_timeout=bad)
                r = self.run_tool(d, spec)
                self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                self.assertIn("mutant_timeout", r.stdout)
                self.assertNotIn("killed", r.stdout)

    def test_a_good_mutant_timeout_is_accepted(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}],
                            mutant_timeout=30)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # Item 2: every line is flushed, so a run stopped from outside leaves its lines. The hang
    # outlasts the wait by far, and the line must be read while mutate.py still runs: its exit
    # flushes too, so a line read after the exit proves nothing (a late wake under load did that).
    def test_lines_are_flushed_when_stdout_is_a_file(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"},
                             {"name": "hangs", "old": "echo ok;", "new": f"echo $$ > {pidfile}; exec sleep 300;"}],
                            mutant_timeout=120)
        lock = d / "heavy.lock"
        out = d / "out.log"
        fd = os.open(lock, os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            with open(out, "w") as f:
                p = subprocess.Popen([sys.executable, str(SCRIPT), str(spec)], cwd=d, stdout=f,
                                     stderr=subprocess.STDOUT, pass_fds=(fd,), env=self.env(lock))
                try:
                    deadline = time.monotonic() + 30
                    while "killed       bound removed" not in out.read_text() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    seen = out.read_text()
                    running = p.poll() is None
                finally:
                    p.send_signal(signal.SIGTERM)  # a background job's SIGINT may be ignored, and stays so
                    try:
                        p.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
                    self.reap(pidfile)
        finally:
            os.close(fd)
        self.assertTrue(running, "mutate.py ended before the line was read, so its exit may have flushed it")
        self.assertIn("killed       bound removed", seen)

    # Item 3: the first failing test, next to each kill.
    def test_first_failing_test_from_bats_tap(self):
        tap = "1..3\nok 1 fine\nnot ok 2 the guard refuses a bad head # in file x, line 3\nnot ok 3 later\n"
        self.assertEqual(mutate.first_failing(tap), "the guard refuses a bad head")

    def test_first_failing_test_from_unittest(self):
        out = ("..F\n====\nFAIL: test_b (tests.test_x.Case.test_b)\n----\nERROR: test_c (tests.test_x.Case.test_c)\n")
        self.assertEqual(mutate.first_failing(out), "tests.test_x.Case.test_b")
        old = "ERROR: test_c (tests.test_x.Case)\n"
        self.assertEqual(mutate.first_failing(old), "tests.test_x.Case.test_c")

    def test_first_failing_test_is_none_when_unparseable(self):
        self.assertIsNone(mutate.first_failing("boom\nexit 1\n"))
        self.assertIsNone(mutate.first_failing("ok 1 fine\n"))

    def test_first_failing_test_is_sanitised_and_capped(self):
        name = mutate.first_failing("not ok 1 \x1b[31mred\x07\x00 name\rx\n")
        self.assertEqual(name, "red namex")
        long = mutate.first_failing("not ok 1 " + "a" * 500 + "\n")
        self.assertEqual(len(long), 120)

    def test_a_kill_line_names_the_bats_test_that_caught_it(self):
        suite = SUITE.replace("set -e\n", "").replace("bash t.sh 11 >/dev/null\n",
                              "bash t.sh 11 >/dev/null || { echo '1..1'; echo 'not ok 1 accepts eleven # note'; exit 1; }\n")
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "return 1"}],
                            suite=suite)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("  killed       bound removed  [by: accepts eleven]\n", r.stdout)

    def test_a_kill_line_names_the_unittest_test_that_caught_it(self):
        suite = ("bash t.sh 11 >/dev/null || { echo 'FAIL: test_eleven (tests.test_t.Case.test_eleven)' >&2; exit 1; }\n")
        d, spec = self.repo([{"name": "m", "old": "echo ok;", "new": "exit 3;"}], suite=suite)
        r = self.run_tool(d, spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("  killed       m  [by: tests.test_t.Case.test_eleven]\n", r.stdout)

    def test_a_kill_without_a_parseable_test_has_no_by_part(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        r = self.run_tool(d, spec)
        self.assertIn("  killed       bound removed\n", r.stdout)
        self.assertNotIn("[by:", r.stdout)

    def test_a_hostile_test_name_cannot_inject_into_the_kill_line(self):
        suite = SUITE.replace("set -e\n", "").replace("bash t.sh 11 >/dev/null\n",
                              "bash t.sh 11 >/dev/null || { printf 'not ok 1 x\\033]0;pwned\\007 y\\n'; exit 1; }\n")
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "return 1"}],
                            suite=suite)
        r = self.run_tool(d, spec)
        self.assertNotIn("\x1b", r.stdout)
        self.assertNotIn("\x07", r.stdout)
        self.assertIn("[by: x y]", r.stdout)

    def test_the_largest_mutant_timeout_is_accepted(self):
        self.assertTrue(mutate.valid_mutant_timeout(3600))
        self.assertFalse(mutate.valid_mutant_timeout(3601))

    def test_ansi_sequences_are_removed_from_a_test_name(self):
        name = mutate.first_failing("not ok 1 a\x1b[1;31mb\x1b]8;;http://x\x07c\x1b]0;t\x1b\\d\x9b31me\n")
        self.assertEqual(name, "abcde")

    def test_every_unicode_other_and_separator_character_is_removed(self):
        for ch in ("\u202e", "\u2066", "\u200b", "\u2028", "\u2029", "\ue000", "\u0378", "\ud800", "\x7f", "\x85"):
            with self.subTest(ch=hex(ord(ch))):
                self.assertEqual(mutate.first_failing(f"not ok 1 a{ch}b\n"), "ab")

    # Signals: the suite lives in its own session, so mutate.py must end it itself.
    def start_tool(self, d, spec, tmp):
        lock = d / "heavy.lock"
        fd = os.open(lock, os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            return subprocess.Popen([sys.executable, str(SCRIPT), str(spec)], cwd=d, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, pass_fds=(fd,), env=self.env(lock, TMPDIR=str(tmp)))
        finally:
            os.close(fd)

    def wait_for(self, path):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if path.read_text().strip():
                    return
            except OSError:
                pass
            time.sleep(0.05)
        self.fail("the suite never started")

    def alive(self, pidfile):
        """Whether the recorded process is still there (it gets a moment to go)."""
        pid = int(pidfile.read_text())
        for _ in range(40):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            time.sleep(0.05)
        os.kill(pid, signal.SIGKILL)
        return True

    def test_a_signal_during_a_hung_mutant_ends_the_suite_and_removes_the_tree(self):
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            with self.subTest(sig=sig.name):
                d, spec, pidfile = self.hanging_repo(mutant_timeout=60)
                tmp = pathlib.Path(tempfile.mkdtemp())
                p = self.start_tool(d, spec, tmp)
                try:
                    self.wait_for(pidfile)
                    p.send_signal(sig)
                    p.wait(timeout=15)
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.wait()
                self.assertFalse(self.alive(pidfile), "the hung suite outlived mutate.py")
                self.assertEqual(list(tmp.glob("crewkit-mutate-*")), [])
                self.assertEqual(p.returncode, 128 + sig)

    def test_a_signal_during_a_hung_baseline_ends_the_suite_and_removes_the_tree(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(sig=sig.name):
                pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
                d, spec = self.repo([{"name": "m", "old": "echo ok;", "new": "echo fine;"}],
                                    suite=f"echo $$ > {pidfile}; exec sleep 30\n")
                tmp = pathlib.Path(tempfile.mkdtemp())
                p = self.start_tool(d, spec, tmp)
                try:
                    self.wait_for(pidfile)
                    p.send_signal(sig)
                    p.wait(timeout=15)
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.wait()
                self.assertFalse(self.alive(pidfile), "the hung baseline outlived mutate.py")
                self.assertEqual(list(tmp.glob("crewkit-mutate-*")), [])

    def test_a_baseline_that_hangs_past_the_ceiling_stops_the_run(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "m", "old": "echo ok;", "new": "echo fine;"}],
                            suite=f"echo $$ > {pidfile}; exec sleep 30\n")
        saved = mutate.MAX_MUTANT_TIMEOUT
        mutate.MAX_MUTANT_TIMEOUT = 2
        out = io.StringIO()
        t0 = time.monotonic()
        try:
            with contextlib.redirect_stdout(out):
                rc = mutate.run_spec(d, spec, "45")
        finally:
            mutate.MAX_MUTANT_TIMEOUT = saved
        self.assertEqual(rc, 1)
        self.assertIn("the unmutated suite timed out", out.getvalue())
        self.assertLess(time.monotonic() - t0, 15)
        self.assertFalse(self.alive(pidfile))

    def test_a_process_left_behind_by_a_finished_suite_is_ended(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "leaves one", "old": "echo ok;",
                              "new": f"sleep 30 >/dev/null 2>&1 </dev/null & echo $! > {pidfile};"}])
        self.run_tool(d, spec)
        self.assertFalse(self.alive(pidfile), "a daemon of the finished suite was left running")

    # Fix round 2.
    STUBBORN = "echo $$ > {pidfile}; trap '' TERM; for i in $(seq 300); do sleep 0.1; done;"

    def test_a_second_signal_during_the_kill_grace_does_not_stop_the_cleanup(self):
        for sigs in ((signal.SIGTERM, signal.SIGTERM), (signal.SIGINT, signal.SIGINT), (signal.SIGHUP, signal.SIGTERM)):
            with self.subTest(sigs=[x.name for x in sigs]):
                pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
                d, spec = self.repo([{"name": "stubborn", "old": "echo ok;", "new": self.STUBBORN.format(pidfile=pidfile)}],
                                    mutant_timeout=60)
                tmp = pathlib.Path(tempfile.mkdtemp())
                p = self.start_tool(d, spec, tmp)
                try:
                    self.wait_for(pidfile)
                    p.send_signal(sigs[0])
                    time.sleep(0.5)
                    if p.poll() is None:
                        p.send_signal(sigs[1])
                    p.wait(timeout=15)
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.wait()
                self.assertFalse(self.alive(pidfile), "the TERM-ignoring suite outlived mutate.py")
                self.assertEqual(list(tmp.glob("crewkit-mutate-*")), [])
                self.assertEqual((d / "t.sh").read_text(), TARGET)

    def test_a_signal_while_the_suite_is_being_started_still_ends_it(self):
        d, spec = self.repo([{"name": "m", "old": "echo ok;", "new": "echo fine;"}], suite="exec sleep 30\n")
        real = mutate.subprocess.Popen
        started = []

        def popen_hit_by_a_signal(*a, **kw):
            mutate.on_signal(signal.SIGTERM, None)  # arrives while the child is being started
            started.append(real(*a, **kw))
            return started[-1]

        mutate.subprocess.Popen = popen_hit_by_a_signal
        try:
            with self.assertRaises(SystemExit) as cm:
                mutate.run_suite(["bash", str(d / "suite.sh")], d, dict(os.environ), 60)
        finally:
            mutate.subprocess.Popen = real
        self.assertEqual(cm.exception.code, 128 + signal.SIGTERM)
        gone = False
        for _ in range(60):
            try:
                os.killpg(started[0].pid, 0)
            except (ProcessLookupError, PermissionError):
                gone = True
                break
            time.sleep(0.05)
        if not gone:
            os.killpg(started[0].pid, signal.SIGKILL)
        self.assertTrue(gone, "the suite started by a signalled Popen was left running")

    # The kill grace ends in a finally, so a second signal there is survived either way; what the
    # first signal must do is ignore the handled ones, so nothing can cut the cleanup short later.
    def test_the_first_signal_makes_every_handled_signal_ignored(self):
        sigs = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
        saved = {s: signal.getsignal(s) for s in sigs}
        try:
            for s in sigs:
                signal.signal(s, mutate.on_signal)
            mutate._HANDLED[:] = sigs
            with self.assertRaises(SystemExit) as cm:
                mutate.on_signal(signal.SIGTERM, None)
            self.assertEqual(cm.exception.code, 128 + signal.SIGTERM)
            for s in sigs:
                self.assertIs(signal.getsignal(s), signal.SIG_IGN, s.name)
        finally:
            mutate._HANDLED.clear()
            for s, h in saved.items():
                signal.signal(s, h)

    def test_a_signal_that_was_ignored_at_startup_stays_ignored(self):
        # nohup, or a background job's SIGINT: the run must not be ended by what its launcher ignored.
        for sig in (signal.SIGHUP, signal.SIGINT):
            with self.subTest(sig=sig.name):
                d, spec, pidfile = self.hanging_repo(mutant_timeout=60)
                lock = d / "heavy.lock"
                fd = os.open(lock, os.O_RDWR | os.O_CREAT)
                fcntl.flock(fd, fcntl.LOCK_EX)
                tmp = pathlib.Path(tempfile.mkdtemp())
                try:
                    p = subprocess.Popen([sys.executable, str(SCRIPT), str(spec)], cwd=d, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, pass_fds=(fd,), env=self.env(lock, TMPDIR=str(tmp)),
                                         preexec_fn=lambda: signal.signal(sig, signal.SIG_IGN))
                finally:
                    os.close(fd)
                try:
                    self.wait_for(pidfile)
                    p.send_signal(sig)
                    time.sleep(1)
                    self.assertIsNone(p.poll(), f"{sig.name} ended a run that started with it ignored")
                    p.send_signal(signal.SIGTERM)
                    p.wait(timeout=15)
                finally:
                    if p.poll() is None:
                        p.kill()
                        p.wait()
                self.assertFalse(self.alive(pidfile))

    def test_the_spec_error_names_the_range(self):
        d, spec = self.repo([{"name": "m", "old": "echo ok;", "new": "echo fine;"}], mutant_timeout=0)
        r = self.run_tool(d, spec)
        self.assertIn("1 to 3600", r.stdout)

    def test_the_default_mutant_timeout_is_capped_at_the_ceiling(self):
        self.assertEqual(mutate.default_mutant_timeout(2000, 45), 3600)
        self.assertEqual(mutate.default_mutant_timeout(0.2, 3600), 3600)
        self.assertEqual(mutate.default_mutant_timeout(10, 45), 150)

    def test_mutate_bats_test_timeout_has_an_upper_bound(self):
        d, spec = self.repo([{"name": "bound removed", "old": "[[ $1 -gt 10 ]] || return 1", "new": "true"}])
        for bad in ("3601", "1" + "0" * 30):
            r = self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT=bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertIn("1 to 3600", r.stderr)
        self.assertEqual(self.run_tool(d, spec, MUTATE_BATS_TEST_TIMEOUT="3600").returncode, 0)

    # Fix round 3.
    def test_one_signal_during_the_timeout_kill_grace_still_kills_the_group(self):
        pidfile = pathlib.Path(tempfile.mkdtemp()) / "pid"
        d, spec = self.repo([{"name": "stubborn", "old": "echo ok;", "new": self.STUBBORN.format(pidfile=pidfile)}],
                            mutant_timeout=1)
        tmp = pathlib.Path(tempfile.mkdtemp())
        p = self.start_tool(d, spec, tmp)
        try:
            self.wait_for(pidfile)
            time.sleep(1.7)  # past the 1 s limit, inside the 2 s grace after TERM
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=15)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
        self.assertFalse(self.alive(pidfile), "the TERM-ignoring suite outlived a signal in the grace")
        self.assertEqual(p.returncode, 128 + signal.SIGTERM)
        self.assertEqual(list(tmp.glob("crewkit-mutate-*")), [])

    def test_a_failed_start_with_a_signal_held_exits_with_the_signal(self):
        real = mutate.subprocess.Popen

        def failing_popen(*a, **kw):
            mutate.on_signal(signal.SIGHUP, None)
            raise FileNotFoundError("no such suite")

        mutate.subprocess.Popen = failing_popen
        try:
            with self.assertRaises(SystemExit) as cm:
                mutate.run_suite(["nothing"], ".", dict(os.environ), 60)
        finally:
            mutate.subprocess.Popen = real
        self.assertEqual(cm.exception.code, 128 + signal.SIGHUP)

    def test_a_failed_start_without_a_signal_still_raises_the_error(self):
        with self.assertRaises(FileNotFoundError):
            mutate.run_suite(["/nonexistent/suite"], ".", dict(os.environ), 60)


if __name__ == "__main__":
    unittest.main()
