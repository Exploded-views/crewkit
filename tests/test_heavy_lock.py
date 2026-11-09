"""Every mutation runner refuses to start without the heavy lock (tools/heavy_lock.py):
tools/mutate.py (see test_mutate.py), tools/mutate.sh and tools/mutate-check-workflows.py."""
import fcntl
import importlib.util
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent


def env(lock, **extra):
    e = {k: v for k, v in os.environ.items() if k not in ("CI", "GITHUB_ACTIONS") and not k.startswith("BITC")}
    e["CREWKIT_HEAVY_LOCK"] = str(lock)
    e["CREWKIT_HEAVY_LOCK_TEST"] = "1"   # the override works only behind this flag
    e.update(extra)
    return e


def load():
    spec = importlib.util.spec_from_file_location("heavy_lock", ROOT / "tools" / "heavy_lock.py")
    hl = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hl)
    return hl


def fresh_flock(path, mode):
    """Try `mode` (| LOCK_NB) on a new open file description: what an outside process sees."""
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, mode | fcntl.LOCK_NB)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def take(fd, path, mode):
    """flock `fd` (on `path`) without waiting. A lock this process or a child of it already holds
    through another open file description would make a blocking flock wait for ever, and a mutant
    that converts an inherited descriptor does exactly that: fail at once instead, so it is killed."""
    try:
        fcntl.flock(fd, mode | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        raise AssertionError(f"{path} is already held by another open file description, "
                             f"a blocking flock here would wait for ever ({e.strerror})") from e


class CrewHeavyRun(unittest.TestCase):
    """`crew-heavy run` holds heavy.lock shared (one fd) and heavy.slot1 or heavy.slot2 exclusive (another)."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.lock = self.dir / "heavy.lock"
        for n in ("heavy.lock", "heavy.slot1", "heavy.slot2"):
            (self.dir / n).touch()
        self.fds = []

    def tearDown(self):
        for fd in self.fds:
            os.close(fd)

    def hold(self, path, mode):
        fd = os.open(path, os.O_RDWR)
        take(fd, path, mode)
        self.fds.append(fd)
        return fd

    def cli(self, *fds):
        return subprocess.run([sys.executable, str(ROOT / "tools" / "heavy_lock.py")], cwd=ROOT,
                              capture_output=True, text=True, env=env(self.lock), pass_fds=fds)

    def proof_here(self):
        with mock.patch.dict(os.environ, env(self.lock), clear=True):
            return load().proof()

    def test_hold_fails_at_once_on_a_lock_it_cannot_take_instead_of_waiting(self):
        # flock locks belong to the open file description. A child handed a run-hold descriptor
        # (pass_fds) shares that description, so a child that converts it to exclusive converts the
        # test's own lock too, and the next blocking hold() on the same file waits forever. That is
        # how two mutants that flock an inherited descriptor timed out instead of being killed.
        # hold() must raise, and say why; the alarm only turns a hang into a quick failure here.
        self.hold(self.lock, fcntl.LOCK_EX)
        signal.signal(signal.SIGALRM, lambda *a: self.fail("hold() blocked on a lock it cannot take"))
        signal.alarm(5)
        try:
            with self.assertRaises(AssertionError) as cm:
                self.hold(self.lock, fcntl.LOCK_SH)
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, signal.SIG_DFL)
        self.assertIn("already held", str(cm.exception))

    def test_a_shared_lock_plus_a_slot_is_a_crew_heavy_run_hold(self):
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        slot = self.hold(self.dir / "heavy.slot1", fcntl.LOCK_EX)
        self.assertEqual(self.cli(sh, slot).returncode, 0)

    def test_either_slot_will_do_and_a_sibling_run_on_the_other_changes_nothing(self):
        # The sibling holds the lock shared too (its own description) and slot 1; we are slot 2.
        self.hold(self.lock, fcntl.LOCK_SH)
        self.hold(self.dir / "heavy.slot1", fcntl.LOCK_EX)
        fd = os.open(self.lock, os.O_RDWR)
        slot = os.open(self.dir / "heavy.slot2", os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH)
            fcntl.flock(slot, fcntl.LOCK_EX)
            self.assertEqual(self.cli(fd, slot).returncode, 0)
        finally:
            os.close(fd)
            os.close(slot)

    def run_with_slot(self, name, make=None):
        """A hand-built run hold: the lock shared, and the file `name` in the lock's directory held
        exclusively. Returns the check's exit status."""
        path = self.dir / name
        if make:
            make(path)
        else:
            path.touch()
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        slot = self.hold(path, fcntl.LOCK_EX)
        return self.cli(sh, slot).returncode

    def test_any_numbered_slot_is_a_slot(self):
        for name in ("heavy.slot3", "heavy.slot7", "heavy.slot10", "heavy.slot999"):
            with self.subTest(name):
                self.assertEqual(self.run_with_slot(name), 0)

    def test_names_that_are_not_a_slot_number_are_not_slots(self):
        for name in ("heavy.slot0", "heavy.slot01", "heavy.slotX", "heavy.slot1.bak", "xheavy.slot1", "heavy.slot1000", "heavy.slot"):
            with self.subTest(name):
                self.assertEqual(self.run_with_slot(name), 1)

    def test_a_slot_that_is_a_symlink_is_not_accepted(self):
        real = self.dir / "real-slot-target"
        real.touch()
        slot = self.hold(real, fcntl.LOCK_EX)
        os.symlink(real, self.dir / "heavy.slot3")
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        self.assertEqual(self.cli(sh, slot).returncode, 1)

    def test_a_slot_that_is_a_fifo_or_a_directory_is_skipped_without_blocking(self):
        os.mkfifo(self.dir / "heavy.slot4")
        (self.dir / "heavy.slot5").mkdir()
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        self.assertEqual(self.cli(sh).returncode, 1)

    def test_a_shared_lock_without_a_slot_is_refused_and_stays_held(self):
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        r = self.cli(sh)
        self.assertEqual(r.returncode, 1)
        self.assertIn("heavy lock", r.stderr)
        self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_EX))   # a check never gives the lock up

    def test_in_process_a_refused_shared_fd_is_never_converted_to_exclusive(self):
        self.hold(self.lock, fcntl.LOCK_SH)
        self.assertIsNone(self.proof_here())
        self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_EX))
        self.assertTrue(fresh_flock(self.lock, fcntl.LOCK_SH))

    def test_a_shared_lock_beside_a_sibling_is_refused_without_a_slot_and_both_stay_held(self):
        self.hold(self.lock, fcntl.LOCK_SH)
        sib = self.hold(self.lock, fcntl.LOCK_SH)
        self.assertIsNone(self.proof_here())
        self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_EX))
        os.close(sib)
        self.fds.remove(sib)
        self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_EX))   # the first is still held

    def test_a_slot_without_the_lock_is_refused(self):
        slot = self.hold(self.dir / "heavy.slot1", fcntl.LOCK_EX)
        self.assertEqual(self.cli(slot).returncode, 1)

    def test_a_slot_from_another_directory_is_refused(self):
        other = pathlib.Path(tempfile.mkdtemp())
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        slot = self.hold(other / "heavy.slot1", fcntl.LOCK_EX) if (other / "heavy.slot1").touch() is None else None
        self.assertEqual(self.cli(sh, slot).returncode, 1)

    def test_an_inherited_slot_fd_on_a_free_slot_is_no_hold(self):
        # The slot is held by nobody (the child's fd is open, not locked): the probe gets it, so refuse.
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        ours = os.open(self.dir / "heavy.slot1", os.O_RDWR)
        self.fds.append(ours)
        self.assertEqual(self.cli(sh, ours).returncode, 1)
        self.assertTrue(fresh_flock(self.dir / "heavy.slot1", fcntl.LOCK_EX))   # and the probe let go

    def test_the_probes_leave_nothing_held(self):
        sh = self.hold(self.lock, fcntl.LOCK_SH)
        slot = self.hold(self.dir / "heavy.slot1", fcntl.LOCK_EX)
        self.assertIn("descriptor", self.proof_here())
        for fd in (sh, slot):
            os.close(fd)
            self.fds.remove(fd)
        self.assertTrue(fresh_flock(self.lock, fcntl.LOCK_EX))
        self.assertTrue(fresh_flock(self.dir / "heavy.slot1", fcntl.LOCK_EX))

    def test_an_exclusive_probe_that_wins_is_let_go_and_refused(self):
        os.close(os.open(self.lock, os.O_RDWR))
        fd = os.open(self.lock, os.O_RDWR)   # open, nobody holds the lock
        self.fds.append(fd)
        self.assertIsNone(self.proof_here())
        self.assertTrue(fresh_flock(self.lock, fcntl.LOCK_EX))

    def test_an_exclusive_holder_still_passes_and_stays_exclusive(self):
        # bench, or a raw `flock heavy.lock cmd`: no slot needed, and the check never downgrades it.
        self.hold(self.lock, fcntl.LOCK_EX)
        self.assertIn("descriptor", self.proof_here())
        self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_SH))

    def test_residual_an_unlocked_fd_passes_while_someone_else_holds_the_lock(self):
        # Documented in heavy_lock.py: the check is advisory. Another process holds the lock
        # exclusively; our open-but-unlocked descriptor on it is taken for a hold.
        other = subprocess.Popen([sys.executable, "-c",
                                  "import fcntl,sys,time;f=open(sys.argv[1]);fcntl.flock(f,fcntl.LOCK_EX);print('x',flush=True);time.sleep(30)",
                                  str(self.lock)], stdout=subprocess.PIPE, text=True)
        try:
            other.stdout.readline()
            ours = os.open(self.lock, os.O_RDWR)
            self.fds.append(ours)
            self.assertEqual(self.cli(ours).returncode, 0)
            self.assertFalse(fresh_flock(self.lock, fcntl.LOCK_SH))   # and the holder keeps it exclusive
        finally:
            other.kill()
            other.wait()

    def test_a_lock_held_by_someone_else_is_no_hold_without_an_inherited_descriptor(self):
        other = subprocess.Popen([sys.executable, "-c",
                                  "import fcntl,sys,time;f=open(sys.argv[1]);fcntl.flock(f,fcntl.LOCK_EX);print('x',flush=True);time.sleep(30)",
                                  str(self.lock)], stdout=subprocess.PIPE, text=True)
        try:
            other.stdout.readline()
            r = self.cli()
            self.assertEqual(r.returncode, 1)
            self.assertIn("heavy lock", r.stderr)   # a refusal, not a crash
        finally:
            other.kill()
            other.wait()

    def test_a_free_lock_with_an_inherited_fd_is_refused_even_with_a_slot_held(self):
        slot = self.hold(self.dir / "heavy.slot1", fcntl.LOCK_EX)
        ours = os.open(self.lock, os.O_RDWR)
        self.fds.append(ours)
        self.assertEqual(self.cli(ours, slot).returncode, 1)


