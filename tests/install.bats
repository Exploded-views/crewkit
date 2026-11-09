#!/usr/bin/env bats
# Behaviour of install.sh. Run with: tests/run.sh

load helpers

setup() { setup_tree; }

run_install() { run "$TREE/install.sh" "$@"; }

@test "dry run exits 0 and changes nothing" {
  memsync_release v0.1.0
  run_install
  [ "$status" -eq 0 ]
  [[ $output == *"Dry run"* ]]
  [ -z "$(ls -A "$HOME")" ]
}

@test "dry run downloads nothing" {
  memsync_release v0.1.0
  bitc_release v0.2.0
  run_install
  [ "$status" -eq 0 ]
  none -q '^curl' "$CALLS"
}

@test "an unknown flag is a usage error" {
  run_install --bogus
  [ "$status" -eq 64 ]
}

@test "an unpinned tool is skipped, not installed" {
  run_install --yes --only memsync
  [ "$status" -eq 0 ]
  [[ $output == *"skipped"* ]]
  [[ $output != *"paused"* ]]
  none -q '^curl' "$CALLS"
}

@test "memsync: a matching sha hands the unpacked release to its bootstrap as --prebuilt-dir" {
  memsync_release v0.1.0
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 0 ]
  grep -qx 'prebuilt ok' "$CALLS"
}

@test "memsync: downloads the pinned asset and SHA256SUMS from the pinned URL" {
  memsync_release v0.1.0
  run_install --yes --only memsync -- --host h1
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/claude-utils-v0.1.0-linux-amd64.tar.gz' "$CALLS"
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/SHA256SUMS' "$CALLS"
}

@test "memsync: an archive the release's SHA256SUMS disagrees with is refused" {
  memsync_release v0.1.0
  printf '%s  claude-utils-v0.1.0-linux-amd64.tar.gz\n' "$(hex64 2)" > "$FIXTURES/SHA256SUMS"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"SHA256SUMS"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: an archive missing from SHA256SUMS is refused" {
  memsync_release v0.1.0
  : > "$FIXTURES/SHA256SUMS"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: runs the release's bootstrap with the flags after --" {
  memsync_release v0.1.0
  run_install --yes --only memsync -- --host h1 --role personal-dev
  [ "$status" -eq 0 ]
  grep -Eqx 'bootstrap --prebuilt-dir [^ ]+/claude-utils-v0.1.0-linux-amd64 --host h1 --role personal-dev' "$CALLS"
}

@test "memsync: a sha mismatch is refused before anything is unpacked or run" {
  memsync_release v0.1.0
  sed -i "s/^MEMSYNC_SHA256_linux_amd64=.*/MEMSYNC_SHA256_linux_amd64=$(hex64 0)/" "$TREE/pins/memsync.env"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"sha256 mismatch"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: bootstrap exit 3 (paused, needs a human) passes through and stops" {
  memsync_release v0.1.0 3
  run_install --yes --only memsync --only plugins -- --host h1
  [ "$status" -eq 3 ]
  none -q '^claude' "$CALLS"
}

@test "memsync: a bootstrap failure fails the install" {
  memsync_release v0.1.0 1
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
}

@test "a pinned tag with no hash for this target is refused" {
  memsync_release v0.1.0
  export FAKE_ARCH=aarch64
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"no sha256 pinned for linux/arm64"* ]]
  none -q '^curl' "$CALLS"
}

@test "a malformed hash is refused" {
  memsync_release v0.1.0
  sed -i 's/^MEMSYNC_SHA256_linux_amd64=.*/MEMSYNC_SHA256_linux_amd64=abc123/' "$TREE/pins/memsync.env"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  none -q '^curl' "$CALLS"
}

@test "pin files are parsed, never executed" {
  memsync_release v0.1.0
  printf 'MEMSYNC_EXTRA=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >> "$TREE/pins/memsync.env"
  printf 'touch %s/pwned2\n' "$BATS_TEST_TMPDIR" >> "$TREE/pins/memsync.env"
  run_install --only memsync
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
}

@test "a pinned URL must be https" {
  memsync_release v0.1.0
  sed -i 's|^MEMSYNC_URL=.*|MEMSYNC_URL=http://example.test/x|' "$TREE/pins/memsync.env"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  none -q '^curl' "$CALLS"
}

@test "an archive with a path outside its root is refused" {
  memsync_release v0.1.0
  # GNU tar strips ../ when creating, so build the hostile archive with Python.
  python3 -c 'import io,sys,tarfile
t=tarfile.open(sys.argv[1],"w:gz"); i=tarfile.TarInfo("../escape"); d=b"x"; i.size=len(d); t.addfile(i,io.BytesIO(d)); t.close()' \
    "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz"
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe path"* ]]
}

@test "an archive containing a link is refused" {
  memsync_release v0.1.0
  local stage="$BATS_TEST_TMPDIR/stage-memsync"
  ln -s /etc/passwd "$stage/claude-utils-v0.1.0-linux-amd64/claude-memmerge.link"
  tar -czf "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz" -C "$stage" .
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"only files and directories"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: an archive without its claude-utils-<tag>-<os>-<arch>/ dir is refused" {
  memsync_release v0.1.0
  local flat="$BATS_TEST_TMPDIR/flat"
  mkdir -p "$flat/scripts"
  cp -a "$BATS_TEST_TMPDIR/stage-memsync/claude-utils-v0.1.0-linux-amd64/." "$flat/"
  tar -czf "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz" -C "$flat" .
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: a release missing a binary is refused before its bootstrap runs" {
  memsync_release v0.1.0
  local stage="$BATS_TEST_TMPDIR/stage-memsync"
  rm "$stage/claude-utils-v0.1.0-linux-amd64/claude-memmerge"
  tar -czf "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz" -C "$stage" claude-utils-v0.1.0-linux-amd64
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"has no claude-utils-v0.1.0-linux-amd64/claude-memmerge"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "bitc: a matching sha installs bitc into ~/.local/bin" {
  bitc_release v0.2.0
  run_install --yes --only bitc
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/bitc" ]
  grep -qx 'curl https://example.test/OWNER/bitc/releases/download/v0.2.0/bitc_0.2.0_linux_amd64.tar.gz' "$CALLS"
}

@test "bitc: the installed binary's sha256 is recorded for the heavy-lock check" {
  bitc_release v0.2.0
  run_install --yes --only bitc
  [ "$status" -eq 0 ]
  r="$HOME/.local/share/crewkit/bitc.sha256"
  [ -f "$r" ]
  [ "$(cat "$r")" = "$(sha_of "$HOME/.local/bin/bitc")" ]
  [ "$(wc -l < "$r" | tr -d ' ')" = 1 ]
}

@test "bitc: a re-install records the new binary's sha256, replacing the old record" {
  bitc_release v0.2.0
  mkdir -p "$HOME/.local/share/crewkit"
  echo stale > "$HOME/.local/share/crewkit/bitc.sha256"
  run_install --yes --only bitc
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.local/share/crewkit/bitc.sha256")" = "$(sha_of "$HOME/.local/bin/bitc")" ]
}

