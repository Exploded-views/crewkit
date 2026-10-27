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
  none -q '^curl' "$CALLS"
}

@test "memsync: a matching sha hands the unpacked release to its bootstrap as --prebuilt-dir" {
  memsync_release v0.1.0
  run_install --yes --only memsync
  [ "$status" -eq 0 ]
  grep -qx 'prebuilt ok' "$CALLS"
}

@test "memsync: downloads the pinned asset and SHA256SUMS from the pinned URL" {
  memsync_release v0.1.0
  run_install --yes --only memsync
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/claude-utils-v0.1.0-linux-amd64.tar.gz' "$CALLS"
  grep -qx 'curl https://example.test/OWNER/claude-utils/releases/download/v0.1.0/SHA256SUMS' "$CALLS"
}

@test "memsync: an archive the release's SHA256SUMS disagrees with is refused" {
  memsync_release v0.1.0
  printf '%s  claude-utils-v0.1.0-linux-amd64.tar.gz\n' "$(hex64 2)" > "$FIXTURES/SHA256SUMS"
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"SHA256SUMS"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: an archive missing from SHA256SUMS is refused" {
  memsync_release v0.1.0
  : > "$FIXTURES/SHA256SUMS"
  run_install --yes --only memsync
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
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"sha256 mismatch"* ]]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: bootstrap exit 3 (paused, needs a human) passes through and stops" {
  memsync_release v0.1.0 3
  run_install --yes --only memsync --only plugins
  [ "$status" -eq 3 ]
  none -q '^claude' "$CALLS"
}

@test "memsync: a bootstrap failure fails the install" {
  memsync_release v0.1.0 1
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
}

@test "a pinned tag with no hash for this target is refused" {
  memsync_release v0.1.0
  export FAKE_ARCH=aarch64
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"no sha256 pinned for linux/arm64"* ]]
  none -q '^curl' "$CALLS"
}

@test "a malformed hash is refused" {
  memsync_release v0.1.0
  sed -i 's/^MEMSYNC_SHA256_linux_amd64=.*/MEMSYNC_SHA256_linux_amd64=abc123/' "$TREE/pins/memsync.env"
  run_install --yes --only memsync
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
  run_install --yes --only memsync
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
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe path"* ]]
}

@test "an archive containing a link is refused" {
  memsync_release v0.1.0
  local stage="$BATS_TEST_TMPDIR/stage-memsync"
  ln -s /etc/passwd "$stage/claude-utils-v0.1.0-linux-amd64/claude-memmerge.link"
  tar -czf "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz" -C "$stage" .
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync
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
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  none -q '^bootstrap' "$CALLS"
}

@test "memsync: a release missing a binary is refused before its bootstrap runs" {
  memsync_release v0.1.0
  local stage="$BATS_TEST_TMPDIR/stage-memsync"
  rm "$stage/claude-utils-v0.1.0-linux-amd64/claude-memmerge"
  tar -czf "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz" -C "$stage" claude-utils-v0.1.0-linux-amd64
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync
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

@test "an unsupported OS is refused" {
  export FAKE_OS=FreeBSD
  run_install
  [ "$status" -eq 1 ]
}

@test "plugins: --yes adds the marketplace, installs both plugins and the rules fragment" {
  run_install --yes --only plugins
  [ "$status" -eq 0 ]
  grep -qx "claude plugin marketplace add $TREE" "$CALLS"
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

@test "plugins: without claude on PATH, a dry run warns and --yes fails" {
  rm "$BATS_TEST_TMPDIR/stubs/claude"
  PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin"
  if command -v claude >/dev/null; then skip "claude is installed system-wide"; fi
  run_install --only plugins
  [ "$status" -eq 0 ]
  [[ $output == *"not on PATH"* ]]
  run_install --yes --only plugins
  [ "$status" -eq 1 ]
}

@test "a tag that isn't vMAJOR.MINOR.PATCH is refused before any download" {
  local bad
  for bad in v1.2 .. v1.2.3/ 'v1.2.3;x' v1.2.3- 'v1.2.3-/x' 'v1.2.3-a b' 'v1.2.3-$x' 'v1.2.3+meta'; do
    memsync_release v0.1.0
    sed -i "s|^MEMSYNC_TAG=.*|MEMSYNC_TAG=$bad|" "$TREE/pins/memsync.env"
    : > "$CALLS"
    run_install --yes --only memsync
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
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"unsafe path"* ]]
}

@test "an archive with a FIFO or other special file is refused" {
  memsync_release v0.1.0
  python3 -c 'import sys,tarfile
t=tarfile.open(sys.argv[1],"w:gz"); i=tarfile.TarInfo("claude-utils-v0.1.0-linux-amd64/pipe"); i.type=tarfile.FIFOTYPE; t.addfile(i); t.close()' \
    "$FIXTURES/claude-utils-v0.1.0-linux-amd64.tar.gz"
  republish claude-utils-v0.1.0-linux-amd64.tar.gz
  run_install --yes --only memsync
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
  tmp="$mine" run_install --yes --only memsync
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
  export CLAUDE_PLUGINS_JSON='[{"id": "agent-practice@crewkit"}, {"id": "memory-notices@crewkit"}]'
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
}

@test "memsync: a pre-release tag (vX.Y.Z-suffix) is installed" {
  memsync_release v0.3.0-ev.1
  run_install --yes --only memsync
  [ "$status" -eq 0 ]
  grep -qx 'prebuilt ok' "$CALLS"
}

@test "memsync: the unpacked claude-memsync must report the pinned tag, or its bootstrap never runs" {
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.2"
  run_install --yes --only memsync
  [ "$status" -eq 1 ]
  [[ $output == *"claude-memsync version"* ]]
  none -q '^bootstrap' "$CALLS"
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.1-dirty"
  run_install --yes --only memsync
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
    LC_ALL=en_US.UTF-8 run_install --yes --only memsync
    [ "$status" -eq 1 ] || { echo "accepted tag $bad"; return 1; }
    none -q '^curl' "$CALLS"
  done
  memsync_release v0.1.0
  sed -i "s|^MEMSYNC_URL=.*|MEMSYNC_URL=https://exämple.test/o/r/releases/download|" "$TREE/pins/memsync.env"
  LC_ALL=en_US.UTF-8 run_install --yes --only memsync
  [ "$status" -eq 1 ]
}

@test "memsync: only the version's first line counts, so extra lines after it don't fail the check" {
  memsync_release v0.3.0-ev.1 0 "claude-memsync v0.3.0-ev.1
built by the release workflow"
  run_install --yes --only memsync
  [ "$status" -eq 0 ]
}
