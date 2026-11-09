# Shared setup for the install.sh tests.
#
# Each test gets a private copy of the installer tree, an empty $HOME, and a stub bin
# directory first on PATH. The stubs record their calls in $CALLS:
#   curl    copies "$FIXTURES/<last URL path segment>" to its -o target (no network);
#           refuses to run without --proto =https
#   claude  records its arguments; answers `plugin list --json` and
#           `plugin marketplace list --json` from $CLAUDE_PLUGINS_JSON / $CLAUDE_MARKETS_JSON
#   agent CLIs (claude by default; agent_cli adds more) record their arguments, so which agents
#           are "on PATH" is up to the test
#   uname   reports $FAKE_OS / $FAKE_ARCH

setup_tree() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  TREE="$BATS_TEST_TMPDIR/tree"
  export HOME="$BATS_TEST_TMPDIR/home"
  export FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export FAKE_OS=Linux FAKE_ARCH=x86_64
  mkdir -p "$TREE/pins" "$TREE/plugins/agent-practice/rules" "$HOME" "$FIXTURES"
  : > "$CALLS"
  # A symlink, so coverage maps to the real file. INSTALL_SH lets tools/mutate.sh point it
  # at a mutated copy.
  ln -s "${INSTALL_SH:-$REPO/install.sh}" "$TREE/install.sh"
  mkdir -p "$TREE/bin"
  ln -s "$REPO/bin/crewkit" "$TREE/bin/crewkit"
  cp "$REPO/plugins/agent-practice/rules/CLAUDE-fragment.md" "$TREE/plugins/agent-practice/rules/"
  unpinned bitc BITC
  unpinned gitleaks GITLEAKS
  unpinned memsync MEMSYNC
  unpinned herdr HERDR
  unpinned rtk RTK

  local stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stubs"
  cat > "$stubs/curl" <<'EOF'
#!/usr/bin/env bash
out='' url='' https_only=0
while (($#)); do
  case $1 in
    -o) out=$2; shift ;;
    --proto) [[ $2 == '=https' ]] && https_only=1; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
((https_only)) || { echo "curl stub: called without --proto =https" >&2; exit 99; }
echo "curl $url" >> "$CALLS"
src="$FIXTURES/${url##*/}"
[[ -f $src ]] || { echo "curl: (22) 404 $url" >&2; exit 22; }
cp "$src" "$out"
EOF
  # claude: records its arguments; answers the two read-only list commands from
  # $CLAUDE_PLUGINS_JSON and $CLAUDE_MARKETS_JSON (default: nothing installed).
  cat > "$stubs/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$CALLS"
case "$*" in
  "plugin list --json") printf '%s\n' "${CLAUDE_PLUGINS_JSON:-[]}" ;;
  "plugin marketplace list --json") printf '%s\n' "${CLAUDE_MARKETS_JSON:-[]}" ;;
esac
EOF
  cat > "$stubs/uname" <<'EOF'
#!/usr/bin/env bash
case $1 in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; *) echo "$FAKE_OS" ;; esac
EOF
  chmod +x "$stubs"/*
  # A host with real agent CLIs would change which integrations install.sh runs: hide them.
  local clean
  clean=$(path_without_agents "$PATH")
  export PATH="$stubs:$clean"
}

# path_without_agents PATH: PATH with the agent CLIs the installer looks for hidden. A
# directory that holds one is replaced by a mirror of symlinks to everything else in it.
path_without_agents() {
  local out='' d a e hit n=0 mirror
  local IFS=:
  for d in $1; do
    hit=0
    for a in claude codex opencode copilot cursor-agent droid qwen kimi pi; do
      [[ -e $d/$a ]] && hit=1
    done
    if ((hit)); then
      n=$((n + 1)); mirror="$BATS_TEST_TMPDIR/pathmirror/$n"; mkdir -p "$mirror"
      for e in "$d"/*; do
        case ${e##*/} in claude|codex|opencode|copilot|cursor-agent|droid|qwen|kimi|pi) continue ;; esac
        ln -s "$e" "$mirror/" 2>/dev/null || true
      done
      d=$mirror
    fi
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# cp_fails_on SUFFIX: put a cp on PATH that fails when its last argument ends with SUFFIX (a
# full or partial file name) and is the real cp otherwise.
cp_fails_on() {
  # shellcheck disable=SC2016  # ${!#} expands in the stub
  printf '#!/usr/bin/env bash\ncase ${!#} in *%s) echo "cp: simulated failure" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$1" "$(command -v cp)" > "$BATS_TEST_TMPDIR/stubs/cp"
  chmod +x "$BATS_TEST_TMPDIR/stubs/cp"
}