@test "bitc: a sha mismatch and a dry run record nothing" {
  bitc_release v0.2.0
  run_install --only bitc
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/share/crewkit/bitc.sha256" ]
  sed "s/^BITC_SHA256_linux_amd64=.*/BITC_SHA256_linux_amd64=$(hex64 1)/" "$TREE/pins/bitc.env" > "$TREE/pins/bitc.env.new"
  mv "$TREE/pins/bitc.env.new" "$TREE/pins/bitc.env"
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/share/crewkit/bitc.sha256" ]
}

@test "bitc: a sha mismatch installs nothing" {
  bitc_release v0.2.0
  sed -i "s/^BITC_SHA256_linux_amd64=.*/BITC_SHA256_linux_amd64=$(hex64 1)/" "$TREE/pins/bitc.env"
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "bitc: on macOS the darwin build is installed" {
  bitc_release v0.2.0 darwin arm64
  export FAKE_OS=Darwin FAKE_ARCH=arm64
  run_install --yes --only bitc
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/bitc" ]
  grep -qx 'curl https://example.test/OWNER/bitc/releases/download/v0.2.0/bitc_0.2.0_darwin_arm64.tar.gz' "$CALLS"
}

@test "gitleaks: a matching sha installs it for the push gate, with its own sha256 beside it" {
  gitleaks_release v8.30.1
  run_install --yes --only gitleaks
  [ "$status" -eq 0 ]
  g="$HOME/.local/share/crewkit/gitleaks/gitleaks"
  [ -x "$g" ]
  [ "$(cat "$g.sha256")" = "$(sha_of "$g")" ]
  grep -qx 'curl https://example.test/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz' "$CALLS"
  grep -qx 'curl https://example.test/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt' "$CALLS"
}

@test "gitleaks: on macOS arm64 the darwin_arm64 build is installed" {
  gitleaks_release v8.30.1 darwin arm64
  export FAKE_OS=Darwin FAKE_ARCH=arm64
  run_install --yes --only gitleaks
  [ "$status" -eq 0 ]
  grep -qx 'curl https://example.test/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz' "$CALLS"
}

@test "gitleaks: on arm64 Linux (uname aarch64) the linux_arm64 build is installed" {
  gitleaks_release v8.30.1 linux arm64
  export FAKE_OS=Linux FAKE_ARCH=aarch64
  run_install --yes --only gitleaks
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/share/crewkit/gitleaks/gitleaks" ]
  grep -qx 'curl https://example.test/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz' "$CALLS"
}

@test "gitleaks: a sha mismatch, or a checksums file that disagrees, installs nothing" {
  gitleaks_release v8.30.1
  sed -i "s/^GITLEAKS_SHA256_linux_amd64=.*/GITLEAKS_SHA256_linux_amd64=$(hex64 1)/" "$TREE/pins/gitleaks.env"
  run_install --yes --only gitleaks
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/share/crewkit/gitleaks" ]
  gitleaks_release v8.30.1
  echo "$(hex64 2)  gitleaks_8.30.1_linux_x64.tar.gz" > "$FIXTURES/gitleaks_8.30.1_checksums.txt"
  run_install --yes --only gitleaks
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/share/crewkit/gitleaks/gitleaks" ]
}

@test "gitleaks: a binary that reports another version is refused, and nothing is recorded" {
  gitleaks_release v8.30.1 linux amd64 8.29.0
  run_install --yes --only gitleaks
  [ "$status" -eq 1 ]
  [[ $output == *"8.29.0"* ]]
  [ ! -e "$HOME/.local/share/crewkit/gitleaks/gitleaks" ]
  [ ! -e "$HOME/.local/share/crewkit/gitleaks/gitleaks.sha256" ]
}

@test "gitleaks: unpinned is skipped, and the dry run names it" {
  run_install
  [ "$status" -eq 0 ]
  [[ $output == *"gitleaks:"*"skipped"* ]]
}

@test "an unsupported OS is refused" {
  export FAKE_OS=FreeBSD
  run_install
  [ "$status" -eq 1 ]
}

@test "plugins: --yes adds the marketplace, installs the plugins and the rules fragment" {
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  grep -qx "claude plugin marketplace add $TREE" "$CALLS"
  grep -qx 'claude plugin install crew-nodes@crewkit' "$CALLS"
  grep -qx 'claude plugin install agent-practice@crewkit' "$CALLS"
  grep -qx 'claude plugin install memory-notices@crewkit' "$CALLS"
  cmp "$TREE/plugins/agent-practice/rules/CLAUDE-fragment.md" "$HOME/.claude/rules/agent-practice.md"
}

@test "plugins: an edited rules file is backed up, not lost" {
  mkdir -p "$HOME/.claude/rules"
  echo "my edits" > "$HOME/.claude/rules/agent-practice.md"
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  grep -qx 'my edits' "$HOME/.claude/rules/agent-practice.md.bak"
}

@test "--help prints usage and exits 0" {
  run_install --help
  [ "$status" -eq 0 ]
  [[ $output == *"Usage:"* ]]
}

@test "an unsupported architecture is refused" {
  export FAKE_ARCH=riscv64
  run_install
  [ "$status" -eq 1 ]
  [[ $output == *"unsupported architecture"* ]]
}

@test "a missing pin file is an error" {
  rm "$TREE/pins/memsync.env"
  run_install --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"missing pin file"* ]]
}

