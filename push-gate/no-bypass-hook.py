#!/usr/bin/env python3
"""no-bypass-hook.py: a Claude Code PreToolUse hook (matcher Bash) that refuses a command which
would skip git's hooks, and with them the push gate and the pre-commit scrub.

Refused, in any case, through quoting, env, $(...), backticks, subshells and any word that is
itself a command (bash -c "...", ssh host '...'):
  -c core.hooksPath=... and -c include.path= / includeIf.* (git -c, -c<key>, --config-env and
      its abbreviations), the same keys in GIT_CONFIG_PARAMETERS or GIT_CONFIG_KEY_<n>
  git config <those keys> <value>, --unset / --unset-all / unset of them, and --remove-section /
      --rename-section of core, include or includeIf (reading them, --get or --list, passes)
  an alias (-c alias.*, --config-env alias.*, git config alias.*) whose command is refused here
  --no-verify and any abbreviation git accepts for it (--no-veri), and -n in git commit's short
      flags (git push -n is --dry-run, and passes)
  GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG, GIT_CONFIG_NOSYSTEM, HOME, XDG_CONFIG_HOME or
      pre-commit's SKIP set (or env -i / env -u) for a command that runs git
  git commit-tree, send-pack and http-push (a commit or a push with no hooks)
  a write (>, >>, tee, sed -i, perl -i) to .gitconfig, .git/config, git/config or
      config.worktree when the command mentions hooksPath or [include
The command is read the way bash would: a backslash-newline joins lines, a # that starts a word
starts a comment, and $'...' is decoded. A heredoc's body is checked as a command of its own
(bash <<'X', ssh host <<'X'), except a message's: git commit/tag/notes/merge -m "$(cat <<'X'",
-F - <<'X', or gh --body "$(cat <<'X'", with no other $( before it and nothing after the
delimiter on its line; a variable set on the heredoc's line counts for its body. It is
then split into words (shlex), and every word holding whitespace is split again, except a
message of git commit/tag/notes/merge (-m, -am, -F, --message) or gh (--body, --title, -b, -t)
as the command itself, so a message that mentions these forms isn't refused; an argument of
bash -c, ssh, eval or xargs is split whatever flag comes before it. A command that can't be
parsed is refused. A word inside it that can't be parsed is refused if it holds a shell
metacharacter (\\ $ ` ; & | < > ( )) and could run git: it names git (quotes and backslashes
taken out) or holds $, `, a glob or a brace (which could build the name). Otherwise, like a heredoc body that
can't be parsed (prose: "it's (x)"), it is searched as plain text, without quotes and
backslashes, for these forms.
Nesting deeper than three levels is refused.
Input that can't be read is refused. A variable that hides a flag ($X) can't be seen here: this
is a guard against habit, and the push gate is what enforces.

Exit 0 = allowed, 2 = refused (the reason on stderr, which Claude Code shows the session); any
error in the hook itself also refuses.

  no-bypass-hook.py --install [--yes] [SETTINGS]   add this hook to SETTINGS (default
      ~/.claude/settings.json) as a PreToolUse Bash hook beside any already there (rtk's), once;
      dry run without --yes; with --yes a backup goes to SETTINGS.bak-no-bypass first.
      Exit 0 = done or dry run, 1 = SETTINGS isn't a JSON object, 64 = usage.
"""
import json
import os
import re
import shlex
import shutil
import sys

REASON = ("no-bypass-hook: refused: this command skips git's hooks (the push gate and the "
          "pre-commit scrub) via {what}. Run git without it. Only the owner may bypass a gate, "
          "by running the command themselves.")
HOOKSPATH = "core.hookspath"


