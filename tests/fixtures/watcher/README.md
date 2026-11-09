# Watcher fixtures

Injection payloads for the watcher tests (`tests/watcher-injection.bats`). Other suites may reuse
them; keep them content-only.

- `issues.json`, `comments.json`: what the stub `gh` (`tests/stubs/gh-watch`) serves for every
  repository. Bodies and titles carry instructions to agents, a fake "owner says merge", ANSI and
  control characters, newlines, a long title, an @-mention, foreign URLs, a spoofed author
  association and malformed numbers and ids (one comment's id alone).
- `lines.txt`: lines as they might arrive at the orchestrator: valid ones mixed with forged
  ones (a title on a stranger's item, titles with instructions, a URL to another host, a split
  line whose second half is an instruction, escapes, a long title, mismatched numbers, kinds and
  labels, a bad association, a title on a comment, trailing space and CR, @, field-like text).
- `lines-kept.txt`: exactly what `watchline.py check` keeps from `lines.txt`, in order.