@test "plugins: without claude on PATH the step is skipped with a note, dry run or --yes" {
  rm "$BATS_TEST_TMPDIR/stubs/claude"
  PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin"
  if command -v claude >/dev/null; then skip "claude is installed system-wide"; fi
  run_install --only plugins
  [ "$status" -eq 0 ]
  [[ $output == *"not on PATH"* ]]
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  [[ $output == *"skipped"* && $output == *"not on PATH"* ]]
  none -q '^claude' "$CALLS"
  [ ! -e "$HOME/.claude/rules/agent-practice.md" ]
}

@test "a tag that isn't vMAJOR.MINOR.PATCH is refused before any download" {
  local bad
  for bad in v1.2 .. v1.2.3/ 'v1.2.3;x' v1.2.3- 'v1.2.3-/x' 'v1.2.3-a b' 'v1.2.3-$x' 'v1.2.3+meta'; do
    memsync_release v0.1.0
    sed -i "s|^MEMSYNC_TAG=.*|MEMSYNC_TAG=$bad|" "$TREE/pins/memsync.env"
    : > "$CALLS"
    run_install --yes --only memsync -- --host h1
    [ "$status" -eq 1 ]
    [[ $output == *"vMAJOR.MINOR.PATCH"* ]]
    none -q '^curl' "$CALLS"
  done
}

@test "an archive with an absolute path is refused" {
  memsync_release v0.1.0
  python3 -c 'import io,sys,tarfile
t=tarfile.open(sys.argv[1],"w:gz"); i=tarfile.TarInfo("/tmp/abs-escape"); d=b"x"; i.size=len(d); t.addfile(i,io.BytesIO(d)); t.close()' \
    "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz"
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe path"* ]]
}

@test "an archive with a FIFO or other special file is refused" {
  memsync_release v0.1.0
  python3 -c 'import sys,tarfile
t=tarfile.open(sys.argv[1],"w:gz"); i=tarfile.TarInfo("claude-utils-v0.1.0-linux-amd64/pipe"); i.type=tarfile.FIFOTYPE; t.addfile(i); t.close()' \
    "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz"
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"only files and directories"* ]]
}

@test "bitc: an archive without a bitc binary is refused" {
  bitc_release v0.2.0
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"; echo x > "$empty/README.md"
  tar -czf "$FIXTURES/bitc_0.2.0_linux_amd64.tar.gz" -C "$empty" README.md
  republish bitc_0.2.0_linux_amd64.tar.gz
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [[ $output == *"no bitc binary"* ]]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "an inherited tmp variable doesn't redirect the work dir" {
  memsync_release v0.1.0
  local mine="$BATS_TEST_TMPDIR/mine"
  mkdir -p "$mine/memsync"; echo keep > "$mine/memsync/notes.txt"
  tmp="$mine" run_install --yes --only memsync -- --host h1
  [ "$status" -eq 0 ]
  [ "$(ls -A "$mine/memsync")" = notes.txt ]
}

@test "a failing step exits 1 whatever the failing command's own code" {
  printf '#!/usr/bin/env bash\necho "claude $*" >> "$CALLS"\nexit 3\n' > "$BATS_TEST_TMPDIR/stubs/claude"
  run_install --yes --only plugins
  [ "$status" -eq 1 ]
}

@test "plugins: a second edit keeps the first backup too" {
  mkdir -p "$HOME/.claude/rules"
  echo "edit one" > "$HOME/.claude/rules/agent-practice.md"
  run_install --yes --only plugins
  echo "edit two" > "$HOME/.claude/rules/agent-practice.md"
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  grep -qx 'edit one' "$HOME"/.claude/rules/agent-practice.md.bak*
  grep -qx 'edit two' "$HOME"/.claude/rules/agent-practice.md.bak*
}

@test "bootstrap flags are not echoed in the plan" {
  memsync_release v0.1.0
  run_install --only memsync -- --org-app-key-cmd 'secret-thing'
  [ "$status" -eq 0 ]
  [[ $output != *"secret-thing"* ]]
}

@test "flags after -- are reported when the memsync step isn't run" {
  run_install --only plugins -- --host h1
  [ "$status" -eq 0 ]
  [[ $output == *"ignored"* ]]
}

@test "plugins: a re-run with everything installed adds and installs nothing" {
  export CLAUDE_MARKETS_JSON='[{"name": "crewkit", "source": "directory"}]'
  export CLAUDE_PLUGINS_JSON='[{"id": "crew-nodes@crewkit"}, {"id": "agent-practice@crewkit"}, {"id": "memory-notices@crewkit"}]'
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  none -q '^claude plugin install' "$CALLS"
  none -q '^claude plugin marketplace add' "$CALLS"
  [[ $output == *"already installed"* ]]
}

@test "plugins: only the missing plugin is installed" {
  export CLAUDE_MARKETS_JSON='[{"name":"crewkit"}]'
  export CLAUDE_PLUGINS_JSON='[{"id":"agent-practice@crewkit"}]'
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  none -qx 'claude plugin install agent-practice@crewkit' "$CALLS"
  grep -qx 'claude plugin install memory-notices@crewkit' "$CALLS"
}

@test "plugins: a plugin from another marketplace with the same name doesn't count" {
  export CLAUDE_MARKETS_JSON='[{"name":"crewkit"}]'
  export CLAUDE_PLUGINS_JSON='[{"id":"agent-practice@elsewhere"}]'
  run_install --yes --only plugins
  grep -qx 'claude plugin install agent-practice@crewkit' "$CALLS"
}

@test "plugins: a current rules fragment is left alone on a re-run" {
  run_install --yes --only plugins
  touch -d '2001-01-01' "$HOME/.claude/rules/agent-practice.md"
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  [[ $output == *"rules fragment already current"* ]]
  [ "$(date -r "$HOME/.claude/rules/agent-practice.md" +%Y)" = 2001 ]
  none -q 'agent-practice.md.bak' <(ls "$HOME/.claude/rules")
}

@test "plugins: a dry run makes no claude calls (it stays fast)" {
  run_install --only plugins
  [ "$status" -eq 0 ]
  none -q '^claude' "$CALLS"
  [[ $output == *"skipped if already"* ]]
}

@test "an unknown --only step is a usage error (64)" {
  run_install --only nonsense
  [ "$status" -eq 64 ]
}

@test "bitc: the release's checksums.txt must list the pinned hash" {
  bitc_release v0.2.0
  printf '%s  bitc_0.2.0_linux_amd64.tar.gz\n' "$(hex64 2)" > "$FIXTURES/checksums.txt"
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [[ $output == *checksums.txt* ]]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "bitc: the installed binary must report the pinned version as a release" {
  bitc_release v0.2.0 linux amd64 '{"commit":"1111111","release":true,"version":"0.1.9"}'
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [[ $output == *"bitc version"* ]]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "bitc: a version that only starts with the pinned one is refused" {
  bitc_release v0.2.0 linux amd64 '{"commit":"1111111","release":true,"version":"0.2.0-rc1"}'
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "bitc: a development build (release=false) is refused" {
  bitc_release v0.2.0 linux amd64 '{"commit":"1111111","release":false,"version":"0.2.0"}'
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/bitc" ]
}

@test "bitc: a failed version check leaves an existing bitc in place" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho old\n' > "$HOME/.local/bin/bitc"; chmod +x "$HOME/.local/bin/bitc"
  bitc_release v0.2.0 linux amd64 '{"commit":"1111111","release":true,"version":"0.1.9"}'
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ "$("$HOME/.local/bin/bitc")" = old ]
  [ ! -e "$HOME/.local/share/crewkit/bitc.sha256" ]
}

@test "bitc: a failed version check leaves an existing record unchanged" {
  mkdir -p "$HOME/.local/share/crewkit"
  echo previous > "$HOME/.local/share/crewkit/bitc.sha256"
  bitc_release v0.2.0 linux amd64 '{"commit":"1111111","release":true,"version":"0.1.9"}'
  run_install --yes --only bitc
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.local/share/crewkit/bitc.sha256")" = previous ]
}

@test "bitc: the record and a new ~/.local/bin get fixed modes under umask 002" {
  bitc_release v0.2.0
  umask 002
  run_install --yes --only bitc
  [ "$status" -eq 0 ]
  [ "$(ls -ld "$HOME/.local/share/crewkit/bitc.sha256" | cut -c1-10)" = "-rw-r--r--" ]
  [ "$(ls -ld "$HOME/.local/bin" | cut -c1-10)" = "drwxr-xr-x" ]
  [ "$(ls -ld "$HOME/.local" | cut -c1-10)" = "drwxr-xr-x" ]
  [ "$(ls -ld "$HOME/.local/bin/bitc" | cut -c1-10)" = "-rwxr-xr-x" ]
}

@test "memsync: a pre-release tag (vX.Y.Z-suffix) is installed" {
  memsync_release v0.3.0-ev.1
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 0 ]
  grep -qx 'prebuilt ok' "$CALLS"
}

