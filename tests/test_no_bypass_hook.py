"""Tests for push-gate/no-bypass-hook.py, the Claude Code PreToolUse hook that refuses a Bash
command which would skip git's hooks (and so the push gate and the pre-commit scrub)."""
import json
import pathlib
import shlex
import subprocess
import sys
import unittest

HOOK = pathlib.Path(__file__).resolve().parent.parent / "push-gate" / "no-bypass-hook.py"


def run(command, tool="Bash"):
    payload = json.dumps({"tool_name": tool, "tool_input": {"command": command}})
    return subprocess.run([sys.executable, str(HOOK)], input=payload, capture_output=True, text=True)


BLOCKED = [
    "git -c core.hooksPath=/dev/null stash list",
    "git -c core.hooksPath= push origin main",
    'git -c "core.hooksPath=/dev/null" commit -m x',
    "git -c 'core.hooksPath'=/tmp push",
    "git -c core.hookspath=/dev/null push",
    "git -c CORE.HOOKSPATH=x push",
    "git -ccore.hooksPath=x push",
    "git --config-env=core.hooksPath=EMPTY push",
    "GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='/dev/null'\" git push",
    "env GIT_CONFIG_PARAMETERS=\"'core.hookspath'=''\" git commit -m x",
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git push",
    "export GIT_CONFIG_KEY_0=core.hooksPath",
    "git commit --no-verify -m x",
    "git push --no-verify origin main",
    "git commit -n -m x",
    "git commit -anm x",
    "git -C repo commit -qn -m x",
    "cd repo && git commit --no-verify -m x",
    'bash -c "git commit --no-verify -m x"',
    "sh -c 'git -c core.hooksPath=/dev/null push'",
    "git commit --no-verify=true -m x",
    # review of 8b9a01c: abbreviations, config writes and includes, substitutions, any nesting
    "git commit --no-veri -m x",
    "git push --no-verif origin main",
    "git --config-e=core.hooksPath=E push",
    "git config core.hooksPath /dev/null",
    "git config --local core.hooksPath .husky",
    "git config --global core.hooksPath /tmp/none",
    "git -c include.path=/tmp/evil.cfg commit -m x",
    "git -c includeIf.gitdir:/.path=/tmp/x push",
    "GIT_CONFIG_PARAMETERS=\"'include.path'='/tmp/x'\" git push",
    "echo $(git commit --no-verify -m x)",
    "echo `git commit --no-verify -m x`",
    "(git commit --no-verify -m x)",
    "echo $(git commit -m x --no-verify)",
    "x=`git push --no-verify`",
    "ssh host 'git commit --no-verify -m x'",
    'xargs -I{} sh -c "git push --no-verify origin {}"',
    # review of d5d427e: substitution inside a message, a separated --config-env, '#' mid-word
    'git commit -m "$(git push --no-verify)"',
    'git commit -m "`git push --no-verify`"',
    "git --config-env core.hooksPath=EMPTY push",
    "git commit -m x#y --no-verify",
    "git status\ngit commit -n -m x",
    # review of d9834b4 (part 2), #1: the global core.hooksPath removed, or the global config hidden
    "git config --global --unset core.hooksPath",
    "git config unset --global core.hooksPath",
    "git config --global --remove-section core",
    "GIT_CONFIG_GLOBAL=/dev/null git push origin main",
    "HOME=/tmp git push origin main",
    "git config --global --unset-all core.hooksPath",
    "git config --rename-section core old",
    "git config --remove-section include",
    "GIT_CONFIG_SYSTEM=/dev/null git push",
    "GIT_CONFIG=/tmp/x git push",
    "GIT_CONFIG_NOSYSTEM=1 git push",
    "XDG_CONFIG_HOME=/tmp git commit -m x",
    "env HOME=/tmp git push",
    "HOME=/tmp bash -c 'git push'",
    "env -i git push",
    "env -u HOME git push",
    # #2: a command that can't be parsed is refused; a comment is bash's, so its apostrophe is fine
    "git commit -n  # don't",
    "echo $'\\''; git commit --no-veri -m x",
    "git commit -m 'it''s --no-verify",
    # #3: an alias that hides a bypass
    "git -c 'alias.c=commit -n' c -m x",
    "git -c alias.p='push --no-verify' p origin main",
    "git -c 'alias.x=!git commit --no-verify' x",
    "git -c'alias.c=commit -n' c -m x",
    "git --config-env alias.c=E c -m x",
    "git config --global alias.c 'commit -n'",
    "GIT_CONFIG_PARAMETERS=\"'alias.c'='commit -n'\" git c -m x",
    # #4: line continuations and ANSI-C quoting
    "git commit --no-\\\nverify -m x",
    "git -c core.hooks\\\nPath=/dev/null push",
    "git commit $'\\x2d\\x2dno-verify' -m x",
    "git -c $'core.hooks\\x50ath=/dev/null' push",
    "git commit $'-\\055no-verify' -m x",
    # #5: config files written directly, plumbing commits and pushes, pre-commit's SKIP
    "printf '[core]\\n\\thooksPath = /dev/null\\n' >> ~/.gitconfig",
    "cat >> .git/config <<'EOF'\n[include]\n\tpath = /tmp/x\nEOF",
    "sed -i 's/^\\[user\\]/[core]\\n\\thooksPath=x\\n[user]/' .git/config",
    "echo '[includeIf \"gitdir:/\"]' | tee -a ~/.config/git/config",
    "git update-ref HEAD $(git commit-tree $(git write-tree) -p HEAD -m x)",
    "git send-pack https://example.com/r.git HEAD:refs/heads/main",
    "SKIP=scrub git commit -m x",
    "git http-push https://example.com/r.git main",
    "git commit -m x 2>&1 -n",
    # a heredoc that isn't one (inside quotes), and one whose body runs a command
    ": \"<<'X'\"\ngit commit -n -m x\nX",
    "cat <<EOF\n$(git commit -n -m x)\nEOF",
    # security review of ef7ef7a: a heredoc fed to a shell is a command, not data
    "bash <<'X'\ngit commit -n -m x\nX",
    "sh <<'X'\ngit push --no-verify\nX",
    "zsh <<X\ngit commit -n -m x\nX",
    "dash <<-'X'\n\tgit commit -n -m x\n\tX",
    "ksh <<'X'\ngit push --no-verify\nX",
    "ssh host <<'X'\ngit push --no-verify origin main\nX",
    "eval \"$(cat <<'X'\ngit commit -n -m x\nX\n)\"",
    "source /dev/stdin <<'X'\ngit commit -n -m x\nX",
    "cat <<'X' | bash\ngit commit -n -m x\nX",
    "xargs -0 git <<'X'\npush --no-verify\nX",
    "bash -c \"$(cat <<'X'\ngit commit -n -m x\nX\n)\"",
    "git commit -m \"$(cat <<'X' | bash\ngit push --no-verify\nX\n)\"",
    # a nested word that can't be parsed is still searched
    "bash -c \"git commit --no-verify -m 'x\"",
    "ssh host \"git commit -n -m it's\"",
    # a nested word shlex can't split, that could still run git: named through a backslash, or
    # built from a variable or a substitution
    "bash -c \"g\\\\it commit -n -m it's (x)\"",
    "bash -c \"$G commit $F -m it's (x)\"",
    # glob and brace forms build the name (and a flag) too
    "bash -c \"/usr/bin/g?t push --n?-verify it's (x)\"",
    "bash -c \"/usr/bin/g[i]t push --no-ver*fy it's (x)\"",
    "bash -c \"/usr/bin/{g,x}it push --n{o,}-verify it's (x)\"",
    "bash -c \"`echo g`it push --n`echo o`-verify it's\"",
    # the message exemption is git's and gh's only
    "bash -c -m 'git commit -n -m x'",
    "sh -c -m 'git push --no-verify'",
    "ssh host git commit -m 'x; git push --no-verify origin main'",
    "eval git commit -m '\"x\"; git commit -n -m y'",
    "xargs -m 'git commit -n -m x'",
    "ssh -t host 'git push --no-verify'",
    "bash -c -t 'git push --no-verify'",
    "git commit -m \"fix: $(git push --no-verify)\"",
    "git commit -m \"fix: `git push --no-verify`\"",
    "git commit -m \"$(cat <<X\n$(git push --no-verify)\nX\n)\"",
    # security review of 5dc8fd7: an unparsable nested word hiding a form in quotes, a backslash
    # or $'..'; a heredoc's own line setting a config variable; another $( before a message heredoc
    "bash -c \"git commit --n''o-verify -m 'x\"",
    "bash -c \"git -c core.hooks\\\\Path=/dev/null push 'x\"",
    "bash -c \"git commit --n$'o'-verify -m 'x\"",
    "bash -c \"git push --no-$(echo v)erify 'x\"",
    "ssh host \"git commit -m it's; GIT_CONFIG_GLOBAL=/dev/null git push\"",
    "GIT_CONFIG_GLOBAL=/dev/null bash <<'X'\ngit push\nX",
    "HOME=/tmp sh <<'X'\ngit push origin main\nX",
    "env -i bash <<'X'\ngit push\nX",
    "cat <<'X' | XDG_CONFIG_HOME=/tmp bash\ngit push\nX",
    "git commit -m \"$(bash -c -m \"$(cat <<'X'\ngit push --no-verify\nX\n)\")\"",
    "gh pr create --body \"$(bash -c -b \"$(cat <<'X'\ngit push --no-verify\nX\n)\")\"",
    # #7: deeper nesting than the hook follows is refused, not allowed
    "bash -c " + shlex.quote("bash -c " + shlex.quote("bash -c " + shlex.quote("bash -c " + shlex.quote("git commit --no-verify -m x")))),
    # a value or command after a substitution: the bare $ and ) are words, not nothing
    "git config core.hooksPath $(git rev-parse HEAD)",
    "x=$(git rev-parse HEAD) git commit -n -m x",
    "$(git log) git config core.hooksPath /x",
    # a $ stuck to the command word (a variable that could be git)
    "$git commit -n -m x",
    # an empty value, or one that starts with a dash: git stores it, and the hook is skipped
    'git config core.hooksPath ""',
    "git config core.hooksPath ''",
    'git config --global core.hooksPath ""',
    "git config --add core.hooksPath ''",
    "git config --replace-all core.hooksPath ''",
    "git config core.hooksPath -",
    "git config core.hooksPath -x",
    "git config core.hooksPath --local /x",
    "git config core.hooksPath --type=path /x",
    "git config core.hooksPath -- /x",
    "git config --global core.hooksPath --",
    "git config include.path ''",
    "git config include.path -x",
    # a read flag that is the value of an option taking one is not a read
    "git config --comment --get core.hooksPath /x",
    "git config -f --get core.hooksPath /x",
    "git config --file --get-all core.hooksPath /x",
    "git config --blob --list core.hooksPath /x",
    "git config --default --get core.hooksPath /x",
    "git config --type --get core.hooksPath /x",
    "git config -t --get core.hooksPath /x",
    "git config --comment ; git config core.hooksPath /x",
    # proven on git 2.56 (the key is set): --value takes the next word; unique prefixes of options
    # are options; after set, add or replace-all no read flag is a read
    "git config set --value --get core.hooksPath /x",
    "git config set --value --get-all core.hooksPath /x",
    "git config set --value -l core.hooksPath /x",
    "git config --comm --get core.hooksPath /x",
    "git config --comme --get core.hooksPath /x",
    "git config set --comm --get core.hooksPath /x",
    "git config set --val --get core.hooksPath /x",
    # fail closed: a read flag counts only after known no-argument options, written in full
    "git config --fil --get core.hooksPath /x",
    "git config --typ --get core.hooksPath /x",
    "git config --defa --get core.hooksPath /x",
    "git config --bl --get core.hooksPath /x",
    "git config --glob --get core.hooksPath /x",
    "git config set --get core.hooksPath /x",
    "git config add --get core.hooksPath /x",
    "git config --add --get core.hooksPath /x",
    "git config --replace-all --get core.hooksPath /x",
    "git config --default x --get core.hooksPath /x",
    "git config --file .git/config --get core.hooksPath /x",
    "git config --type bool --get core.hooksPath /x",
    "git config foo --get core.hooksPath /x",
    "git config --value --get core.hooksPath /x",
    "git config --get set core.hooksPath /x",
    "git config --get-all add core.hooksPath /x",
    # a redirection before a section's name doesn't hide it
    "git config --remove-section >/dev/null core",
    # a quoted substitution before a git command: over-refused on purpose (the shell would run
    # the substitution's output as the command), so what follows it is read afresh
    'git status "$(true)" git commit -n -m x',
]
ALLOWED = [
    "git commit -m 'never use --no-verify'",
    'git commit -m "docs: -c core.hooksPath= is forbidden"',
    "git push -n origin main",
    "git push --dry-run origin main",
    "git commit -m x",
    "git config --get core.hooksPath",
    "git log --oneline -3",
    "git -c user.name=t commit -m x",
    "grep -n 'no-verify' docs/push-gate.md",
    "echo GIT_CONFIG_PARAMETERS",
    "git config core.hooksPath",
    "git config --get core.hooksPath",
    "git config --global --get core.hooksPath",
    "git config --list",
    "git commit -m 'git config core.hooksPath /x is forbidden'",
    "git push --no-progress origin main",
    "git commit -m x\nls -n /tmp",
    # review of d9834b4 (part 2), #6: false positives
    "git commit -m \"$(cat <<'EOF'\nhook: refuse --no-verify\n\nA commit that says commit, then -n.\nEOF\n)\"",
    "git commit -am 'doc: refuse --no-verify'",
    "gh pr create --body 'refuses --no-verify'",
    "git log --grep commit -n 5",
    # reads with a further argument (a pattern, a value to match) are still reads
    "git config --get core.hooksPath /tmp",
    "git config --get-regexp core.hookspath ^/tmp",
    "git config --list core.hooksPath x",
    "git config core.hooksPath >/dev/null",
    "git config get core.hooksPath",
    "git config list",
    "git config --system --includes --get-all core.hooksPath x",
    "git config --local --show-origin --show-scope --name-only --get core.hooksPath",
    "git config --null --list core.hooksPath x",
    "git config -z --get-regexp core.hookspath",
    "git config --global --bool --get core.hooksPath /x",
    # every known no-argument option, in full, before a read flag
    "git config --global --local --system --worktree --show-origin --show-scope --null -z --name-only "
    "--show-names --includes --no-includes --bool --int --bool-or-int --bool-or-str --path --expiry-date "
    "--fixed-value --all --regexp --get core.hooksPath x",
    "git config core.hooksPath; echo x",
    # a << inside double quotes is text, not a heredoc whose body swallows the closing quote
    'echo "usage: cmd <<X\nmore text\n"',
    "grep commit CHANGELOG.md -n",
    "git config core.hooksPath 2>/dev/null || echo unset",
    "git config core.hooksPath 2>&1 | head -1",
    "git config core.hooksPath > /tmp/out",
    "git commit -F msg.txt",
    "git commit --message='refuse --no-verify'",
    "git commit -qam 'never -n, never --no-verify'",
    "gh pr create --title 'no --no-verify' --body \"$(cat <<'EOF'\nnever git commit -n\nEOF\n)\"",
    "gh issue comment 5 -b 'git commit --no-verify is refused'",
    "cat <<'EOF' > notes.md\nplain notes, nothing to run\nEOF",
    "cat <<'EOF' > notes.md\nThe hook's job (a guard) is done; see push-gate.md.\nEOF",
    "git commit -F - <<'EOF'\nhook: refuse --no-verify; it's done\nEOF",
    "git tag -a v1 -m \"$(cat <<'EOF'\nno --no-verify, it's fine\nEOF\n)\"",
    "cd repo && git -C . commit -qm \"$(cat <<'EOF'\nnever git commit -n\nEOF\n)\"",
    "ssh host 'echo \"it'\"'\"'s fine\"'",
    "ls  # don't",
    "echo \"it's fine\"",
    # prose that shlex can't split again, with a metacharacter but nothing that could run git
    "echo \"don't (x)\"",
    "grep -n \"it's (fixed); done\" notes.md",
    "echo \"can't > maybe | no\"",
    "cat <<'EOF' > notes.md\nIt's run as git status (read-only); nothing else.\nEOF",
    "HOME=/tmp ls",
    "XDG_CONFIG_HOME=/tmp/x nvim f",
    "grep -n hooksPath .git/config",
    "git -c alias.l='log -n 5' l",
    "git config --global --unset user.name",
    "git config --remove-section alias",
    "git config --global alias.st status",
    "git commit -uno -m x",
    "bash -c " + shlex.quote("bash -c " + shlex.quote("bash -c " + shlex.quote("git status"))),
]


