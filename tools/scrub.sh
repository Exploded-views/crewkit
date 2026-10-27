#!/usr/bin/env bash
# scrub.sh: refuse to commit secrets, personal data or private terms.
#
# Prints RULE NAMES, FILE NAMES and COUNTS only. It never prints the matched text, so
# running it (in a terminal, a hook, CI or an agent transcript) can't leak what it finds.
#
# Usage:
#   tools/scrub.sh                  # tracked + staged files, all rules + private denylist
#   tools/scrub.sh --all            # also untracked (not ignored) files
#   tools/scrub.sh --secrets-only   # secret rules only: no PII rules, no denylist (for CI)
#   tools/scrub.sh --require-denylist   # fail if the private denylist is missing
#   tools/scrub.sh --self-test      # plant a canary for every rule in a temp dir and check each fires
#   tools/scrub.sh --history        # every commit reachable from any ref: every version of every
#                                   # file, commit and tag messages, author/committer/tagger
#                                   # identities and ref names (run before a repo goes public)
#
# Private denylist: one case-insensitive extended regex per line (client and product names,
# people's names, internal hostnames and domains, account IDs). Blank lines and lines starting
# with # are ignored. Read from $SCRUB_DENYLIST, default ~/.config/crewkit/denylist.txt.
# Keep it OUT of the repo, mode 0600. Its contents are never printed.
#
# Exit 0 = clean, 1 = findings (or a required denylist is missing), 2 = usage.
set -euo pipefail

all=0 secrets_only=0 require_denylist=0 self_test=0 history=0
for a in "$@"; do
  case $a in
    --all) all=1 ;;
    --secrets-only) secrets_only=1 ;;
    --require-denylist) require_denylist=1 ;;
    --self-test) self_test=1 ;;
    --history) history=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "usage: tools/scrub.sh [--all|--history] [--secrets-only] [--require-denylist] [--self-test]" >&2; exit 2 ;;
  esac
done

# Secret rules: always on, including in CI.
declare -A secret_rules=(
  [private-key]='-----BEGIN [A-Z ]*PRIVATE KEY-----'
  [github-token]='\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}'
  [llm-api-key]='\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}'
  [slack-token]='\bxox[abprs]-[A-Za-z0-9-]{10,}|hooks\.slack\.com/services/'
  [aws-key]='\b(AKIA|ASIA)[0-9A-Z]{16}\b'
  [gcp-key]='\bAIza[0-9A-Za-z_-]{35}\b'
  [jwt]='\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
  [long-hex]='(^|[^@0-9A-Za-z])[0-9a-f]{32,}\b'          # 40-char SHAs after "@" (pinned actions) are allowed
  [uuid]='\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
  [secret-assign]='(api[_-]?key|token|secret|password|passwd|routing[_-]?key)["'"'"' ]*[:=] *["'"'"'][^"'"'"'<>{} ]{12,}'
  [url-credentials]='[a-z][a-z0-9+.-]*://[^/ :@]+:[^/ @]+@'
)
# Private-data rules: off with --secrets-only.
declare -A private_rules=(
  [email]='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  [phone]='\(?\b[2-9][0-9]{2}\)?[ .-][0-9]{3}[ .-][0-9]{4}\b'
  [ntfy-url]='https?://ntfy\.[A-Za-z0-9.-]+/[A-Za-z0-9_-]+'
  [artifact-url]='claude\.ai/(code/)?artifact/[A-Za-z0-9-]{6,}'
  [platform-host]='\.(workers\.dev|supabase\.co|fly\.dev|onrender\.com|vercel\.app)\b'
  [internal-host]='\b[a-z0-9-]+\.(local|lan|internal|home\.arpa|corp)([^.A-Za-z0-9_-]|$)'   # not foo.local.md
  [private-ip]='\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b'
  [home-path]='/(home|Users)/[a-z][a-z0-9_-]+/'
)
# Allowed shapes, applied to the matched text only. Lines marked scrub:pinned-hash, and the
# sha256 lines of pins/*.env, are also exempt from long-hex (see count_rule).
allow_email='^noreply@anthropic\.com$|^[^@]+@users\.noreply\.github\.com$|^noreply@github\.com$|@example\.(com|org|net)$'
allow_ntfy='ntfy\.example/'
allow_home='/(home|Users)/(user|you|me|runner)/'

denylist=${SCRUB_DENYLIST:-$HOME/.config/crewkit/denylist.txt}