@test "memsync: the unpacked claude-memsync must report the pinned tag, or its bootstrap never runs" {
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.2"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  [[ $output == *"claude-memsync version"* ]]
  none -q '^bootstrap' "$CALLS"
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.1-dirty"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
  none -q '^bootstrap' "$CALLS"
}

@test "pin checks are ASCII whatever the locale: a non-ASCII tag or URL is refused" {
  locale -a 2>/dev/null | grep -qix 'en_US.utf-\{0,1\}8' || skip "needs the en_US.UTF-8 locale"
  local bad
  for bad in 'v1.2.3-é' 'v١.2.3' 'v1.2.3-ｅv'; do
    memsync_release v0.1.0
    sed -i "s|^MEMSYNC_TAG=.*|MEMSYNC_TAG=$bad|" "$TREE/pins/memsync.env"
    : > "$CALLS"
    LC_ALL=en_US.UTF-8 run_install --yes --only memsync -- --host h1
    [ "$status" -eq 1 ] || { echo "accepted tag $bad"; return 1; }
    none -q '^curl' "$CALLS"
  done
  memsync_release v0.1.0
  sed -i "s|^MEMSYNC_URL=.*|MEMSYNC_URL=https://exämple.test/o/r/releases/download|" "$TREE/pins/memsync.env"
  LC_ALL=en_US.UTF-8 run_install --yes --only memsync -- --host h1
  [ "$status" -eq 1 ]
}

@test "memsync: only the version's first line counts, so extra lines after it don't fail the check" {
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.1
built by the release workflow"
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 0 ]
}

@test "plugins: crew-nodes is installed first, then agent-practice, then memory-notices" {
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  local a b c
  a=$(grep -n 'install crew-nodes@crewkit' "$CALLS" | cut -d: -f1)
  b=$(grep -n 'install agent-practice@crewkit' "$CALLS" | cut -d: -f1)
  c=$(grep -n 'install memory-notices@crewkit' "$CALLS" | cut -d: -f1)
  [ "$a" -lt "$b" ]; [ "$b" -lt "$c" ]
}

@test "herdr: a matching sha installs the fork tarball's binary and runs the integration of the one agent on PATH" {
  herdr_release v0.9.5
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/herdr" ]
  grep -qx 'curl https://example.test/OWNER/herdr/releases/download/v0.9.5/herdr-v0.9.5-x86_64-unknown-linux-musl.tar.gz' "$CALLS"
  grep -qx 'curl https://example.test/OWNER/herdr/releases/download/v0.9.5/herdr-v0.9.5-x86_64-unknown-linux-musl.tar.gz.sha256' "$CALLS"
  grep -qx 'herdr integration install claude' "$CALLS"
  [ "$(grep -c '^herdr integration' "$CALLS")" -eq 1 ]
}

@test "herdr: every agent CLI on PATH gets its integration" {
  herdr_release v0.9.5
  agent_cli codex
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  grep -qx 'herdr integration install claude' "$CALLS"
  grep -qx 'herdr integration install codex' "$CALLS"
  [ "$(grep -c '^herdr integration' "$CALLS")" -eq 2 ]
}

@test "herdr: cursor's agent CLI is cursor-agent, and its integration is cursor" {
  herdr_release v0.9.5
  agent_cli cursor-agent
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  grep -qx 'herdr integration install cursor' "$CALLS"
}

@test "herdr: with no agent CLI on PATH herdr is installed, no integration runs, and that is success" {
  herdr_release v0.9.5
  rm "$BATS_TEST_TMPDIR/stubs/claude"
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/herdr" ]
  none -q '^herdr integration' "$CALLS"
  [[ $output == *"no agent CLI"* ]]
}

@test "herdr: an integration refused because the agent was never run is a note, not a failed step" {
  herdr_release v0.9.5
  HERDR_STUB_FAIL=missing run_install --yes --only herdr
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/herdr" ]
  [[ $output == *"integration install claude"*"failed"* ]]
}

