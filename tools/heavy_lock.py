#!/usr/bin/env python3
"""heavy_lock.py: does this process hold the machine's heavy lock? The one check for every heavy
runner (tools/mutate.py, tools/mutate.sh, tools/mutate-check-workflows.py, tools/linux-gate.sh).

A heavy job (a mutation run, a full suite, coverage, perf) runs one at a time per machine under
  crew-heavy run <secs> <command>     suites, mutants, gates: two at once
  crew-heavy bench <secs> <command>   benchmarks: exclusive
or, the legacy way, flock ~/.local/state/crew/heavy.lock <command>. `run` holds heavy.lock SHARED
on one inherited descriptor and heavy.slotN (N = 1, 2, 3, ...; same directory) EXCLUSIVE on another;
`bench` and a raw flock hold heavy.lock EXCLUSIVE.

What counts as a hold. This process has an inherited descriptor on the heavy lock file (same
st_dev/st_ino), AND the lock is held right now. "Held" is read with FRESH descriptors this check
opens itself, never with flock on an inherited one: flock converts a descriptor's lock in place
(and on Linux a failed non-blocking conversion can drop the lock), so touching an inherited
descriptor could downgrade a bench or give up a run's share. A probe is a new open file
description, so it conflicts with every inherited lock, ours included, and each probe lock is
released at once.
  1. LOCK_EX|LOCK_NB on a fresh descriptor must fail with EWOULDBLOCK. If it succeeds nobody holds
     the lock: release it and refuse.
  2. LOCK_SH|LOCK_NB on a fresh descriptor: if it fails, the holder is exclusive (bench, raw flock)
     and that is a hold. If it succeeds, the holder is shared (a `crew-heavy run`, ours or a
     sibling's), and a shared lock alone proves nothing about which run holds a slot, so also
     require an inherited descriptor on a heavy.slotN file (N = 1-999) in the lock's directory whose
     LOCK_EX|LOCK_NB on a fresh descriptor fails (the slot is held).

Where it applies. Only where the DEFAULT crew state dir (~/.local/state/crew, ~ from the password
database, not $HOME) exists, or where a valid configured lock is named: elsewhere (public
installs, GitHub-hosted runs, containers) nothing shares a lock and the check passes as
"no crew state dir: unguarded". So CI and the old gate-container token are no longer accepted
reasons: where the dir exists they would let an environment variable switch the guard off. The
lock path is the user-only crewkit setting `heavy_lock` (read only from ~/.claude/crewkit.md by
lib/settings.sh; a leading ~/ is the home), else the default. A configured path moves the lock
but cannot switch the guard off: the default dir's existence enforces it. CREWKIT_HEAVY_LOCK
overrides the path, and enforces the check regardless of any dir, only with
CREWKIT_HEAVY_LOCK_TEST=1 (the tests).

A bitc hold. crew-heavy is a wrapper over `bitc run`, the machine's slot pool runner, and a job it
starts may hold no flock at all. `bitc run` exports BITC_JOB (the job id) into the job; that counts as
a hold only when ALL of these are true, and any doubt is "not a bitc hold" (the flock checks above then
decide, unchanged, so old and new callers both pass during the switch):
  - BITC_JOB is set and well formed (6-32 lowercase hex digits);
  - the bitc binary is ONLY <home>/.local/bin/bitc (home from the password database); it, its
    directory and that directory's parent must be ours, not links, not group- or other-writable, and
    its sha256 must equal the one install.sh recorded in ~/.local/share/crewkit/bitc.sha256 (a missing,
    malformed or mismatching record, or a replaced binary, is a refusal that says to re-run
    `./install.sh --only bitc --yes`). BITC, PATH and BITC_CONFIG are never used to find the binary or
    its config, and a BITC_DIR that is not the canonical state dir is refused;
  - it runs as `bitc --state-dir ~/.local/state/bitc --config ~/.config/bitc/bitc.toml status --json`
    (global flags before the subcommand; --config is always passed: an absent host file refuses the
    hold with a reason naming it, since bitc 0.1.4 then lists no pools or exits 78, and an existing
    one that is not ours, is a link, or is group- or other-writable refuses it too) with an environment of HOME, PATH and LC_ALL only, under a
    timeout (BITC_TIMEOUT), exits 0, and lists a holder whose job is exactly BITC_JOB in the heavy,
    gate or bench pool (never light), in a slot within that pool's size;
  - that holder's pid is this process or one of its ancestors, read from one `ps` snapshot of the real
    parent chain, never from an environment variable. A job id copied into a process bitc did not
    start fails here.
BITC_POOL, BITC_SLOT and BITC_HOLD are not read. Bitc missing or unsafe, a timeout, any non-zero
exit (usage 64, state dir refused 78), unparsable or oddly shaped JSON, and a pid that is not an
ancestor are all refusals of this path, never a pass; the refusal text then adds "bitc: <why>".
Tests only: with CREWKIT_HEAVY_LOCK_TEST=1 and CREWKIT_HEAVY_LOCK set (the flock path's switch),
BITC, BITC_DIR and BITC_CONFIG name the binary and its state, run with the caller's environment.
Residuals: the hash catches an accidental or wrong replacement of the binary, not a same-user
writer who also rewrites the record (the flock path has the same limit, as does "a python3 earlier
on PATH"); the hash is read from the opened file but the file is exec'd by path afterwards. Pid reuse: a listed holder whose `bitc run`
died and whose pid an ancestor of a job-id copier reuses would pass; bitc lists a holder only while
its ticket exists, which was not verified to be tied to the slot lock.

A failed lookup of the setting refuses (never "unguarded"): when ~/.claude/crewkit.md exists and
names `heavy_lock` (a file without that key needs no lookup and no bash), a user file that isn't
ours or is writable by others (lib/settings.sh would skip it), a
timeout, a missing or failing bash, a non-zero exit, or a value that is not an absolute path to a
regular, non-symlink file in an existing directory is a refusal that names the failure. The
lookup runs /bin/bash --noprofile --norc with only HOME (from the password database), PATH
and LC_ALL set, so the caller's environment (BASH_ENV, exported functions, PATH) cannot change
its answer; only the last line of its output is read.

The check is advisory: it stops a heavy job started by mistake without the lock, not one that
means to get past it. Every residual within the check:
  - an inherited descriptor on heavy.lock that is open but NOT locked passes while someone else
    holds the lock (the probes see a held lock, not whose it is);
  - likewise a slot descriptor, open but not locked, passes while a SIBLING run holds that slot
    (shared lock plus a slot held by anyone that this process also has open);
  - CREWKIT_HEAVY_LOCK with CREWKIT_HEAVY_LOCK_TEST=1 points the check at any file. That is a
    bypass by design: anyone who can set two environment variables can set them. It exists for
    the tests only;
  - the lock file is identified once and the probes check they opened the same inode, but a lock
    file replaced after the check isn't noticed, and a configured path is lstat'ed once and
    reopened (following links) later, so a same-user swap in between moves the check;
  - the default lock is followed through a symlink (crew-heavy opens that path and follows it
    too); a configured one is refused when it is a link;
  - a probe that wins a free lock or slot holds it for a moment (microseconds) before releasing;
    a concurrent `crew-heavy run` choosing a slot at that instant fails its non-blocking try and
    polls again (CREW_HEAVY_POLL). Harmless, and left as is.
And outside the check, the interpreter that runs it: the shell callers (tools/linux-gate.sh,
tools/mutate.sh) run `python3 -I`, which ignores PYTHON* variables and the user site, but a
python3 earlier on PATH still replaces the check. The in-process callers (tools/mutate.py,
tools/mutate-check-workflows.py) run it in their own interpreter, so PYTHONPATH, PYTHONHOME and
a python3 on PATH, set by whoever starts them, can replace it too.

  python3 tools/heavy_lock.py [NAME]   exit 0 if the lock is held, else 1 with why on stderr
"""
import errno
import fcntl
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys

TEST_FLAG = "CREWKIT_HEAVY_LOCK_TEST"
SLOT_NAME = re.compile(r"heavy\.slot[1-9][0-9]{0,2}")   # heavy.slotN: any count of slots
UNGUARDED = "no crew state dir: unguarded"
BASH = "/bin/bash"
LOOKUP_TIMEOUT = 10
BITC_JOB = re.compile(r"[0-9a-f]{6,32}")
BITC_POOLS = ("heavy", "gate", "bench")   # the pools whose holders are heavy jobs (not light)
BITC_TIMEOUT = 10
BITC_WHY = None   # why the last bitc check refused, when BITC_JOB was set
CHECKED = None   # the lock path the last proof() looked at
WHY = None       # why the last proof() refused, when it is more than "not held"


def home():
    """The home directory from the password database (HOME can point anywhere), or None."""
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:   # a uid with no passwd entry
        return None


def default_lock():
    """~/.local/state/crew/heavy.lock, or None with no home."""
    h = home()
    return os.path.join(h, ".local", "state", "crew", "heavy.lock") if h else None


def configured_lock():
    """(path, error): the user-only `heavy_lock` setting (lib/settings.sh reads it from
    ~/.claude/crewkit.md only). (None, None) when there is no user file or no setting; an error
    string for any failed lookup or bad value, which the caller must treat as a refusal."""
    h = home()
    user_file = os.path.join(h, ".claude", "crewkit.md") if h else ""
    if not h or not os.path.isfile(user_file):
        return None, None
    # lib/settings.sh skips a user file that isn't ours or is writable by others, and the setting
    # would then read as empty: fail closed here instead, by a rule that covers both views of the
    # file. settings.sh tests ownership through a link (-O) but world-writability on the link
    # itself (find -perm -002; every symlink is 0777 on Linux), and a world-writable target behind
    # a plain link passes it on some systems. Here the file fails if EITHER the link or its target
    # is not ours or is world-writable.
    try:
        views = (os.lstat(user_file), os.stat(user_file))
    except OSError as e:
        return None, f"the heavy_lock settings lookup failed: can't read ~/.claude/crewkit.md ({e.strerror})"
    if any(v.st_uid != os.getuid() or v.st_mode & stat.S_IWOTH for v in views):
        return None, "the heavy_lock settings lookup failed: ~/.claude/crewkit.md isn't yours or is writable by others"
    try:
        with open(user_file, encoding="utf-8", errors="replace") as f:
            has_key = re.search(r'^\s*["\']?heavy_lock["\']?\s*:', f.read(), re.M) is not None
    except OSError as e:
        return None, f"the heavy_lock settings lookup failed: can't read ~/.claude/crewkit.md ({e.strerror})"
    if not has_key:   # a superset of what settings.sh can match: no key, no setting, no bash needed
        return None, None
    sh = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "settings.sh")
    env = {"HOME": h, "PATH": "/usr/bin:/bin", "LC_ALL": "C"}   # nothing from the caller's environment
    try:
        r = subprocess.run([BASH, "--noprofile", "--norc", "-c", 'source "$1" && crew_setting heavy_lock', "_", sh],
                           cwd=h, env=env, capture_output=True, text=True, timeout=LOOKUP_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, "the heavy_lock settings lookup failed: timed out"
    except OSError as e:
        return None, f"the heavy_lock settings lookup failed: could not run bash ({e.strerror})"
    if r.returncode != 0:
        return None, f"the heavy_lock settings lookup failed: exit {r.returncode}"
    lines = r.stdout.strip().splitlines()
    if not lines or not lines[-1].strip():
        return None, None
    value = lines[-1].strip()
    if value.startswith("~/"):
        value = os.path.join(h, value[2:])
    if not os.path.isabs(value):
        return None, f"the heavy_lock settings lookup failed: the value is not an absolute path: {value}"
    try:
        st = os.lstat(value)
    except OSError:
        return None, f"the heavy_lock settings lookup failed: the value names no file: {value}"
    if not stat.S_ISREG(st.st_mode):
        return None, f"the heavy_lock settings lookup failed: the value is not a regular file (or is a symlink): {value}"
    if not os.path.isdir(os.path.dirname(value)):
        return None, f"the heavy_lock settings lookup failed: the value is in no existing directory: {value}"
    return value, None


def identity(path):
    """(st_dev, st_ino) of the regular file at `path`, opened without blocking; else None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        return (st.st_dev, st.st_ino) if stat.S_ISREG(st.st_mode) else None
    finally:
        os.close(fd)


def probe(path, mode, ident):
    """Try `mode` | LOCK_NB on a FRESH descriptor, release it at once. True: it was free for `mode`;
    False: it was held (EWOULDBLOCK); None: could not tell (including: not the file `ident`)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino) != ident or not stat.S_ISREG(st.st_mode):
            return None
        try:
            fcntl.flock(fd, mode | fcntl.LOCK_NB)
        except OSError as e:
            return False if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN) else None
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    finally:
        os.close(fd)