count_rule() { # file rule-name regex [path for exemptions] -> prints count
  local f=$1 r=$2 re=$3 ctx=${4:-$1}
  # Deliberate pins are exempt from long-hex only: a line marked "scrub:pinned-hash" (a
  # release sha256 or an image digest in a script), and in pins/*.env exactly the
  # <TOOL>_SHA256_<os>_<arch>=<64 hex> lines install.sh reads.
  local pin_line='^[A-Z][A-Z0-9_]*_SHA256_(linux|darwin)_(amd64|arm64)=[0-9a-f]{64}$'
  # -a everywhere: a binary file is still read as text, so NUL bytes hide nothing.
  # On a line marked scrub:pinned-hash only a sha256-length value (64 hex) is exempt, so the
  # marker can't hide a token of another length.
  local marked='/scrub:pinned-hash/ s/[0-9a-f]{64}//g'
  { if [[ $r == long-hex && $ctx =~ (^|/)pins/[^/]+\.env$ ]]; then
      sed -E "$marked" -- "$f" | grep -aEv "$pin_line"
    elif [[ $r == long-hex && $ctx == tools/scrub-known-versions.txt ]]; then
      # The reviewed scrub.sh versions: a line that is exactly one blob SHA.
      sed -E "$marked" -- "$f" | grep -aEv '^[0-9a-f]{40}$'
    elif [[ $r == long-hex ]]; then sed -E "$marked" -- "$f"
    else cat -- "$f"
    fi; } 2>/dev/null \
    | grep -aEio -- "$re" \
    | { case $r in
          email) grep -Eiv "$allow_email" ;;
          ntfy-url) grep -Eiv "$allow_ntfy" ;;
          home-path) grep -Eiv "$allow_home" ;;
          *) cat ;;
        esac; } | wc -l || true
}

# scan_one FILE LABEL CTX SELF: run every rule on FILE and print hits as LABEL (never the
# matched text). CTX is the path the exemptions look at; SELF=1 marks this script's own
# reviewed text, whose pattern tables would match the secret and private rules (it is still
# checked against the denylist).
scan_one() {
  local f=$1 label=$2 ctx=$3 self=${4:-0} r n rc
  if (( ! self )); then
    for r in "${!secret_rules[@]}"; do
      n=$(count_rule "$f" "$r" "${secret_rules[$r]}" "$ctx")
      if (( n > 0 )); then printf '  %-18s %-60s %s\n' "$r" "$label" "$n"; total=$((total + n)); fi
    done
    if (( ! secrets_only )); then
      for r in "${!private_rules[@]}"; do
        n=$(count_rule "$f" "$r" "${private_rules[$r]}" "$ctx")
        if (( n > 0 )); then printf '  %-18s %-60s %s\n' "$r" "$label" "$n"; total=$((total + n)); fi
      done
    fi
  fi
  if (( ! secrets_only )) && [[ -r $denylist ]]; then
    # grep -c exits 1 for no match (and prints 0); anything else is a failed search, not a pass.
    n=$(grep -aEic -f <(grep -Ev '^\s*(#|$)' "$denylist") -- "$f" 2>/dev/null) || {
      rc=$?
      (( rc == 1 )) || { echo "scrub: the denylist search failed (exit $rc); nothing was checked"; exit 1; }
    }
    if (( ${n:-0} > 0 )); then printf '  %-18s %-60s %s\n' denylist "$label" "$n"; total=$((total + n)); fi
  fi
}

