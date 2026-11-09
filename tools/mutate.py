#!/usr/bin/env python3
"""mutate.py: mutation check for one file's safety lines.

Usage: tools/mutate.py SPEC.json [SPEC.json ...]

A spec names the target, the suite that guards it, and the mutants:

  {"target": "lib/settings.sh",
   "suite": ["bats", "tests/settings.bats"],
   "mutant_timeout": 300,
   "mutants": [{"name": "...", "old": "exact text, may span lines", "new": "replacement"}]}

The tracked tree is copied to a temp directory and every run happens there, so the real tree
is never changed. The unmutated suite must pass first. Each `old` must occur exactly once in
the target, and the mutated file must still parse (bash -n for shell, compile() for Python),
or the mutant is reported instead of counted. A mutant is killed when the suite fails; where the
output allows it (bats TAP, unittest) the line names the first failing test: `killed  <name>  [by: <test>]`.
Tracked links stay links in the copy: a relative one as it is, an absolute one into the repo
pointed at the same file in the copy. A link that leaves the tree, or a target that is itself a
link, is refused (the mutant could be written through it into the real tree).
"bats" as the suite's first word runs the pinned bats-core from tools/get-bats.sh.
Every suite run (the baseline too) gets BATS_TEST_TIMEOUT=$MUTATE_BATS_TEST_TIMEOUT (seconds,
default 45, 3x the slowest test measured) in place of the caller's: a mutant that hangs a test
is killed by bats's watchdog then, not after a bats file's own default (120 s) or the Linux
gate's (300 s). A test that is slow for that limit fails the baseline, so it stops the run
rather than count as a kill.
Each mutant's suite also has a per-mutant limit, the optional spec key "mutant_timeout" (whole
seconds, 1 to 3600, the length of a crew-heavy slot; default max(60, 3 x the unmutated suite's
wall time, rounded up) + 2 x MUTATE_BATS_TEST_TIMEOUT, room for two bats tests that each wait out
the watchdog, never more than 3600; MUTATE_BATS_TEST_TIMEOUT is 1 to 3600 too). A mutant that hangs more than two bats tests can still run past the default and be
a TIMEOUT: put a longer "mutant_timeout" in the spec for such a suite. The unmutated baseline is
bounded too, at 3600 s. The suite runs in its own process group; past the limit the group gets TERM, then KILL after 2 s, and the
mutant is reported `TIMEOUT`. A hung mutant is not a killed one: the suite may hang for a reason
unrelated to the mutated line (load, a stuck tool), so a timeout is counted apart from the kills
and fails the run like a survivor, to be looked at and either fixed or given a longer limit. (The
bats watchdog above still ends a test that hangs inside bats; that failure is a kill, so a mutant
that only makes a test slower than the watchdog under load is counted killed and can hide a
survivor: rerun a kill that looks too easy on an idle machine.)
Every line is flushed as it is printed, so a run stopped from outside leaves its lines behind.
SIGTERM, SIGHUP (the outer `timeout`, crew-heavy at its limit, a hangup) and SIGINT (Ctrl-C) end the
suite's process group and remove the temp tree before mutate.py exits (128 + the signal number);
the suite is in its own session and would otherwise outlive the heavy lock. The first of them makes
the three ignored, so a second one can't cut the cleanup short (the KILL after the 2 s grace still
happens), and one that arrives while the suite is being started is held until it has. A signal that
was already ignored when mutate.py started (nohup, a background job) stays ignored. What is left of the
suite's process group after a normal finish is ended too, so one mutant's leftovers can't fail the
next. The `[by: <test>]` name has escape sequences and every Unicode control, format, separator,
private-use and unassigned character removed.

A mutation run is a heavy job: it refuses to start unless it holds the machine's heavy lock
(~/.local/state/crew/heavy.lock, or the user-only `heavy_lock` setting), so run it as
  crew-heavy run <secs> python3 tools/mutate.py SPEC.json
tools/heavy_lock.py proves the hold (an inherited descriptor on the lock file while the lock is
held; a crew-heavy run's shared lock also needs its slot) and passes where there is no crew state
dir (CI, containers, public installs).

Exit 0 = every mutant killed, 1 = a mutant survived, timed out, didn't apply, was invalid, the spec
is bad, or the baseline failed or timed out, or the heavy lock isn't held, 2 = usage (or a bad MUTATE_BATS_TEST_TIMEOUT).
"""
import json
import math
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import heavy_lock  # noqa: E402  (the one heavy-lock check, shared by every mutation runner)


def say(*args):
    """Print one line and flush it: stdout to a file is block-buffered, and a run stopped from
    outside (the outer timeout) must still leave the lines it got through."""
    print(*args, flush=True)


MAX_MUTANT_TIMEOUT = 3600  # a crew-heavy slot; also the ceiling on the baseline run


def default_mutant_timeout(baseline_secs, test_timeout):
    """Whole seconds: max(60, 3 x the unmutated suite's wall time, rounded up), plus room for two
    tests that each wait out the bats watchdog (TEST_TIMEOUT seconds), at most MAX_MUTANT_TIMEOUT."""
    return min(MAX_MUTANT_TIMEOUT, max(60, math.ceil(3 * baseline_secs)) + 2 * int(test_timeout))


