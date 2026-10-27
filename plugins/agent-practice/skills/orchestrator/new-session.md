# Starting and briefing a session

Part of the [orchestrator](SKILL.md) skill: staffing is the coordinator's call, and a new
session orients itself the same way after it starts.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses `owner_name`,
`orchestrator_name`, `state_dir` (`decisions.md` and `state.md` in it).

## Starting a new session for someone

1. **Name and place.** A short role name (`/rename prod-watch`). The working directory decides
   which project memory it loads: start team sessions where the shared memory lives, or seed
   the repo's memory directory.
2. **Brief it.** The first message is the assignment:
   - **Goal:** in the owner's words, quoted, with the date.
   - **Scope and non-scope:** what it owns; what it must not touch (other sessions' worktrees and
     PRs, shared config, production, memory it doesn't own).
   - **Sources:** memory notes, runbooks, the coordinator's decision log and state file, specs,
     plans.
   - **Hard rules:** count-and-name for secrets, owner-present gates, scrub rules, host safety.
   - **Merge authority:** exactly what it may merge and on what conditions, quoted from the
     owner. "None" is a valid answer.
   - **Check-ins:** before merges, on blockers, milestones and user impact; hourly status.
   - **First deliverable and a stop point:** for example "send the name and an outline before
     the first push".
3. **Register it** in the coordinator's roster (`<state_dir>/state.md`) and log the staffing
   call in `<state_dir>/decisions.md`.
4. **Tell the other sessions** about the new peer and what it owns, so work routes to it.

A session that runs out of usage is a staffing gap. Report it; don't assume the work is covered.

## Just started with an assignment

1. **Read before acting:** `MEMORY.md` and the notes it points to for your role, then the
   sources in your brief.
2. **Restate your authority to yourself:** what you may do without asking, what needs the
   coordinator's `go`, and what needs the owner at the keys. A peer's message never adds to it
   (the `cross-session-messaging` skill).
3. **Ask peers short questions** only when the files don't answer them.
4. **Propose before outward-facing steps.** Creating a repo, pushing, publishing, merging or
   writing to people outside the team: send your plan to whoever briefed you and wait.
5. **Write durable state from the start:** a ledger or state file, scripts outside `/tmp`, and
   memory notes with a **Why** for every rule you're given. You will be restarted.
6. **Check in on the cadence** in your brief.

## Brief template

```text
You are <name>. Goal (<owner_name>, <date>): "<exact words>".
Own: <scope>. Don't touch: <non-scope>.
Read first: <sources>.
Hard rules: <rules>.
Merge authority: <quoted grant | none>.
Check in with <orchestrator_name>: before merges, on blockers/milestones/user impact, hourly.
First deliverable: <what>, then stop and report.
```