class NoBypassHook(unittest.TestCase):
    def test_each_bypass_form_is_refused_with_exit_2_and_a_reason(self):
        for c in BLOCKED:
            with self.subTest(command=c):
                r = run(c)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("skips git's hooks", r.stderr)
                self.assertIn("owner", r.stderr)

    def test_ordinary_commands_pass(self):
        for c in ALLOWED:
            with self.subTest(command=c):
                r = run(c)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_other_tools_pass(self):
        self.assertEqual(run("git commit --no-verify", tool="Read").returncode, 0)

    def test_unbalanced_quotes_are_refused(self):
        self.assertEqual(run("git commit --no-verify -m 'oops").returncode, 2)
        r = run("git commit -m 'oops")
        self.assertEqual(r.returncode, 2)
        self.assertIn("can't be parsed", r.stderr)

    def test_unreadable_input_fails_closed(self):
        r = subprocess.run([sys.executable, str(HOOK)], input="not json", capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)

    def install(self, settings, *args):
        import tempfile
        d = pathlib.Path(tempfile.mkdtemp())
        f = d / "settings.json"
        if settings is not None:
            f.write_text(json.dumps(settings))
        r = subprocess.run([sys.executable, str(HOOK), "--install", *args, str(f)], capture_output=True, text=True)
        return r, f

    def test_install_dry_run_changes_nothing(self):
        r, f = self.install({"model": "x"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(f.read_text()), {"model": "x"})

    def test_install_adds_beside_an_existing_bash_hook_once_with_a_backup(self):
        rtk = {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook"}]}
        r, f = self.install({"hooks": {"PreToolUse": [rtk]}, "model": "x"}, "--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        pre = json.loads(f.read_text())["hooks"]["PreToolUse"]
        self.assertEqual(pre[0], rtk)
        self.assertEqual(len(pre), 2)
        self.assertEqual(pre[1]["matcher"], "Bash")
        self.assertTrue(pre[1]["hooks"][0]["command"].endswith("no-bypass-hook.py"))
        self.assertTrue((f.parent / "settings.json.bak-no-bypass").exists())
        r2 = subprocess.run([sys.executable, str(HOOK), "--install", "--yes", str(f)], capture_output=True, text=True)
        self.assertIn("already installed", r2.stdout)
        self.assertEqual(len(json.loads(f.read_text())["hooks"]["PreToolUse"]), 2)

    def test_install_into_a_missing_file_creates_it(self):
        r, f = self.install(None, "--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(f.read_text())["hooks"]["PreToolUse"]), 1)

    def test_install_refuses_a_settings_file_that_isnt_an_object(self):
        r, f = self.install([1, 2], "--yes")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(json.loads(f.read_text()), [1, 2])


if __name__ == "__main__":
    unittest.main()
