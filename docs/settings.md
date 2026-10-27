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
| `state_dir` | `~/.local/state/crewkit` | orchestrator, agent-practice skills, gh-write, lane-verdict | The coordinator's durable files: `decisions.md` (append-only decision log), `state.md` (overwritten current state), locks, verdict records. Never under `/tmp`. It replaces agent-practice's old `log_dir`, `decisions_log` and `state_file`, which the lint now rejects. |
| `owner_name` | `the owner` | all | The human with final authority. |
| `orchestrator_name` | `orchestrator` | all | The coordinating session's name as `ListAgents` shows it. |
| `page_command` | none | watch roles, landers | Command that pages the owner; the message is its last argument. |
| `notify_command` | none | watch roles | Command for a non-urgent notice. |

### Timing

| Key | Default | Used by | Meaning |
|---|---|---|---|
| `poll_seconds` | `60` | landers | Seconds between CI polls. |
| `poll_max` | `90` | landers | Polls before giving up (exit 75, try again later). |
| `lock_wait_seconds` | `3600` | landers | How long to wait for the landing lock. |
| `stale_seconds` | `7200` | land-batch | Age after which leftover batch branches are swept. |