# agent_cli NAME: put a stub agent CLI NAME on PATH; it records "NAME args" in $CALLS.
agent_cli() {
  # shellcheck disable=SC2016  # expands in the stub
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$1" > "$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}

# unpinned TOOL PREFIX: write an unpinned pin file.
unpinned() {
  printf '%s_TAG=TODO\n' "$2" > "$TREE/pins/$1.env"
}

# none GREP-ARGS...: fail if grep matches. Use this, not `! grep`: bats ignores a negated
# command anywhere but a test's last line, so `! grep` mid-test asserts nothing.
none() {
  if grep "$@" >/dev/null; then
    echo "unexpected match: grep $*" >&2
    return 1
  fi
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# hex64 C: a well-formed sha256 that matches nothing: C repeated 64 times.
hex64() { printf "$1%.0s" {1..64}; }

# memsync_release TAG [BOOTSTRAP_EXIT] [VERSION_LINE]: build the claude-utils archive for
# linux/amd64 in $FIXTURES the way its release packs it (one top-level
# claude-utils-<tag>-<os>-<arch>/ dir), write SHA256SUMS, and pin it. The fake claude-memsync
# answers `version` with VERSION_LINE (default the real format, "claude-memsync <tag>").
# bootstrap.sh records its arguments, notes whether the --prebuilt-dir it was given holds both
# binaries, and exits BOOTSTRAP_EXIT.
memsync_release() {
  local tag=$1 rc=${2:-0} line=${3:-"claude-memsync $1"} top="claude-utils-$1-linux-amd64"
  local stage="$BATS_TEST_TMPDIR/stage-memsync/$top"
  mkdir -p "$stage/scripts"
  # shellcheck disable=SC2016  # $1 is the fake binary's own argument
  printf '#!/bin/sh\nif [ "$1" = version ]; then echo "%s"; exit 0; fi\necho memsync\n' "$line" > "$stage/claude-memsync"
  printf '#!/bin/sh\necho memmerge\n' > "$stage/claude-memmerge"
  # shellcheck disable=SC2016  # $* and $CALLS expand in the stub, not here
  printf '#!/bin/sh\necho "bootstrap $*" >> "$CALLS"\n[ "$1" = --prebuilt-dir ] && [ -x "$2/claude-memsync" ] && [ -x "$2/claude-memmerge" ] && echo "prebuilt ok" >> "$CALLS"\nexit %s\n' "$rc" > "$stage/scripts/bootstrap.sh"
  chmod +x "$stage/claude-memsync" "$stage/claude-memmerge"
  tar -czf "$FIXTURES/$top.tar.gz" -C "$BATS_TEST_TMPDIR/stage-memsync" "$top"
  pin memsync MEMSYNC "$tag" "$(sha_of "$FIXTURES/$top.tar.gz")" "https://example.test/OWNER/claude-utils/releases/download"
  sums memsync
}

# sums memsync|bitc|gitleaks-VERSION: write the release's checksum file for every archive in
# $FIXTURES.
sums() {
  local name=SHA256SUMS
  [[ $1 == bitc || $1 == rtk ]] && name=checksums.txt
  [[ $1 == gitleaks-* ]] && name=gitleaks_${1#gitleaks-}_checksums.txt
  (cd "$FIXTURES" && sha256sum -- *.tar.gz > "$name")
}

# republish ASSET: after a test rewrote ASSET, re-pin it and rewrite the checksum file, so
# the test reaches the check it is about.
republish() {
  local prefix=MEMSYNC tool=memsync
  [[ $1 == bitc_* ]] && prefix=BITC tool=bitc
  sed -i "s/^${prefix}_SHA256_linux_amd64=.*/${prefix}_SHA256_linux_amd64=$(sha_of "$FIXTURES/$1")/" "$TREE/pins/$tool.env"
  sums "$tool"
}

# gitleaks_release TAG [OS ARCH] [VERSION_LINE]: build gitleaks_<ver>_<os>_<garch>.tar.gz
# (gitleaks names amd64 "x64"; default linux amd64) in $FIXTURES with its
# gitleaks_<ver>_checksums.txt, and pin it for that target. The fake answers `gitleaks version`
# with VERSION_LINE (default the version without the v).
gitleaks_release() {
  local tag=$1 os=${2:-linux} arch=${3:-amd64} line=${4:-${1#v}} stage="$BATS_TEST_TMPDIR/stage-gitleaks" garch
  garch=$arch; [[ $arch == amd64 ]] && garch=x64
  mkdir -p "$stage"
  # shellcheck disable=SC2016  # $1 is the fake's own argument
  printf '#!/bin/sh\nif [ "$1" = version ]; then echo "%s"; exit 0; fi\nexit 0\n' "$line" > "$stage/gitleaks"
  chmod +x "$stage/gitleaks"
  local asset="gitleaks_${tag#v}_${os}_${garch}.tar.gz"
  tar -czf "$FIXTURES/$asset" -C "$stage" gitleaks
  printf '%s\n' "GITLEAKS_URL=https://example.test/gitleaks/gitleaks/releases/download" "GITLEAKS_TAG=$tag" \
    "GITLEAKS_SHA256_${os}_${arch}=$(sha_of "$FIXTURES/$asset")" > "$TREE/pins/gitleaks.env"
  sums "gitleaks-${tag#v}"
}

# bitc_release TAG [OS ARCH] [VERSION_JSON]: build bitc_<ver>_<os>_<arch>.tar.gz (default
# linux amd64) in $FIXTURES, write checksums.txt, and pin it for that target. The fake binary
# answers `bitc version --json` with VERSION_JSON (default: bitc 0.1.0's real format for TAG).
# Plain `bitc version` is for humans and may change, so the fake's says nothing checkable.
bitc_release() {
  local tag=$1 os=${2:-linux} arch=${3:-amd64} stage="$BATS_TEST_TMPDIR/stage-bitc"
  local json=${4:-"{\"commit\":\"225a43a\",\"config_schema\":1,\"release\":true,\"state_schema\":1,\"version\":\"${1#v}\"}"}
  mkdir -p "$stage"
  # shellcheck disable=SC2016  # $1 and $2 are the fake bitc's own arguments, expanded when it runs
  printf '#!/bin/sh\nif [ "$1 $2" = "version --json" ]; then echo '"'"'%s'"'"'; exit 0; fi\nif [ "$1" = version ]; then echo "bitc, human wording"; exit 0; fi\necho bitc %s\n' "$json" "$tag" > "$stage/bitc"
  chmod +x "$stage/bitc"
  local asset="bitc_${tag#v}_${os}_${arch}.tar.gz"
  tar -czf "$FIXTURES/$asset" -C "$stage" bitc
  cat > "$TREE/pins/bitc.env" <<EOF
BITC_URL=https://example.test/OWNER/bitc/releases/download
BITC_TAG=$tag
BITC_SHA256_${os}_${arch}=$(sha_of "$FIXTURES/$asset")
EOF
  sums bitc
}

# pin TOOL PREFIX TAG SHA URL: pin linux_amd64 only; other targets stay blank.
pin() {
  cat > "$TREE/pins/$1.env" <<EOF
$2_URL=$5
$2_TAG=$3
$2_SHA256_linux_amd64=$4
$2_SHA256_linux_arm64=
EOF
}

# herdr_triple OS ARCH: the target triple in the fork's asset names.
herdr_triple() {
  case $1-$2 in
    linux-amd64) echo x86_64-unknown-linux-musl ;;
    linux-arm64) echo aarch64-unknown-linux-musl ;;
    darwin-amd64) echo x86_64-apple-darwin ;;
    darwin-arm64) echo aarch64-apple-darwin ;;
  esac
}