# Config keys that set where git finds its hooks, directly or by including another config file,
# and the sections that hold them.
HOOK_KEYS = (HOOKSPATH, "include.path", "includeif.")
HOOK_SECTIONS = ("core", "include", "includeif")
# A message is data only as an argument of git's commands that take one, or of gh.
MESSAGE_SUBS = {"commit", "tag", "notes", "merge"}
GIT_MESSAGE_FLAGS = {"-m", "--message", "-F", "--file"}
GH_MESSAGE_FLAGS = {"-b", "-t", "-F", "--body", "--title", "--body-file"}
# The line before a heredoc's << that makes its body a message: git commit/tag/notes/merge (or
# gh) as the command, and -m "$(cat or -F - (gh: --body "$(cat ...) just before it, with no other
# $( or ` between (so the -m is git's own, not that of a command inside a substitution).
GIT_MESSAGE_LINE = re.compile(
    r"\s*(?:[A-Za-z_]\w*=[^\s$`]*\s+)*(?:(?:sudo|env|command|nice|nohup|time)\s+)*(?:[^\s$`]*/)?git"
    r"(?:\s+(?:-[Cc]|--git-dir|--work-tree|--namespace)\s+[^\s$`]+|\s+-[^\s$`]+)*\s+(?:commit|tag|notes|merge)(?=\s)"
    r"(?:(?!\$\(|`).)*(?:\s(?:-[A-Za-z]*m|--message)[=\s]*\"?\$\(\s*cat|\s(?:-[A-Za-z]*F|--file)[=\s]*(?:-|\"?\$\(\s*cat))\s*$")
GH_MESSAGE_LINE = re.compile(
    r"\s*(?:[^\s$`]*/)?gh\s(?:(?!\$\(|`).)*\s(?:-[bt]|--body|--title)[=\s]*\"?\$\(\s*cat\s*$")
# What a nested word that can't be parsed is still searched for, as plain text.
RAW_RISK = re.compile(r"--no-v|hookspath|include\.path|includeif|alias\.|git_config|commit-tree|send-pack"
                      r"|http-push|\bcommit\b.*\s-[a-z]*n|\b(?:home|xdg_config_home|skip)=|\benv\s+-"
                      r"|\.gitconfig|\.git/config", re.S)
# What a nested word that can't be parsed is refused for outright: any of these could hide a form
# from the plain-text search, or run something...
METACHARS = re.compile(r"[\\$`;&|<>()]")
# ...when it could run git at all: it names git, or $, `, a glob (? * [ ]) or a brace ({ }) could
# build the name.
RUNS_GIT = re.compile(r"\bgit\b|[$`?*\[\]{}]")
READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--list", "-l"}
# A read flag counts only when every word before it after `config` is one of these, written in
# full: options that take no argument. git accepts any unique prefix of an option and some options
# take the next word (--value, --comment, ...), so anything else could swallow the flag as its value.
CONFIG_NOARG_OPTS = {"--global", "--local", "--system", "--worktree", "--show-origin", "--show-scope",
                     "--null", "-z", "--name-only", "--show-names", "--includes", "--no-includes", "--bool",
                     "--int", "--bool-or-int", "--bool-or-str", "--path", "--expiry-date", "--fixed-value",
                     "--all", "--regexp"}
# These write: after one of them no read flag is honoured, and an earlier one no longer stands.
CONFIG_WRITE_WORDS = {"set", "add", "replace-all", "--add", "--replace-all"}
UNSET_FLAGS = {"--unset", "--unset-all", "unset"}
SECTION_FLAGS = {"--remove-section", "--rename-section", "remove-section", "rename-section"}
# git commands that commit or push without running any hook.
PLUMBING = {"commit-tree", "send-pack", "http-push"}
# Variables that point git at another config (or none), or skip pre-commit hooks by id.
CONFIG_ENV = {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG", "GIT_CONFIG_NOSYSTEM", "HOME",
              "XDG_CONFIG_HOME", "SKIP"}
# Words before a command that leave the next word still a command (env HOME=x git ...).
PREFIXES = {"env", "sudo", "command", "exec", "nice", "nohup", "time"}
# git's global options that take the next word as their value (git -C dir commit).
GIT_ARG_OPTS = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
REDIRECT = re.compile(r"[0-9]*(?:&>>?|>>?\|?|<<?<?|>&|<&|<>)(.*)")
CONFIG_FILE = re.compile(r"\.gitconfig|\.git/config|/git/config|config\.worktree")
SEPARATOR = re.compile(r"[;&|()]+")
# <<WORD or <<-WORD, the word quoted in whole or in part or not at all.
HEREDOC = re.compile(r"<<(-?)[ \t]*((?:[^\s;&|()<>'\"\\]|\\.|'[^']*'|\"[^\"]*\")+)")
ESCAPES = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r",
           "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
MAX_DEPTH = 3
# A variable set (or env -i / env -u) on a heredoc's own line: its body runs with it.
LINE_ENV = re.compile(r"(?:^|[\s;&|(])(" + "|".join(sorted(CONFIG_ENV)) + r")=|\benv\s+(?:\S+\s+)*?(-i|-|--ignore-environment|-u|--unset)(?=[\s=])")


