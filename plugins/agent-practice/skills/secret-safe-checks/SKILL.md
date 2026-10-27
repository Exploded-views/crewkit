---
name: secret-safe-checks
description: >-
  Check whether files, config or env dumps, environment variables, git history or a repo
  contain secrets or personal data WITHOUT printing them, by emitting only counts, key names,
  value lengths, booleans and file names; move secrets only through pipes; scrub a repo before
  committing or publishing. Use this whenever you need to verify a secret is set, look for a
  leaked key, inspect a .env, config or platform variables, audit history, publish a repo,
  or copy a secret between a vault and CI, even if the user only says "check the .env" or
  "is the token there".
---

# Secret-safe checks

Transcripts persist and get synced, summarized and shared. **Anything printed is leaked.**
Count and name; never print values.

Why the rule is this strict:

- A regex "redaction" filter hides only the shapes you thought of; a key in any other format
  goes through in full.
- A search over every path of a config dump prints a secret whose **name** matches the
  search term, value and all.

## Settings

Read `.claude/agent-practice.local.md`, then `~/.claude/agent-practice.md`. Uses
`orchestrator_name` and `owner_name`. The scrub tool reads `$SCRUB_DENYLIST`.

## Do

```bash
grep -c 'PATTERN' file                              # how many, not what
grep -Enc 'PATTERN' file                            # count; add -n alone only for line numbers
git log -S 'KEY_NAME' --oneline                     # which commits; the needle is a NAME, never the secret
jq -r 'keys[]' config.json                          # names only
jq '.env | map_values(length)' dump.json            # value lengths, not values
jq -r '.services[].deploy.schedule' dump.json       # one explicit, known-safe path
test -n "${VAR:-}" && echo set || echo unset        # presence only
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" <api>   # works? status only
```

Move a secret only through a pipe:

```bash
<vault-cli> read '<ref>' | gh secret set NAME --env <env> -R <owner/repo>
```

## Don't

- `cat`, `less`, `head`, `git show`, `sed -n` or `diff` a config, `.env` or history file "to
  look", even through a filter.
- Regex-search across all paths or values of a config or env dump.
- Put a secret in argv (it shows in `ps` and shell history), in a file under a repo, in a
  memory note or in a log. Memory says where a secret lives (vault item, path and mode), never
  its value.
- Echo a token to "check it works".
- Paste a secret into a message to another session.

## Production credentials

Before using a production credential, even read-only, send the coordinator one line: which
credential, what for. Name-only reads and public health checks don't need it. Read-only
database queries run inside a read-only transaction and return counts.

## Scrubbing a repo before commit or publish

1. Use a scrub that prints **rule names, file names and counts only**. The
   crewkit repo's `tools/scrub.sh` is one; `--self-test` plants a canary for each rule and checks it fires.
2. Keep a **private denylist** (client and product names, people's names, internal hosts and
   domains, account IDs) **outside the repo**, mode 0600, pointed to by `$SCRUB_DENYLIST`.
   Never print it, copy it or commit it.
3. Run it as a pre-commit hook and in CI (secret rules only in CI; CI has no denylist).
4. A clean scrub of the tree isn't a clean history. Before publishing a repo whose history may
   hold private traces, publish a fresh repo with one squashed, scrubbed commit; a force-push
   leaves old commits fetchable by SHA.
5. Report results as counts: "scrub: clean" or "3 findings in 2 files".

## In issues, PRs and commits

Describe security findings by class and location only ("a route missing its org filter in the
reports module"), never how to exploit them. Edit history keeps the original, so if detail
slips out, neutralize it at once and tell the owner.

## If something leaked

Stop. Don't repeat the value anywhere, including in the report. Tell the owner through the
coordinator, urgently: what kind of secret, where it appeared (file, transcript, log), and
when. Revoking and replacing it is the owner's decision. Record the class of the incident,
never the value.