class HomeCase(unittest.TestCase):
    """A scratch password-database home, and proof() run as that user."""

    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp())
        self.state = self.home / ".local" / "state" / "crew"
        self.fds = []

    def tearDown(self):
        for fd in self.fds:
            os.close(fd)

    def hold(self, path, mode):
        path = pathlib.Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT)
        take(fd, path, mode)
        self.fds.append(fd)
        return fd

    def setting(self, line):
        (self.home / ".claude").mkdir(exist_ok=True)
        f = self.home / ".claude" / "crewkit.md"
        f.write_text("---\n" + line + "\n---\n")
        f.chmod(0o600)

    def proof(self, attrs=None, **extra):
        """proof() as this uid with the password database's home = self.home; ATTRS patch the module."""
        e = {k: v for k, v in os.environ.items()
             if not k.startswith(("CREWKIT_", "BITC")) and k not in ("CI", "GITHUB_ACTIONS")}
        e["HOME"] = "/nonexistent"
        e.update(extra)
        entry = mock.Mock(pw_dir=str(self.home))
        hl = load()
        with mock.patch.dict(os.environ, e, clear=True), mock.patch("pwd.getpwuid", return_value=entry), \
                mock.patch.multiple(hl, create=True, **(attrs or {})) if attrs else mock.patch.dict(os.environ, {}):
            r = hl.proof()
            self.why = hl.refusal("t", "t") if r is None else ""
            return r

    def script(self, name, body):
        f = self.home / name
        f.write_text("#!/bin/sh\n" + body + "\n")
        f.chmod(0o755)
        return str(f)