def strip_subst(w):
    """A word without the $( ` ( ) of a substitution or subshell stuck to it; a bare $ or ) stays,
    or it would read as no word at all (git config core.hooksPath $(...) has a value)."""
    return w.lstrip("$(`").rstrip(")`") or w


def abbrev_of(word, option, shortest):
    """True if WORD (before any =) is OPTION or an abbreviation git would accept for it."""
    base = word.split("=", 1)[0]
    return len(base) >= shortest and option.startswith(base)


def ansi_c(body):
    """The text bash makes of $'BODY'."""
    def one(m):
        e = m.group(1)
        if e[0] in "xuU":
            return chr(min(int(e[1:], 16), 0x10FFFF))
        if e[0] in "01234567":
            return chr(int(e, 8) & 0xFF)
        if e[0] == "c":
            return chr(ord(e[1]) & 0x1F)
        return ESCAPES.get(e, "\\" + e)
    return re.sub(r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|[0-7]{1,3}|c.|.)", one, body,
                  flags=re.S)


def message_line(line):
    """True if a heredoc opened at the end of LINE is a git or gh message."""
    seg = re.split(r"[;&|]", line)[-1]
    return bool(GIT_MESSAGE_LINE.match(seg) or GH_MESSAGE_LINE.match(seg))


def normalize(command, drop_heredocs=True, bodies=None):
    """COMMAND as bash reads it: line continuations joined, comments dropped, $'...' decoded and
    quoted again. With DROP_HEREDOCS every heredoc body is taken out: a message's (git commit -m
    "$(cat <<'X' ...", -F -, gh --body) is data and dropped, unless it is unquoted and runs a
    command; any other is a command (bash <<X, ssh host <<X) and goes to BODIES, to be checked."""
    out, stack, depth, heredocs = [], ["sh"], [0], []
    i, n = 0, len(command)

    def last():
        return out[-1][-1:] if out else ""
    while i < n:
        c, ctx = command[i], stack[-1]
        if c == "\\" and command[i + 1:i + 2] == "\n":
            i += 2
            continue
        if ctx == "dq":
            if c == "\\":
                out.append(command[i:i + 2])
                i += 2
            elif c == '"':
                stack.pop()
                out.append(c)
                i += 1
            elif command.startswith("$(", i):
                stack.append("sh")
                depth.append(0)
                out.append("$(")
                i += 2
            else:
                out.append(c)
                i += 1
            continue
        if c == "\\":
            out.append(command[i:i + 2])
            i += 2
        elif c == "'":
            j = command.find("'", i + 1)
            j = n - 1 if j < 0 else j
            out.append(command[i:j + 1])
            i = j + 1
        elif c == '"':
            stack.append("dq")
            out.append(c)
            i += 1
        elif command.startswith("$'", i):
            j, buf = i + 2, []
            while j < n and command[j] != "'":
                buf.append(command[j:j + 2] if command[j] == "\\" else command[j])
                j += len(buf[-1])
            q = shlex.quote(ansi_c("".join(buf)))
            if "dq" in stack:
                q = q.replace("\\", "\\\\").replace('"', '\\"')
            out.append(q)
            i = j + 1
        elif c == "#" and last() in ("", " ", "\t", "\n", ";", "&", "|", "(", ")", "<", ">"):
            j = command.find("\n", i)
            i = n if j < 0 else j
        elif command.startswith("<<", i) and not command.startswith("<<<", i):
            m = HEREDOC.match(command, i)
            if not m:
                out.append("<<")
                i += 2
                continue
            word = m.group(2)
            before, after = "".join(out).rsplit("\n", 1)[-1], command[m.end():].split("\n", 1)[0]
            heredocs.append((re.sub(r"[\\'\"]", "", word), m.group(1) == "-", word != re.sub(r"[\\'\"]", "", word),
                             message_line(before) and not after.strip(), before + m.group(0) + after))
            out.append(m.group(0))
            i = m.end()
        elif c == "\n" and heredocs:
            out.append("\n")
            i += 1
            for delim, tabs, quoted, message, opener in heredocs:
                body = []
                while i < n:
                    e = command.find("\n", i)
                    line = command[i:] if e < 0 else command[i:e]
                    i = n if e < 0 else e + 1
                    if (line.lstrip("\t") if tabs else line) == delim:
                        break
                    body.append(line)
                text = "\n".join(body)
                if not drop_heredocs:
                    out.append(text + "\n")
                elif not message or (not quoted and ("$(" in text or "`" in text)):
                    if bodies is not None:
                        bodies.append((text, opener))
            heredocs = []
        else:
            if c == "(":
                depth[-1] += 1
            elif c == ")":
                depth[-1] -= 1
                if depth[-1] < 0 and len(stack) > 1:
                    stack.pop()
                    depth.pop()
            out.append(c)
            i += 1
    return "".join(out)


