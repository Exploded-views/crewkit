---
kind: bridge
lead: hub
model: small
permission_mode: dontAsk
permission_detail: {allow: ['message delivery', 'ledger file']}
runs_as: session
tools: []
checkin: hourly
---

# bridge (base)

Escalation, restart checklist and stop conditions come from the common preamble in roles-spec.md; restate them in a variant only to change them.

## Owns

- faithful carriage between places that cannot talk directly
- its ledger

## May

- relay ids and states
- verify state
- chase unacked cross-host items

## Never

- interpret, approve, merge or widen scope
- forward content that fails the wall gate
- read content it was told not to

## Reports

acks and ledger

`lead` is the supervising session (a spoke bridge's host orchestrator; the hub's own bridge leads to the hub). The peer that carries its traffic is the `transport:` field, not `lead`.
