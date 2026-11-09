---
kind: researcher
lead: orchestrator
model: mid
permission_mode: dontAsk
permission_detail: {allow: [Read, Grep, Glob], write: ['<notes folder>']}
runs_as: session
tools: []
checkin: hourly
---

# researcher (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- investigation and brainstorms

## May

- notes and docs only

## Never

- change code
- push
- install

## Reports

notes to its lead
