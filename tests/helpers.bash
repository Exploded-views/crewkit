# Shared setup for the install.sh tests.
#
# Each test gets a private copy of the installer tree, an empty $HOME, and a stub bin
# directory first on PATH. The stubs record their calls in $CALLS:
#   curl    copies "$FIXTURES/<last URL path segment>" to its -o target (no network);
#           refuses to run without --proto =https
#   claude  records its arguments; answers `plugin list --json` and
#           `plugin marketplace list --json` from $CLAUDE_PLUGINS_JSON / $CLAUDE_MARKETS_JSON
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
  cp "$REPO/plugins/agent-practice/rules/CLAUDE-fragment.md" "$TREE/plugins/agent-practice/rules/"
  unpinned bitc BITC
  unpinned memsync MEMSYNC

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
  export PATH="$stubs:$PATH"
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

# sums memsync|bitc: write the release's checksum file for every archive in $FIXTURES.
sums() {
  local name=SHA256SUMS
  [[ $1 == bitc ]] && name=checksums.txt
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