def valid_mutant_timeout(value):
    return (isinstance(value, int) and not isinstance(value, bool)
            and 1 <= value <= MAX_MUTANT_TIMEOUT)


BY_CAP = 120
_ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]"               # CSI
                   r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"       # OSC
                   r"|\x9b[0-?]*[ -/]*[@-~]"                  # 8-bit CSI
                   r"|\x1b[@-Z\\-_]")                          # two-character sequences
_FAILING = (re.compile(r"^not ok \d+ (.*)"), re.compile(r"^(?:FAIL|ERROR): (\S+) \((\S+)\)"))


def clean_name(name):
    """A test name is data from the suite's output: escape sequences and every control, format,
    surrogate, private-use, unassigned, line and paragraph separator character out, at most BY_CAP long."""
    name = _ANSI.sub("", name)
    name = "".join(c for c in name if unicodedata.category(c)[0] != "C"
                   and unicodedata.category(c) not in ("Zl", "Zp"))
    return name[:BY_CAP].strip()


def first_failing(output):
    """The first failing test's name in a suite's output (bats TAP `not ok N name`, unittest
    `FAIL: test (module.Class.test)`), cleaned, or None when there is none to parse."""
    for line in output.split("\n"):
        line = line.rstrip("\r")
        m = _FAILING[0].match(line)
        if m:
            name = re.sub(r"\s+#.*$", "", m.group(1))
        else:
            m = _FAILING[1].match(line)
            if not m:
                continue
            test, where = m.groups()
            name = where if where.endswith("." + test) else f"{where}.{test}"
        name = clean_name(name)
        return name or None
    return None


def stop_group(proc):
    """End the suite's process group, by its exact pgid: TERM, then KILL after 2 s if any of it
    is still there. The KILL is in a `finally`: however the grace ends (a signal's SystemExit
    included) the group is not left running."""
    pgid = proc.pid
    gone = False
    try:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            gone = True
            return
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            proc.poll()  # reap the leader, or the group never looks empty
            try:
                os.killpg(pgid, 0)
            except (ProcessLookupError, PermissionError):  # macOS: EPERM once only zombies are left
                gone = True
                return
            time.sleep(0.05)
    finally:
        if not gone:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass


def sweep_group(pgid):
    """KILL whatever is left of a finished suite's group (a daemon it started)."""
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


_HANDLED = []  # the signals main() took over (not those it found already ignored)
_STATE = {"spawning": False, "pending": None}


def on_signal(signum, frame):
    """End the run: the first signal makes the handled ones ignored (cleanup runs to the end), then
    exits 128 + SIGNUM through the cleanup paths. While the suite is being started it only notes
    the signal, so the child can't be left unowned between fork and exec."""
    for sig in _HANDLED:
        signal.signal(sig, signal.SIG_IGN)
    if _STATE["spawning"]:
        _STATE["pending"] = signum
        return
    sys.exit(128 + signum)


def run_suite(cmd, cwd, env, timeout=None):
    """Run the suite in its own process group. Returns (returncode, output, timed_out)."""
    proc = None
    _STATE["pending"] = None
    _STATE["spawning"] = True
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True)
        _STATE["spawning"] = False
        if _STATE["pending"] is not None:
            sys.exit(128 + _STATE["pending"])
        out, _ = proc.communicate(timeout=timeout)
        sweep_group(proc.pid)
        return proc.returncode, out, False
    except subprocess.TimeoutExpired:
        stop_group(proc)
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass  # something outside the group still holds the pipe; the group is gone
        return proc.returncode, "", True
    except BaseException:
        _STATE["spawning"] = False
        held = _STATE["pending"]
        if proc is not None:
            stop_group(proc)
        if held is not None:
            sys.exit(128 + held)  # a signal held while the suite started, even if the start failed
        raise


def parses(path, text):
    if path.suffix == ".py" or text.startswith("#!/usr/bin/env python"):
        try:
            compile(text, str(path), "exec")
            return True
        except SyntaxError:
            return False
    if path.suffix in (".sh", ".bash", "") or text.startswith("#!"):
        return subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True).returncode == 0
    return True


class UnsafeLink(Exception):
    pass


def link_in_copy(root, dest, rel, link):
    """Where the copy of the link at REL should point: LINK itself if relative and inside the
    tree, the same file in DEST if absolute and inside the repo; UnsafeLink if it leaves."""
    real_root = os.path.realpath(root)
    if os.path.isabs(link):
        # Resolve the directory only: a link to a link stays a link to that link.
        to = os.path.join(os.path.realpath(os.path.dirname(link)), os.path.basename(link))
        inside = os.path.relpath(to, real_root)
        if inside == os.pardir or inside.startswith(os.pardir + os.sep):
            raise UnsafeLink(f"{rel} -> {link}: the link leaves the tree")
        return str(dest / inside)
    inside = os.path.normpath(os.path.join(os.path.dirname(rel), link))
    if inside == os.pardir or inside.startswith(os.pardir + os.sep):
        raise UnsafeLink(f"{rel} -> {link}: the link leaves the tree")
    return link


