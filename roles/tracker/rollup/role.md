---
kind: tracker
variant: rollup
model: small
permission_mode: dontAsk
permission_detail:
  allow: [Read, "<ping a stale session>"]
  write: ["<status table>"]
cron_host_ok: "ruling <id>"   # lets this cron hold its host session's wider mode; the lint prints it
runs_as: cron
schedule: "<hourly>"
writes: own
checkin: hourly (idle: slower, e.g. 4 h)
---

# tracker/rollup

Reads outboxes, updates a cadence table, marks stale sessions and sends one line up. As a cron it runs inside its host session and holds the host's permissions. That is allowed only with `cron_host_ok: ruling <id>` (accepted and printed by the lint) or when the host is no wider than `dontAsk`; otherwise run it as `session`.

## Owns

- the status table and the rollup line

## May

- ping a stale session once
- send the one-line rollup to its lead

## Never

- close a session (the lead does, after the closure checklist)
- page the owner
