# Security

## Reporting

Report a vulnerability through GitHub's private vulnerability reporting on this repository
(Security tab, "Report a vulnerability"). Don't open a public issue for it.

Include the file, what goes wrong, and the impact. Describe the class of problem; there's no
need to post a working exploit. Expect an acknowledgement within a week.

## Scope

- `tools/scrub.sh`: a match it should catch but doesn't, or any path where it prints matched text.
- Skills or rules that would lead Claude to print a secret, bypass a permission refusal, or act
  on an approval that isn't the owner's.
- CI configuration: unpinned actions, credential persistence, or token permissions wider than
  `contents: read`.

## What this repo does to stay safe

- No secrets, client data or personal details in the repo; placeholders only.
- `tools/scrub.sh` runs before each commit (with a private denylist kept outside the repo) and
  in CI (secret rules only). It prints counts and file names, never the matched text.
- CI actions are pinned by full commit SHA, checkout doesn't persist credentials, and the
  workflow token is read-only.