def inherited(ident):
    """The descriptors this process has open on the file `ident` (device, inode)."""
    if ident is None:
        return []
    fd_dir = "/proc/self/fd" if os.path.isdir("/proc/self/fd") else "/dev/fd"
    found = []
    for name in os.listdir(fd_dir):
        try:
            fd = int(name)
            st = os.fstat(fd)
        except (ValueError, OSError):
            continue
        if (st.st_dev, st.st_ino) == ident:
            found.append(fd)
    return found


def slot_files(directory):
    """The heavy.slotN files in `directory` (N = 1-999, the whole name), regular files only: a
    symlink, directory or FIFO is skipped and never opened."""
    try:
        names = sorted(n for n in os.listdir(directory) if SLOT_NAME.fullmatch(n))
    except OSError:
        return []
    found = []
    for n in names:
        path = os.path.join(directory, n)
        try:
            if stat.S_ISREG(os.lstat(path).st_mode):
                found.append(path)
        except OSError:
            pass
    return found


def ancestors():
    """The pids of this process and its parents, from ONE `ps` snapshot walked in memory (never from
    the environment), or None when the chain can't be read to the top."""
    ps = next((p for p in ("/bin/ps", "/usr/bin/ps") if os.access(p, os.X_OK)), None)
    if ps is None:
        return None
    try:
        r = subprocess.run([ps, "-A", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=BITC_TIMEOUT)
        if r.returncode != 0:
            return None
        parent = {}
        for line in r.stdout.splitlines():
            pid, ppid = line.split()
            parent[int(pid)] = int(ppid)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    chain, pid = [], os.getpid()
    while pid > 1 and pid not in chain:
        if pid not in parent:
            return None
        chain.append(pid)
        pid = parent[pid]
    return chain


REINSTALL = "re-run ./install.sh --only bitc --yes"


def recorded_bitc_sha256(h):
    """The sha256 install.sh recorded for the bitc it installed (<home>/.local/share/crewkit/bitc.sha256,
    a fixed path, no override), or None when the record is missing, unreadable, not ours, writable by
    others, or not exactly one 64-digit hex line."""
    path = os.path.join(h, ".local", "share", "crewkit", "bitc.sha256")
    if not owned_private(path, stat.S_ISREG):
        return None
    try:
        with open(path, encoding="ascii") as f:
            text = f.read(200)
    except (OSError, ValueError):
        return None
    return text.strip() if re.fullmatch(r"[0-9a-fA-F]{64}\n?", text) else None


def bitc_argv(binary, state, config):
    """The command line: the global flags (--state-dir, --config) go BEFORE the subcommand."""
    return [binary, "--state-dir", state, "--config", config, "status", "--json"]


def owned_private(path, kind):
    """True when `path` (not followed if a link) is a `kind` (stat.S_ISREG or S_ISDIR), is ours, and
    is not group- or other-writable."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return bool(kind(st.st_mode)) and st.st_uid == os.getuid() and not st.st_mode & (stat.S_IWGRP | stat.S_IWOTH)


def pinned_bitc(h):
    """(path, None) for <home>/.local/bin/bitc if it, its directory and that directory's parent are
    ours, not links and not group- or other-writable, and its sha256 equals recorded_bitc_sha256(h);
    else (None, why)."""
    path = os.path.join(h, ".local", "bin", "bitc")
    for p, kind in ((path, stat.S_ISREG), (os.path.dirname(path), stat.S_ISDIR),
                    (os.path.dirname(os.path.dirname(path)), stat.S_ISDIR)):
        if not owned_private(p, kind):
            return None, f"{p} is not yours, is a link or the wrong kind, is missing, or is group- or other-writable"
    want = recorded_bitc_sha256(h)
    if want is None:
        return None, f"install.sh's record (~/.local/share/crewkit/bitc.sha256) is missing, unreadable or malformed; {REINSTALL}"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError as e:
        return None, f"{path} can't be opened ({e.strerror})"
    try:
        with os.fdopen(fd, "rb", closefd=False) as f:
            digest = hashlib.sha256(f.read()).hexdigest()
    except OSError as e:
        return None, f"{path} can't be read ({e.strerror})"
    finally:
        os.close(fd)
    if digest != want.lower():
        return None, f"{path} does not match install.sh's record; {REINSTALL}"
    return path, None


def test_switch():
    """True only with the flock path's own test switch (CREWKIT_HEAVY_LOCK_TEST=1 and CREWKIT_HEAVY_LOCK)."""
    return os.environ.get(TEST_FLAG) == "1" and bool(os.environ.get("CREWKIT_HEAVY_LOCK"))


def bitc_refusal(why):
    global BITC_WHY
    BITC_WHY = why
    return None


def bitc_proof():
    """A description of the bitc hold this process is under, or None (see the docstring)."""
    job = os.environ.get("BITC_JOB")
    if job is None:
        return None
    if not BITC_JOB.fullmatch(job):
        return bitc_refusal("BITC_JOB is not a job id")
    h = home()
    if not h:
        return bitc_refusal("no home directory")
    state = os.path.join(h, ".local", "state", "bitc")
    config = os.path.join(h, ".config", "bitc", "bitc.toml")
    check_config = True
    if test_switch():   # the tests only
        binary = os.environ.get("BITC")
        state = os.environ.get("BITC_DIR") or state
        if os.environ.get("BITC_CONFIG"):
            config, check_config = os.environ["BITC_CONFIG"], False
        run_env = None
        if not binary:
            return bitc_refusal("no bitc binary")
    else:
        binary, why = pinned_bitc(h)
        run_env = {"HOME": h, "PATH": "/usr/bin:/bin", "LC_ALL": "C"}
        if not binary:
            return bitc_refusal(why)
        given = os.environ.get("BITC_DIR")
        if given and os.path.realpath(given) != os.path.realpath(state):
            return bitc_refusal("BITC_DIR is not the machine's bitc state directory")
    if check_config:   # decided here, not from bitc's stderr
        if not os.path.lexists(config):
            return bitc_refusal(f"bitc's host file {config} does not exist (bitc 0.1.4 then lists no pools or "
                                f"exits 78): install and configure bitc first (the heavy-pool cutover)")
        if not owned_private(config, stat.S_ISREG):   # bitc reads this same file and refuses an unsafe one too
            return bitc_refusal(f"{config} is not yours, is a link or the wrong kind, or is group- or other-writable")
    try:
        r = subprocess.run(bitc_argv(binary, state, config), capture_output=True, text=True,
                           timeout=BITC_TIMEOUT, stdin=subprocess.DEVNULL, env=run_env)
        if r.returncode != 0:
            return bitc_refusal(f"bitc status exited {r.returncode}")
        pools = json.loads(r.stdout)["pools"]
        pids = []
        for p in pools:
            if p["name"] not in BITC_POOLS:
                continue
            size = p["slots"]
            if type(size) is not int:
                continue
            pids += [hd["pid"] for hd in p["holders"]
                     if hd["job"] == job and type(hd["slot"]) is int and 1 <= hd["slot"] <= size]
    except (OSError, ValueError, KeyError, TypeError, RecursionError, subprocess.TimeoutExpired):
        return bitc_refusal("bitc status could not be read")
    chain = ancestors()
    if not chain:
        return bitc_refusal("the parent chain could not be read")
    for pid in pids:
        if type(pid) is int and pid in chain:
            return f"bitc job {job} (pid {pid})"
    return bitc_refusal("no bitc holder of this job is this process or an ancestor")


def proof():
    """How this run holds the heavy lock (or why none is needed), or None. CHECKED and WHY say
    which lock was looked at and, for a refusal that isn't a plain "not held", why."""
    global CHECKED, WHY, BITC_WHY
    CHECKED = WHY = BITC_WHY = None
    held = bitc_proof()
    if held:
        return held
    if os.environ.get(TEST_FLAG) == "1" and os.environ.get("CREWKIT_HEAVY_LOCK"):
        lock = os.environ["CREWKIT_HEAVY_LOCK"]
    else:
        default = default_lock()
        configured, err = configured_lock()
        if err:
            WHY = err
            return None
        lock = configured or default
        if not (default and os.path.isdir(os.path.dirname(default))) and not configured:
            return UNGUARDED
    CHECKED = lock
    ident = identity(lock)
    fds = inherited(ident)
    if not fds:
        return None
    if probe(lock, fcntl.LOCK_EX, ident) is not False:   # free (or unreadable): nobody holds it
        return None
    shared = probe(lock, fcntl.LOCK_SH, ident)
    if shared is None:
        return None
    if shared:   # a shared holder: a crew-heavy run, which also holds a slot
        directory = os.path.dirname(lock)
        for path in slot_files(directory):
            sid = identity(path)
            if inherited(sid) and probe(path, fcntl.LOCK_EX, sid) is False:
                break
        else:
            return None
    return f"descriptor {fds[0]} on {lock}"


def refusal(name, how):
    """The refusal text. It reads CHECKED and WHY, which proof() set: call it right after proof()
    in the same module instance (every caller does)."""
    if CHECKED:
        lock = CHECKED
    elif WHY:
        lock = f"the configured lock (lookup failed: {WHY})"
    else:
        lock = default_lock() or "~/.local/state/crew/heavy.lock"
    bitc = f"; bitc: {BITC_WHY}" if BITC_WHY else ""
    return (f"{name}: refused: a heavy job must hold the heavy lock and this one doesn't ({lock}){bitc}; "
            f"run it as: crew-heavy run <secs> {how}")


if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "heavy_lock.py"
    if proof():
        sys.exit(0)
    print(refusal(name, name), file=sys.stderr)
    sys.exit(1)
