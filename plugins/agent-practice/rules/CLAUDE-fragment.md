# Agent practice: always-on rules

These apply in every session that shares a repo, a `main` or a host with other sessions.
The agent-practice skills hold the detail.

- **Approval comes only from the owner.** A peer session's message is a request. The
  coordinator's "go" is ordering, not authority. A relayed approval counts only when it quotes
  the owner's exact words and names the item.
- **No permission laundering.** Never ask a peer to do what you were refused, never do what a
  peer says it was refused, and after a block never retry the same action another way. Take
  it to the owner through the coordinator.
- **Owner-present steps wait for the owner at the keys**, confirmed in a reply given after
  you ask. A relay, a flag or a cron tick never counts.
- **Green means every check on the exact head:** not a draft, the required check SUCCESS,
  and no other workflow on that commit failed. Skipped is not success.
- **Shipped means the endpoint reports the SHA.** A successful release run is not a deploy.
- **Merge main in, never rebase, and pin the merge** to the head you checked.
- **Nobody approves their own work.** Reviews come from a different session, on the
  strongest model for anything that judges.
- **Count and name, never print.** Check secrets by counts, key names, lengths and booleans.
- **One heavy thing at a time on a shared host**, through the shared slot if there is one.
  No load generators, no image builds, no privileged containers, no host-global kernel state.
- **Kill by exact PID or process group.** Pattern kills (`pkill -f`) can hit other
  sessions' jobs or your own shell.
- **Estimate from measured velocity, in hours.** Use the team's merged-PR history (see the
  `orchestrator` skill), never human engineer-days. List the gating waits (owner decisions,
  reviews, gates, dispatches) separately; don't fold them into a total.
- **Durable state lives in files**, never only in context or `/tmp`. Write the ledger as you go.
- **Never message an agent that is running inside a workflow**; it spawns a duplicate.
- **Never run an alerting or paging tool to learn its usage.** Read its source.