def copy_tree(root):
    dest = pathlib.Path(tempfile.mkdtemp(prefix="crewkit-mutate-"))
    try:
        files = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=root,
                               capture_output=True, text=True, check=True).stdout.splitlines()
        for rel in files:
            src = root / rel
            if src.is_symlink():
                # Kept a link (git hooks are links to one dispatcher): a copy of its target would
                # run the unmutated text, and every mutant of that target would survive.
                (dest / rel).parent.mkdir(parents=True, exist_ok=True)
                (dest / rel).symlink_to(link_in_copy(root, dest, rel, os.readlink(src)))
            elif src.is_file():
                (dest / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest / rel)
    except BaseException:
        shutil.rmtree(dest, ignore_errors=True)
        raise
    return dest


def suite_cmd(root, suite):
    if suite and suite[0] == "bats":
        bats = subprocess.run([str(root / "tools" / "get-bats.sh")], cwd=root,
                              capture_output=True, text=True, check=True).stdout.strip()
        return [bats] + suite[1:]
    return suite


def run_spec(root, spec_path, test_timeout):
    spec = json.loads(spec_path.read_text())
    if "mutant_timeout" in spec and not valid_mutant_timeout(spec["mutant_timeout"]):
        say(f"{spec['target']}:\n  mutant_timeout must be a whole number of seconds, 1 to {MAX_MUTANT_TIMEOUT}")
        return 1
    if (root / spec["target"]).is_symlink():
        say(f"{spec['target']}:\n  the target is a symlink; name the file it points to")
        return 1
    try:
        tree = copy_tree(root)
    except UnsafeLink as e:
        say(f"{spec['target']}:\n  can't copy the tree: {e}")
        return 1
    try:
        target = tree / spec["target"]
        original = target.read_text()
        cmd = suite_cmd(root, spec["suite"])

        def suite(timeout=None):
            env = dict(os.environ, BATS_TEST_TIMEOUT=test_timeout)
            return run_suite(cmd, tree, env, timeout)

        say(f"{spec['target']}:")
        started = time.monotonic()
        rc, _, timed_out = suite(MAX_MUTANT_TIMEOUT)
        if timed_out:
            say(f"  the unmutated suite timed out after {MAX_MUTANT_TIMEOUT} s; fix it first")
            return 1
        if rc != 0:
            say("  the unmutated suite fails; fix it first")
            return 1
        limit = spec.get("mutant_timeout") or default_mutant_timeout(time.monotonic() - started, test_timeout)
        bad = 0
        timeouts = 0
        for m in spec["mutants"]:
            n = original.count(m["old"])
            if n != 1:
                say(f"  NOT APPLIED  {m['name']} (old text found {n} times)")
                bad = 1
                continue
            mutated = original.replace(m["old"], m["new"])
            if not parses(target, mutated):
                say(f"  INVALID      {m['name']} (the mutant doesn't parse; fix it)")
                bad = 1
                continue
            target.write_text(mutated)
            rc, output, timed_out = suite(limit)
            target.write_text(original)
            if timed_out:
                timeouts += 1
                bad = 1
                say(f"  TIMEOUT      {m['name']} ({limit} s)")
                continue
            killed = rc != 0
            by = first_failing(output) if killed else None
            say(("  killed       " if killed else "  SURVIVED     ") + m["name"] + (f"  [by: {by}]" if by else ""))
            bad |= not killed
        total = len(spec["mutants"])
        if bad:
            note = f" ({timeouts} timed out)" if timeouts else ""
            say(f"  a mutant survived, timed out, did not apply or was invalid{note}")
        else:
            say(f"  all {total} mutants killed")
        return bad
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def main(argv):
    if not argv or any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip(), file=sys.stderr if not argv else sys.stdout)
        return 2 if not argv else 0
    test_timeout = os.environ.get("MUTATE_BATS_TEST_TIMEOUT", "45")
    if not (test_timeout.isascii() and test_timeout.isdigit() and len(test_timeout) <= 4
            and 1 <= int(test_timeout) <= MAX_MUTANT_TIMEOUT):
        print(f"mutate.py: MUTATE_BATS_TEST_TIMEOUT must be a whole number of seconds, 1 to {MAX_MUTANT_TIMEOUT}",
              file=sys.stderr)
        return 2
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        if signal.getsignal(sig) is not signal.SIG_IGN:
            _HANDLED.append(sig)
            signal.signal(sig, on_signal)
    if not heavy_lock.proof():
        print(heavy_lock.refusal("mutate.py", "python3 tools/mutate.py SPEC.json"), file=sys.stderr)
        return 1
    root = pathlib.Path(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                       capture_output=True, text=True, check=True).stdout.strip())
    return max(run_spec(root, pathlib.Path(a), test_timeout) for a in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
