# Settings

Rows that name `merge-when-green`, `wait-release-quiet`, `land-when-ready` or `crew-log`
describe planned crew-orchestrator tools that aren't in this release.

Every crewkit script reads its settings through one reader, `lib/settings.sh`, so they all
behave the same way. This page is the schema: `tools/lint-skills.py` fails on any key a script
reads, or a settings file sets, that isn't listed here.

## Where settings come from

First match wins; a key set to an empty value counts as set.

1. **Environment:** `CREWKIT_<KEY>`, the key upper-cased with dots as underscores
   (`gates.test` is `CREWKIT_GATES_TEST`), for operational keys only. Every **gate setting**,
   anything that changes whether or what merges, is **file-only**: its `CREWKIT_*` is ignored,
   since any session can set its own environment. `lib/settings.sh` declares the two lists
   (`CREW_FILE_ONLY`, `CREW_ENV_OK`); a key in neither is file-only, and the lint fails unless
   every key in this table is in exactly one. `CREW_ENV_OK` names exact keys; its only
   prefixes are placeholder families whose row says "Never gates a merge", so a new key can't
   slip in under a broad prefix. The lists in `lib/settings.sh` are the one record of which
   keys are which.
2. **`.claude/crewkit.local.md`** in the project: this checkout only, git-ignored.
3. **`.claude/crewkit.md`** in the project: committed and shared by the team. Project policy
   such as `high_risk_areas` lives here.
4. **`~/.claude/crewkit.md`:** your defaults across projects.
5. The default in the table below.

A few keys describe your machine rather than a project, and are **user-only**: they are read
only from `~/.claude/crewkit.md` (layer 4), never from the environment or a project's
`.claude/crewkit.md` or `.claude/crewkit.local.md`, so a repository or a lane's worktree can't
widen, shrink or redirect them. `lib/settings.sh` declares them in a third list,
`CREW_USER_ONLY` (today `nodes.*`, `registry.*`, `limits.*` and `push_gate.*`); `crew_keys`
lists them only from the user file too, and the lint fails unless every entry is also file-only
and names a documented key.

The project files are found from the current directory upwards. A settings file is Markdown
whose frontmatter holds flat `key: value` lines; notes can follow the frontmatter. Values may be
quoted, and an unquoted comment (a `#` after a space) is dropped. Nothing in a settings file is ever run.

```text
---
repo: OWNER/REPO
required_check: ci-ok
gates.test: "make test"
high_risk_areas.billing.paths: "src/billing/**, migrations/**"
high_risk_areas.billing.why: calls the payment provider
---

Anything below the frontmatter is notes.
```

### Settings are code

Some settings name commands to run (`lane.setup_hook`, `lane.db_hook`, `gates.<name>`,
`page_command`), so treat a project's `.claude/crewkit.md` like its build scripts: review
changes to it, and run crewkit's scripts only in checkouts whose code you'd run anyway. The
reader protects the edges:

- The project search stops at the repository root, so a settings file in a directory above
  the repo never applies to it.
- A settings file not owned by you, or writable by everyone, is skipped with a warning.
  Group-writable is allowed: with a user-private group (the usual `umask 002`) the group is
  just you.

The file list is found once per directory and cached for the life of the process.

A script that can't run without a key uses `crew_require`, which exits 78 ("config") and names
the key. `<name>` in a key below stands for one name you choose (letters, digits, `_`, `-`).

## Keys

### Project

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `repo` | none (required) | landers, lanes | The GitHub repo, `OWNER/REPO`. Always passed as `-R`. |
| `main_branch` | `main` | landers, lanes | The branch work lands on. |
| `checkout` | the current repo | lanes | Path of the main checkout lanes branch from. |
| `required_check` | `ci-ok` | landers | The single aggregate check that must pass on the exact head. |
| `ci.workflow` | none (required) | landers | The workflow file (for example `.github/workflows/ci.yml`) whose runs carry `required_check`. |
| `ci.event` | `pull_request` | landers | The event those runs must come from. Empty: any event. |
| `ci.noise_step_prefix` | none | landers | A run with a job that ran a step starting with this text only mirrors another run, and is passed over. (A run that finished `skipped` with every job skipped is passed over too.) |
| `min_green_checks` | `1` | landers | Other successful checks required on the head besides the aggregate one. |
| `ignored_checks` | none | landers | Comma-separated check names that never block (for example a deploy-provider status). Only `success` is green: a skipped or neutral job blocks until it is named here, because a job that didn't run proved nothing, and only a person knows which ones may not run. Name any job that is skipped by `if:` or paths, or that may fail, and the jobs that `needs:` it. Can't name `required_check` (exit 78). |
| `release_workflows` | none | wait-release-quiet, land-when-ready | Comma-separated workflow names that make up the release chain on `main_branch`. |
| `health_url` | none | land-when-ready | Production endpoint that reports the deployed commit SHA. |