def config_write(text):
    """A write to a git config file that mentions hooksPath or [include, or None."""
    lt = text.lower()
    if HOOKSPATH.split(".")[1] not in lt and "[include" not in lt:
        return None
    for seg in re.split(r"[\n;&|]", lt):
        if not CONFIG_FILE.search(seg):
            continue
        if re.search(r">\s*['\"]?[^\s'\"]*(?:\.gitconfig|\.git/config|/git/config|config\.worktree)", seg) \
                or re.search(r"\btee\b", seg) \
                or (re.search(r"\b(?:sed|perl)\b", seg) and re.search(r"\s-[a-z]*i", seg)):
            return "a write to a git config file"
    return None


def join_redirects(words):
    """WORDS with a redirection shlex split apart (2>&1, &>file, >|file) as one word again."""
    out = []
    for w in words:
        if out and w == "&" and out[-1][-1:] in "<>" and REDIRECT.fullmatch(out[-1]):
            out[-1] += w
        elif out and out[-1] == "&" and w.startswith(">"):
            out[-1] += w
        elif out and w == "|" and out[-1].endswith(">") and REDIRECT.fullmatch(out[-1]):
            out[-1] += w
        elif out and out[-1].endswith(("&", ">|")) and REDIRECT.fullmatch(out[-1]) and out[-1] != "&":
            out[-1] += w
        else:
            out.append(w)
    return out


def next_word(words, i):
    """The word after WORDS[i] that isn't a redirection (or its target), lowered; '' at the end."""
    j = i + 1
    while j < len(words):
        w = strip_subst(words[j]).lower()
        m = REDIRECT.fullmatch(w)
        if not m:
            return w
        j += 1 if m.group(1) else 2
    return ""


def has_value(words, i):
    """True if a word follows WORDS[i] that is a value: anything, an empty word and a dash-led
    one included, but not a redirection (or its target) or a separator."""
    j = i + 1
    while j < len(words):
        m = REDIRECT.fullmatch(strip_subst(words[j]))
        if not m:
            return not SEPARATOR.fullmatch(words[j])
        j += 1 if m.group(1) else 2
    return False


def alias_finding(kv, depth):
    """What the alias in KV (alias.<name>=<command>) skips, or None."""
    value = kv.split("=", 1)[1] if "=" in kv else ""
    value = value[1:] if value.startswith("!") else "git " + value
    return finding_in(value, depth + 1)


def commit_short_n(w):
    """True if W is a cluster of git commit's short flags that holds -n (-qn, -anm); a flag that
    takes a value (-m, -F, -C, -c, -t, -S, -u) ends the cluster."""
    if not re.fullmatch(r"-[A-Za-z][^\s]*", w):
        return False
    for ch in w[1:]:
        if ch == "n":
            return True
        if ch in "mFCctSu" or not ch.isalpha():
            return False
    return False


