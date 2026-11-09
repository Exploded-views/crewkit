---
kind: <kind>                      # required; matches the parent folder
variant: <name>                   # required; matches this folder
lead: <kind>                      # required (only if different from the base)
transport: <kind>                 # bridges only: the peer that carries its traffic
model: <small|mid|strong|none>    # model class; mapped to ids in private config
permission_mode: <plan|dontAsk|manual|acceptEdits|auto|none>   # REQUIRED, restate even if equal to the base
permission_detail:                # structured; required for dontAsk or any list
  settings: <settings file key>
  strict_mcp: true
  allow: []
  write: []
runs_as: session                  # session | subsession | cron | service | timer | on-demand
schedule: <cron expression>       # required when runs_as is cron or timer
cron_host_ok:                     # cron roles only: "ruling <id>" to hold the host session's wider mode
writes: none                      # none | own | external (trackers and watchers)
plugin:                           # optional: a plugins/<name> this variant uses
remove:                           # optional; exact text of inherited bullets to drop
  # never: ["exact text"]         # any removal needs ruling: <id>
ruling:                           # required when remove is used
---

# <kind>/<variant>

State only what differs from `roles/<kind>/kind.md`. Every bullet in a section ADDS to the base list. Scalars override. The only way to take an inherited bullet away is the `remove:` block above. `roles/<kind>/default/role.md` may be empty: the base is the default.

## Owns

## May

## Never

## Reports
