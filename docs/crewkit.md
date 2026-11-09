# crewkit

crewkit is a front door for crews that span machines: one command on your own machine that sets
up, checks and talks to the other nodes, built on herdr for the sessions and agents on each one.
A verb that changes anything is a dry run until you pass `--yes`.

Run `crewkit --version` to see the version. A verb is `crewkit <verb>`, or `crewkit registry
<verb>`, `crewkit node <verb>`, `crewkit holder <verb>` and `crewkit owner <verb>` for the four groups. The command needs bash 4.4 or newer (on
macOS: `brew install bash`). `./install.sh --only cli` links it into `~/.local/bin`.

## Verbs

- `crewkit init`: (added by a later change)
- `crewkit join`: (added by a later change)
- `crewkit status`: (added by a later change)
- `crewkit open`: (added by a later change)
- `crewkit ask`: (added by a later change)
- `crewkit doctor`: check this node's install, one line per check (`ok`, `warn` or `FAIL`); exit 1 if any check is a FAIL. Reads only, changes nothing. The checks and their order are listed at the top of `libexec/crewkit-doctor`.
- `crewkit outbox add ID --owner yes|no "ONE LINE"`: record an item in this node's outbox and send the holder a pointer to it (see below).
- `crewkit owner send --notify-entry ENTRY [--rule R --level L [--note W]]`: push one owner-notify item through `yo-human notify` and print one line for mc-notify ([see below](#owner-send)).
- `crewkit holder tokens NODE --base-url URL`: on the hub, make the node's write-only ntfy user and token (see below).
- `crewkit registry move`: (added by a later change)
- `crewkit node report [--session S]`: print this node's read-only report as one JSON line (version, platform, boot start, push gate, bridge status, agents with role and access, other sessions). It is the forced ssh command the hub runs on a node; it takes nothing from the caller and writes nothing. Exit 0 reported, 1 herdr failed or no scratch directory, 64 usage, 65 node state invalid, 78 not a crewkit node (see [exit-codes.md](exit-codes.md)).
- `crewkit node join`: (added by a later change)
- `crewkit node drill`: (added by a later change)
- `crewkit node authorize`: (added by a later change)
- `crewkit node take-registry`: (added by a later change)
- `crewkit watchline repo|log|check`: [the content-free watcher](#the-content-free-watcher)

## The content-free watcher

A watcher is a reader-only agent (`role=watcher access=reader`) that reads sources strangers can
write to (issues, pull requests, comments, logs). It never passes on what it reads. It writes one
line per item, made of fixed fields, and the orchestrator reads those lines, not the sources.

```console
crewkit watchline repo SOURCE N TYPE ASSOCIATION URL [--author LOGIN] [--text TEXT]
crewkit watchline log SERVICE HOST LEVEL COUNT WINDOW
crewkit watchline check OWNER/REPO...   # lines on stdin
```

- `repo` prints `repo <source>#<N> <type> <association> <url>`. SOURCE is the url's repository name,
  lower-cased with `.` and `_` as `-`, so it carries no words of the writer's choosing (a repository whose name starts with `.`, or
  whose label would start with `--`, cannot be reported). TYPE is `issue`, `pr`, `comment`,
  `discussion` or `release`; ASSOCIATION is one of GitHub's author associations; the URL must be
  `https://github.com/<owner>/<repo>/(issues|pull|discussions)/<N>` for the same N, with no query
  string or fragment.
- `log` prints `log <service> <host> <level> <count> <window> sig:<16 hex digits>`. The signature
  is a checksum, not a secret: the first 16 digits of the sha256 of the line before it, computed
  here and never given, so that equal events have equal signatures.
- `--text` adds a space and `text:'...'` (shell-quoted, one line of printable ASCII, at most 200 characters), and only with `--author LOGIN` when that login is in
  [`watch.trusted_authors`](settings.md#watcher); the line then carries `author:<login>`. The
  association (OWNER, MEMBER, COLLABORATOR or any other) never grants a text: it is the watcher's
  own claim, and a watcher that was talked into writing OWNER would carry a stranger's words
  through. For anyone else, and with no `--author`, it is refused; `check` drops a text line with no
  trusted author.
- A `log` line's service and host are lower-case names of at most 64 characters, taken from the
  host's own configuration; they are not compared with a list.
- Every field that is not a fixed value is exit 65, nothing is printed, and the value is never
  echoed. A wrong number of arguments is 64.
- `check` prints the lines on stdin that are exactly what `repo` or `log` would have printed (and that
  point into one of the `OWNER/REPO` repositories given, at least one: pass the repositories you
  watch; a stream of `log` lines alone needs one too, any repository will do) and counts the others on stderr (`dropped N`, never their text). It also decides again whether a
  `text:` is allowed, from this machine's own `watch.trusted_authors`. The orchestrator runs it;
  the watcher's settings do not allow it. A `text:` is only the watcher's claim about who wrote it,
  so look the item up again before acting on it.

`templates/watcher/` holds the watcher's `CLAUDE.md` and its `settings.json`: read and fetch only,
every write tool denied (edit, `git`, `gh` writes, `curl`, `ssh`, `herdr`, push, merge, release,
deploy), and only `crewkit watchline repo` and `log` allowed. `tools/check-watcher-settings.py`
proves a watcher's settings allow no write.

## The signal path

An item that needs attention goes through two steps. `crewkit outbox add` appends it to the node's
outbox (`<state_dir>/outbox/<session>.log`) and posts a pointer, `<id> owner:<yes|no>` and
nothing else, to the node's own topic on the holder's ntfy. The holder follows every node's
topic, drops anything that is not exactly a pointer (and counts it), and pulls that node's report;
the item's text reaches the holder only through the report. If the post fails, or the node has no
`nodes.hub.pointer_url` and `nodes.hub.pointer_token` settings, nothing is lost: the holder's
10-minute poll finds the item.

`crewkit holder tokens NODE` runs on the hub. It makes the node's ntfy user, which may only write
to its topic `crewkit-<node_id>`, and prints the node's two settings lines for `crewkit join` to
write. Run it again to rotate the token. The listener is `ck_pointer_listen` in
`libexec/ck/pointer.sh`, for the holder's entrypoint to run.

## Owner send

`crewkit owner send` is the sender that MC's `mc-notify` runs (argv only, no shell, 20 seconds, exit
0 needed) to push one item to the owner. It delivers through `yo-human notify --json` and prints
the one stdout line `mc-notify` reads. It sends without `--yes`, and sets no timeout of its own.

```console
crewkit owner send --notify-entry ID@REV:NONCE --rule RULE --level LEVEL [--note NOTE]   # the Bark form
crewkit owner send --notify-entry ID@REV:NONCE                                            # the ntfy form
```

- **Forms.** The Bark form takes its four arguments in any order, each at most once. The ntfy form
  is the entry alone, and sends the id and nonce only, never a rule or a note; a `--rule`,
  `--level` or `--note` without the pair that makes the Bark form is exit 64.
- **Values** (anything else is exit 65, and nothing is called). `ENTRY` is `<ref>:<nonce>`, where
  `<ref>` is what `mc-notify`'s `check_ref` accepts, ported exactly from MC's `lib/crewpatterns.py`:
  `<id>@<rev>` with an id of `[a-z]{1,8}-[0-9]{1,6}`, `ruling-<8 digits>-<1 to 4 digits>` or
  `(ob|th)-<1 to 5 digits>` and a revision of 1 to 4 digits, or one of the synthetic ids, each
  ending `@1`: `digest-<stamp>`, `hub-blind-<name>-<stamp>`, `bark-fail-<stamp>`, `bridge-<stamp>`,
  `baseline-<stamp>`, `herdr-<stamp>`, `wall-<stamp>`, `bark-orphan-<stamp>` (a stamp is
  `20261103T1200Z`; `bark-fail` and `bark-orphan` also take seconds, `20261103T120059Z`; a name is
  `[a-z][a-z0-9-]{0,39}`). The nonce is 16 lowercase hex digits. `RULE` is lowercase letters and
  hyphens, 30 at most. `LEVEL` is `passive`, `active` or `time-sensitive`. `NOTE` is one line of 200
  characters at most, with no control character.
- **The call.** `yo-human notify --level <mapped> --title "<ref> <RULE>" --dedup-key
  "<ref with @ as ->-<nonce>" --json [--body "<NOTE>"]` (the ntfy form: `--title "<ref>"`, no body,
  no `--ask`). The Bark form adds `--ask "<owner_send.ask>"` before the body (default `Open <ref> on
  the board`), with no shell and no stdin. The dedup key holds the nonce, so yo-human never
  suppresses a deliberate re-raise, and `mc-notify`'s own cap stays the only throttle. The levels and
  the channels come from the [`owner_send.*` settings](settings.md#owner-send); the script names no
  level of its own.
- **The line.** Only the channel in `owner_send.channels.bark` (the ntfy form: `.ntfy`) is read;
  the journal and every other channel in the result are ignored. A duplicate ping is cheap and a
  silent miss is not, so every outcome splits into two buckets and the tool always prints a line
  and exits 0 once it has found yo-human.

**Delivered, not delivered, or refused before any send.** `mc-notify` may resend a `failed -`. It
never resends a `refused config`: that raises one blocked item for the owner, deduplicated per
config problem.

| yo-human exit | The read channel | stdout |
|---|---|---|
| 0 | `sent`, not `unconfirmed` | `sent -` (delivered) |
| 69 | `dead`, `failed`, `skipped`, any other status, or absent | `failed -` |
| 64 | any | `refused config`, and yo-human's error text on stderr |
| binary missing or not executable | n/a | `refused config`, and a stderr line naming `owner_send.yo_human` |

yo-human refuses 64 (usage) before any network call, and a missing binary is also before the
network. 69 is a provider that refused for good, or a channel that was never built.

**Exit 78 is its own case: the read channel decides, and the line carries a `config` tag.** yo-human
exits 78 when any channel of the level could not be built (a missing secret, for one), even if the
channel this tool reads did send. A blanket `refused config` there would invite a retry and a
duplicate page. So:

| yo-human exit | The read channel | stdout |
|---|---|---|
| 78 | `sent`, not `unconfirmed` | `sent - config` |
| 78 | anything else, absent, or output that doesn't parse | `unknown - config` |

The caller never resends a `- config` line: it raises one blocked item for the owner, deduplicated
per (host, level), and a later clean send clears it. The stderr line keeps yo-human's error text:
`error.what` (a refusal), else `errors[0].what` (a result with problems), else a plain string
`error`, cut to one line of 300 characters.

**Ambiguous** (a request may have left: `unknown -`, so `mc-notify` never resends):

| yo-human exit | The read channel | stdout |
|---|---|---|
| 0 | `sent` and `unconfirmed`, or any other status | `unknown -` |
| 0 | absent from the result, or JSON that doesn't parse | `unknown -` |
| 75 (queued; yo-human retries it itself) | any | `unknown -` |
| 69 | `sent` (it contradicts the code), or JSON that doesn't parse | `unknown -` |
| 70 or 74 | any | `unknown -` |
| 1 to 63, 65 to 68, 71 to 73, 76, 77, 79 and above | any | `unknown -` |
| killed by a signal (above 128) | n/a | `unknown -` |

The tool itself exits 70 with no line only for its own error before it calls yo-human (no `jq`). A
bad entry, rule, level or note is 65, a usage error is 64, and a bad `owner_send.*` setting is 78,
each with nothing on stdout. Every diagnostic is on stderr.

**Runtime.** `mc-notify` runs its senders with `PATH=/usr/bin:/bin`, no shell and no profile, so:

- `bark_send` and `ntfy_send` must each be one absolute path to a small wrapper that does
  `exec <absolute bash 4.4 or newer> <absolute path>/bin/crewkit owner send "$@"` (macOS's
  `/bin/bash` is 3.2 and `crewkit` refuses it);
- `owner_send.yo_human` must be an absolute path, because `yo-human` is not on that `PATH`;
- `jq` is a dependency (`/usr/bin/jq` ships with macOS 15 and later; on Linux, install it). Any jq
  from 1.6 on works: jq 1.6 answers an empty input with exit 0 and no output, and the tool treats
  that as output that doesn't parse, as later versions do.

## Exit codes

See [exit-codes.md](exit-codes.md#crewkit).