class Scope(HomeCase):
    """Where the check applies and which lock it looks at: the default crew state dir
    (~ from the password database), a user-only `heavy_lock` setting, a test-only override."""

    def test_no_default_crew_state_dir_means_unguarded(self):
        self.assertEqual(self.proof(), "no crew state dir: unguarded")

    def test_a_uid_with_no_password_entry_is_unguarded_not_a_crash(self):
        """A container run as the caller's uid has no entry: no home, so no crew state dir and no
        user file. HOME is not consulted, even where it names a crew state dir."""
        (self.home / ".local" / "state" / "crew").mkdir(parents=True)
        hl = load()
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}, clear=True), \
                mock.patch("pwd.getpwuid", side_effect=KeyError("getpwuid(): uid not found")):
            self.assertIsNone(hl.home())
            self.assertIsNone(hl.default_lock())
            self.assertEqual(hl.configured_lock(), (None, None))
            self.assertEqual(hl.proof(), "no crew state dir: unguarded")

    def test_no_default_dir_also_when_ci_is_set_or_not(self):
        for e in ({}, {"CI": "true", "GITHUB_ACTIONS": "true"}):
            self.assertEqual(self.proof(**e), "no crew state dir: unguarded")

    def test_with_the_default_dir_a_free_lock_is_refused(self):
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        self.assertIsNone(self.proof())

    def test_with_the_default_dir_ci_is_no_way_round(self):
        self.state.mkdir(parents=True)
        for e in ({"CI": "true", "GITHUB_ACTIONS": "true"},):
            self.assertIsNone(self.proof(**e))

    def test_the_default_lock_comes_from_the_password_database_not_HOME(self):
        # HOME holds a lock this process holds exclusively; the password database's home has a free one.
        decoy = pathlib.Path(tempfile.mkdtemp())
        self.hold(decoy / ".local" / "state" / "crew" / "heavy.lock", fcntl.LOCK_EX)
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        self.assertIsNone(self.proof(HOME=str(decoy)))

    def test_the_default_lock_held_exclusively_passes(self):
        self.hold(self.state / "heavy.lock", fcntl.LOCK_EX)
        self.assertIn("descriptor", self.proof())

    def test_the_setting_moves_the_lock(self):
        elsewhere = self.home / "elsewhere" / "heavy.lock"
        self.setting(f"heavy_lock: {elsewhere}")
        self.state.mkdir(parents=True)
        self.hold(elsewhere, fcntl.LOCK_EX)
        self.assertIn(str(elsewhere), self.proof())

    def test_with_the_setting_the_default_lock_is_no_longer_the_one(self):
        self.setting(f"heavy_lock: {self.home / 'elsewhere' / 'heavy.lock'}")
        (self.home / "elsewhere").mkdir()
        (self.home / "elsewhere" / "heavy.lock").touch()
        self.hold(self.state / "heavy.lock", fcntl.LOCK_EX)
        self.assertIsNone(self.proof())

    def test_the_setting_takes_a_leading_tilde(self):
        self.setting('heavy_lock: "~/moved/heavy.lock"')
        self.hold(self.home / "moved" / "heavy.lock", fcntl.LOCK_EX)
        self.state.mkdir(parents=True)
        self.assertIn("moved", self.proof())

    def test_the_setting_cannot_switch_the_guard_off(self):
        # A path in a directory that doesn't exist, on a host that has the default dir: still enforced.
        self.state.mkdir(parents=True)
        self.setting(f"heavy_lock: {self.home / 'nowhere' / 'heavy.lock'}")
        self.assertIsNone(self.proof())

    def test_the_setting_is_read_only_from_the_user_file(self):
        # A project's .claude/crewkit.md can't redirect the lock: the check reads the user file alone.
        project = pathlib.Path(tempfile.mkdtemp())
        (project / ".claude").mkdir()
        (project / ".git").mkdir()
        (project / ".claude" / "crewkit.md").write_text(f"---\nheavy_lock: {project}/heavy.lock\n---\n")
        self.hold(project / "heavy.lock", fcntl.LOCK_EX)
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        old = os.getcwd()
        os.chdir(project)
        try:
            self.assertIsNone(self.proof())
        finally:
            os.chdir(old)

    def test_the_env_override_is_ignored_without_the_test_flag(self):
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        scratch = self.home / "scratch.lock"
        self.hold(scratch, fcntl.LOCK_EX)
        self.assertIsNone(self.proof(CREWKIT_HEAVY_LOCK=str(scratch)))
        self.assertIn("scratch.lock", self.proof(CREWKIT_HEAVY_LOCK=str(scratch), CREWKIT_HEAVY_LOCK_TEST="1"))

    def test_the_env_override_with_the_flag_is_enforced_even_without_a_crew_dir(self):
        scratch = self.home / "scratch.lock"
        scratch.touch()
        self.assertIsNone(self.proof(CREWKIT_HEAVY_LOCK=str(scratch), CREWKIT_HEAVY_LOCK_TEST="1"))


