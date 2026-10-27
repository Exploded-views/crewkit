# agent-practice

A Claude Code plugin with the working practices for running several Claude Code sessions
against one repo, one `main` and one host. It ships skills (loaded on demand) and a short
rules fragment (always on, if you include it).

## Skills

| Skill | Use when |
|---|---|
| [cross-session-messaging](skills/cross-session-messaging/SKILL.md) | Sending or acting on a message from another session; relaying or relying on an approval. |
| [orchestrator](skills/orchestrator/SKILL.md) | Being, starting or resuming the coordinating session: authority, sequencing, durable log, holds, paging; starting and briefing new role sessions, or orienting yourself after being started. |
| [landing](skills/landing/SKILL.md) | Merging to a shared `main`: what green means, freshness, the handshake, pinned merges, verifying the deployed tip. |
| [independent-review](skills/independent-review/SKILL.md) | Reviewing someone else's PR for merge; deciding whether a change needs an independent review and on which model. |
| [host-safety](skills/host-safety/SKILL.md) | Running heavy commands, containers, waiters or kills on a host other sessions share. |
| [secret-safe-checks](skills/secret-safe-checks/SKILL.md) | Checking for secrets or personal data without printing them; moving secrets; scrubbing a repo. |
| [crash-recovery](skills/crash-recovery/SKILL.md) | Coming back after a host restart, harness crash, usage-limit stall or account change. |
| [herdr](skills/herdr/SKILL.md) | Inside herdr: reading other sessions' state and screens, spawning a named session, choosing SendMessage over typing into a pane. |
| [using-bitc](skills/using-bitc/SKILL.md) | Running heavy commands through the bitc slot pool and reading its exit codes (75 retry, 124 wait again, 69 stop). |

## Rules fragment

[rules/CLAUDE-fragment.md](rules/CLAUDE-fragment.md) holds the rules that should apply even
when no skill has loaded. Claude Code doesn't load a plugin's markdown as context, so include it
yourself, either by copying it to `~/.claude/rules/agent-practice.md` or by adding an import line
to your `CLAUDE.md`:

```text
@/path/to/crewkit/plugins/agent-practice/rules/CLAUDE-fragment.md
```

## Settings

Nothing project-specific is hard-coded. Each skill names the settings it reads, and falls
back to the defaults below. Put your values in a settings file with YAML frontmatter:

- per project: `.claude/agent-practice.local.md` (add it to `.gitignore`), or
- per user: `~/.claude/agent-practice.md`.

The project file wins. Copy [settings.example.md](settings.example.md) to start.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `owner_name` | `the owner` | all | The human who holds final authority. |
| `orchestrator_name` | `orchestrator` | messaging, orchestrator, landing | The coordinating session's name as `ListAgents` shows it. |
| `state_dir` | `~/.local/state/crewkit` | orchestrator, messaging, crash-recovery | The coordinator's durable directory, the same `state_dir` as crewkit's [settings](../../docs/settings.md). It holds `decisions.md` (the append-only decision log) and `state.md` (the overwritten current state). Never under `/tmp`. |
| `repo` | `<owner>/<repo>` | landing, review | The GitHub repo, always passed as `-R`. |
| `required_check` | `ci-ok` | landing | The single aggregate required check. |
| `extra_checks` | `[]` | landing | Checks outside the required one that must also pass on the head (for example a workflow linter). |
| `sensitive_paths` | see the landing skill | landing | Regexes; a landed change touching one forces a refresh. |
| `freshness_command` | none | landing | Your read-only "green and fresh?" script, if you have one. |
| `land_command` | none | landing, orchestrator | Your batch lander, if you have one. Takes PR numbers in order. |
| `health_url` | none | landing | Production endpoint that reports the deployed commit SHA. |
| `verify_workflow` | none | landing | The post-deploy (staging) verification workflow file path. |
| `review_model` | `opus` | review, orchestrator | Model for reviews, verdicts, rulings and checks. |
| `implement_model` | `sonnet` | review, orchestrator | Model for long implementation and mechanical steps. |
| `high_risk_areas` | `money, trust, security, authorization, infrastructure` | review, landing | Areas that always need an independent review and land alone. |
| `reply_timeout_urgent` / `reply_timeout_normal` | `10m` / `15m` | messaging, landing | How long to wait for the coordinator before using your own judgement. |
| `pool_command` | none | host-safety | Prefix that runs a command in a shared slot, for example `bitc run heavy --`. |
| `mem_floor_gb` | `6` | host-safety | Don't start a big-memory job below this much available memory. |
| `durable_dir` | `~/.local/state/agent-practice` | host-safety, crash-recovery | Where scripts and scratch that must survive a restart live. |
| `page_command` | none | orchestrator | The paging tool. Read its source; never run it to learn its usage. |