@test "herdr: any other integration failure fails the step, naming the agent and herdr's exit code" {
  herdr_release v0.9.5
  HERDR_STUB_FAIL=other run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"herdr integration install claude failed (exit 7)"* ]]
}

@test "herdr: an integration that drops a hook from settings.json is undone and fails the step" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  HERDR_STUB_CLOBBER=1 run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"keep-me"* ]]
  cmp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  [ ! -e "$HOME/.claude/settings.json.crewkit-before" ]
}

@test "guard: a restore that fails keeps the backup, names it, and does not claim a restore" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  cp_fails_on /settings.json
  HERDR_STUB_CLOBBER=1 run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"$HOME/.claude/settings.json.crewkit-before"* ]]
  [[ $output != *"is restored"* ]]
  cmp "$HOME/.claude/settings.json.crewkit-before" "$BATS_TEST_TMPDIR/before.json"
}

@test "guard: a backup that can't be made stops the step before the command runs" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  cp_fails_on .crewkit-before
  HERDR_STUB_CLOBBER=1 run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"could not back up"* ]]
  none -q 'integration' "$CALLS"
  cmp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "guard: a backup left by an earlier run is never overwritten or deleted (herdr)" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{}}' > "$HOME/.claude/settings.json"
  printf '%s' 'precious old copy' > "$HOME/.claude/settings.json.crewkit-before"
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"$HOME/.claude/settings.json.crewkit-before"* ]]
  none -q 'integration' "$CALLS"
  [ "$(cat "$HOME/.claude/settings.json.crewkit-before")" = 'precious old copy' ]
}

@test "guard: a backup left by an earlier run is never deleted when settings.json is missing (rtk)" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  printf '%s' 'precious old copy' > "$HOME/.claude/settings.json.crewkit-before"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  none -qx 'rtk init -g --auto-patch' "$CALLS"
  [ "$(cat "$HOME/.claude/settings.json.crewkit-before")" = 'precious old copy' ]
}

@test "herdr: a 'directory not found' without the 'at <path>' is not the benign case" {
  herdr_release v0.9.5
  HERDR_STUB_FAIL=vague run_install --yes --only herdr
  [ "$status" -eq 1 ]
}

@test "guard: the dropped-hook message names the command, not a shell function" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  HERDR_STUB_CLOBBER=1 run_install --yes --only herdr
  [[ $output == *"herdr integration install claude dropped"* ]]
}

@test "herdr: a failed version check names herdr, not the asset file" {
  herdr_release v0.9.5 linux amd64 "herdr 0.9.4"
  run_install --yes --only herdr
  [[ $output == *"downloaded herdr reports 'herdr 0.9.4' to herdr --version"* ]]
}

@test "herdr: an integration that keeps the hooks leaves no backup behind" {
  herdr_release v0.9.5
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json.crewkit-before" ]
}

@test "herdr: without jq on PATH and claude present, the step fails naming jq before anything is installed" {
  herdr_release v0.9.5
  local d="$BATS_TEST_TMPDIR/nojq" t
  mkdir -p "$d"
  for t in bash env tar gzip sed grep awk cut mktemp install mv cp rm cmp mkdir chmod cat dirname sha256sum shasum uname curl tr head claude; do
    ln -s "$(command -v "$t")" "$d/$t" 2>/dev/null || true
  done
  PATH="$d" run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"jq"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: a sha mismatch installs nothing and runs nothing" {
  herdr_release v0.9.5
  sed -i "s/^HERDR_SHA256_linux_amd64=.*/HERDR_SHA256_linux_amd64=$(hex64 1)/" "$TREE/pins/herdr.env"
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"sha256 mismatch"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
  none -q 'integration' "$CALLS"
}

@test "herdr: a binary that reports another version is refused before it replaces anything" {
  herdr_release v0.9.5 linux amd64 "herdr 0.9.4"
  mkdir -p "$HOME/.local/bin"; echo old > "$HOME/.local/bin/herdr"
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"herdr 0.9.5"* ]]
  [ "$(cat "$HOME/.local/bin/herdr")" = old ]
  none -q 'integration' "$CALLS"
}

@test "herdr: a version that only starts like the pin (0.9.50) is refused" {
  herdr_release v0.9.5 linux amd64 "herdr 0.9.50"
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: only the first line of --version counts" {
  herdr_release v0.9.5 linux amd64 "herdr 0.9.5
more text"
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
}

@test "herdr: on linux arm64 the aarch64-unknown-linux-musl tarball is fetched" {
  export FAKE_ARCH=aarch64
  herdr_release v0.9.5 linux arm64
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  grep -q 'herdr-v0.9.5-aarch64-unknown-linux-musl.tar.gz$' "$CALLS"
}

@test "herdr: on macOS the apple-darwin tarballs are fetched" {
  export FAKE_OS=Darwin FAKE_ARCH=arm64
  herdr_release v0.9.5 darwin arm64
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  grep -q 'herdr-v0.9.5-aarch64-apple-darwin.tar.gz$' "$CALLS"
  export FAKE_ARCH=x86_64
  herdr_release v0.9.5 darwin amd64
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  grep -q 'herdr-v0.9.5-x86_64-apple-darwin.tar.gz$' "$CALLS"
}

# --- herdr: the fork's release (tarball + per-asset .sha256) ---

herdr_asset() { echo "herdr-$1-x86_64-unknown-linux-musl.tar.gz"; }

@test "herdr: a .sha256 file that lists another hash is refused before anything is unpacked or run" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  local a; a=$(herdr_asset v0.9.5-ev.2)
  printf '%s  %s\n' "$(hex64 1)" "$a" > "$FIXTURES/$a.sha256"
  spy_tar
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"$a.sha256 for v0.9.5-ev.2 does not list $a with the pinned sha256"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
  none -q '^tar' "$CALLS"
  none -q '^herdr' "$CALLS"
}

@test "herdr: a .sha256 file that does not name the asset is refused" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  local a; a=$(herdr_asset v0.9.5-ev.2)
  printf '%s  %s\n' "$(sha_of "$FIXTURES/$a")" "herdr-other.tar.gz" > "$FIXTURES/$a.sha256"
  spy_tar
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"$a.sha256 for v0.9.5-ev.2 does not list $a with the pinned sha256"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
  none -q '^tar' "$CALLS"
  none -q '^herdr' "$CALLS"
}