class Lookup(HomeCase):
    """The settings lookup: no way for the environment to redirect it, and a failure refuses."""

    def crew_host(self):
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        self.setting("heavy_lock:")   # the key, no value: the lookup runs and finds no setting

    def decoy(self):
        d = self.home / "decoy"
        d.mkdir()
        self.hold(d / "heavy.lock", fcntl.LOCK_EX)   # a lock this process holds: the redirect's target
        return d / "heavy.lock"

    def test_BASH_ENV_cannot_redirect_the_lock(self):
        self.crew_host()
        d = self.decoy()
        self.assertIsNone(self.proof(BASH_ENV=self.script("benv.sh", f"echo {d}; exit 0")))

    def test_an_exported_function_cannot_redirect_the_lock(self):
        self.crew_host()
        d = self.decoy()
        self.assertIsNone(self.proof(**{"BASH_FUNC_awk%%": f'() {{ echo "F={d}"; }}'}))

    def test_a_bash_earlier_on_PATH_cannot_redirect_the_lock(self):
        self.crew_host()
        d = self.decoy()
        fake = self.home / "fakebin"
        fake.mkdir()
        (fake / "bash").write_text(f"#!/bin/sh\necho {d}\n")
        (fake / "bash").chmod(0o755)
        self.assertIsNone(self.proof(PATH=f"{fake}:{os.environ['PATH']}"))

    def test_only_the_last_line_of_the_output_is_the_setting(self):
        self.crew_host()
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        self.hold(elsewhere / "heavy.lock", fcntl.LOCK_EX)
        noisy = self.script("noisy", f"echo noise; echo {self.home / 'noise.lock'}; echo {elsewhere / 'heavy.lock'}")
        self.assertIn("elsewhere", self.proof({"BASH": noisy}))

    def test_a_configured_dir_alone_enforces_the_guard(self):
        x = self.home / "x"
        x.mkdir()
        (x / "heavy.lock").touch()
        self.setting(f"heavy_lock: {x / 'heavy.lock'}")
        self.assertIsNone(self.proof())   # no default dir, but not "unguarded"
        self.hold(x / "heavy.lock", fcntl.LOCK_EX)
        self.assertIn("x/heavy.lock", self.proof())

    def test_a_failed_lookup_refuses_and_says_why(self):
        self.crew_host()
        (self.home / "rel").mkdir()
        self.hold(self.home / "rel" / "heavy.lock", fcntl.LOCK_EX)   # a relative value that would resolve from the home
        for name, bash in (("missing", str(self.home / "no-such-bash")), ("nonzero", self.script("bad", "exit 3")),
                           ("relative", self.script("relbash", "echo rel/heavy.lock"))):
            with self.subTest(name):
                old = os.getcwd()
                os.chdir(self.home)   # so a relative value would resolve to the held lock
                try:
                    self.assertIsNone(self.proof({"BASH": bash}))
                finally:
                    os.chdir(old)
                self.assertIn("heavy_lock", self.why)

    def test_a_failed_lookup_is_never_unguarded_even_with_only_a_configured_dir(self):
        x = self.home / "x"
        x.mkdir()
        self.setting(f"heavy_lock: {x / 'heavy.lock'}")
        for bash in (str(self.home / "no-such-bash"), self.script("bad", "exit 3")):
            self.assertIsNone(self.proof({"BASH": bash}))

    def test_a_slow_lookup_refuses_not_unguarded(self):
        x = self.home / "x"
        x.mkdir()
        self.setting(f"heavy_lock: {x / 'heavy.lock'}")
        slow = self.script("slow", "exec sleep 5")
        self.assertIsNone(self.proof({"BASH": slow, "LOOKUP_TIMEOUT": 0.5}))
        self.assertIn("heavy_lock", self.why)

    def test_a_fifo_or_a_symlink_or_a_directory_as_the_lock_is_refused_and_never_opened_blocking(self):
        self.crew_host()
        os.mkfifo(self.home / "fifo")
        (self.home / "real").touch()
        os.symlink(self.home / "real", self.home / "link")
        (self.home / "adir").mkdir()
        for target in ("fifo", "link", "adir"):
            with self.subTest(target):
                self.assertIsNone(self.proof({"BASH": self.script("v", f"echo {self.home / target}")}))

    def test_a_symlink_to_a_held_lock_is_not_the_setting(self):
        self.crew_host()
        self.hold(self.home / "real.lock", fcntl.LOCK_EX)
        os.symlink(self.home / "real.lock", self.home / "link.lock")
        self.assertIsNone(self.proof({"BASH": self.script("v", f"echo {self.home / 'link.lock'}")}))
        self.assertIn("heavy_lock", self.why)

    def test_the_lookup_runs_bash_with_no_profile_or_rc_and_a_minimal_environment(self):
        self.crew_host()
        rec = self.home / "rec"
        self.proof({"BASH": self.script("v", f'echo "$@" > {rec}; env | cut -d= -f1 | sort >> {rec}')}, BASH_ENV="/x", FOO="1")
        text = rec.read_text()
        self.assertIn("--noprofile --norc", text)
        for name in ("BASH_ENV", "FOO"):
            self.assertNotIn(name + "\n", text)
        for name in ("HOME", "PATH", "LC_ALL"):
            self.assertIn(name + "\n", text)

    def test_a_user_file_settings_sh_would_skip_refuses_never_unguarded(self):
        # Configured lock only (no default dir). A crewkit.md writable by others is skipped by
        # lib/settings.sh and would read as "no setting": the same home must refuse at 0600 and 0666.
        x = self.home / "x"
        x.mkdir()
        (x / "heavy.lock").touch()
        self.setting(f"heavy_lock: {x / 'heavy.lock'}")
        f = self.home / ".claude" / "crewkit.md"
        self.assertIsNone(self.proof())
        f.chmod(0o666)
        self.assertIsNone(self.proof())
        self.assertIn("writable", self.why)
        f.chmod(0o600)
        self.hold(x / "heavy.lock", fcntl.LOCK_EX)
        self.assertIn("x/heavy.lock", self.proof())

    def configured_only(self):
        """A host with no default dir and a heavy_lock setting; returns the lock file."""
        x = self.home / "x"
        x.mkdir()
        lock = x / "heavy.lock"
        lock.touch()
        self.setting(f"heavy_lock: {lock}")
        return lock

    def user_file_behind_a_link(self, target_mode, link_mode):
        f = self.home / ".claude" / "crewkit.md"
        target = self.home / "dotfiles-crewkit.md"
        f.rename(target)
        target.chmod(target_mode)
        os.symlink(target, f)
        if hasattr(os, "lchmod"):
            os.lchmod(f, link_mode)   # macOS; on Linux every link is 0777
        elif link_mode != 0o777:
            self.skipTest("a link's mode can't be set here (Linux links are always 0777)")

    def test_a_symlinked_user_file_whose_link_is_world_writable_refuses(self):
        # lib/settings.sh's `find -perm -002` looks at the link itself and skips such a file.
        lock = self.configured_only()
        self.user_file_behind_a_link(0o600, 0o777)
        self.assertIsNone(self.proof())
        self.assertIn("writable", self.why)
        self.hold(lock, fcntl.LOCK_EX)
        self.assertIsNone(self.proof())   # still: the setting can't be trusted, so no pass either

    def test_a_world_writable_target_behind_a_plain_link_refuses(self):
        self.configured_only()
        self.user_file_behind_a_link(0o666, 0o755)
        self.assertIsNone(self.proof())
        self.assertIn("writable", self.why)

    def test_a_group_writable_user_file_is_allowed_as_settings_sh_allows_it(self):
        lock = self.configured_only()
        (self.home / ".claude" / "crewkit.md").chmod(0o660)
        self.hold(lock, fcntl.LOCK_EX)
        self.assertIn("x/heavy.lock", self.proof())

    def test_a_user_file_that_is_not_ours_refuses(self):
        self.configured_only()
        with mock.patch("os.getuid", return_value=os.getuid() + 1):
            self.assertIsNone(self.proof())
        self.assertIn("isn't yours", self.why)

    def test_a_user_file_that_vanishes_after_the_check_refuses_cleanly(self):
        with mock.patch("os.path.isfile", return_value=True):   # the file is gone when it is stat'ed
            self.assertIsNone(self.proof())
        self.assertIn("heavy_lock", self.why)

    def test_a_user_file_with_no_heavy_lock_key_needs_no_bash(self):
        self.setting("repo: o/r")
        gone = str(self.home / "no-such-bash")
        self.assertEqual(self.proof({"BASH": gone}), "no crew state dir: unguarded")
        self.state.mkdir(parents=True)
        (self.state / "heavy.lock").touch()
        self.assertIsNone(self.proof({"BASH": gone}))   # the default lock, free: a plain refusal
        self.assertNotIn("lookup failed", self.why)

    def test_a_user_file_with_the_key_and_no_bash_still_refuses(self):
        x = self.home / "x"
        x.mkdir()
        self.setting(f"heavy_lock: {x / 'heavy.lock'}")
        self.assertIsNone(self.proof({"BASH": str(self.home / "no-such-bash")}))
        self.assertIn("lookup failed", self.why)

    def test_a_failed_lookup_names_the_configured_lock_not_the_default(self):
        self.crew_host()
        self.assertIsNone(self.proof({"BASH": self.script("bad", "exit 3")}))
        self.assertIn("the configured lock (lookup failed:", self.why)
        self.assertNotIn(str(self.state), self.why)

    def test_a_default_lock_that_is_a_symlink_is_followed_a_configured_one_is_not(self):
        # crew-heavy opens the default path and follows a link, so the check does too; a configured
        # path is refused when it is a link (see test_a_symlink_to_a_held_lock_is_not_the_setting).
        self.state.mkdir(parents=True)
        self.hold(self.home / "real.lock", fcntl.LOCK_EX)
        os.symlink(self.home / "real.lock", self.state / "heavy.lock")
        self.assertIn("descriptor", self.proof())

    def test_the_refusal_names_the_lock_that_was_checked(self):
        self.crew_host()
        moved = self.home / "moved"
        moved.mkdir()
        (moved / "heavy.lock").touch()
        self.setting(f"heavy_lock: {moved / 'heavy.lock'}")
        self.assertIsNone(self.proof())
        self.assertIn(str(moved / "heavy.lock"), self.why)
        self.assertIn("crew-heavy run", self.why)

    def test_the_default_lock_is_named_when_it_was_checked(self):
        self.crew_host()
        self.assertIsNone(self.proof())
        self.assertIn(str(self.state / "heavy.lock"), self.why)


