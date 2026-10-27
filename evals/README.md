# Evals

[cases.json](cases.json) holds behaviour evals for the agent-practice skills. Each case gives
a context, a prompt, what the reply **must** do and what it **must not** do. Most test a
refusal or a check that a session without the skill tends to skip. Some (such as
`msg-quoted-relay`) test that the skill doesn't over-refuse.

The permission-laundering and unquoted-approval cases come from the first eval round on the
skills this plugin grew from. In that round, the run without the skill caught the missing
quote but missed that hand-run production SQL needs the owner present, which no relay covers.

## Running

1. Use a scratch directory with **no memory notes**, so the baseline is a clean slate.
2. For each case, run the prompt twice on the same model: with the plugin installed, and
   without. Put the `context` in the first message or set it up for real.
3. Dry run only: read-only tools, nothing sent, merged or run against production.
4. Grade each `must` and `must_not` as pass or fail, by hand or with a grader model given only
   the case and the transcript.
5. Record results with the date, model and plugin version.

[run_cases.py](run_cases.py) runs both arms the same way, differing only in the plugins:

```bash
mkdir -p /tmp/eval-run   # an empty directory, no memory notes
python3 -I evals/run_cases.py base   . /tmp/eval-red   /tmp/eval-run herdr-no-prompt-existing,bitc-75-retry
python3 -I evals/run_cases.py plugin . /tmp/eval-green /tmp/eval-run herdr-no-prompt-existing,bitc-75-retry
evals/leakcheck.sh /tmp/eval-green
```

The memory-notices plugin shows each session the machine's shared-memory index, so the runner
points it at a temporary **fake index** (three example notes) and silences its change notices.
`leakcheck.sh` fails if any output names a real note or the real sync directory; run it before
sharing or committing anything from a run. Results so far are in
[docs/tdd/skills-red-green.md](../docs/tdd/skills-red-green.md).

The `skill-creator` plugin's eval loop also works for this. Case IDs are stable; add new cases at
the end and never reuse an ID.

## Adding a case

Add one when a skill changes, or when a real incident shows a behaviour the skills should
cover. Keep the context generic (no real names, hosts or numbers), and write `must` items
that a grader can check from the transcript alone.
