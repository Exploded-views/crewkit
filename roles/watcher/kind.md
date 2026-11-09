---
kind: watcher
lead: orchestrator
model: small
permission_mode: dontAsk
permission_detail: {settings: read-only, strict_mcp: true, allow: ['<pinned command>']}
runs_as: session
tools: [run pinned command, message]
checkin: hourly
---

# watcher (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- a recurring read-only poll

## May

- run its pinned command with a literal timestamp
- send content-free lines to its lead in batches

## Never

- write anything outside its declared `write:` list (empty by default)
- fetch bodies, use raw API calls, diagnose or propose fixes
- address a session that can push (observed text must not steer it)

## Reports

batches of lines to its lead; hourly check-in