class HeavyLock(unittest.TestCase):
    def setUp(self):
        self.lock = pathlib.Path(tempfile.mkdtemp()) / "heavy.lock"
        self.lock.touch()

    def run_cmd(self, cmd, hold):
        fd = os.open(self.lock, os.O_RDWR)
        try:
            if hold:
                fcntl.flock(fd, fcntl.LOCK_EX)
            return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env(self.lock),
                                  pass_fds=(fd,) if hold else ())
        finally:
            os.close(fd)

    def test_the_check_passes_with_the_lock_and_refuses_without(self):
        cmd = [sys.executable, str(ROOT / "tools" / "heavy_lock.py")]
        self.assertEqual(self.run_cmd(cmd, hold=True).returncode, 0)
        r = self.run_cmd(cmd, hold=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("heavy lock", r.stderr)

    def test_no_lock_file_at_all_is_refused(self):
        missing = self.lock.parent / "none.lock"
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "heavy_lock.py")], cwd=ROOT, capture_output=True,
                           text=True, env=env(missing))
        self.assertEqual(r.returncode, 1)

    def test_a_descriptor_on_another_file_isnt_the_lock(self):
        other = self.lock.parent / "other"
        other.touch()
        fd = os.open(other, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            r = subprocess.run([sys.executable, str(ROOT / "tools" / "heavy_lock.py")], cwd=ROOT, capture_output=True,
                               text=True, env=env(self.lock), pass_fds=(fd,))
        finally:
            os.close(fd)
        self.assertEqual(r.returncode, 1)

    def test_mutate_sh_refuses_before_anything_else(self):
        # From outside any repository: past the lock check, mutate.sh would fail on git (128).
        r = subprocess.run(["bash", str(ROOT / "tools" / "mutate.sh")], cwd=tempfile.mkdtemp(), capture_output=True,
                           text=True, env=env(self.lock))
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("heavy lock", r.stderr)

    def test_a_hostile_PYTHONPATH_cannot_make_the_shell_callers_guard_pass(self):
        evil = pathlib.Path(tempfile.mkdtemp())
        (evil / "subprocess.py").write_text("import sys\nsys.exit(0)\n")
        r = subprocess.run(["bash", str(ROOT / "tools" / "mutate.sh")], cwd=tempfile.mkdtemp(), capture_output=True,
                           text=True, env=env(self.lock, PYTHONPATH=str(evil)))
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("heavy lock", r.stderr)

    def test_mutate_sh_refuses_without_the_lock_and_runs_nothing(self):
        r = self.run_cmd(["bash", str(ROOT / "tools" / "mutate.sh")], hold=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("heavy lock", r.stderr)
        self.assertNotIn("killed", r.stdout + r.stderr)

    def test_mutate_check_workflows_refuses_without_the_lock_and_runs_nothing(self):
        r = self.run_cmd([sys.executable, str(ROOT / "tools" / "mutate-check-workflows.py")], hold=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("heavy lock", r.stderr)
        self.assertNotIn("killed", r.stdout + r.stderr)


STUB = """#!%(py)s
import os, sys, time
if os.environ.get("FAKE_REC"):
    open(os.environ["FAKE_REC"], "a").write(repr((sys.argv[1:], os.environ.get("BITC_DIR"))) + "\\n")
a = sys.argv[1:]
if len(a) != 6 or a[0] != "--state-dir" or a[2] != "--config" or a[4:] != ["status", "--json"]:
    sys.exit(64)   # the global flags come before the subcommand, as in bitc itself
time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
sys.stdout.write(open(os.environ["FAKE_STATUS"]).read())
sys.exit(int(os.environ.get("FAKE_RC", "0")))
"""


class BitcHold(unittest.TestCase):
    """A hold verified through bitc: BITC_JOB names a holder, in heavy/gate/bench, whose pid is this
    process or an ancestor of it. Everything else falls through to the flock checks."""

    JOB = "c7c68d84"

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.lock = self.dir / "heavy.lock"
        self.lock.touch()
        self.stub = self.dir / "bitc"
        self.stub.write_text(STUB % {"py": sys.executable})
        self.stub.chmod(0o755)
        self.status = self.dir / "status.json"
        self.kids = []
        self.home = self.dir / "home"   # the home the proof sees: never this machine's
        (self.home / ".config" / "bitc").mkdir(parents=True)
        self.config = self.home / ".config" / "bitc" / "bitc.toml"
        self.config.write_text("")
        self.config.chmod(0o644)

    def tearDown(self):
        for k in self.kids:
            k.kill()
            k.wait()

    def write(self, pool="heavy", job=None, pid=None, slot=1, slots=3):
        import json
        holders = [] if job is None else [{"job": job, "slot": slot, "pid": pid, "since": "2026-01-01T00:00:00Z"}]
        self.status.write_text(json.dumps({"version": "1", "pools": [
            {"name": "light", "slots": 8, "holders": []}, {"name": pool, "slots": slots, "holders": holders}]}))

    def proof(self, **extra):
        e = env(self.lock, BITC=str(self.stub), FAKE_STATUS=str(self.status), BITC_JOB=self.JOB,
                BITC_POOL="heavy", BITC_SLOT="heavy.1", BITC_HOLD="x:y")
        e.update(extra)
        for k in [k for k, v in e.items() if v is None]:
            del e[k]
        with mock.patch.dict(os.environ, e, clear=True):
            hl = load()
            hl.BITC_TIMEOUT = 1.5
            hl.home = lambda: str(self.home)
            return hl.proof(), hl

    def child(self, code, **extra):
        """Run `code` in a child python that has loaded tools/heavy_lock.py as `m`, with the test
        switch on and a config file; its parent is THIS process (pid > 1 whoever started the runner)."""
        pre = ("import importlib.util as u, sys, json; sp = u.spec_from_file_location('hl', %r); "
               "m = u.module_from_spec(sp); sp.loader.exec_module(m); " % str(ROOT / "tools" / "heavy_lock.py"))
        e = env(self.lock, BITC=str(self.stub), FAKE_STATUS=str(self.status), BITC_JOB=self.JOB,
                BITC_CONFIG=str(self.config), **extra)
        return subprocess.run([sys.executable, "-c", pre + code], env=e, capture_output=True, text=True)

    def stranger(self):
        k = subprocess.Popen(["sleep", "30"])
        self.kids.append(k)
        return k.pid

    def test_a_holder_that_is_this_process_passes(self):
        self.write(job=self.JOB, pid=os.getpid())
        got, _ = self.proof()
        self.assertIn(self.JOB, got or "")

    def test_a_holder_that_is_the_parent_passes(self):
        # The holder is the PARENT of the checking process: a child of this test process checks.
        self.write(job=self.JOB, pid=os.getpid())
        r = self.child("sys.exit(0 if m.proof() else 1)")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_pid_1_is_never_a_holder(self):
        # ancestors() stops before pid 1 (a container runner's parent is pid 1; a holder there proves nothing).
        self.write(job=self.JOB, pid=1)
        self.assertIsNone(self.proof()[0])
        r = self.child("sys.exit(0 if m.proof() else 1)")
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_a_holder_two_levels_up_passes(self):
        self.write(job=self.JOB, pid=os.getpid())
        code = ("import importlib.util as u, sys; sp = u.spec_from_file_location('hl', %r); m = u.module_from_spec(sp); "
                "sp.loader.exec_module(m); sys.exit(0 if m.proof() else 1)" % str(ROOT / "tools" / "heavy_lock.py"))
        r = subprocess.run(["sh", "-c", f'"{sys.executable}" -c "$0"', code], env=env(self.lock, BITC=str(self.stub),
                           FAKE_STATUS=str(self.status), BITC_JOB=self.JOB, BITC_CONFIG=str(self.config)),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_holder_that_is_an_unrelated_process_fails(self):
        self.write(job=self.JOB, pid=self.stranger())
        self.assertIsNone(self.proof()[0])

    def test_a_forged_job_held_by_another_process_fails(self):
        self.write(job="deadbeef", pid=self.stranger())
        self.assertIsNone(self.proof(BITC_JOB="deadbeef")[0])

    def test_no_matching_job_fails(self):
        self.write(job="deadbeef", pid=os.getpid())
        self.assertIsNone(self.proof()[0])

    def test_no_holders_at_all_fails(self):
        self.write()
        self.assertIsNone(self.proof()[0])

    def test_pools_that_count_are_heavy_gate_and_bench(self):
        for pool in ("heavy", "gate", "bench"):
            with self.subTest(pool):
                self.write(pool=pool, job=self.JOB, pid=os.getpid())
                self.assertTrue(self.proof()[0])

    def test_a_light_pool_holder_fails(self):
        for pool in ("light", "other"):
            with self.subTest(pool):
                self.write(pool=pool, job=self.JOB, pid=os.getpid())
                self.assertIsNone(self.proof()[0])

    def test_pool_slot_and_hold_variables_are_never_trusted(self):
        self.write(pool="light", job=self.JOB, pid=os.getpid())
        self.assertIsNone(self.proof(BITC_POOL="heavy", BITC_SLOT="heavy.1", BITC_HOLD="heavy:1")[0])

    def test_bitc_missing_fails(self):
        self.write(job=self.JOB, pid=os.getpid())
        self.assertIsNone(self.proof(BITC=str(self.dir / "nope"))[0])

    def test_with_the_test_switch_on_bitc_is_not_searched_on_PATH(self):
        self.write(job=self.JOB, pid=os.getpid())
        self.assertIsNone(self.proof(BITC=None, PATH=f"{self.dir}:/usr/bin:/bin")[0])

    def test_with_the_test_switch_on_BITC_DIR_reaches_bitc(self):
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        self.assertTrue(self.proof(FAKE_REC=str(rec), BITC_DIR="/scratch/state")[0])
        self.assertIn(f"['--state-dir', '/scratch/state', '--config', '{self.config}', 'status'", rec.read_text())

    def test_the_argv_the_proof_builds_has_the_global_flags_before_status(self):
        # The stub exits 64 (bitc's usage error) on any other shape, as bitc does.
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        self.assertTrue(self.proof(FAKE_REC=str(rec), BITC_CONFIG=str(self.dir / "bitc.toml"))[0])
        argv = eval(rec.read_text().splitlines()[0])[0]
        self.assertEqual([argv[0], argv[2], argv[-2], argv[-1]], ["--state-dir", "--config", "status", "--json"])

    REAL = pathlib.Path.home() / ".local" / "bin" / "bitc"

    @unittest.skipUnless(os.access(REAL, os.X_OK), "bitc is not installed at ~/.local/bin/bitc")
    def test_the_argv_the_proof_builds_is_accepted_by_the_real_bitc(self):
        # Read-only: `status --json` only. A stub can accept an order the real binary rejects (exit 64).
        hl = load()
        h = pathlib.Path(hl.home())
        config = h / ".config" / "bitc" / "bitc.toml"
        if not config.is_file():
            self.skipTest("no ~/.config/bitc/bitc.toml (bitc's host file) on this machine")
        argv = hl.bitc_argv(str(h / ".local" / "bin" / "bitc"), str(h / ".local" / "state" / "bitc"), str(config))
        r = subprocess.run(argv, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("pools", __import__("json").loads(r.stdout))

    def test_a_usage_error_or_state_dir_refusal_exit_is_a_refusal(self):
        self.write(job=self.JOB, pid=os.getpid())
        for rc in ("64", "78"):
            with self.subTest(rc):
                self.assertIsNone(self.proof(FAKE_RC=rc)[0])

    def test_the_argv_always_has_the_canonical_config_of_the_home(self):
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        self.assertTrue(self.proof(FAKE_REC=str(rec))[0])
        self.assertIn(f"'--config', '{self.config}', 'status', '--json'", rec.read_text())

    def test_an_absent_config_refuses_the_hold_and_says_why(self):
        self.write(job=self.JOB, pid=os.getpid())
        self.config.unlink()
        rec = self.dir / "rec"
        got, hl = self.proof(FAKE_REC=str(rec))
        self.assertIsNone(got)
        self.assertFalse(rec.exists())   # decided before bitc runs
        text = hl.refusal("t", "t")
        self.assertIn(f"{self.config}", text)
        self.assertIn("host file", text)

    def test_the_outer_environments_bitc_variables_do_not_leak_into_these_tests(self):
        # The gate runs the suite inside a bitc job, which exports BITC_DIR, BITC_CONFIG and BITC_JOB.
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        with mock.patch.dict(os.environ, {"BITC_DIR": "/outer/state", "BITC_CONFIG": "/outer/bitc.toml"}):
            self.assertTrue(self.proof(FAKE_REC=str(rec))[0])
        self.assertNotIn("/outer", rec.read_text())

    def test_with_the_test_switch_on_BITC_CONFIG_reaches_bitc(self):
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        self.assertTrue(self.proof(FAKE_REC=str(rec), BITC_CONFIG="/scratch/bitc.toml")[0])
        self.assertIn("'--config', '/scratch/bitc.toml', 'status'", rec.read_text())

    def test_a_deeply_nested_status_is_a_refusal_not_a_traceback(self):
        self.status.write_text("[" * 200000)
        got, hl = self.proof()
        self.assertIsNone(got)
        self.assertIn("bitc", hl.refusal("t", "t"))

    def test_a_light_pool_without_a_size_does_not_hide_a_heavy_hold(self):
        import json
        self.status.write_text(json.dumps({"pools": [
            {"name": "light", "holders": []},
            {"name": "heavy", "slots": 3, "holders": [{"job": self.JOB, "slot": 1, "pid": os.getpid()}]}]}))
        self.assertTrue(self.proof()[0])

    def test_a_slot_outside_the_pools_size_fails(self):
        for slot in (0, 4, 99, "1", True, None):
            with self.subTest(slot=slot):
                self.write(job=self.JOB, pid=os.getpid(), slot=slot)
                self.assertIsNone(self.proof()[0])

    def test_a_pool_without_a_real_size_fails(self):
        for slots in ("3", None, 0, True):
            with self.subTest(slots=slots):
                self.write(job=self.JOB, pid=os.getpid(), slots=slots)
                self.assertIsNone(self.proof()[0])

    def test_the_parent_chain_is_read_with_one_ps_call(self):
        r = self.child("real = m.subprocess.run; calls = []\n"
                       "m.subprocess.run = lambda *a, **k: calls.append(a) or real(*a, **k)\n"
                       "print(json.dumps([m.ancestors(), len(calls)]))")
        self.assertEqual(r.returncode, 0, r.stderr)
        import json
        chain, calls = json.loads(r.stdout)
        self.assertIn(os.getpid(), chain)   # this test process: the child's parent, pid > 1 anywhere
        self.assertEqual(calls, 1)

    def test_a_refusal_names_the_bitc_reason_when_BITC_JOB_was_set(self):
        self.write(job=self.JOB, pid=os.getpid())
        got, hl = self.proof(BITC=str(self.dir / "nope"))
        self.assertIsNone(got)
        self.assertIn("bitc", hl.refusal("t", "t").split("run it as")[0])

    def test_a_failing_bitc_fails_even_with_a_matching_holder_on_stdout(self):
        self.write(job=self.JOB, pid=os.getpid())
        self.assertIsNone(self.proof(FAKE_RC="1")[0])

    def test_unparsable_or_oddly_shaped_status_fails(self):
        for text in ("not json", "[]", "{}", '{"pools": 3}', '{"pools": [3]}',
                     '{"pools": [{"name": "heavy", "holders": [{"job": "c7c68d84", "pid": "abc"}]}]}',
                     '{"pools": [{"name": "heavy", "holders": [{"job": "c7c68d84", "pid": true}]}]}'):
            with self.subTest(text):
                self.status.write_text(text)
                self.assertIsNone(self.proof()[0])

    def test_a_bitc_that_hangs_fails_at_the_timeout(self):
        self.write(job=self.JOB, pid=os.getpid())
        got, _ = self.proof(FAKE_SLEEP="10")
        self.assertIsNone(got)

    def test_no_BITC_JOB_falls_through_to_the_flock_path_and_never_runs_bitc(self):
        self.write(job=self.JOB, pid=os.getpid())
        rec = self.dir / "rec"
        got, _ = self.proof(BITC_JOB=None, FAKE_REC=str(rec))
        self.assertIsNone(got)
        self.assertFalse(rec.exists())

    def test_a_malformed_BITC_JOB_fails(self):
        self.write(job="x y", pid=os.getpid())
        for job in ("", "x y", "../../etc", "a" * 200, "c7c68d84\n"):
            with self.subTest(job):
                self.assertIsNone(self.proof(BITC_JOB=job)[0])

    def test_a_flock_hold_still_passes_with_no_bitc_at_all(self):
        fd = os.open(self.lock, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            got, _ = self.proof(BITC=str(self.dir / "nope"), BITC_JOB=None)
            self.assertIn("descriptor", got or "")
        finally:
            os.close(fd)

    def test_a_flock_hold_still_passes_when_the_bitc_check_fails(self):
        fd = os.open(self.lock, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            self.status.write_text("garbage")
            got, _ = self.proof()
            self.assertIn("descriptor", got or "")
        finally:
            os.close(fd)

    def test_the_cli_passes_on_a_bitc_hold(self):
        self.write(job=self.JOB, pid=os.getpid())   # the CLI's parent is this test process
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "heavy_lock.py")], capture_output=True, text=True,
                           env=env(self.lock, BITC=str(self.stub), FAKE_STATUS=str(self.status), BITC_JOB=self.JOB,
                                    BITC_CONFIG=str(self.config)))
        self.assertEqual(r.returncode, 0, r.stderr)


class BitcProduction(HomeCase):
    """The test switch is OFF: the bitc binary is only <home>/.local/bin/bitc (home from the password
    database), run with an explicit --state-dir and a scrubbed environment. BITC, PATH and BITC_DIR
    from the caller change nothing."""

    JOB = "deadbeef"

    def setUp(self):
        super().setUp()
        self.state.mkdir(parents=True)   # the default crew state dir exists: the guard is in force
        self.bin = self.home / ".local" / "bin"
        self.bin.mkdir(parents=True)
        self.rec = self.home / "rec"
        self.body = ("#!/bin/sh\n"
                     f"echo \"$0|$*|$(env | sort | tr '\\n' ' ')\" >> {self.rec}\n"
                     "printf '{\"pools\":[{\"name\":\"heavy\",\"slots\":3,\"holders\":"
                     "[{\"job\":\"%s\",\"slot\":1,\"pid\":%d}]}]}\\n' deadbeef $PPID\n")
        self.config()   # bitc's host file exists unless a test removes it

    def sha(self, text=None):
        import hashlib
        return hashlib.sha256((self.body if text is None else text).encode()).hexdigest()

    def record(self, text):
        """install.sh's record of the installed binary's sha256."""
        d = self.home / ".local" / "share" / "crewkit"
        d.mkdir(parents=True, exist_ok=True)
        (d / "bitc.sha256").write_text(text)
        (d / "bitc.sha256").chmod(0o644)


    def stub(self, path=None, record=True):
        path = pathlib.Path(path or self.bin / "bitc")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.body)
        path.chmod(0o755)
        if record:
            self.record(self.sha() + "\n")
        return path

    def check(self, **extra):
        return self.proof(BITC_JOB=self.JOB, **extra)

    def config(self, mode=0o644):
        d = self.home / ".config" / "bitc"
        d.mkdir(parents=True, exist_ok=True)
        (d / "bitc.toml").write_text("")
        (d / "bitc.toml").chmod(mode)

    def argv(self):
        return self.rec.read_text().splitlines()[0].split("|")[1]

    def test_a_missing_config_refuses_the_hold_before_bitc_runs_and_says_why(self):
        # Without bitc's host file bitc 0.1.4 reports no pools (or exits 78 with --config): no hold can exist.
        self.stub()
        (self.home / ".config" / "bitc" / "bitc.toml").unlink()
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())
        self.assertIn(f"{self.home}/.config/bitc/bitc.toml", self.why)
        self.assertIn("host file", self.why)

    def test_an_existing_config_is_passed(self):
        self.stub()
        self.config()
        self.assertTrue(self.check())
        self.assertEqual(self.argv(), f"--state-dir {self.home}/.local/state/bitc --config "
                                      f"{self.home}/.config/bitc/bitc.toml status --json")

    def test_an_unsafe_config_is_a_refusal_not_a_config_left_out(self):
        # Real bitc reads this same path and refuses an unsafe file itself; the proof refuses too.
        self.stub()
        for mode in (0o666, 0o664, 0o646):
            with self.subTest(oct(mode)):
                self.config(mode)
                self.assertIsNone(self.check())
                self.assertIn("bitc.toml is not yours", self.why)
        self.assertFalse(self.rec.exists())

    def test_a_symlinked_config_is_a_refusal(self):
        self.stub()
        self.config()
        cfg = self.home / ".config" / "bitc" / "bitc.toml"
        cfg.rename(cfg.with_name("real.toml"))
        cfg.symlink_to(cfg.with_name("real.toml"))
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_config_owned_by_someone_else_is_a_refusal(self):
        self.stub()
        self.config()
        real = os.lstat
        cfg = str(self.home / ".config" / "bitc" / "bitc.toml")

        def foreign(path, *a, **k):
            st = real(path, *a, **k)
            if str(path) == cfg:
                return os.stat_result((st.st_mode, st.st_ino, st.st_dev, st.st_nlink, st.st_uid + 1, st.st_gid,
                                       st.st_size, st.st_atime, st.st_mtime, st.st_ctime))
            return st
        with mock.patch("os.lstat", side_effect=foreign):
            self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_BITC_CONFIG_is_never_honoured_without_the_test_switch(self):
        self.stub()
        self.config()
        other = self.home / "other.toml"
        other.write_text("")
        self.assertTrue(self.check(BITC_CONFIG=str(other)))
        self.assertNotIn("other.toml", self.argv())
        self.assertIn(f"--config {self.home}/.config/bitc/bitc.toml", self.argv())

    def test_an_unreadable_parent_chain_is_a_refusal(self):
        self.stub()
        self.assertIsNone(self.proof(attrs={"ancestors": lambda: None}, BITC_JOB=self.JOB))
        self.assertIsNone(self.proof(attrs={"ancestors": lambda: []}, BITC_JOB=self.JOB))

    def test_a_binary_that_cannot_be_opened_is_a_refusal(self):
        # An executable script is unreadable-and-runnable only on paper (the kernel needs to read it),
        # so make the open itself fail for the binary, as a race or a device error would.
        self.stub()
        real = os.open

        def refuse(path, *a, **k):
            if str(path).endswith("/bin/bitc"):
                raise OSError(13, "Permission denied")
            return real(path, *a, **k)
        with mock.patch("os.open", side_effect=refuse):
            self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())
        self.assertIn("can't be opened", self.why)

    def test_a_read_error_while_hashing_is_a_refusal(self):
        class Broken:
            @staticmethod
            def sha256(data):
                raise OSError(5, "I/O error")
        self.stub()
        self.assertIsNone(self.proof(attrs={"hashlib": Broken}, BITC_JOB=self.JOB))
        self.assertFalse(self.rec.exists())

    def test_a_record_that_cannot_be_read_is_a_refusal(self):
        self.stub()
        (self.home / ".local" / "share" / "crewkit" / "bitc.sha256").chmod(0o200)
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_an_unsafe_binary_says_which_path_and_why(self):
        self.stub().chmod(0o775)
        self.assertIsNone(self.check())
        self.assertIn(f"{self.bin}/bitc is not yours", self.why)
        self.assertIn("writable", self.why)

    def test_a_mismatching_record_says_to_reinstall_and_names_the_record(self):
        self.stub(record=False)
        self.record(self.sha("other") + "\n")
        self.assertIsNone(self.check())
        self.assertIn("does not match", self.why)
        self.assertIn("./install.sh --only bitc --yes", self.why)

    def test_the_canonical_binary_is_used_with_an_explicit_state_dir_and_a_scrubbed_env(self):
        self.stub()
        self.config()
        self.assertTrue(self.check(BITC_DIR=str(self.home / ".local" / "state" / "bitc")))
        line = self.rec.read_text()
        self.assertIn(f"|--state-dir {self.home}/.local/state/bitc --config {self.home}/.config/bitc/bitc.toml status --json|", line)
        for var in ("BITC_DIR=", "BITC_CONFIG=", "BITC_JOB=", "BITC=", "FAKE_"):
            self.assertNotIn(var, line.split("|", 2)[2].replace("PATH=", ""))
        self.assertIn("HOME=" + str(self.home), line)
        self.assertIn("LC_ALL=C", line)

    def test_a_BITC_stub_is_never_run(self):
        other = self.stub(self.home / "elsewhere" / "bitc")
        self.assertIsNone(self.check(BITC=str(other)))
        self.assertFalse(self.rec.exists())

    def test_a_BITC_stub_is_never_run_even_with_the_test_flag_but_no_lock_override(self):
        other = self.stub(self.home / "elsewhere" / "bitc")
        self.assertIsNone(self.check(BITC=str(other), CREWKIT_HEAVY_LOCK_TEST="1"))
        self.assertFalse(self.rec.exists())

    def test_a_stub_first_on_PATH_is_never_run(self):
        self.stub(self.home / "evil" / "bitc")
        self.assertIsNone(self.check(PATH=f"{self.home}/evil:/usr/bin:/bin"))
        self.assertFalse(self.rec.exists())

    def test_a_scratch_BITC_DIR_is_refused_and_never_reaches_bitc(self):
        self.stub()
        scratch = self.home / "scratch"
        scratch.mkdir(mode=0o700)
        self.assertIsNone(self.check(BITC_DIR=str(scratch)))
        self.assertFalse(self.rec.exists())

    def test_BITC_DIR_set_to_the_canonical_dir_passes(self):
        self.stub()
        self.assertTrue(self.check(BITC_DIR=str(self.home / ".local" / "state" / "bitc")))

    def test_a_symlinked_binary_is_refused(self):
        real = self.stub(self.home / "real" / "bitc")
        (self.bin / "bitc").symlink_to(real)
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_group_or_other_writable_binary_is_refused(self):
        for mode in (0o775, 0o757, 0o777):
            with self.subTest(oct(mode)):
                self.stub().chmod(mode)
                self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_group_or_other_writable_directory_or_parent_is_refused(self):
        self.stub()
        for d in (self.bin, self.bin.parent):
            for mode in (0o775, 0o757):
                with self.subTest(str(d), mode=oct(mode)):
                    d.chmod(mode)
                    try:
                        self.assertIsNone(self.check())
                    finally:
                        d.chmod(0o755)
        self.assertFalse(self.rec.exists())

    def test_a_binary_owned_by_someone_else_is_refused(self):
        self.stub()
        with mock.patch("os.getuid", return_value=os.getuid() + 1):
            self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_binary_replaced_after_install_is_refused(self):
        path = self.stub()
        path.write_text(self.body + "# replaced\n")   # same path, owner and mode; other bytes
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_record_that_matches_passes_in_either_case(self):
        self.stub(record=False)
        for text in (self.sha(), self.sha() + "\n", self.sha().upper() + "\n"):
            with self.subTest(text):
                self.record(text)
                self.assertTrue(self.check())

    def test_a_missing_record_is_a_refusal_that_says_to_reinstall(self):
        self.stub(record=False)
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())
        self.assertIn("./install.sh --only bitc --yes", self.why)

    def test_a_mismatching_record_is_a_refusal(self):
        self.stub(record=False)
        self.record(self.sha("something else") + "\n")
        self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())
        self.assertIn("./install.sh --only bitc --yes", self.why)

    def test_a_malformed_record_is_a_refusal(self):
        self.stub(record=False)
        for text in ("", "\n", "zz", self.sha()[:63], self.sha() + "0", self.sha() + "\n" + self.sha() + "\n",
                     self.sha() + " bitc\n", "0x" + self.sha()[2:]):
            with self.subTest(text):
                self.record(text)
                self.assertIsNone(self.check())
        self.assertFalse(self.rec.exists())

    def test_a_record_writable_by_others_or_a_link_is_refused(self):
        self.stub()
        rec = self.home / ".local" / "share" / "crewkit" / "bitc.sha256"
        rec.chmod(0o666)
        self.assertIsNone(self.check())
        rec.chmod(0o644)
        real = rec.with_name("real")
        rec.rename(real)
        rec.symlink_to(real)
        self.assertIsNone(self.check())

    def test_a_missing_binary_is_a_refusal(self):
        self.assertIsNone(self.check())

    def test_the_outer_environments_bitc_variables_never_leak_into_the_proof(self):
        # The gate runs these tests inside a bitc job, which exports BITC_JOB, BITC_DIR and friends.
        self.stub()
        outer = {"BITC_JOB": "cafe0001", "BITC_POOL": "heavy", "BITC_SLOT": "heavy.1", "BITC_HOLD": "x:y"}
        with mock.patch.dict(os.environ, outer):
            self.assertIsNone(self.proof())
        self.assertFalse(self.rec.exists())

    def test_no_BITC_JOB_never_runs_bitc(self):
        self.stub()
        self.assertIsNone(self.proof())
        self.assertFalse(self.rec.exists())


if __name__ == "__main__":
    unittest.main()