### Risk and review

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `high_risk_areas.<area>.paths` | none | landers, review | Comma-separated path globs for one high-risk area. A change touching one always gets an independent review on `review_model` and lands alone. |
| `high_risk_areas.<area>.why` | none | setup, review | One line on why the area is high risk. |
| `high_risk_areas.confirmed_by` | none | landers | Who confirmed the list. Until it is set, the landers refuse to batch anything. |
| `high_risk_areas.confirmed_on` | none | landers | When the list was confirmed (`YYYY-MM-DD`). |
| `review_model` | `opus` | review, landers | Model for independent reviews and verdicts. Verdicts for high-risk PRs (and every `lane-land` verdict, until lane gates classify risk) must name it. Empty in a settings file: no model is checked. File-only, like every gate setting: `CREWKIT_REVIEW_MODEL` is ignored. See [review-verdicts.md](review-verdicts.md#the-review-model). |
| `implement_model` | `sonnet` | lanes | Model for implementation steps. |
| `review.markers` | `Verdict: MERGE` | landers | Comma-separated phrases that open an independent verdict. |
| `review.require_sha` | `true` | landers | A verdict must name the head commit it reviewed. |
| `review.source` | `comments` | landers | Where verdicts come from: `comments` (PR comments) or `records` (verdict records). See [review-verdicts.md](review-verdicts.md). |
| `review.reviewers` | none | landers, lane-verdict | Comma-separated reviewers whose verdicts count (logins for `comments`, session or agent names for `records`). Unset means any reviewer who isn't the author or implementer. |
| `review.verdict_dir` | `<state_dir>/verdicts` | lane-verdict, landers | Where verdict records are kept. Keep it outside every lane's worktree. |

`high_risk_areas` has no default list, because what is high risk depends on the project.

#### Choosing `high_risk_areas` for a project

The setup agent sets the list once per project, with the human:

1. **Inspect.** It reads the repo for areas where a mistake costs money, access, data or trust:
   payments and billing, authentication and authorization, secrets and credentials,
   infrastructure and deploy config, migrations and data deletion, equity or ownership
   records, personal data, and anything the project's own docs call critical. It cites the paths
   and the evidence for each (for example "`src/billing/` calls a payment provider's API").
2. **Propose.** It shows a short list: each area, its paths, one line on why, and the areas it
   considered and left out.
3. **Confirm.** The human edits and confirms. Nothing is stored until they do.
4. **Store.** The confirmed areas go into the project's committed `.claude/crewkit.md` as
   `high_risk_areas.<area>.paths` and `.why`, with `high_risk_areas.confirmed_by` and
   `.confirmed_on`. Changing the list later is the same flow.

Until `high_risk_areas.confirmed_by` is set, the landers treat every change as needing the
owner: they refuse to batch anything.

### Lanes

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `campaign_dir` | `~/.local/state/crewkit/campaign` | lanes | Lane packets, results, the journal and `state.json`. Never under `/tmp`. |
| `branch_prefix.lane` | `lane/` | lanes | Branch name prefix for a lane. |
| `branch_prefix.refresh` | `lane-refresh/` | lane-refresh | Prefix for temporary refresh branches. |
| `branch_prefix.batch` | `batch/` | land-batch | Prefix for batch branches. |
| `lane.worktree_dir` | `.claude/worktrees` | lane-new | Where lane worktrees go, relative to `checkout`. |
| `lane.note_dir` | `docs/lanes` | lane-new | Where each lane's note is committed, inside the worktree. |
| `gates.<name>` | none | lane-gates | A gate command, run through `pool_command` in the lane's worktree (for example `gates.lint_changed`, `gates.test`). Never gates a merge. |
| `lane.setup_hook` | none | lane-new | Command run after a lane's worktree is created (dependencies, generated code). |
| `lane.db_hook` | none | lane-gates | Command that provisions a private database for a lane whose schema differs. |
| `pool_command` | none | lanes, gates | Prefix that runs a heavy command in a shared slot, for example `bitc run heavy --`. |

### GitHub writes

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `gh_write.min_gap_ms` | `1500` | gh-write | Minimum time between GitHub writes (secondary rate limits punish bursts). |
| `gh_write.retries` | `4` | gh-write | Tries per write before giving up. |
| `gh_write.backoff_seconds` | `15` | gh-write | Backoff step between tries (the wait grows by this much each time). |
| `gh_write.max_body_bytes` | `1800` | gh-write | A PR comment or review longer than this is posted as a summary with a pointer to the full text. |

### Labels

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `labels.do_not_merge` | `do-not-merge` | landers | A PR with this label is never landed. |
| `labels.awaiting_approval` | `awaiting-approval` | landers | Waiting for the owner; never landed. |
| `labels.fixed_in_main` | none | lane-land | Label added to a lane's closing issues once its PR has landed (through gh-write). After the merge, so it never gates one. |
| `labels.<name>` | none | lanes | Other labels the lanes apply; one that code reads by name gets its own row, as `labels.fixed_in_main` does (the lint checks). Never gates a merge. |

### Landing

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `flakes_file` | `<state_dir>/flakes.txt` | land-batch | Known flakes, one literal text per line (4 characters or more; `#` starts a comment). A failed batch is rerun once only if every FAIL line of every failed job contains one. |
| `merge_retries` | `3` | land-batch | Retries of a squash refused with "Base branch was modified", which is transient. |
| `land.honor_merge_pause` | `true` | landers | Hold every PR not in `mergePauseExempt` while the campaign state has `mergePaused` ([campaign state](campaign-state.md)). Set `false` only for a pause meant for the lanes alone. |
| `land.precheck_hook` | none | lane-land | A project's own landing gate, run with `PR`, `HEAD` and `LANE` set, from the root of the main checkout (so relative paths resolve there, wherever lane-land was started). A non-zero exit refuses the landing (PRECHECK-REFUSED) and its output is shown. |
| `land.precheck_timeout_seconds` | `300` | lane-land | How long `land.precheck_hook` may run; a timeout refuses the landing. |

### Coordination

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `state_dir` | `~/.local/state/crewkit` | orchestrator, agent-practice skills, gh-write, lane-verdict, `crewkit` verbs (locks, registry state) | The coordinator's durable files: `decisions.md` (append-only decision log), `state.md` (overwritten current state), locks, verdict records. Never under `/tmp`. It replaces agent-practice's old `log_dir`, `decisions_log` and `state_file`, which the lint now rejects. |
| `owner_name` | `the owner` | all | The human with final authority. |
| `orchestrator_name` | `orchestrator` | all | The coordinating session's name as `ListAgents` shows it. |
| `page_command` | none | watch roles, landers | Command that pages the owner; the message is its last argument. |
| `notify_command` | none | watch roles | Command for a non-urgent notice. |

### Nodes

crew-nodes' `pane-ask` sends one message from this host's bridge to the bridge of another node (a
machine in the crew) and waits for its reply, where `SendMessage` can't reach. It is bridge to
bridge only: any other caller or target is refused (exit 45), and on one host sessions use
`SendMessage`. That is a guard rail, not enforcement: it is an environment check that stops accidents, not a determined caller. A caller can claim another pane or unset the variable, and real enforcement waits on a herdr feature. Each node is a name you
choose, `<name>` below. Every `nodes.*` key is user-only: it is read only from
`~/.claude/crewkit.md`, since a node's settings decide where commands run and which sessions are
never typed into, so neither `CREWKIT_*` nor a project's settings files can change them. None of
them gates a merge.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `nodes.<name>.this_host` | none | pane-ask | `true` or `false` (anything else is exit 78). `true` marks a node as this host's own, and only on the host itself: a wrong flag lets that node's bridge name send from here. A local node has neither `host` nor `machine` (both is exit 78). Several nodes may be local (a host with several herdr sessions). `pane-ask` runs a local node's herdr directly, with no ssh, in the node's `session` (with several local nodes the target's `session` must be set, else 78). A caller is a bridge when it matches the `bridge` of a local node; with one local node that is enough, and with several `HERDR_SESSION` (absent means `default`) must equal a local node's `session`, else 45. If no node is local, or this host's bridge is unset, pane-ask exits 78. |
| `nodes.default` | none | pane-ask | The node used when no `--node`, `--host` or `--machine` is given. |
| `nodes.<name>.machine` | none | pane-ask | The node's saved herdr machine profile (a label from `herdr machine list --json`). When set, pane-ask uses `herdr --machine <label>` (herdr 0.9.1 or later on both sides) and no ssh. |
| `nodes.<name>.host` | none | pane-ask | The ssh target (`[user@]host` or an ssh config alias) for a node without `machine`. |
| `nodes.<name>.herdr` | `~/.local/bin/herdr` | pane-ask | herdr's path on the node, over ssh. A non-interactive ssh shell usually doesn't have it on `PATH`; a leading `~/` is the node's home. No backslash (exit 78). |
| `nodes.<name>.node_id` | none | crewkit | The registered node's ID (written by init and join). |
| `nodes.<name>.role` | none | crewkit | `hub` or `spoke`, on the node with `this_host: true`. `crewkit doctor` runs its `hub-inbound` check only when the role is `hub`; unset or `spoke` is not a hub, and any other value is a doctor FAIL (`bad-role`). |
| `nodes.<name>.owner_keys` | none | crewkit | On a hub: the fingerprints (`SHA256:...`, separated by commas) of the ssh keys that may log in to this machine, which are the owner's own. `crewkit doctor` fails any key in `~/.ssh/authorized_keys` or `authorized_keys2` that is not listed. Set by the owner, one key at a time; doctor only reads it. |
| `nodes.<name>.session` | the herdr default session (required for a `this_host` node when several nodes are `this_host`) | crewkit, pane-ask | The herdr session that is this node (over ssh, not with `machine`). It also selects the local herdr session for a node marked `this_host`: pane-ask runs the local herdr with `--session <session>`, and matches it against `HERDR_SESSION` to tell which local node a caller is in. When several nodes are `this_host`, each needs it (exit 78 otherwise). |
| `nodes.<name>.crewkit` | none | crewkit | Absolute path of crewkit on that node, recorded at join; every remote crewkit call runs `<bash> <crewkit>`. |
| `nodes.<name>.bash` | none | crewkit | Absolute path of a bash 4.4 or newer on that node, recorded at join; every remote crewkit call runs `<bash> <crewkit>`. |
| `nodes.hub.pointer_url` | none | crewkit | On a node: the full URL of this node's topic on the holder's ntfy (`http(s)://` and plain URL characters only), written by `crewkit join` from `crewkit holder tokens`. `crewkit outbox add` posts the pointer here. Unset: no pointer is sent and the holder's poll finds the item. |
| `nodes.hub.pointer_token` | none | crewkit | On a node: the post-only ntfy token for that topic (letters, digits, `_`, `.`, `-`). Sent to curl on stdin, never in argv, and never printed. A bad value is exit 78. |
| `nodes.<name>.bridge` | none | pane-ask | The agent name or pane id of that node's bridge. It is the only target `pane-ask` sends to or reads on that node (exit 45 for any other), and the default when no target is given. For this host's own node it is the only caller that may send. |
| `nodes.<name>.lead_pane` | none | pane-ask | Agent names or pane ids on that node, separated by commas or spaces, that pane-ask never sends to (exit 65): the node's lead sessions. Checked against the target as typed and against what `herdr agent get` resolves it to: its `pane_id`, and its `name` when it has one (not `agent`, the agent's kind, such as `claude`), ignoring case. A guard against mistakes, not a security boundary. |
| `nodes.local_herdr` | `herdr` | pane-ask | The local herdr binary: used with a machine profile, for a node marked `this_host`, and for the read-only lookup of the caller's own pane. |
| `nodes.prefix` | `orchestrator_name` | pane-ask | The sender name put before each message (`NAME: MESSAGE`). `--prefix` overrides it. |
| `nodes.timeout_seconds` | `900` | pane-ask | How long herdr waits for a busy agent to settle before the send (then exit 75, nothing sent), and for the reply (then exit 40). The two waits are separate, so one pane-ask can take up to twice this (plus the ssh round trips). `--timeout` overrides it. |
| `nodes.wait_idle` | `true` | pane-ask | `false`: refuse a busy agent at once (exit 75) instead of waiting for it. |
| `nodes.idle_statuses` | `idle,done` | pane-ask | Comma- or space-separated herdr `agent_status` values that mean ready. Anything else (`working`, `blocked`, `unknown`) is busy; `blocked` is refused without waiting. |
| `nodes.read_lines` | `80` | pane-ask | Lines `--read` prints. `--lines` overrides it. |
| `nodes.scan_lines` | `1000` | pane-ask | Lines read back after a reply to find the sent message. `--lines` overrides it. |

### Registry

The registry is a private git repo that the nodes of a crew sync through. Every `registry.*` key is
user-only, like `nodes.*`: it is read only from `~/.claude/crewkit.md`, since it decides which
repo is pushed to and with which key. None of them gates a merge.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `registry.dir` | `~/.local/share/crewkit/registry` | crewkit | Local clone of the sync repo, on the holder and on any node that keeps a read clone (only the holder pushes). |
| `registry.remote` | none | crewkit | The private sync repo's git URL, on any node that has a clone (only the holder pushes). |
| `registry.ssh_key` | none | crewkit | An ssh identity file for registry pulls and pushes; the holder sets it to its deploy key. |
| `registry.report_timeout_seconds` | `10` | crewkit | ssh ConnectTimeout for one report pull. |
| `registry.sync_min_seconds` | `300` | crewkit | A report change that is only its timestamp is committed at most this often. |
| `registry.spend_cap_usd` | `5` | crewkit | The holder's monthly spend cap in dollars (a plain decimal, at most 99999.99). The holder's estimated spend is its monthly machine price times the fraction of the month it has run (time without ticks is not counted; a lost state file counts as a whole month so far); at 80% it alerts once a month, at 100% it stops. A machine price over the cap, or of zero, is refused at start, which is the main protection: see `docs/holder-spend.md`. A value that is not a price is an error, never "no cap". |
| `registry.alert_command` | none | crewkit | A command the holder runs once a month when its spend reaches 80% of the cap (for example the owner's page command). It runs through `bash -c`; a failure is retried at the next check. |

### Host limits

Every `limits.*` key is user-only, like `nodes.*`: it is read only from `~/.claude/crewkit.md`,
since a project must not raise what its host allows. None of them gates a merge.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `limits.max_sessions` | none (computed from host size at init) | crewkit | The most agent sessions on the node at once. |
| `limits.reserve_cpu_pct` | none (computed at init) | crewkit | Headroom that must stay free for the host and its human. |
| `limits.reserve_mem_mb` | none (computed at init) | crewkit | Headroom that must stay free for the host and its human. |
| `limits.reserve_disk_gb` | none (computed at init) | crewkit | Headroom that must stay free for the host and its human. |

### Heavy lock

`heavy_lock` is user-only: read only from `~/.claude/crewkit.md`, so no repository, worktree or
environment can point the heavy-lock check (`tools/heavy_lock.py`) at a different lock. It moves
the lock; it can't switch the check off, which holds while `~/.local/state/crew` exists.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `heavy_lock` | `~/.local/state/crew/heavy.lock` | mutation runners, Linux gate | The machine's heavy lock file (absolute, or starting with `~/`). `heavy.slot1` and `heavy.slot2` are looked for beside it. |

### Watcher

`watch.trusted_authors` is user-only, like `nodes.*`: read only from `~/.claude/crewkit.md`, so
no repository or environment can add a login to it. A watcher that names a listed login falsely
can still pass a stranger's text, because the login on the line is its own claim
([crewkit.md](crewkit.md#the-content-free-watcher)); logins are compared as GitHub spells them,
upper and lower case included.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `watch.trusted_authors` | none | crewkit | GitHub logins, separated by spaces or commas, whose free text `crewkit watchline` may pass on, and the only ones: an author association never grants a text ([crewkit.md](crewkit.md#the-content-free-watcher)). |

### Owner send

`owner_send.*` is file-only: its `CREWKIT_*` variables are ignored, so no environment can point
`crewkit owner send` at another program or channel. The `crewkit` command runs every verb from
`$HOME`, so in practice the settings come from `~/.claude/crewkit.md`. The level and channel values are the names in the owner's own yo-human config (`yo-human levels --json`,
`yo-human config`); the Bark form passes `--ask` (`owner_send.ask`), the ntfy form none, so the ntfy level must be `ask: optional`.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `owner_send.yo_human` | `yo-human` | owner send | The yo-human binary: an absolute path, or a command name looked up on `PATH`. Under `mc-notify` (`PATH=/usr/bin:/bin`) it must be an absolute path. A bad value is exit 78; one that isn't there or isn't executable prints `refused config`. |
| `owner_send.ask` | `Open <id>@<rev> on the board` | owner send | The `--ask` text of the Bark form (the ntfy form passes none), because the owner's `ask` and `urgent` levels are `ask: required` in yo-human. `<id>@<rev>` is replaced by the entry's id and revision and is the only placeholder allowed. One line, 1 to 200 characters, no control character, else exit 78. |
| `owner_send.levels.passive` | `fyi` | owner send | The yo-human level for `--level passive`. A plain name (letters, digits, `_`, `-`), else exit 78. |
| `owner_send.levels.active` | `ask` | owner send | The yo-human level for `--level active`. |
| `owner_send.levels.time_sensitive` | `urgent` | owner send | The yo-human level for `--level time-sensitive`. |
| `owner_send.levels.ntfy` | `wake` | owner send | The yo-human level for the ntfy form. |
| `owner_send.channels.bark` | `iphone` | owner send | The yo-human channel instance whose result decides the line for the Bark form. Every other channel in the result, the journal included, is ignored. |
| `owner_send.channels.ntfy` | `phone` | owner send | The same, for the ntfy form. |

### Push gate

`push-gate/push-gate.sh` refuses a push that holds a private denylist term or a secret
([push-gate.md](push-gate.md)). Every `push_gate.*` key is user-only: read only from
`~/.claude/crewkit.md`, so no repository, worktree or environment can point the gate at an empty
denylist, a different gitleaks or a different log. A leading `~/` is your home.

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `push_gate.denylist` | `~/.config/crewkit/denylist.txt` | push gate | The private denylist: one case-insensitive extended regex per line; `#` lines and blank lines are ignored. Missing, empty or invalid blocks every push to a gated remote. The same file as the scrub's default. |
| `push_gate.exempt` | `~/.config/crewkit/push-gate-exempt` | push gate | Push URLs that skip checks: a regex line skips the denylist (gitleaks still runs); `skip-all <regex>` skips every check. Missing means nothing is exempt. Anchor each pattern (`^https://github\.com/owner/`): it matches the whole URL. `--doctor` reports its counts and fingerprint. |
| `push_gate.gitleaks` | `~/.local/share/crewkit/gitleaks/gitleaks` | push gate | The gitleaks binary. It must match the sha256 that `install.sh --only gitleaks` recorded beside it (`<path>.sha256`), and the copy of it the gate recorded at `push-gate.sh install`, or every push is refused: after a new gitleaks, run `install` again. |
| `push_gate.log` | `~/.local/state/crewkit/push-gate.log` | push gate | One line per push: time, PASS/BLOCKED/SKIP, repository, URL. A log failure never blocks. |
| `push_gate.root` | none | push gate `--doctor` | The directory whose repositories (up to 4 levels down) `--doctor` checks for a `core.hooksPath` (as git reads it in each checkout) that isn't the gate and lacks the shim. Unset is a FAIL. |
| `push_gate.notify_command` | none | push gate `doctor-watch` | The command for the scheduled doctor's pointer (`push-gate: 1 FAIL: repo:~/code/x`), its last argument; sent only when the set of FAIL checks changes. A failed notify isn't recorded, so the next run sends it again. Unset: the pointer goes to the schedule's log. Use the owner's notice path (not a page). |

### Timing

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `poll_seconds` | `60` | landers | Seconds between CI polls. |
| `poll_max` | `90` | landers | Polls before giving up (exit 75, try again later). |
| `lock_wait_seconds` | `3600` | landers; `crewkit` verbs (default `30`) | How long to wait for a lock: the landing lock, or a `crewkit` lock under `state_dir` (then exit 75). A lock whose holder has died is taken over at once. One key serves both: a value set for landing (default 3600) also applies to `crewkit` verbs. |
| `stale_seconds` | `7200` | land-batch | Age after which leftover batch branches are swept. |
