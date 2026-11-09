---
kind: daemon
lead: orchestrator
model: none
permission_mode: none
runs_as: service
tools: []
checkin: hourly
---

# daemon (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- its status files and logs

## May

- observe, record, alert, fail closed

## Never

- decide
- type free text into a pane
- clear its own latch
- be edited in place (install atomically after review)

## Reports

status files; a page only on breach, lost latch, guard trip or dead-man

Not an agent session: `permission_mode: none` is the only allowed value. `runs_as` is `service`, `timer` or `on-demand`.
