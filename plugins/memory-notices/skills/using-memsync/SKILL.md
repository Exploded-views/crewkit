---
name: using-memsync
description: >-
  Work with claude-memsync, which syncs Claude Code memory across machines through private
  git repos: where shared notes live, what a changed-note notice means, and how to check
  sync health without touching keys. Use this when a session start shows the shared memory
  index or a "memory changed" notice, when saving a rule about the user or how to work, when
  memory seems stale or missing on this machine, and before running any claude-memsync
  command.
---

# Using memsync

> Draft. The setup and key flows (host join, recipients, key rotation) are still changing, so
> this skill covers only the parts that are stable. For commands and flags, the installed
> binary is the authority: `claude-memsync help`, and claude-memsync's generated
> `docs/reference.md` for the release you have.

claude-memsync keeps each machine's Claude Code memory in sync through private git repos.
The memory-notices hooks in this plugin show you two things it produces: the **shared
(distilled) index** at session start, and **changed-note notices** when another machine
changed a note.

## Settings

None of its own. Reads come from claude-memsync's config; notices from its `changes` command.

## 1. Read before you rely

- The session-start index lists shared notes by name and file only. **Read a note before
  acting on it.** A name is not its content.
- A changed-note notice means the file changed elsewhere. Re-read it before relying on what
  you remembered from earlier in the session.
- Notes are background, written when they were true. If one names a file, flag or command,
  check it still exists before recommending it.

## 2. Where a new note goes

- **Rules about the user and how to work** (memory types `user` and `feedback`) go in the
  shared distilled directory the index names, as `<slug>.md` with `name` and `description`
  frontmatter, so every project and machine sees them.
- **Project facts** stay in that project's own memory.
- Never write a secret, key, token or client-identifying detail into any note. Synced notes
  travel to every machine on that repo.

## 3. Checking health

Read-only commands are safe to run:

```bash
claude-memsync version
claude-memsync status
```

Report a failure with the command, its exit code and the line it printed. Don't try to repair
sync yourself.

## 4. Not yours to run

Unless the owner asked for it, in person, in this conversation, never run commands that
change who can read the repos or how they are set up: `init`, `join`, `recipients`, `host`,
`app`, `repo`, `route`, `install`, `uninstall`, `start`, `stop`, or anything that touches age
keys or deploy keys. These change trust between machines.

## Red flags

- Acting on a note's name from the index without reading it.
- Copying a key, token or recipient line into a note, message or log.
- "Fixing" sync by editing the sync repo by hand or re-running setup.
