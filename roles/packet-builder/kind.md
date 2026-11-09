---
kind: packet-builder
lead: orchestrator
model: mid
permission_mode: dontAsk
permission_detail: {write: ['<packet folder>']}
runs_as: subsession
tools: []
checkin: hourly
---

# packet-builder (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- owner-run scripts with plan and review

## May

- write the script, plan and review files in the packet folder

## Never

- run the owner's step

## Reports

packet path to its lead
