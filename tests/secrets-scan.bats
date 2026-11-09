#!/usr/bin/env bats
# tools/secrets-scan.sh: CI's gitleaks over every commit, with the build install.sh pinned and
# recorded. gitleaks is a stub that flags a GitHub token shape in `git log -p <its --log-opts>`
# (GL_RC forces its exit), and keeps a copy of the config and ignore file it was given.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  G="$HOME/.local/share/crewkit/gitleaks/gitleaks"
  mkdir -p "${G%/*}"
  cat > "$G" <<'STUB'
#!/usr/bin/env bash
echo "gitleaks $*" >> "$HOME/gl-calls"
opts=--all
while (($#)); do
  case $1 in
    --log-opts=*) opts=${1#--log-opts=} ;;
    --config) cp "$2" "$HOME/gl-config"; echo "$2" > "$HOME/gl-config-path"; shift ;;
    --gitleaks-ignore-path) cp "$2" "$HOME/gl-ignore"; shift ;;
  esac
  shift
done
[[ -n ${GL_RC:-} ]] && exit "$GL_RC"
# shellcheck disable=SC2086 # the options are words, as gitleaks splits them
git log -p $opts | grep -Eq 'ghp_[A-Za-z0-9]{36}' && { echo "Finding: REDACTED"; exit 1; }
exit 0
STUB
  chmod +x "$G"
  if command -v sha256sum >/dev/null; then sha256sum "$G" | cut -d' ' -f1 > "$G.sha256"; else shasum -a 256 "$G" | cut -d' ' -f1 > "$G.sha256"; fi
  T="$BATS_TEST_TMPDIR/t"; git init -q -b main "$T"; cd "$T"
  echo hi > a.txt; git add a.txt; git commit -qm one
}

@test "clean history: exit 0, and it says what it scanned" {
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 0 ]
  [[ $output == "secrets: clean (gitleaks over 1 commit(s), every ref)" ]]
  grep -q -- '--log-opts=--all' "$HOME/gl-calls"
}

@test "a secret anywhere in history fails, even after it was removed" {
  echo "t=ghp_$(printf 'q7Rk2Lm9Xw4Tz8Bn3Vc6Hj1Pd5Fs0Ga7Ye2U')" > s.txt; git add s.txt; git commit -qm leak
  git rm -q s.txt; git commit -qm gone
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"secrets: gitleaks found leaks"* ]]
}

@test "no gitleaks (not pinned yet): fails, never reads as clean" {
  rm "$G"
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"isn't installed"* ]]
  [[ $output != *clean* ]]
}

@test "a gitleaks that changed since install.sh verified it fails" {
  echo '# changed' >> "$G"
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"doesn't match"* ]]
  rm "$G.sha256"
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
}

@test "a gitleaks with no recorded sha256 fails, and says so (it is not left to the mismatch check)" {
  rm "$G.sha256"
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"no recorded sha256"* ]]
  [[ $output != *"doesn't match"* ]]
  [[ $output != *clean* ]]
}

@test "a gitleaks error (not a finding) fails, never reads as clean" {
  GL_RC=2 run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"gitleaks failed (exit 2)"* ]]
  [[ $output != *clean* ]]
}

@test "a shallow clone fails: the history it would scan isn't all there" {
  git clone -q --depth 1 "file://$T" "$BATS_TEST_TMPDIR/shallow"
  cd "$BATS_TEST_TMPDIR/shallow"
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"shallow"* ]]
}

# A token built at run time, so this file holds none.
token() { printf 'ghp_%s' "q7Rk2Lm9Xw4Tz8Bn3Vc6Hj1Pd5Fs0Ga7Ye2U"; }

@test "the config and ignore file come from the script, never the scanned tree" {
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 0 ]
  grep -qx 'useDefault = true' "$HOME/gl-config"
  run grep -qi allowlist "$HOME/gl-config"
  [ "$status" -eq 1 ]
  [ -e "$HOME/gl-ignore" ]
  [ ! -s "$HOME/gl-ignore" ]
  [[ $(cat "$HOME/gl-config-path") != "$T"/* ]]
  grep -q -- '--ignore-gitleaks-allow' "$HOME/gl-calls"
}

@test "a .gitleaks.toml or .gitleaksignore in the tree fails: a change can't allowlist itself" {
  printf '[allowlist]\npaths = [".*"]\n' > .gitleaks.toml; git add .gitleaks.toml; git commit -qm cfg
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *".gitleaks.toml"* ]]
  [[ $output != *clean* ]]
  git rm -q .gitleaks.toml; git commit -qm gone
  echo 'abc:s.txt:generic-api-key:1' > .gitleaksignore
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *".gitleaksignore"* ]]
  rm .gitleaksignore
  mkdir sub; touch sub/.gitleaks.toml; git add sub; git commit -qm sub
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
}

@test "diff attributes can't hide a secret: binary and textconv are read as text" {
  echo "s.txt -diff" > .gitattributes
  echo "t=$(token)" > s.txt; git add .gitattributes s.txt; git commit -qm hidden
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"secrets: gitleaks found leaks"* ]]
  echo "s.txt diff=hide" > .gitattributes; git add .gitattributes; git commit -qm textconv
  git config diff.hide.textconv 'sed -e s/ghp_/nope/'
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"secrets: gitleaks found leaks"* ]]
}

@test "a secret added only in a merge's own resolution fails (merges are scanned against each parent)" {
  git checkout -qb side; echo side > b.txt; git add b.txt; git commit -qm side
  git checkout -q main; echo main > c.txt; git add c.txt; git commit -qm main
  git merge -q --no-ff --no-commit side
  echo "t=$(token)" > s.txt; git add s.txt; git commit -qm merged
  run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"secrets: gitleaks found leaks"* ]]
}

@test "CI's runner (Linux x86_64): the real pin names the release tarball and its sha256, not TODO" {
  # The secrets job runs `./install.sh --yes --only gitleaks` on ubuntu-latest; this is its dry
  # run, with uname answering as that runner does. Nothing is downloaded.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ncase $1 in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  pin="$REPO/pins/gitleaks.env"
  url=$(sed -n 's/^GITLEAKS_URL=//p' "$pin")
  tag=$(sed -n 's/^GITLEAKS_TAG=//p' "$pin")
  sha=$(sed -n 's/^GITLEAKS_SHA256_linux_amd64=//p' "$pin")
  [[ $url == https://github.com/gitleaks/gitleaks/releases/download ]]
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $sha =~ ^[0-9a-f]{64}$ ]]
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REPO/install.sh" --only gitleaks
  [ "$status" -eq 0 ]
  [[ $output == *"$url/$tag/gitleaks_${tag#v}_linux_x64.tar.gz (sha256 $sha)"* ]]
  [[ $output != *skipped* ]]
}

@test "every GITLEAKS_* variable is stripped, not only the two config ones" {
  printf '#!/usr/bin/env bash\nenv | grep "^GITLEAKS_" > "$HOME/gl-env"\nexit 0\n' > "$G"
  if command -v sha256sum >/dev/null; then sha256sum "$G" | cut -d' ' -f1 > "$G.sha256"; else shasum -a 256 "$G" | cut -d' ' -f1 > "$G.sha256"; fi
  GITLEAKS_CONFIG=/x GITLEAKS_ENABLE_RULES=y GITLEAKS_REPORT_PATH=/z run "$REPO/tools/secrets-scan.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/gl-env" ]
}
