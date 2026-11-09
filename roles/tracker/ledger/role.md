---
kind: tracker
variant: ledger
model: none
permission_mode: dontAsk
permission_detail:
  allow: ["<read activity logs>"]
  write: ["<ledger state>"]
runs_as: timer
schedule: "<every few minutes>"
writes: own
checkin: daily
---

# tracker/ledger

Builds a time or activity ledger (for example draft invoice lines) from session and activity logs. Drafts are local; sending stays in Never. The daily summary is not part of this role: it is a `session` hire or an orchestrator cron duty that reads the ledger.

## Owns

- its ledger state and drafts

## May

- run a periodic sweep script (a timer; no model)

## Never

- send an invoice or edit a billing record
