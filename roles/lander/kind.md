---
kind: lander
lead: orchestrator
model: mid or a script
permission_mode: dontAsk
permission_detail: {allow: ['<merge command only>']}
runs_as: session
tools: []
checkin: hourly
---

# lander (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- merges and enqueues

## May

- merge pinned to the reviewed sha after the land check

## Never

- merge without an approving verdict and green checks at that sha
- rebase (merge main in)

## Reports

`done` with the merge sha