def finding_in_words(words, depth=0, env=None):
    """What in WORDS skips the hooks, or None. ENV names a variable set for the command around
    them that hides git's config (HOME=/tmp bash -c '...')."""
    words = join_redirects(words)
    git = in_commit = in_config = config_read = config_unset = git_arg = cfg_clean = False
    sub = cmd = None
    cmd_pos, risky, prefix = True, env, None
    for i, raw in enumerate(words):
        w = strip_subst(raw)
        lw = w.lower()
        nxt = next_word(words, i)
        raw_next = strip_subst(words[i + 1]) if i + 1 < len(words) else ""
        if lw == "-c" and nxt.startswith(HOOK_KEYS):
            return "-c " + nxt.split("=", 1)[0]
        if lw.startswith(tuple("-c" + k for k in HOOK_KEYS)):
            return "-c " + lw[2:].split("=", 1)[0]
        if lw == "-c" and nxt.startswith("alias."):
            found = alias_finding(raw_next, depth)
            if found:
                return "an alias: " + found
        if lw.startswith("-calias."):
            found = alias_finding(w[2:], depth)
            if found:
                return "an alias: " + found
        if abbrev_of(lw, "--config-env", len("--config-e")) and (
                lw.split("=", 1)[-1].startswith(HOOK_KEYS) or ("=" not in lw and nxt.startswith(HOOK_KEYS))):
            return "--config-env"
        if abbrev_of(lw, "--config-env", len("--config-e")) and (
                lw.split("=", 1)[-1].startswith("alias.") or ("=" not in lw and nxt.startswith("alias."))):
            return "--config-env alias.*"
        if lw.startswith("git_config_parameters=") and any(k in lw for k in HOOK_KEYS):
            return "GIT_CONFIG_PARAMETERS"
        if lw.startswith("git_config_parameters=") and "alias." in lw:
            return "an alias in GIT_CONFIG_PARAMETERS"
        if re.match(r"git_config_key_[0-9]+=", lw) and lw.split("=", 1)[1].startswith(HOOK_KEYS + ("alias.",)):
            return "GIT_CONFIG_KEY_<n>"
        if abbrev_of(lw, "--no-verify", len("--no-v")):
            return "--no-verify"
        # A separator ends a command; a substitution or subshell starts one.
        if SEPARATOR.fullmatch(lw) or raw.startswith(("$(", "`", "(")):
            git = in_commit = in_config = config_read = config_unset = git_arg = cfg_clean = False
            sub = cmd = None
            cmd_pos, risky, prefix = True, env, None
            if SEPARATOR.fullmatch(lw):
                continue
        if cmd_pos:
            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", w)
            if m:
                if m.group(1).upper() in CONFIG_ENV:
                    risky = risky or m.group(1)
            elif lw in PREFIXES:
                prefix = lw
            elif prefix == "env" and lw in ("-i", "--ignore-environment", "-"):
                risky = risky or "env " + lw
            elif prefix == "env" and lw in ("-u", "--unset") and raw_next.upper() in CONFIG_ENV:
                risky = risky or "env -u " + raw_next
            elif prefix == "env" and lw.startswith("--unset=") and w.split("=", 1)[1].upper() in CONFIG_ENV:
                risky = risky or "env " + w
            elif prefix and lw.startswith("-"):
                pass
            else:
                cmd_pos, cmd = False, lw.rsplit("/", 1)[-1]
        if lw.rsplit("/", 1)[-1] == "git" and not git:
            if risky:
                return risky + " set for git"
            git, sub, git_arg = True, None, False
        elif git and sub is None:
            if git_arg:
                git_arg = False
            elif lw in GIT_ARG_OPTS:
                git_arg = True
            elif not lw.startswith("-"):
                sub = lw
                if sub in PLUMBING:
                    return "git " + sub
                in_commit, in_config = sub == "commit", sub == "config"
                cfg_clean = True
        elif in_config and lw in CONFIG_NOARG_OPTS:
            pass
        elif in_config and lw in READ_FLAGS and cfg_clean:
            config_read = True
        elif in_config and lw in CONFIG_WRITE_WORDS:
            cfg_clean, config_read = False, False
        elif in_config and lw in UNSET_FLAGS:
            config_unset = True
        elif in_config and lw in SECTION_FLAGS and (nxt in HOOK_SECTIONS or nxt.startswith("includeif.")):
            return "git config " + lw + " " + nxt
        elif in_config and config_unset and lw.startswith(HOOK_KEYS):
            return "git config --unset " + lw
        elif in_config and not config_read and lw.startswith(HOOK_KEYS) and has_value(words, i):
            return "git config " + lw
        elif in_config and not config_read and lw.startswith("alias.") and raw_next:
            found = alias_finding(lw + "=" + raw_next, depth)
            if found:
                return "an alias: " + found
        elif in_config:
            cfg_clean = False   # any other word: an option it doesn't know, or a positional
        elif in_commit and commit_short_n(w):
            return "git commit -n"
        # A word holding a command of its own (bash -c "...", ssh host '...', xargs sh -c ...) is
        # split again; a message isn't, so its text can mention the forms.
        # A message holding $( or ` runs a command, so it is split too.
        prev = words[i - 1] if i > 0 else ""
        # Only git (commit, tag, notes, merge) or gh as the command itself: an argument of
        # bash -c, ssh, eval or xargs is a command whatever flag comes before it.
        git_message = cmd == "git" and sub in MESSAGE_SUBS and (
            prev in GIT_MESSAGE_FLAGS or re.fullmatch(r"-[A-Za-z]*[mF]", prev)
            or re.match(r"--message=|-[A-Za-z]*m.", raw))
        gh_message = cmd == "gh" and (prev in GH_MESSAGE_FLAGS or re.match(r"--(?:body|title)=", raw))
        message = (git_message or gh_message) and "$(" not in raw and "`" not in raw
        if (" " in raw or "\t" in raw or "$(" in raw or "`" in raw) and not message:
            if depth >= MAX_DEPTH:
                return "a command nested deeper than the hook follows"
            found = finding_in(raw, depth + 1, risky)
            if found:
                return found
    return None