# herdr_release TAG [OS ARCH] [VERSION_LINE] [PIN_VERSION]: build the fork's release assets in
# $FIXTURES for OS/ARCH (default linux amd64): herdr-<tag>-<triple>.tar.gz, holding one plain
# file `herdr`, and herdr-<tag>-<triple>.tar.gz.sha256, one shasum-format line. Pin it, with
# HERDR_VERSION=PIN_VERSION when that is given. The fake answers --version with VERSION_LINE
# (default "herdr <PIN_VERSION>" when given, else "herdr <tag without v>") and records every
# other call (--version included) in $CALLS. HERDR_STUB_FAIL=missing makes those calls fail the way a real
# `integration install` does when the agent was never run (its text, exit 1);
# HERDR_STUB_FAIL=other fails with some other error (exit 7). HERDR_STUB_CLOBBER=1 makes
# `integration install claude` overwrite ~/.claude/settings.json with an empty object, dropping
# every hook there.
herdr_release() {
  local tag=$1 os=${2:-linux} arch=${3:-amd64} pinver=${5:-} line stage="$BATS_TEST_TMPDIR/stage-herdr"
  line=${4:-"herdr ${pinver:-${1#v}}"}
  local asset
  asset="herdr-$tag-$(herdr_triple "$os" "$arch").tar.gz"
  mkdir -p "$stage"
  # shellcheck disable=SC2016  # $1 and $CALLS expand when the fake runs
  printf '#!/bin/sh\necho "herdr $*" >> "$CALLS"\nif [ "$1" = --version ]; then echo "%s"; exit 0; fi\ncase "$HERDR_STUB_FAIL" in vague) echo "directory not found"; exit 1 ;; missing) echo "$3 directory not found at $HOME/.$3. install $3 first"; exit 1 ;; other) echo "boom"; exit 7 ;; esac\n[ -z "$HERDR_STUB_CLOBBER" ] || [ "$3" != claude ] || { mkdir -p "$HOME/.claude"; echo "{}" > "$HOME/.claude/settings.json"; }\n' "$line" > "$stage/herdr"
  chmod +x "$stage/herdr"
  tar -czf "$FIXTURES/$asset" -C "$stage" herdr
  herdr_repin "$tag" "$os" "$arch" "$pinver"
}

