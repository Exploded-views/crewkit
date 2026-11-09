---
kind: daemon
variant: timer-job
permission_mode: none
runs_as: timer
schedule: "<timer expression>"
---

# daemon/timer-job

A scheduled script with narrow, explicit authority: a state backup, a memory sync, or removal of named items.

## May

- copy or sync only the folders it is configured for (backed-up storage)
- remove only items named by explicit ID after checks

## Never

- blanket prune or wildcard delete
- touch volumes or data stores outside its list
- sync outside its routed folders
