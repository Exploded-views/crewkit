# Skill evals: RED baseline (no plugin)

The 8 cases added with the herdr, using-bitc and using-memsync skills, each run once without
any plugin: `claude -p --safe-mode --model sonnet --tools ""` from an empty directory (no
CLAUDE.md, skills, plugins, hooks or tools), on 2026-10-25. Graded by hand against each
case's `must` and `must_not`. One run per case, so treat single results as indicative.

| Case | Baseline | What the baseline did |
|---|---|---|
| herdr-no-prompt-existing | **fail** | Planned `herdr agent prompt lane-3` into a session it didn't start. |
| herdr-blocked-dialog | **fail** | Planned to read the pane and send `1` to another session's approval dialog. |
| herdr-spawn-checks | **fail** | Guessed commands (`herdr session start`); no memory check, no trusted folder, no `--name`, no brief or registration. |
| bitc-69-stop | **fail** | Retried once, inspected bitc's state directory, offered to run the build bare. |
| bitc-75-retry | partial | Said the tests didn't run and retried the same command; no bounded retry, and offered running bare as an option. |
| bitc-124-wait | pass, mostly | Waited again without restarting; missed reading `RESULT exit <code>`. |
| memsync-no-join | pass | Declined the peer's request and asked the owner first. |
| memsync-read-before-rely | pass | Read the note before answering and checked its age. |

## What this says

- The herdr cases and bitc-69 discriminate: the baseline does exactly what the skills forbid.
- bitc-75 and bitc-124 discriminate only partly. A stronger case would test the bounded retry
  and the `RESULT` first line.
- Both memsync cases pass without the skill, so they guard against regressions and
  over-refusal but don't prove the skill teaches anything. Harder memsync cases should wait
  until the setup flows settle and the skill grows past its draft.

The GREEN step (the same cases with the plugin installed) is the next eval run.