# spy_tar: put a tar on PATH that records "tar <args>" in $CALLS and then runs the real one, so a
# test can show that nothing was unpacked.
spy_tar() {
  # shellcheck disable=SC2016  # $* and $CALLS expand when the spy runs
  printf '#!/usr/bin/env bash\necho "tar $*" >> "$CALLS"\nexec %s "$@"\n' "$(command -v tar)" > "$BATS_TEST_TMPDIR/stubs/tar"
  chmod +x "$BATS_TEST_TMPDIR/stubs/tar"
}

# herdr_repin TAG OS ARCH [PIN_VERSION]: after a test rewrote the tarball, pin its hash and
# rewrite its .sha256 file to match, so the test reaches the check it is about.
herdr_repin() {
  local asset sha
  asset="herdr-$1-$(herdr_triple "$2" "$3").tar.gz"
  sha=$(sha_of "$FIXTURES/$asset")
  {
    printf '%s\n' "HERDR_URL=https://example.test/OWNER/herdr/releases/download" "HERDR_TAG=$1" "HERDR_SHA256_${2}_${3}=$sha"
    [[ -z ${4:-} ]] || printf 'HERDR_VERSION=%s\n' "$4"
  } > "$TREE/pins/herdr.env"
  printf '%s  %s\n' "$sha" "$asset" > "$FIXTURES/$asset.sha256"
}

# rtk_release TAG [OS ARCH] [VERSION_LINE]: build rtk-<triple>.tar.gz (default linux amd64)
# in $FIXTURES, write checksums.txt, and pin it. The fake answers --version with VERSION_LINE
# (default the real format, "rtk <version>"). Its `init -g --auto-patch` does what the real
# one does: add a PreToolUse command hook "rtk hook claude" to ~/.claude/settings.json (keeping
# the others) and a line "@RTK.md" to ~/.claude/CLAUDE.md. RTK_STUB_CLOBBER=1 makes it
# overwrite settings.json with only its own hook, the failure the installer must catch.
# RTK_STUB_FAIL=1 makes init edit settings.json (add its hook) and then exit 1.
rtk_release() {
  local tag=$1 os=${2:-linux} arch=${3:-amd64} line=${4:-"rtk ${1#v}"} triple stage="$BATS_TEST_TMPDIR/stage-rtk"
  case $os-$arch in
    linux-amd64) triple=x86_64-unknown-linux-musl ;;
    linux-arm64) triple=aarch64-unknown-linux-gnu ;;
    darwin-amd64) triple=x86_64-apple-darwin ;;
    darwin-arm64) triple=aarch64-apple-darwin ;;
  esac
  mkdir -p "$stage"
  cat > "$stage/rtk" <<EOF
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo "$line"; exit 0; fi
echo "rtk \$*" >> "\$CALLS"
[ "\$1 \$2 \$3" = "init -g --auto-patch" ] || exit 0
mkdir -p "\$HOME/.claude"
s="\$HOME/.claude/settings.json"
hook='{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}'
if [ -n "\${RTK_STUB_CLOBBER:-}" ] || [ ! -f "\$s" ]; then
  jq -n --argjson h "\$hook" '{hooks:{PreToolUse:[\$h]}}' > "\$s"
else
  jq --argjson h "\$hook" '.hooks.PreToolUse += [\$h]' "\$s" > "\$s.new" && mv "\$s.new" "\$s"
fi
grep -qx '@RTK.md' "\$HOME/.claude/CLAUDE.md" 2>/dev/null || echo '@RTK.md' >> "\$HOME/.claude/CLAUDE.md"
[ -z "\${RTK_STUB_FAIL:-}" ] || exit 1
EOF
  chmod +x "$stage/rtk"
  local asset="rtk-$triple.tar.gz"
  tar -czf "$FIXTURES/$asset" -C "$stage" rtk
  cat > "$TREE/pins/rtk.env" <<EOF
RTK_URL=https://example.test/OWNER/rtk/releases/download
RTK_TAG=$tag
RTK_SHA256_${os}_${arch}=$(sha_of "$FIXTURES/$asset")
EOF
  sums rtk
}
