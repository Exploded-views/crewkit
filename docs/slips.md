# Slips get a mechanism

A slip is a mistake that reached, or nearly reached, something it shouldn't have: a push before
a check ran, a gate read as green when it hadn't run, a step skipped. The first slip happens.
The same slip a second time is the team's fault, because it knew and didn't prevent it. A note
that says "be careful next time" prevents nothing. An enforced check does.

## The rule

- **Every slip gets an enforced mechanism** that makes it impossible, or at least loud: a git
  hook, a CI or local gate, a lint, or a test. Write it test-first, like any other change: the
  failing test that reproduces the slip comes first.
- **Prefer a mechanism that covers new repos and sessions by default** (a host-wide hook, a
  shared template, a lint every repo runs) over one each repo must remember to install.
- **Check first whether a mechanism already failed.** If one existed and the slip got past it,
  fix the mechanism and its test, not the note.
- **Every slip gets a slip-log entry**: what happened, the root cause, the mechanism, and the
  test that proves the mechanism works. An entry without a mechanism and a test isn't finished.
- **Never bypass a mechanism.** No `--no-verify`, no `-c core.hooksPath=`, no skipping a gate,
  no "just this once". Only the owner may bypass, and the owner does it themself.
- **Tell the owner plainly** when a slip happens, before the fix, not after it.

## The slip log

`crewkit init` and `join` will create (planned) a slip log on each node, from `templates/slips.md`. One entry
per slip:

```markdown
## <date>: <one-line title>

- **What happened:** the slip, in one or two sentences.
- **Root cause:** why it could happen at all (not who did it).
- **Mechanism:** the hook, gate, lint or test that now prevents it, and where it lives.
- **Test:** the test that fails without the mechanism, and passes with it.
- **Was there an earlier mechanism?** If one failed, what was wrong with it and how it was fixed.
```

`crewkit doctor` will check (planned) that the log exists and that every entry names its
mechanism and its test.

## A worked example: an empty scan read as clean

- **What happened:** a privacy scan was run through a wrapper against a mistyped path to its
  private term list. The scan failed, but the wrapper threw away its exit status and its error
  output. Nothing was printed, and the empty output was read as "0 hits".
- **Root cause:** the caller read empty output as a pass. It didn't check the exit status, and a
  clean result didn't show its own coverage.
- **Mechanism:** the scan prints the number of patterns it loaded on every run, and its clean
  line carries that count; evidence of a clean scan must quote the count. Callers check the exit
  status.
- **Test:** a test checks that every run prints the loaded pattern count and that the clean line
  carries it, and that a missing or comment-only list still fails.
- **Was there an earlier mechanism?** Yes: the scan already failed on a missing or empty list. The
  wrapper threw that failure away, so the fix is to make the result show its coverage and to
  check the exit status, not to add another failure the wrapper could also discard.

The same shape applies to any check: a check whose silence means "pass" must show its own
coverage (how many patterns, files, commits or cases it read) and fail when that's zero.