@test "herdr: a missing .sha256 file is refused" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  rm "$FIXTURES/$(herdr_asset v0.9.5-ev.2).sha256"
  spy_tar
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"download failed"*".sha256"* ]]
  none -q '^tar' "$CALLS"
  none -q '^herdr' "$CALLS"
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: a tarball without a herdr file is refused" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  local a stage="$BATS_TEST_TMPDIR/stage-other"; a=$(herdr_asset v0.9.5-ev.2)
  mkdir -p "$stage"; echo x > "$stage/README"
  tar -czf "$FIXTURES/$a" -C "$stage" README
  herdr_repin v0.9.5-ev.2 linux amd64
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"no herdr"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: a tarball whose herdr is not a plain file, or that holds a .. member, is refused" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  local a stage="$BATS_TEST_TMPDIR/stage-bad"; a=$(herdr_asset v0.9.5-ev.2)
  mkdir -p "$stage"; ln -s /bin/sh "$stage/herdr"
  tar -czf "$FIXTURES/$a" -C "$stage" herdr
  herdr_repin v0.9.5-ev.2 linux amd64
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe entry"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
  rm "$stage/herdr"; echo x > "$stage/herdr"
  python3 -c 'import sys, tarfile
t = tarfile.open(sys.argv[1], "w:gz"); t.add(sys.argv[2], arcname="../herdr"); t.close()' "$FIXTURES/$a" "$stage/herdr"
  herdr_repin v0.9.5-ev.2 linux amd64
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe path"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: a tarball whose herdr is a directory is refused" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5-ev.2"
  local a stage="$BATS_TEST_TMPDIR/stage-dir"; a=$(herdr_asset v0.9.5-ev.2)
  mkdir -p "$stage/herdr"; echo x > "$stage/herdr/inner"
  tar -czf "$FIXTURES/$a" -C "$stage" herdr
  herdr_repin v0.9.5-ev.2 linux amd64
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [[ $output == *"no herdr binary"* ]]
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr: with HERDR_VERSION=0.9.5 and tag v0.9.5-ev.2, 'herdr 0.9.5' installs" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5" 0.9.5
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/herdr" ]
}

@test "herdr: with HERDR_VERSION=0.9.5, 'herdr 0.9.5-ev.2' and 'herdr 0.9.50' are refused" {
  local bad
  for bad in "herdr 0.9.5-ev.2" "herdr 0.9.50"; do
    herdr_release v0.9.5-ev.2 linux amd64 "$bad" 0.9.5
    run_install --yes --only herdr
    [ "$status" -eq 1 ] || { echo "accepted $bad"; return 1; }
    [ ! -e "$HOME/.local/bin/herdr" ]
  done
}

@test "herdr: without HERDR_VERSION, tag v0.9.5-ev.2 needs exactly 'herdr 0.9.5-ev.2'" {
  herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5"
  run_install --yes --only herdr
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/herdr" ]
  herdr_release v0.9.5-ev.2
  run_install --yes --only herdr
  [ "$status" -eq 0 ]
}

@test "herdr: a malformed HERDR_VERSION is refused, naming pins/herdr.env" {
  local bad
  for bad in "0.9" "v0.9.5" "0.9.5-" "0.9.5 x" "0.9.5+meta"; do
    herdr_release v0.9.5-ev.2 linux amd64 "herdr 0.9.5" 0.9.5
    sed -i "s|^HERDR_VERSION=.*|HERDR_VERSION=$bad|" "$TREE/pins/herdr.env"
    run_install --yes --only herdr
    [ "$status" -eq 1 ] || { echo "accepted $bad"; return 1; }
    [[ $output == *"pins/herdr.env"* ]]
    none -q '^curl' "$CALLS"
  done
}

@test "rtk: installs the pinned archive and runs rtk init -g" {
  rtk_release v1.1.0
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/rtk" ]
  grep -qx 'curl https://example.test/OWNER/rtk/releases/download/v1.1.0/rtk-x86_64-unknown-linux-musl.tar.gz' "$CALLS"
  grep -qx 'rtk init -g --auto-patch' "$CALLS"
  grep -qx '@RTK.md' "$HOME/.claude/CLAUDE.md"
  jq -e '[..|.command? // empty] | index("rtk hook claude")' "$HOME/.claude/settings.json"
}

@test "rtk: a sha mismatch installs nothing" {
  rtk_release v1.1.0
  sed -i "s/^RTK_SHA256_linux_amd64=.*/RTK_SHA256_linux_amd64=$(hex64 1)/" "$TREE/pins/rtk.env"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/rtk" ]
  none -q '^rtk' "$CALLS"
}

@test "rtk: an archive the release's checksums.txt disagrees with is refused" {
  rtk_release v1.1.0
  printf '%s  rtk-x86_64-unknown-linux-musl.tar.gz\n' "$(hex64 2)" > "$FIXTURES/checksums.txt"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [[ $output == *"checksums.txt"* ]]
  [ ! -e "$HOME/.local/bin/rtk" ]
}

@test "rtk: an archive missing from checksums.txt is refused" {
  rtk_release v1.1.0
  : > "$FIXTURES/checksums.txt"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/rtk" ]
}

@test "rtk: a binary that reports another version is refused before it replaces anything" {
  rtk_release v1.1.0 linux amd64 "rtk 1.0.9"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/rtk" ]
  none -q '^rtk' "$CALLS"
}

@test "rtk: an archive without an rtk binary is refused" {
  rtk_release v1.1.0
  local empty="$BATS_TEST_TMPDIR/empty-rtk"
  mkdir -p "$empty"; echo x > "$empty/LICENSE"
  tar -czf "$FIXTURES/rtk-x86_64-unknown-linux-musl.tar.gz" -C "$empty" LICENSE
  sed -i "s/^RTK_SHA256_linux_amd64=.*/RTK_SHA256_linux_amd64=$(sha_of "$FIXTURES/rtk-x86_64-unknown-linux-musl.tar.gz")/" "$TREE/pins/rtk.env"
  sums rtk
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [[ $output == *"no rtk binary"* ]]
}