# check_denylist: a denylist that is present must hold at least one pattern, and every pattern
# must be a valid extended regex; otherwise the search would fail open. Prints line numbers only.
check_denylist() {
  local n=0 line bad=0 patterns=0
  (( secrets_only )) && return 0
  [[ -r $denylist ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    patterns=$((patterns + 1))
    if printf '' | grep -E -- "$line" >/dev/null 2>&1; [[ $? -eq 2 ]]; then
      echo "scrub: denylist line $n is not a valid extended regex"; bad=1
    fi
  done < "$denylist"
  if (( patterns == 0 )); then echo "scrub: the denylist has no patterns, so it would check nothing"; exit 1; fi
  if (( bad )); then exit 1; fi
}

# label_for PATH: PATH, unless the path itself matches the denylist or any rule (then it isn't
# printed, so a finding line can't show a term or a secret-shaped name).
label_for() {
  local r
  for r in "${secret_rules[@]}" "${private_rules[@]}"; do
    if printf '%s\n' "$1" | grep -aEiq -- "$r"; then printf '(a tracked file whose path matches a rule)'; return; fi
  done
  if (( ! secrets_only )) && [[ -r $denylist ]] \
    && printf '%s\n' "$1" | grep -aEiq -f <(grep -Ev '^\s*(#|$)' "$denylist"); then
    printf '(a tracked file whose path matches the denylist)'
  else
    printf '%s' "$1"
  fi
}

if (( self_test )); then
  # Canaries are assembled at runtime so no literal secret shape lives in this file.
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  x16=ABCDEFGHIJKLMNOP; h=0123456789abcdef
  declare -A canary=(
    [private-key]="-----BEGIN RSA PRIVATE"" KEY-----"
    [github-token]="gh""p_${x16}${x16}abcd"
    [llm-api-key]="s""k-ant-${x16}${x16}"
    [slack-token]="xo""xb-1234567890-abcdef"
    [aws-key]="AK""IA${x16}"
    [gcp-key]="AI""za${x16}${x16}abc"
    [jwt]="ey""J${x16}.${x16}.sig"
    [long-hex]="key ${h}${h}"
    [uuid]="${h:0:8}-${h:0:4}-${h:4:4}-${h:8:4}-${h:0:12}"
    [secret-assign]="api_key = \"${x16}xyz\""
    [url-credentials]="https://user"":hunter2long@host.example/x"
    [email]="someone@""corp-mail.test"
    [phone]="(555) 234-5678"
    [ntfy-url]="https://ntfy.""sh/private-topic"
    [artifact-url]="claude.ai/""artifact/abcdef123"
    [platform-host]="app.""fly.dev"
    [internal-host]="buildbox.""lan"
    [private-ip]="192.168.""1.20"
    [home-path]="/home/""alice/x"
  )
  fail=0
  ( cd "$tmp"
    for r in "${!canary[@]}"; do printf '%s\n' "${canary[$r]}" > "$r.txt"; done
    printf 'fine: noreply@anthropic.com uses: x@%s%s%s\n' "$h" "$h" "01234567" > allowed.txt
    printf 'sha=%s%s%s%s  # scrub:pinned-hash\n' "$h" "$h" "$h" "$h" >> allowed.txt )
  for r in "${!canary[@]}"; do
    if [[ -n ${secret_rules[$r]:-} ]]; then re=${secret_rules[$r]}; else re=${private_rules[$r]}; fi
    n=$(count_rule "$tmp/$r.txt" "$r" "$re")
    if (( n > 0 )); then echo "  ok    $r"; else echo "  MISS  $r"; fail=1; fi
  done
  n=0
  for r in "${!secret_rules[@]}"; do n=$((n + $(count_rule "$tmp/allowed.txt" "$r" "${secret_rules[$r]}"))); done
  n=$((n + $(count_rule "$tmp/allowed.txt" email "${private_rules[email]}")))
  if (( n == 0 )); then echo "  ok    allowlist"; else echo "  FALSE-POSITIVE allowlist ($n)"; fail=1; fi
  # pins/*.env: a pinned sha256 line is allowed; any other long hex in the same file is not.
  mkdir -p "$tmp/pins"
  printf 'TOOL_SHA256_linux_amd64=%s%s%s%s\n' "$h" "$h" "$h" "$h" > "$tmp/pins/tool.env"
  n=$(count_rule "$tmp/pins/tool.env" long-hex "${secret_rules[long-hex]}")
  if (( n == 0 )); then echo "  ok    pin line"; else echo "  FALSE-POSITIVE pin line ($n)"; fail=1; fi
  printf 'TOOL_URL=https://x.example/%s%s\n' "$h" "$h" >> "$tmp/pins/tool.env"
  n=$(count_rule "$tmp/pins/tool.env" long-hex "${secret_rules[long-hex]}")
  if (( n == 1 )); then echo "  ok    other hex in a pin file"; else echo "  MISS  other hex in a pin file ($n)"; fail=1; fi
  printf 'NOTE=%s%s\n' "$h" "$h" > "$tmp/elsewhere.env"
  printf 'TOOL_SHA256_linux_amd64=%s%s%s%s\n' "$h" "$h" "$h" "$h" >> "$tmp/elsewhere.env"
  n=$(count_rule "$tmp/elsewhere.env" long-hex "${secret_rules[long-hex]}")
  if (( n == 2 )); then echo "  ok    pin-shaped line outside pins/"; else echo "  MISS  pin-shaped line outside pins/ ($n)"; fail=1; fi
  (( fail )) && { echo "scrub self-test: FAILED"; exit 1; }
  echo "scrub self-test: all rules fire"
  exit 0
fi

cd "$(git rev-parse --show-toplevel)"
root=$PWD
check_denylist
total=0
mode="all rules"; (( secrets_only )) && mode="secret rules only"
# The reviewed versions of this script, by blob SHA: only these get its self-exemption.
known_self=$(grep -Eo '^[0-9a-f]{40}' "$root/tools/scrub-known-versions.txt" 2>/dev/null || true)
is_known_self() { grep -qx -- "$1" <<<"$known_self"; }

if (( history )); then
  # Lay the history out as files and streams from the objects themselves, then scan them:
  # - every blob reachable from any ref is its own file, named by its SHA (no path can collide,
  #   overwrite a stream or abort the scan; a binary version hides nothing);
  # - history:paths is every full path of every commit's tree (ls-tree -r -z), so a renamed
  #   file's old name, a path sharing its content with another, a submodule entry and a name
  #   with a newline are all read;
  # - history:commits is every commit header beyond tree/parent/author/committer (a mergetag
  #   carries a whole tag: tagger and message), history:messages the commit and tag messages,
  #   history:identities every author, committer and tagger, history:refs ref and tag names.
  # Output names a blob by its SHA, never by a path. A git failure exits 1. Reflog-only objects
  # (a stash that was never pushed) aren't reachable from a ref and aren't scanned.
  export GIT_NO_REPLACE_OBJECTS=1
  # Extract in the C locale: under UTF-8, sed's "." and grep skip bytes that aren't valid UTF-8,
  # and an old Latin-1 author name would drop out of every stream. The user's locale comes back
  # for the scan, so the denylist's case-insensitive match still covers non-ASCII letters.
  user_lc_all=${LC_ALL-} had_lc_all=${LC_ALL+x}
  export LC_ALL=C
  set -E
  trap 'echo "scrub: a git command failed; the history was not fully read"; exit 1' ERR
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  mkdir "$tmp/blobs" "$tmp/streams"
  for s in paths commits messages identities refs; do : > "$tmp/streams/$s"; done
  : > "$tmp/blob-paths"
  # read_tree TREE: every full path in TREE into history:paths, and "<sha> <path>" for its blobs.
  # NUL-separated, so a tab, quote or newline inside a name stays in it.
  read_tree() {
    git ls-tree -r -z --full-tree "$1" > "$tmp/tree"
    tr '\0' '\n' < "$tmp/tree" | sed -n 's/^[0-9]* [a-z]* \([0-9a-f]*\)\t\(.*\)$/\1 \2/p' >> "$tmp/blob-paths"
    tr '\0' '\n' < "$tmp/tree" | sed 's/^[0-9]* [a-z]* [0-9a-f]*\t//' >> "$tmp/streams/paths"
  }
  # Only well-formed standard headers are left out of history:commits; anything else (a
  # mergetag, a signature, an unknown header, a malformed author line) is scanned there.
  known_commit='^(tree|parent) [0-9a-f]{40}([0-9a-f]{24})?$|^(author|committer) .* <[^>]*> [0-9]+ [-+][0-9]{4}$'
  known_tag='^(object [0-9a-f]{40}([0-9a-f]{24})?|type [a-z]+|tag .*)$|^tagger .* <[^>]*> [0-9]+ [-+][0-9]{4}$'
  # nomatch_ok: grep's exit 1 (no match) is fine; 2 (an error) is not.
  nomatch_ok() { [[ $? -eq 1 ]]; }
  git rev-list --all > "$tmp/commits"
  git rev-list --all --objects | cut -d' ' -f1 \
    | git cat-file --batch-check='%(objecttype) %(objectname)' > "$tmp/typed"
  { grep '^blob ' "$tmp/typed" || nomatch_ok; } | while read -r _ sha; do
    git cat-file blob "$sha" > "$tmp/blobs/$sha"
  done
  while read -r c; do
    read_tree "$c"
    git cat-file commit "$c" > "$tmp/commit"
    sed '1,/^$/d' "$tmp/commit" >> "$tmp/streams/messages"
    sed -n 's/^\(author\|committer\) \(.*\) [0-9][0-9]* [-+][0-9]\{4\}$/\2/p' "$tmp/commit" >> "$tmp/streams/identities"
    sed -n '1,/^$/p' "$tmp/commit" | { grep -aEv "$known_commit" || nomatch_ok; } >> "$tmp/streams/commits"
  done < "$tmp/commits"
  git for-each-ref --format='%(refname)' > "$tmp/streams/refs"
  # Every ref, following annotated tags on any ref (and tags of tags); a ref or tag that points
  # at a tree has that tree's paths read too.
  git for-each-ref --format='%(objectname) %(objecttype)' | while read -r sha type; do
    while [[ $type == tag ]]; do
      git cat-file tag "$sha" > "$tmp/tag"
      sed '1,/^$/d' "$tmp/tag" >> "$tmp/streams/messages"
      sed -n 's/^tagger \(.*\) [0-9][0-9]* [-+][0-9]\{4\}$/\1/p' "$tmp/tag" >> "$tmp/streams/identities"
      sed -n 's/^tag //p' "$tmp/tag" >> "$tmp/streams/refs"
      sed -n '1,/^$/p' "$tmp/tag" | { grep -aEv "$known_tag" || nomatch_ok; } >> "$tmp/streams/commits"
      sha=$(sed -n 's/^object //p' "$tmp/tag" | head -1)
      type=$(git cat-file -t "$sha")
    done
    if [[ $type == tree ]]; then read_tree "$sha"; fi
  done
  sort -u -o "$tmp/blob-paths" "$tmp/blob-paths"
  sort -u -o "$tmp/streams/paths" "$tmp/streams/paths"
  # A full SHA of one of this repo's own objects is public with the repo, not a secret.
  for s in messages commits; do
    { grep -aEo '[0-9a-f]{40}([0-9a-f]{24})?' "$tmp/streams/$s" || nomatch_ok; } | sort -u | while read -r x; do
      if git cat-file -e "$x" 2>/dev/null; then printf 's/%s/<object>/g\n' "$x"; fi
    done > "$tmp/own.sed"
    sed -f "$tmp/own.sed" "$tmp/streams/$s" > "$tmp/s" && mv "$tmp/s" "$tmp/streams/$s"
  done
  commits=$(wc -l < "$tmp/commits" | tr -d ' ')
  refs=$(git for-each-ref | wc -l | tr -d ' ')
  blobs=$(find "$tmp/blobs" -type f | wc -l | tr -d ' ')
  echo "scrub: history of $commits commit(s) on $refs refs: $blobs blobs, every path, commits, messages, identities, ref names ($mode)"
  trap - ERR
  if [[ -n $had_lc_all ]]; then export LC_ALL=$user_lc_all; else unset LC_ALL; fi
  for s in paths commits messages identities refs; do scan_one "$tmp/streams/$s" "history:$s" ""; done
  for f in "$tmp/blobs"/*; do
    [[ -e $f ]] || continue
    sha=${f##*/}
    # Path-based exemptions only when every path the blob ever had qualifies.
    mapfile -t paths < <(sed -n "s/^$sha //p" "$tmp/blob-paths" | sort -u)
    ctx=""
    if ((${#paths[@]})) && [[ $(printf '%s\n' "${paths[@]}" | sort -u | wc -l) -eq 1 ]]; then ctx=${paths[0]}; fi
    self=0
    [[ $ctx == tools/scrub.sh ]] && is_known_self "$sha" && self=1
    scan_one "$f" "history:blob ${sha:0:12}" "$ctx" "$self"
  done
else
  # -z: names with non-ASCII bytes or quotes aren't escaped, so every file is read.
  if (( all )); then
    mapfile -d '' -t listed < <(git ls-files -z --cached --others --exclude-standard)
  else
    mapfile -d '' -t listed < <(git ls-files -z --cached)
  fi
  files=()
  for f in "${listed[@]}"; do [[ -f $f ]] && files+=("$f"); done
  echo "scrub: scanning ${#files[@]} files and their paths ($mode)"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  printf '%s\n' "${listed[@]}" > "$tmp/paths"
  scan_one "$tmp/paths" "tree:paths" ""
  for f in "${files[@]}"; do
    self=0
    [[ $f == tools/scrub.sh ]] && self=1
    scan_one "$f" "$(label_for "$f")" "$f" "$self"
  done
fi

if (( ! secrets_only )) && [[ ! -r $denylist ]]; then
  if (( require_denylist )); then
    echo "scrub: no private denylist at \$SCRUB_DENYLIST or the default path; refusing (--require-denylist)"
    exit 1
  fi
  echo "scrub: WARNING no private denylist found (private terms not checked). Set \$SCRUB_DENYLIST."
fi

if (( total > 0 )); then
  echo "scrub: $total finding(s). Replace them with placeholders. Matched text is deliberately not shown."
  echo "       To locate privately: grep -Enc '<pattern>' <file>, or git cat-file -p <blob sha> | grep -Enc '<pattern>'"
  echo "       (counts and line numbers only)"
  exit 1
fi
echo "scrub: clean"
