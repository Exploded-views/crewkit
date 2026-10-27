# Campaign state

Rows that name `merge-when-green`, `wait-release-quiet`, `land-when-ready` or `crew-log`
describe planned crew-orchestrator tools that aren't in this release.

A lane campaign keeps its shared state in one JSON file, `<campaign_dir>/state.json`
(`campaign_dir` is a [setting](settings.md)). The lanes write it; the landers and the
coordinator read it. Every write goes through `lane-state` (in the `crew-lanes` plugin), which
checks this schema, takes the lock, and replaces the file atomically.

## Reading and writing

```bash
lane-state get ownerPresent                 # false
lane-state get lanes.fix-login.status       # review
lane-state set mergePaused true
lane-state set lanes.fix-login.pr 101       # also stamps lanes.fix-login.updatedAt
lane-state validate state.json             # exit 0 if it matches this schema
```

- **Writers** use `lane-state set`. It locks `<campaign_dir>/state.lock` (waiting up to
  `lock_wait_seconds`, then exit 75), writes a temp file in the same directory, and renames it
  over `state.json`. A value of the wrong type is refused with exit 2 and nothing is written.
- **Readers** need no lock: the rename means they always see a whole file. Read with
  `lane-state get`, or parse the JSON directly and apply the defaults below.
- Keys this schema doesn't list are **kept** on every write, so a project adapter can store
  its own flags beside these.

## Locks

Every lock is a `flock` on a file in `<state_dir>/locks/`, except the campaign state's own:

| Lock | Taken by | Covers |
|---|---|---|
| `<state_dir>/locks/land.lock` | every lander (`lane-land`, `land-batch`, `merge-when-green`, `land-when-ready`) | From the pre-merge checks through the post-merge verification, so two landers never merge at once. |
| `<state_dir>/locks/gh-write.lock` | `gh-write` | One GitHub write at a time, spaced out. |
| `<state_dir>/locks/crew-log.lock` | `crew-log` | Appends to `decisions.md` and rewrites of `state.md`. |
| `<campaign_dir>/state.lock` | `lane-state set` | Each write of the campaign state. |

Each waits up to `lock_wait_seconds` and then exits 75 (try again later). A lock is never
inherited by a child process, so a helper that lingers can't hold it.

## Schema

### Top level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ownerPresent` | boolean | `false` | The owner is at the keys. Set only on the owner's own word. While false, owner-gated PRs and lanes don't land. |
| `ownerGatedPrs` | list of PR numbers | `[]` | PRs that land only while `ownerPresent` is true. Writers emit numbers; readers accept numbers or numeric strings. |
| `ownerGatedLanes` | list of lane names | `[]` | Lanes whose PRs land only while `ownerPresent` is true. |
| `mergePaused` | boolean | `false` | Landing is paused. Batch landers honour it when told to. |
| `mergePauseExempt` | list of PR numbers | `[]` | PRs that may land during a pause. |
| `mergePausedNote` | string | `""` | Why landing is paused, for whoever reads the state. |
| `lanes` | object | `{}` | One entry per lane, keyed by lane name. |

### `lanes.<lane>`

| Key | Type | Meaning |
|---|---|---|
| `status` | one of `open`, `implementing`, `gates`, `review`, `ready`, `landing`, `merged`, `parked`, `failed` | Where the lane is. |
| `pr` | PR number or null | The lane's PR. |
| `headSha` | full 40-hex SHA or null | The head the lane last reported. A lander that finds it set and different from the PR's current head treats the lane's view as stale and waits. |
| `implementer` | string | The session or agent implementing the lane, set when it starts. A lander checks a verdict record against it: the record's `implementer` must match, and its `reviewer` must differ. |
| `mergedSha` | full 40-hex SHA or null | The commit on the main branch after landing. |
| `mergedAt` | ISO 8601 UTC time or null | When it landed. |
| `updatedAt` | ISO 8601 UTC time | Stamped by `lane-state` on every write to the lane. |

## Shared fixture

[tests/fixtures/campaign-state.py](../tests/fixtures/campaign-state.py) prints a valid state
that both the writers' and the readers' tests use: an owner-gated PR given as a string, an
exempt PR, lanes in three statuses with full SHAs and implementers, and an adapter's own flag
that writers must keep. It is a generator so the SHAs aren't committed as long hex literals.
Change it only with both sides' tests.