@test "rtk: on each other target the matching triple is fetched" {
  export FAKE_ARCH=aarch64
  rtk_release v1.1.0 linux arm64
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  grep -q 'rtk-aarch64-unknown-linux-gnu.tar.gz$' "$CALLS"
  export FAKE_OS=Darwin FAKE_ARCH=arm64
  rtk_release v1.1.0 darwin arm64
  run_install --yes --only rtk
  grep -q 'rtk-aarch64-apple-darwin.tar.gz$' "$CALLS"
  export FAKE_ARCH=x86_64
  rtk_release v1.1.0 darwin amd64
  run_install --yes --only rtk
  grep -q 'rtk-x86_64-apple-darwin.tar.gz$' "$CALLS"
}

@test "rtk: existing settings.json hooks survive rtk init -g" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  jq -e '[..|.command? // empty] | index("keep-me") and index("rtk hook claude")' "$HOME/.claude/settings.json"
}

@test "rtk: an init that drops a hook is undone and fails the step" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  RTK_STUB_CLOBBER=1 run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [[ $output == *"keep-me"* ]]
  jq -e '[..|.command? // empty] == ["keep-me"]' "$HOME/.claude/settings.json"
}

@test "rtk: an init that fails after editing settings.json is undone and fails the step" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  RTK_STUB_FAIL=1 run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [[ $output == *"rtk init -g failed"* ]]
  cmp "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  [ ! -e "$HOME/.claude/settings.json.crewkit-before" ]
}

@test "rtk: only the first line of --version counts" {
  rtk_release v1.1.0 linux amd64 "rtk 1.1.0
more text"
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
}

@test "rtk: a version that only starts like the pin (1.1.00) is refused" {
  rtk_release v1.1.0 linux amd64 "rtk 1.1.00"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.local/bin/rtk" ]
}

@test "rtk: a re-run with the hook and @RTK.md present doesn't call rtk init" {
  rtk_release v1.1.0
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  : > "$CALLS"
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  none -qx 'rtk init -g --auto-patch' "$CALLS"
}

@test "rtk: the hook present but no @RTK.md line still runs rtk init" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}' > "$HOME/.claude/settings.json"
  run_install --yes --only rtk
  [ "$status" -eq 0 ]
  grep -qx 'rtk init -g --auto-patch' "$CALLS"
}

@test "rtk: settings.json that isn't JSON is refused before rtk init touches it" {
  rtk_release v1.1.0
  mkdir -p "$HOME/.claude"
  echo 'not json' > "$HOME/.claude/settings.json"
  run_install --yes --only rtk
  [ "$status" -eq 1 ]
  none -qx 'rtk init -g --auto-patch' "$CALLS"
  [ "$(cat "$HOME/.claude/settings.json")" = 'not json' ]
}

@test "rtk: without jq the step fails naming it" {
  rtk_release v1.1.0
  local d="$BATS_TEST_TMPDIR/nojq" t
  mkdir -p "$d"
  for t in bash env tar gzip sed grep awk cut mktemp install mv cp rm cmp mkdir chmod cat dirname sha256sum shasum uname curl tr head; do
    ln -s "$(command -v "$t")" "$d/$t" 2>/dev/null || true
  done
  PATH="$d" run_install --yes --only rtk
  [ "$status" -eq 1 ]
  [[ $output == *"jq"* ]]
  [ ! -e "$HOME/.local/bin/rtk" ]
}

@test "--only herdr, rtk and cli are accepted; --only nope is a usage error" {
  run_install --only herdr
  [ "$status" -eq 0 ]
  run_install --only rtk
  [ "$status" -eq 0 ]
  run_install --only cli
  [ "$status" -eq 0 ]
  run_install --only nope
  [ "$status" -eq 64 ]
}

@test "the default steps run in order: bitc memsync herdr rtk plugins cli" {
  run_install
  [ "$status" -eq 0 ]
  local order
  order=$(grep -E '^(bitc|memsync|herdr|rtk|plugins|cli):' <<<"$output" | tr -d '\n')
  [ "$order" = 'bitc:memsync:herdr:rtk:plugins:cli:' ]
}

@test "dry run names the herdr and rtk assets and downloads nothing" {
  herdr_release v0.9.5
  rtk_release v1.1.0
  run_install
  [ "$status" -eq 0 ]
  [[ $output == *herdr-v0.9.5-x86_64-unknown-linux-musl.tar.gz* && $output == *herdr-v0.9.5-x86_64-unknown-linux-musl.tar.gz.sha256* && $output == *rtk-x86_64-unknown-linux-musl.tar.gz* ]]
  none -q '^curl' "$CALLS"
  none -q '^herdr' "$CALLS"
  [ ! -e "$HOME/.local/bin/herdr" ]
}

@test "herdr and rtk: an unpinned tool is skipped" {
  run_install --yes --only herdr --only rtk
  [ "$status" -eq 0 ]
  [[ $output == *"pins/herdr.env has no release pinned"* && $output == *"pins/rtk.env has no release pinned"* ]]
  none -q '^curl' "$CALLS"
}

# ---- cli -----------------------------------------------------------------------------------------

@test "cli: --yes links ~/.local/bin/crewkit to the tree's bin/crewkit" {
  run_install --yes --only cli
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/crewkit" ]
  [ "$(readlink "$HOME/.local/bin/crewkit")" = "$TREE/bin/crewkit" ]
}

@test "cli: a second run says the link is already current and changes nothing" {
  run_install --yes --only cli
  run_install --yes --only cli
  [ "$status" -eq 0 ]
  [[ $output == *"already"* ]]
  [ "$(readlink "$HOME/.local/bin/crewkit")" = "$TREE/bin/crewkit" ]
}

@test "cli: a dry run prints the link and makes none" {
  run_install --only cli
  [ "$status" -eq 0 ]
  [[ $output == *"ln -s $TREE/bin/crewkit $HOME/.local/bin/crewkit"* ]]
  [ -z "$(ls -A "$HOME")" ]
}

@test "cli: an existing crewkit that isn't our link is refused" {
  mkdir -p "$HOME/.local/bin"
  echo "my own script" > "$HOME/.local/bin/crewkit"
  run_install --yes --only cli
  [ "$status" -eq 1 ]
  [ ! -L "$HOME/.local/bin/crewkit" ]
  [ "$(cat "$HOME/.local/bin/crewkit")" = "my own script" ]
  [[ $output == *"crewkit"*"not"* ]]
}