def finding_in(command, depth=0, env=None, body=False):
    found = config_write(normalize(command, drop_heredocs=False))
    if found:
        return found
    bodies = []
    text = normalize(command, bodies=bodies)
    try:
        # A newline ends a command, as ; does; a comment is gone already, so # is a plain
        # character here (shlex would take it anywhere).
        lexer = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
    except ValueError:
        # The command itself is refused rather than guessed at. A word inside it (or a heredoc
        # body) that can't be parsed may be prose ("it's"), so it is searched as plain text.
        # A nested word holding a metacharacter is refused; a heredoc body (a file being written
        # may hold "print('it's')") is searched with its quotes and backslashes taken out.
        if depth == 0:
            return "a command that can't be parsed"
        plain = re.sub(r"[\\'\"]", "", text).lower()
        if not body and METACHARS.search(text) and RUNS_GIT.search(plain):
            return "a nested command that can't be parsed, with a shell metacharacter"
        m = RAW_RISK.search(plain)
        return f"a nested command that can't be parsed, holding {m.group(0)!r}" if m else None
    found = finding_in_words(words, depth, env)
    for text_, opener in bodies:
        line_env = LINE_ENV.search(opener)
        found = found or finding_in(text_, depth + 1, env or (line_env and line_env.group(0).strip()), body=True)
    return found


def install(argv):
    yes = "--yes" in argv
    rest = [a for a in argv if a != "--yes"]
    if len(rest) > 1 or any(a.startswith("-") for a in rest):
        print("usage: no-bypass-hook.py --install [--yes] [SETTINGS]", file=sys.stderr)
        return 64
    path = rest[0] if rest else os.path.expanduser("~/.claude/settings.json")
    me = os.path.realpath(__file__)
    command = f"python3 {me}"
    try:
        with open(path) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    except (OSError, ValueError) as e:
        print(f"no-bypass-hook: can't read {path} ({e.__class__.__name__})", file=sys.stderr)
        return 1
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        print(f"no-bypass-hook: {path} isn't a settings object", file=sys.stderr)
        return 1
    pre = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
    if any(h.get("command") == command for e in pre if isinstance(e, dict) for h in e.get("hooks", []) if isinstance(h, dict)):
        print(f"already installed in {path}")
        return 0
    pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": command}]})
    print(f"add a PreToolUse Bash hook to {path}: {command}")
    if not yes:
        print("(dry run: nothing changed; --yes to do it)")
        return 0
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak-no-bypass")
    tmp = path + ".new"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print("installed")
    return 0


def main():
    if sys.argv[1:2] == ["--install"]:
        return install(sys.argv[2:])
    try:
        event = json.load(sys.stdin)
        if event.get("tool_name") != "Bash":
            return 0
        command = event["tool_input"]["command"]
        if not isinstance(command, str):
            raise TypeError
    except (ValueError, KeyError, TypeError, AttributeError):
        print("no-bypass-hook: refused: the hook input can't be read", file=sys.stderr)
        return 2
    try:
        what = finding_in(command)
    except Exception as e:  # noqa: BLE001 - any failure in the check refuses rather than allows
        print(f"no-bypass-hook: refused: the check failed ({e.__class__.__name__})", file=sys.stderr)
        return 2
    if what:
        print(REASON.format(what=what), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
