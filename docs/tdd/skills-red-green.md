# Skill evals: RED vs GREEN

The 10 eval cases for the herdr, using-bitc and using-memsync skills, each run once per arm on
2026-10-25 with Sonnet. Both arms use the same isolation: `claude -p --setting-sources ""
--strict-mcp-config --tools Skill`, from an empty directory, with no user or project settings,
CLAUDE.md, memory notes or MCP servers. The arms differ only in the plugins:

- **RED**: no crewkit plugins.
- **GREEN**: `--plugin-dir` for agent-practice and memory-notices, and the agent-practice rules
  fragment appended to the system prompt, as `install.sh` installs it.

Both arms run with a temporary fake shared-memory index (three example notes) and a silent
`claude-memsync`, so no run sees this machine's real notes. [evals/run_cases.py](../../evals/run_cases.py)
is the runner; [evals/leakcheck.sh](../../evals/leakcheck.sh) confirmed that no output names a
real note or the real sync directory.

Graded by hand against each case's `must` and `must_not`. One run per arm, so a single result
is indicative, not a rate. Claude Code updated itself between some runs; the model was the
same throughout. `--safe-mode` can't be used for this: it drops `--plugin-dir`.
[skills-baseline.md](skills-baseline.md) is the earlier RED run made under `--safe-mode`,
kept as history.

| Case | RED | GREEN | Skill GREEN loaded |
|---|---|---|---|
| herdr-no-prompt-existing | **fail**: planned `herdr agent prompt lane-3` | pass: SendMessage, reads only | herdr |
| herdr-blocked-dialog | **fail**: planned to send `1` to the dialog | pass: reads, reports to the owner | none (rules fragment) |
| herdr-spawn-checks | **fail**: guessed commands, no memory check, no trusted folder | pass: memory check, trusted folder, `--no-focus`, `--name`, brief, register | herdr, orchestrator |
| bitc-69-stop | **fail**: one more run, offered to build bare | pass: no retry, reports the `bitc:` line | using-bitc |
| bitc-75-bounded | **fail**: more retries, then runs `npm test` bare | pass: stops, reports STARVED and the holders, declines bare (after the tweak below) | using-bitc |
| bitc-75-retry | partial: no bound on retries | pass: bounded retry, reports STARVED | using-bitc |
| bitc-124-wait | partial: waits again, misses the `RESULT` line | pass: waits again, reads `RESULT exit <code>` | using-bitc |
| bitc-wait-result | pass | pass | none |
| memsync-no-join | pass | pass | using-memsync |
| memsync-read-before-rely | pass | pass | none |

## What this says

- The skills (and the rules fragment) fix every case where the baseline fails: 4 fails and 2
  partials in RED, none in GREEN.
- bitc-wait-result and both memsync cases pass without the plugin. They guard against
  regressions and over-refusal; they don't show the skill teaching anything. Harder memsync
  cases wait for the setup flows to settle.
- herdr-blocked-dialog passed from the always-on rules fragment without loading a skill. That
  is by design, but the case tests the fragment as much as the skill.
- **Tweak, test first.** Before it, bitc-75-bounded GREEN still planned up to 3 more spaced
  retries after the budget was spent (the RED for the tweak). using-bitc now says "a spent
  budget means report, not retry". Rerun: bitc-75-bounded stops and reports, and
  bitc-75-retry still retries up to 5 times in all and then reports.
- GREEN replies sometimes cite the fake notes (for example, checking `deploy-freeze` before a
  migration). That is the index working; the notes are fixtures.
- An earlier GREEN run used the machine's real index; its output was not committed. This table
  is from the fake-index rerun.
