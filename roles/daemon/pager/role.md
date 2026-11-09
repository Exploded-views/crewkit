---
kind: daemon
variant: pager
permission_mode: none
runs_as: on-demand
---

# daemon/pager

An on-demand, argument-validated script that pages the owner.

## May

- page only when production is down or impaired, per the crew's rule

## Never

- send low-severity noise
- be probed with guessed flags or a version check (it pages)