@test "cli: a link to some other file, or a dangling one, is refused and left alone" {
  mkdir -p "$HOME/.local/bin"
  ln -s /somewhere/else "$HOME/.local/bin/crewkit"
  run_install --yes --only cli
  [ "$status" -eq 1 ]
  [ "$(readlink "$HOME/.local/bin/crewkit")" = /somewhere/else ]
  run_install --only cli
  [ "$status" -eq 1 ]
}

@test "cli: a directory named crewkit is refused" {
  mkdir -p "$HOME/.local/bin/crewkit"
  run_install --yes --only cli
  [ "$status" -eq 1 ]
  [ -d "$HOME/.local/bin/crewkit" ]
  [ ! -L "$HOME/.local/bin/crewkit" ]
}

@test "cli: is the last default step" {
  run_install
  [ "$status" -eq 0 ]
  [[ $output == *$'\ncli:'* ]]
  [[ ${output##*$'\n'plugins:} == *$'\ncli:'* ]]
}

# --- No bootstrap flags: the memsync step pauses (exit 3) and the other steps still run (#63) ---

all_releases() {
  bitc_release v0.2.0
  memsync_release v0.1.0
  herdr_release v0.9.5
  rtk_release v1.1.0
}

@test "no bootstrap flags: --yes installs the other steps, never runs bootstrap, and exits 3 with the note" {
  all_releases
  run_install --yes
  [ "$status" -eq 3 ]
  [ -x "$HOME/.local/bin/bitc" ]
  [ -x "$HOME/.local/bin/herdr" ]
  [ -x "$HOME/.local/bin/rtk" ]
  grep -qx 'claude plugin install crew-nodes@crewkit' "$CALLS"
  grep -qx 'rtk init -g --auto-patch' "$CALLS"
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/SHA256SUMS' "$CALLS"
  none -q '^bootstrap' "$CALLS"
  [[ $output == *"paused: claude-memsync's bootstrap needs flags"* ]]
  [[ $output == *"finish with: $TREE/install.sh --yes --only memsync -- <bootstrap flags>"* ]]
  [[ $output == *"install.sh: paused at the memsync step"* ]]
}

@test "no bootstrap flags: the memsync release is still checked before the pause" {
  memsync_release v0.1.0 0 "claude-memsync v9.9.9"
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output != *"paused"* ]]
}

@test "no bootstrap flags: the dry run shows the pause in the memsync plan and exits 0" {
  all_releases
  run_install
  [ "$status" -eq 0 ]
  [[ $output == *"would pause: claude-memsync's bootstrap needs flags"* ]]
  [[ $output == *"finish with: $TREE/install.sh --yes --only memsync -- <bootstrap flags>"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "bootstrap flags given: the dry run shows no pause and --yes passes them to bootstrap" {
  all_releases
  run_install -- --host h1
  [ "$status" -eq 0 ]
  [[ $output != *"paused"* ]]
  run_install --yes -- --host h1
  [ "$status" -eq 0 ]
  [[ $output != *"paused"* ]]
  grep -Eqx 'bootstrap --prebuilt-dir [^ ]+/claude-utils-v0.1.0-linux-amd64 --host h1' "$CALLS"
  [ -x "$HOME/.local/bin/rtk" ]
}

@test "no bootstrap flags: --only memsync downloads, verifies, pauses and exits 3" {
  memsync_release v0.1.0
  run_install --yes --only memsync
  [ "$status" -eq 3 ]
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/claude-utils-v0.1.0-linux-amd64.tar.gz' "$CALLS"
  none -q '^bootstrap' "$CALLS"
  [[ $output == *"paused at the memsync step"* ]]
}

@test "no bootstrap flags: a real failure in a later step still exits 1, not 3" {
  all_releases
  sed -i "s/^HERDR_SHA256_linux_amd64=.*/HERDR_SHA256_linux_amd64=$(hex64 0)/" "$TREE/pins/herdr.env"
  run_install --yes
  [ "$status" -eq 1 ]
  [[ $output == *"sha256 mismatch"* ]]
}

@test "no bootstrap flags: a paused run, then the finishing command, completes, and a re-run leaves the other steps as they were" {
  all_releases
  run_install --yes
  [ "$status" -eq 3 ]
  local before
  before=$(cd "$HOME" && find . -type f -not -name '*.bak*' -exec sha256sum {} + | sort)
  run_install --yes --only memsync -- --host h1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^bootstrap' "$CALLS")" -eq 1 ]
  grep -Eqx 'bootstrap --prebuilt-dir [^ ]+/claude-utils-v0.1.0-linux-amd64 --host h1' "$CALLS"
  # the plain command the note prints also works after a pause, and changes nothing else
  run_install --yes -- --host h1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^bootstrap' "$CALLS")" -eq 2 ]
  [ "$(grep -c '^rtk init' "$CALLS")" -eq 1 ]
  [ "$before" = "$(cd "$HOME" && find . -type f -not -name '*.bak*' -exec sha256sum {} + | sort)" ]
  [ -z "$(ls "$HOME"/.claude/rules/*.bak* 2>/dev/null)" ]
}

@test "no bootstrap flags: the finishing command names the path the installer was run by, from any directory" {
  memsync_release v0.1.0
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run "$TREE/install.sh" --yes --only memsync
  [ "$status" -eq 3 ]
  [[ $output == *"finish with: $TREE/install.sh --yes --only memsync -- <bootstrap flags>"* ]]
  [[ $output != *"finish with: ./install.sh"* ]]
}

@test "no bootstrap flags: the finishing command quotes a path with spaces" {
  memsync_release v0.1.0
  mkdir -p "$BATS_TEST_TMPDIR/my clone"
  cp -a "$TREE/." "$BATS_TEST_TMPDIR/my clone/"
  run "$BATS_TEST_TMPDIR/my clone/install.sh" --yes --only memsync
  [ "$status" -eq 3 ]
  [[ $output == *"finish with: $BATS_TEST_TMPDIR/my\\ clone/install.sh --yes --only memsync -- <bootstrap flags>"* ]]
}

@test "no bootstrap flags: run as 'bash install.sh', the finishing command is runnable as printed" {
  memsync_release v0.1.0
  cd "$TREE"
  run bash install.sh --yes --only memsync
  [ "$status" -eq 3 ]
  [[ $output == *"finish with: ./install.sh --yes --only memsync -- <bootstrap flags>"* ]]
}
