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
#   tools/scrub.sh --private-infra  # skip denylist lines tagged class=crew-host (see below); every
#                                   # other line and every secret and personal rule still runs
#   tools/scrub.sh --self-test      # plant a canary for every rule in a temp dir and check each fires,
#                                   # and denylisted identities in a temp repo's history
#   tools/scrub.sh --history        # every commit reachable from any ref: every version of every
#                                   # file, commit and tag messages, author/committer/tagger
#                                   # identities and ref names (run before a repo goes public)
#
# Private denylist: one case-insensitive extended regex per line (client and product names,
# people's names, internal hostnames and domains, account IDs). Blank lines and lines starting
# with # are ignored. Read from $SCRUB_DENYLIST, default ~/.config/crewkit/denylist.txt.
# Keep it OUT of the repo, mode 0600. Its contents are never printed.
# A line may end in a class tag, " #class=<name>" (name: [a-z][a-z0-9-]{0,31}); the tag is not part
# of the pattern. An untagged line, or a line with a class this script doesn't know, applies
# everywhere. A malformed tag is a malformed line: the scrub fails, naming the line number only.
# --private-infra skips only class=crew-host lines, and only when every remote of the repo is listed
# in the private-remote file ($SCRUB_PRIVATE_REMOTES, for tests; default
# ~/.config/crewkit/private-remotes.txt): one remote URL per line (a trailing .git or / is ignored),
# # comments, and the line @no-remote to allow a repo with no remote at all. An unlisted remote, a
# missing file or no remote without @no-remote counts as public: exit 2, a fixed message, no URL.
# With --secrets-only the denylist is off anyway, but the remote check still applies. --history
# skips crew-host lines in every version. --require-denylist still needs the file. --self-test
# can't be combined with it. Offline by design: no network call decides what is public.
#
# Allowlist: a reviewed file named exactly .scrub-allow at the repo root (read from the index, so
# it must be staged or committed; --history reads HEAD's) can exempt single values. A line is
#   sha256:<64 lowercase hex>  <rule>  <short reason>        (two spaces between the columns)
# plus # comments and blank lines. Only the rules long-hex and uuid can be listed. A finding is
# exempt only if the sha256 of the exact text the rule matched is listed FOR THAT RULE; there is
# no path, prefix or pattern exemption. The
# denylist can't be allowlisted. A malformed line fails the scrub (line number only, never the
# line). --history applies the same file to every version of every file. See docs/testing.md.
#
# Exit 0 = clean, 1 = findings (or a required denylist is missing), 2 = usage.
set -euo pipefail

all=0 secrets_only=0 require_denylist=0 self_test=0 history=0 private_infra=0
for a in "$@"; do
  case $a in
    --all) all=1 ;;
    --secrets-only) secrets_only=1 ;;
    --require-denylist) require_denylist=1 ;;
    --self-test) self_test=1 ;;
    --history) history=1 ;;
    --private-infra) private_infra=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "usage: tools/scrub.sh [--all|--history] [--secrets-only] [--require-denylist] [--private-infra] [--self-test]" >&2; exit 2 ;;
  esac
done
(( private_infra && self_test )) && { echo "usage: --private-infra can't be combined with --self-test" >&2; exit 2; }

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
# sha256 lines of pins/*.env, and the checksum lines of a Cargo.lock, are also exempt from
# long-hex (see count_rule). The exact-value allowlist (.scrub-allow) is applied last, per match.
allow_email='^noreply@anthropic\.com$|^[^@]+@users\.noreply\.github\.com$|^noreply@github\.com$|@example\.(com|org|net)$'
allow_ntfy='ntfy\.example/'
allow_home='/(home|Users)/(user|you|me|runner)/'

denylist=${SCRUB_DENYLIST:-$HOME/.config/crewkit/denylist.txt}
private_remotes=${SCRUB_PRIVATE_REMOTES:-$HOME/.config/crewkit/private-remotes.txt}
# A class tag is exactly one or more ASCII spaces or tabs, then "#class=<name>", at the end of the
# line. One parser (strip_tag) serves check_denylist and deny_patterns, and its regexes run under
# LC_ALL=C, so a locale's idea of whitespace (U+2003, NBSP, ...) can never make the two disagree.
# Any "#", then spaces, tabs or bytes that are not printable ASCII (what a Unicode space or a VT/FF
# looks like byte by byte), then "class" in any case, then the same again, then "=", anywhere in the
# line, with or without something before it, that isn't exactly a well-formed tag makes the line
# malformed ("T#class=x", "T #CLASS=x", "T # class=x", "T #class =x", "T #<VT>class=x"). There is no
# "this isn't a tag, so the whole line is the pattern" case: such a line would silently check nothing.
# The classes this tool knows. The scrub applies every class everywhere except the one
# under --private-infra that skip_class names (crew-host); "firm" is known and never skipped.
# An unknown class also applies everywhere.
# shellcheck disable=SC2034  # nothing reads it: it names the classes for readers, as export.py does
known_classes=(crew-host firm)
skip_class=crew-host
# A comment or blank line is ASCII spaces and tabs, then "#" or the end, in both tools. Any other
# space (NBSP, U+2003, VT, FF) before "#" makes the line a pattern.
comment_re=$'^[ \t]*(#|$)'
class_trigger_re=$'#([ \t]|[^ -~])*[cC][lL][aA][sS][sS]([ \t]|[^ -~])*='
class_strip_re=$'([^ \t])[ \t]+#class=[a-z][a-z0-9-]{0,31}$'

# strip_tag LINE: sets tag_pat (LINE without its tag) and tag_cls (the class, or empty). Returns 1
# for a malformed tag. Not run in a subshell, so the variables reach the caller.
strip_tag() {
  local line=$1
  tag_pat=$line tag_cls=""
  [[ $line == *"#"* ]] || return 0
  printf '%s\n' "$line" | LC_ALL=C grep -Eq -- "$class_trigger_re" || return 0
  local out
  out=$(printf '%s\n' "$line" | LC_ALL=C sed -E "s/$class_strip_re/\\1/") || return 1
  if [[ $out == "$line" ]] || printf '%s\n' "$out" | LC_ALL=C grep -Eq -- "$class_trigger_re"; then return 1; fi
  tag_cls=${line##*#class=}
  tag_pat=$out
}

# deny_patterns [all]: the denylist's patterns, one per line, class tags removed. Without "all" and
# under --private-infra, class=crew-host lines are left out. Callers have run check_denylist.
deny_patterns() {
  local skip="" line
  (( private_infra )) && [[ ${1:-} != all ]] && skip=$skip_class
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ $comment_re ]] && continue
    # a malformed line can't get here (check_denylist refused it); if it did, keep it whole and active
    strip_tag "$line" || { printf '%s\n' "$line"; continue; }
    [[ -n $skip && $tag_cls == "$skip" ]] && continue
    printf '%s\n' "$tag_pat"
  done < "$denylist"
}

# The exact-value allowlist, filled by load_allow: allowed["<rule> <sha256>"]=1.
declare -A allowed=()
# One definition of a valid line, used by the loader and by the allow file's own long-hex
# exemption. Only these rules may be listed: their values (a 128-bit id, a UUID) can't be recovered
# from a published sha256, which a phone number, an address or a path could be, and a credential
# rule must never be exemptible. The loader reads a looser shape first only to name the reason.
allow_hash_re='[0-9a-f]{64}'
allow_rules_re='long-hex|uuid'
allow_reason_re='[^[:space:][:cntrl:]][^[:cntrl:]]*'
allow_line_re="^sha256:($allow_hash_re)  ($allow_rules_re)  ($allow_reason_re)\$"
allow_shape_re="^sha256:($allow_hash_re)  ([a-z-]+)  ($allow_reason_re)\$"

# sha256_hex: stdin -> its sha256 as bare lowercase hex. sha256sum (as tools/get-bats.sh uses),
# else shasum -a 256 (macOS).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

# load_allow FILE: parse an allowlist into allowed[]. Any bad line exits 1 naming its line number
# only: the scrub must never echo a line of this file, and a bad file must not silently allow less
# (or more) than it was reviewed to.
load_allow() {
  local f=$1 n=0 line rule hash
  allowed=()
  [[ -f $f ]] || return 0
  if [[ $(tr -d '\0' < "$f" | wc -c) != "$(wc -c < "$f")" ]]; then
    echo "scrub: .scrub-allow holds a NUL byte; refusing"; return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^([[:space:]]*|#.*)$ ]] && continue
    if [[ $line =~ $allow_shape_re ]]; then
      hash=${BASH_REMATCH[1]} rule=${BASH_REMATCH[2]}
    else
      echo "scrub: .scrub-allow line $n is malformed (want: sha256:<64 lowercase hex>  <rule>  <reason>)"; return 1
    fi
    if [[ $rule == denylist ]]; then
      echo "scrub: .scrub-allow line $n names the denylist, which can never be allowlisted"; return 1
    fi
    if [[ ! $line =~ $allow_line_re ]]; then
      echo "scrub: .scrub-allow line $n: rule-not-allowed (only long-hex and uuid can be listed)"; return 1
    fi
    allowed["$rule $hash"]=1
  done < "$f"
  if (( ${#allowed[@]} )) && ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "scrub: .scrub-allow needs sha256sum or shasum, and neither is installed; refusing"; return 1
  fi
}

# allow_filter RULE: stdin is one match per line; prints the matches that are not allowlisted for
# RULE. The unit is the match (the same unit count_rule counts), never the line. long-hex's
# pattern needs one delimiter character before the hex run; it isn't part of the value.
allow_filter() {
  local r=$1 v h
  if (( ${#allowed[@]} == 0 )); then cat; return; fi
  # A NUL inside a match becomes a byte no listed value can contain.
  tr '\0' '\001' | while IFS= read -r v; do
    if [[ $r == long-hex && $v != [0-9A-Fa-f]* ]]; then v=${v:1}; fi
    h=$(printf %s "$v" | sha256_hex)
    [[ -n ${allowed["$r $h"]:-} ]] || printf '%s\n' "$v"
  done
}

# The count is of MATCHES (grep -o, one per match), not lines, and the allowlist is applied per
# match, so a line with one allowed and one other value still counts the other.
count_rule() { # file rule-name regex [path for exemptions] -> prints count
  local f=$1 r=$2 re=$3 ctx=${4:-$1}
  # Deliberate pins are exempt from long-hex only: a line marked "scrub:pinned-hash" (a
  # release sha256 or an image digest in a script), in pins/*.env exactly the
  # <TOOL>_SHA256_<os>_<arch>=<64 hex> lines install.sh reads, and in a file named Cargo.lock
  # exactly the `checksum = "<64 hex>"` lines (a lockfile can't carry the marker).
  local pin_line='^[A-Z][A-Z0-9_]*_SHA256_(linux|darwin)_(amd64|arm64)=[0-9a-f]{64}$'
  # -a everywhere: a binary file is still read as text, so NUL bytes hide nothing. Every stage runs
  # in the C locale (every pattern here is ASCII): under UTF-8, BSD sed and grep stop at, or skip a match
  # on, a line holding an invalid byte, and a secret after it would go unseen.
  # Every long-hex branch splits on NUL first, before the marker sed and the exemption grep: BSD
  # grep reads NUL as the end of a line for $, and the marker's sed would otherwise strip a
  # 64-hex secret after a NUL on a marked line. A NUL can't join two lines into one exempt line.
  # On a line marked scrub:pinned-hash only a sha256-length value (64 hex) is exempt, so the
  # marker can't hide a token of another length.
  local marked='/scrub:pinned-hash/ s/[0-9a-f]{64}//g'
  { if [[ $r == long-hex && $ctx =~ (^|/)pins/[^/]+\.env$ ]]; then
      LC_ALL=C tr '\0' '\n' < "$f" | LC_ALL=C sed -E "$marked" | LC_ALL=C grep -aEv "$pin_line"
    elif [[ $r == long-hex && $ctx == tools/scrub-known-versions.txt ]]; then
      # The reviewed scrub.sh versions: a line that is exactly one blob SHA.
      LC_ALL=C tr '\0' '\n' < "$f" | LC_ALL=C sed -E "$marked" | LC_ALL=C grep -aEv '^[0-9a-f]{40}$'
    elif [[ $r == long-hex && $ctx == .scrub-allow ]]; then
      # The allowlist at the repo root: on a line the loader would accept (the same regex), that
      # first hash is dropped before the scan; the rest of the line (the reason) and every other
      # line, including a stale or invalid line in an old --history version, are scanned as usual.
      # The marker is not honoured here.
      LC_ALL=C tr '\0' '\n' < "$f" | LC_ALL=C sed -E "s/^sha256:$allow_hash_re(  ($allow_rules_re)  $allow_reason_re)\$/sha256:\\1/"
    elif [[ $r == long-hex && $ctx =~ (^|/)Cargo\.lock$ ]]; then
      # Cargo's package checksums: a line that is exactly checksum = "<64 lowercase hex>".
      LC_ALL=C tr '\0' '\n' < "$f" | LC_ALL=C sed -E "$marked" | LC_ALL=C grep -aEv '^checksum = "[0-9a-f]{64}"$'
    elif [[ $r == long-hex ]]; then LC_ALL=C tr '\0' '\n' < "$f" | LC_ALL=C sed -E "$marked"
    else cat -- "$f"
    fi; } 2>/dev/null \
    | LC_ALL=C grep -aEio -- "$re" \
    | { case $r in
          email) grep -Eiv "$allow_email" ;;
          ntfy-url) grep -Eiv "$allow_ntfy" ;;
          home-path) grep -Eiv "$allow_home" ;;
          *) cat ;;
        esac; } | allow_filter "$r" | wc -l || true
}

# denylist_hits FILE: how many lines of FILE match the denylist. Counted twice, in the user's locale
# (which folds the case of non-ASCII terms) and in C (which reads past an invalid byte that makes a
# UTF-8 grep skip the line); a hit in either counts, so the larger count wins. grep -c exits 1 for no
# match (and prints 0); any other failure is a failed search, not a pass.
denylist_hits() {
  local f=$1 n1 n2 rc
  n1=$(grep -aEic -f <(deny_patterns) -- "$f" 2>/dev/null) || { rc=$?; (( rc == 1 )) || return 1; }
  n2=$(LC_ALL=C grep -aEic -f <(deny_patterns) -- "$f" 2>/dev/null) || { rc=$?; (( rc == 1 )) || return 1; }
  echo $(( ${n1:-0} > ${n2:-0} ? ${n1:-0} : ${n2:-0} ))
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
    n=$(denylist_hits "$f") || { echo "scrub: the denylist search failed; nothing was checked"; exit 1; }
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
    [[ $line =~ $comment_re ]] && continue
    patterns=$((patterns + 1))
    # CRLF files: a trailing CR would be part of the pattern, which then matches nothing. Refuse.
    if [[ $line == *$'\r' ]]; then echo "scrub: denylist line $n: CR (a trailing carriage return); strip it"; bad=1; continue; fi
    if strip_tag "$line"; then line=$tag_pat; else
      echo "scrub: denylist line $n has a malformed class tag"; bad=1; continue
    fi
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
    && { printf '%s\n' "$1" | grep -aEiq -f <(deny_patterns all) \
        || printf '%s\n' "$1" | LC_ALL=C grep -aEiq -f <(deny_patterns all); }; then
    printf '(a tracked file whose path matches the denylist)'
  else
    printf '%s' "$1"
  fi
}

if (( self_test )); then
  # The self-test's git work (a temp repo, update-ref) must never reach the caller's repository:
  # a hook, a linked worktree or a --git-dir caller exports these, and git would then use them
  # instead of the temp repo. Everything below, and the --history run it starts, sees none.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE
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
  # Cargo.lock: `checksum = "<64 lowercase hex>"` lines are allowed, in a file named Cargo.lock only,
  # and only that whole line; everything else keeps counting.
  mkdir -p "$tmp/src-tauri"
  h64="${h}${h}${h}${h}"
  printf '[[package]]\nchecksum = "%s"\nchecksum = "%s"\n' "$h64" "$h64" > "$tmp/src-tauri/Cargo.lock"
  n=$(count_rule "$tmp/src-tauri/Cargo.lock" long-hex "${secret_rules[long-hex]}" src-tauri/Cargo.lock)
  if (( n == 0 )); then echo "  ok    Cargo.lock checksum line"; else echo "  FALSE-POSITIVE Cargo.lock checksum line ($n)"; fail=1; fi
  cp "$tmp/src-tauri/Cargo.lock" "$tmp/Cargo.lock.bak"
  n=$(count_rule "$tmp/Cargo.lock.bak" long-hex "${secret_rules[long-hex]}" Cargo.lock.bak)
  if (( n == 2 )); then echo "  ok    checksum lines in Cargo.lock.bak"; else echo "  MISS  checksum lines in Cargo.lock.bak ($n)"; fail=1; fi
  cp "$tmp/src-tauri/Cargo.lock" "$tmp/notes.txt"
  n=$(count_rule "$tmp/notes.txt" long-hex "${secret_rules[long-hex]}" notes.txt)
  if (( n == 2 )); then echo "  ok    checksum lines outside Cargo.lock"; else echo "  MISS  checksum lines outside Cargo.lock ($n)"; fail=1; fi
  printf 'checksum = "%s" x\nsource = "%s"\nchecksum = "%s"\nchecksum = "%s"\nchecksum = "%s"\n' \
    "$h64" "$h64" "${h64:0:40}" "${h64:0:63}" "$(printf %s "$h64" | tr a-f A-F)" > "$tmp/Cargo.lock"
  n=$(count_rule "$tmp/Cargo.lock" long-hex "${secret_rules[long-hex]}" Cargo.lock)
  if (( n == 5 )); then echo "  ok    other hex in Cargo.lock"; else echo "  MISS  other hex in Cargo.lock ($n)"; fail=1; fi
  # More Cargo.lock negatives: a name that only ends in Cargo.lock, and a line that only contains a checksum.
  printf 'checksum = "%s"\n' "$h64" > "$tmp/fooCargo.lock"
  n=$(count_rule "$tmp/fooCargo.lock" long-hex "${secret_rules[long-hex]}" fooCargo.lock)
  if (( n == 1 )); then echo "  ok    fooCargo.lock"; else echo "  MISS  fooCargo.lock ($n)"; fail=1; fi
  printf '# checksum = "%s"\nxchecksum = "%s"\n' "$h64" "$h64" > "$tmp/Cargo.lock"
  n=$(count_rule "$tmp/Cargo.lock" long-hex "${secret_rules[long-hex]}" Cargo.lock)
  if (( n == 2 )); then echo "  ok    checksum text inside a longer Cargo.lock line"; else echo "  MISS  checksum text inside a longer Cargo.lock line ($n)"; fail=1; fi
  # A NUL byte doesn't end the line for an exemption (BSD grep reads NUL as the end of a line for $):
  # hex after an exempt line is still counted, in each exempt file.
  printf 'checksum = "%s"\0key %s\n' "$h64" "$h64" > "$tmp/nul-cargo"
  n=$(count_rule "$tmp/nul-cargo" long-hex "${secret_rules[long-hex]}" src-tauri/Cargo.lock)
  if (( n == 1 )); then echo "  ok    NUL after a Cargo.lock checksum line"; else echo "  MISS  NUL after a Cargo.lock checksum line ($n)"; fail=1; fi
  printf 'TOOL_SHA256_linux_amd64=%s\0key %s\n' "$h64" "$h64" > "$tmp/nul-pin"
  n=$(count_rule "$tmp/nul-pin" long-hex "${secret_rules[long-hex]}" pins/tool.env)
  if (( n == 1 )); then echo "  ok    NUL after a pins/*.env line"; else echo "  MISS  NUL after a pins/*.env line ($n)"; fail=1; fi
  printf '%s\0key %s\n' "${h64:0:40}" "$h64" > "$tmp/nul-known"
  n=$(count_rule "$tmp/nul-known" long-hex "${secret_rules[long-hex]}" tools/scrub-known-versions.txt)
  if (( n == 1 )); then echo "  ok    NUL after a known-versions line"; else echo "  MISS  NUL after a known-versions line ($n)"; fail=1; fi
  # A marked line, a NUL and a secret: the marker must not strip the secret after the NUL.
  printf 'x # scrub:pinned-hash\0%s\n' "$h64" > "$tmp/nul-marked"
  for c in notes.txt src-tauri/Cargo.lock pins/tool.env; do
    n=$(count_rule "$tmp/nul-marked" long-hex "${secret_rules[long-hex]}" "$c")
    if (( n == 1 )); then echo "  ok    NUL after a marked line ($c)"; else echo "  MISS  NUL after a marked line ($c) ($n)"; fail=1; fi
  done
  # The exact-value allowlist (.scrub-allow), both ways: a listed value passes for its rule only,
  # a changed value, another rule, a longer run or a second match on the line still counts, a
  # malformed or denylist line is refused, and the allow file's own hash lines are exempt from
  # long-hex while other hex in it is not.
  av="a1b2c3d4e5f60718293a4b5c6d7e8f90"; ao="f0e1d2c3b4a5968778695a4b3c2d1e0f"
  ah=$(printf %s "$av" | sha256_hex)
  allow_t() { # allow_t NAME EXPECTED-COUNT FILE RULE: count_rule's count for FILE under the loaded list
    local n; n=$(count_rule "$3" "$4" "${secret_rules[$4]}" "${5:-$3}")
    if (( n == $2 )); then echo "  ok    allow: $1"; else echo "  MISS  allow: $1 ($n, want $2)"; fail=1; fi
  }
  printf 'sha256:%s  long-hex  fixture\n' "$ah" > "$tmp/allow"
  printf 'id %s\n' "$av" > "$tmp/a1.txt"
  printf 'id %s\n' "${av%?}1" > "$tmp/a2.txt"
  printf 'id %s %s\n' "$av" "$ao" > "$tmp/a3.txt"
  printf 'id %s\nid %s\n' "$av" "$av" > "$tmp/a4.txt"
  printf 'id %s0\n' "$av" > "$tmp/a5.txt"
  load_allow "$tmp/allow"
  allow_t "listed value" 0 "$tmp/a1.txt" long-hex
  allow_t "one character changed" 1 "$tmp/a2.txt" long-hex
  allow_t "allowed and other match on one line" 1 "$tmp/a3.txt" long-hex
  allow_t "two allowed matches" 0 "$tmp/a4.txt" long-hex
  allow_t "longer run containing the value" 1 "$tmp/a5.txt" long-hex
  printf 'sha256:%s  uuid  fixture\n' "$ah" > "$tmp/allow"
  load_allow "$tmp/allow"
  allow_t "listed under a different rule" 1 "$tmp/a1.txt" long-hex
  printf 'sha256:%s  long-hex  fixture\n' "${ah%?}0" > "$tmp/allow"
  load_allow "$tmp/allow"
  allow_t "listed hash changed" 1 "$tmp/a1.txt" long-hex
  # fail closed: each of these must make load_allow exit non-zero naming line 2 and printing nothing from it
  allow_bad=0
  for bad in "sha1:$ah  long-hex  r" "sha256:${ah:1}  long-hex  r" "sha256:$ah  nosuchrule  r" "sha256:$ah  long-hex" \
             "sha256:$ah long-hex r" "sha256:$(printf %s "$ah" | tr a-f A-F)  long-hex  r"; do
    printf '# c\n%s\n' "$bad" > "$tmp/allow"
    out=$( (load_allow "$tmp/allow") 2>&1 ) && rc=0 || rc=$?
    if (( rc != 0 )) && [[ $out == *"line 2"* && $out != *"$ah"* && $out != *nosuchrule* ]]; then :; else allow_bad=1; fi
  done
  if (( allow_bad == 0 )); then echo "  ok    allow: malformed lines fail closed"; else echo "  MISS  allow: malformed lines fail closed"; fail=1; fi
  printf 'sha256:%s  denylist  r\n' "$ah" > "$tmp/allow"
  out=$( (load_allow "$tmp/allow") 2>&1 ) && rc=0 || rc=$?
  if (( rc != 0 )) && [[ $out == *"line 1"* && $out == *denylist* ]]; then echo "  ok    allow: denylist refused"; else echo "  MISS  allow: denylist refused"; fail=1; fi
  # the allow file itself: exact hash lines pass; other hex in it (reason, comment) and the same
  # lines under any other name or directory do not
  printf 'sha256:%s  long-hex  fixture\n' "$ah" > "$tmp/allow"
  allow_t "allow file hash line" 0 "$tmp/allow" long-hex .scrub-allow
  printf 'sha256:%s  long-hex  see %s\n# %s\n' "$ah" "$ao" "$ao" > "$tmp/allow2"
  allow_t "other hex in the allow file" 2 "$tmp/allow2" long-hex .scrub-allow
  allow_t "hash line in a subdirectory" 1 "$tmp/allow" long-hex sub/.scrub-allow
  allow_t "hash line under another name" 1 "$tmp/allow" long-hex .scrub-allow.bak
  # only long-hex and uuid can be listed: any other rule, credential or private, is refused by code
  allow_bad=0
  for bad in github-token phone private-ip email aws-key secret-assign url-credentials home-path; do
    printf 'sha256:%s  %s  r\n' "$ah" "$bad" > "$tmp/allow"
    out=$( (load_allow "$tmp/allow") 2>&1 ) && rc=0 || rc=$?
    if (( rc != 0 )) && [[ $out == *"line 1"*rule-not-allowed* && $out != *"$ah"* && $out != *"$bad"* ]]; then :; else allow_bad=1; fi
  done
  printf 'sha256:%s  uuid  r\n' "$ah" > "$tmp/allow"
  (load_allow "$tmp/allow") >/dev/null 2>&1 || allow_bad=1
  if (( allow_bad == 0 )); then echo "  ok    allow: only long-hex and uuid"; else echo "  MISS  allow: only long-hex and uuid"; fail=1; fi
  # an old or invalid allow-file line (a refused rule, a missing reason) hides no hex
  printf 'sha256:%s  phone  r\nsha256:%s  long-hex\nsha256:%s  anyword  r\n' "$ah" "$ah" "$ah" > "$tmp/allow3"
  allow_t "invalid allow-file lines hide their hex" 3 "$tmp/allow3" long-hex .scrub-allow
  load_allow /dev/null
  # label_for hides a path that matches the denylist in either locale view: a path with an invalid
  # byte matches only in C, so a UTF-8 grep alone would print it. Needs a UTF-8 locale to mean anything.
  lterm="lbl""zorkwell"; saved_denylist=$denylist; denylist="$tmp/label-denylist"; printf '%s\n' "$lterm" > "$denylist"
  lbl_locale=""
  for l in en_US.UTF-8 C.UTF-8; do
    if [[ $(LC_ALL=$l locale charmap 2>/dev/null) == UTF-8 ]]; then lbl_locale=$l; break; fi
  done
  if [[ -z $lbl_locale ]]; then echo "  skip  label: no UTF-8 locale installed"
  else
    got=$(LC_ALL=$lbl_locale label_for "$(printf 'lib/caf\351 %s' "$lterm")")
    if [[ $got != *"$lterm"* ]]; then echo "  ok    label: a path with an invalid byte is hidden"
    else echo "  MISS  label: a path with an invalid byte is hidden"; fail=1; fi
  fi
  denylist=$saved_denylist
  # The history scan end to end: a temp repo whose one commit has a denylisted author name and
  # committer email (plumbing, so no hook or signing config runs). Both must be found.
  term="canary""zorkwell"
  printf '%s\n' "$term" > "$tmp/history-denylist"
  git init -q "$tmp/history"
  c=$(cd "$tmp/history" && GIT_AUTHOR_NAME="Ann $term" GIT_AUTHOR_EMAIL=ann@example.com \
    GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL="$term@example.com" \
    git commit-tree "$(git mktree < /dev/null)" -m m)
  git -C "$tmp/history" update-ref refs/heads/main "$c"
  # Run by the same bash, never as "$self": a vendored copy run as `bash scrub.sh` may lack the exec bit.
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  out=$(cd "$tmp/history" && SCRUB_DENYLIST="$tmp/history-denylist" "$BASH" "$self" --history 2>&1) && rc=0 || rc=$?
  n=$(awk '$1 == "denylist" && $2 == "history:identities" { print $3 }' <<<"$out")
  if (( rc == 1 )) && [[ ${n:-0} == 2 ]]; then echo "  ok    history identities"
  else echo "  MISS  history identities (exit $rc, ${n:-0} of 2 found)"; fail=1; fi
  (( fail )) && { echo "scrub self-test: FAILED"; exit 1; }
  echo "scrub self-test: all rules fire"
  exit 0
fi

# This script's own path, resolved before the cd below (it may have been started by a relative path).
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script_path=$script_dir/$(basename "${BASH_SOURCE[0]}")
cd "$(git rev-parse --show-toplevel)"
# resolve_path PATH: PATH with every symlink and ".." resolved (the file may not exist).
resolve_path() {
  local p=$1 d i=0
  while [[ -L $p ]] && (( i++ < 40 )); do d=$(dirname -- "$p"); p=$(readlink -- "$p"); [[ $p == /* ]] || p=$d/$p; done
  d=$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${d%/}" "$(basename -- "$p")"
}
# A list the scanned repository holds could be edited by the very change being scanned, so a
# denylist or private-remote list whose real path is inside the repository is refused (exit 2).
# An unresolvable path counts as inside. Checked at scan time, like the rest (see the limit below).
root_real=$(pwd -P)
inside_repo() { local p; p=$(resolve_path "$1") || return 0; [[ $p == "$root_real"/* ]]; }
if (( ! secrets_only )) && [[ -r $denylist ]] && inside_repo "$denylist"; then
  echo "scrub: the denylist is inside the repository being scanned; refusing"; exit 2
fi
# remote_url_norm URL: URL without trailing slashes or a .git suffix.
remote_url_norm() { local u=$1; while [[ $u == */ ]]; do u=${u%/}; done; printf '%s\n' "${u%.git}"; }
# --private-infra is a claim that this repo is private. Check it against the user's own list; any
# remote that isn't on it, or a missing list, means public. Never prints a URL.
# Limit: this is a check at scan time, against what git resolves now. It can't see a later `git push
# <url>`, a remote added afterwards, config that differs at push time (includeIf, hasconfig, -c,
# GIT_CONFIG_*), an ssh alias that maps a listed host elsewhere, or a listed repo made public later.
if (( private_infra )); then
  refuse_infra() { echo "scrub: --private-infra refused: every remote must be on the private-remote list"; exit 2; }
  [[ -r $private_remotes ]] || refuse_infra
  if inside_repo "$private_remotes"; then
    echo "scrub: --private-infra refused: the private-remote list is inside the repository being scanned"; exit 2
  fi
  # The list is a trust root that weakens the scan: a regular file (not a link), ours, that no one else can write.
  if [[ -L $private_remotes || ! -f $private_remotes || ! -O $private_remotes ]] \
    || [[ -n $(find -H "$private_remotes" -prune \( -perm -020 -o -perm -002 \) -print 2>/dev/null) ]]; then
    echo "scrub: --private-infra refused: the private-remote list must be a regular file you own that no one else can write"
    exit 2
  fi
  # git push also reads .git/remotes/<name> and .git/branches/<name>, which `git remote` doesn't list.
  for legacy in remotes branches; do
    p=$(git rev-parse --git-path "$legacy") || refuse_infra
    if [[ -d $p ]]; then entry=$(ls -A -- "$p") || refuse_infra; entry=${entry%%$'\n'*}
    elif [[ -e $p || -L $p ]]; then entry=$legacy
    else entry=""; fi
    if [[ -n $entry ]]; then
      printf 'scrub: --private-infra refused: legacy remote definition %q (in %s) is not checked\n' "$entry" "$legacy"
      exit 2
    fi
  done
  declare -A listed_remotes=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=${line%"${line##*[![:space:]]}"}; line=${line#"${line%%[![:space:]]*}"}
    if [[ $line == @no-remote ]]; then listed_remotes[@no-remote]=1; continue; fi
    key=$(remote_url_norm "$line")
    [[ -n $key ]] || { echo "scrub: --private-infra refused: an entry in the private-remote list is empty"; exit 2; }
    listed_remotes["$key"]=1
  done < "$private_remotes"
  remotes=$(git remote) || refuse_infra
  if [[ -z $remotes ]]; then
    [[ -n ${listed_remotes[@no-remote]:-} ]] || refuse_infra
  fi
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    fetch_urls=$(git remote get-url --all -- "$r") || refuse_infra
    push_urls=$(git remote get-url --push --all -- "$r") || refuse_infra
    while IFS= read -r u; do
      key=$(remote_url_norm "$u")
      [[ -n $key && -n ${listed_remotes["$key"]:-} ]] || refuse_infra
    done <<<"$fetch_urls"$'\n'"$push_urls"
  done <<<"$remotes"
fi
check_denylist
# Under --private-infra the crew-host lines are left out; if that leaves no pattern, the denylist
# checks nothing. Counts only.
if (( private_infra && ! secrets_only )) && [[ -r $denylist ]]; then
  n_active=$(deny_patterns | awk 'END { print NR }')
  n_skipped=$(( $(deny_patterns all | awk 'END { print NR }') - n_active ))
  if (( n_active == 0 )); then
    if (( require_denylist )); then
      echo "scrub: --private-infra leaves no active denylist pattern (active=0 skipped=$n_skipped); refusing (--require-denylist)"
      exit 2
    fi
    echo "scrub: WARNING --private-infra leaves no active denylist pattern (active=0 skipped=$n_skipped); private terms not checked"
  fi
fi
# The allowlist is read from the index for a tree or pre-commit scan, not the work tree: an
# untracked or unstaged file can't exempt anything, and what is exempt is what is about to be
# committed. --history is about commits, not staged state, so it reads HEAD's file.
allow_ref=:.scrub-allow; (( history )) && allow_ref=HEAD:.scrub-allow
if git cat-file -e "$allow_ref" 2>/dev/null; then
  allow_tmp=$(mktemp)
  git cat-file blob "$allow_ref" > "$allow_tmp" || { rm -f "$allow_tmp"; echo "scrub: could not read .scrub-allow"; exit 1; }
  load_allow "$allow_tmp" || { rm -f "$allow_tmp"; exit 1; }
  rm -f "$allow_tmp"
fi
total=0
mode="all rules"; (( secrets_only )) && mode="secret rules only"
# The reviewed versions of this script, by blob SHA: only these get its self-exemption.
# The list is read from this script's own directory, never from the tree being scanned (which the
# gate does not trust: it runs this script against a clone).
known_self=$(grep -Eo '^[0-9a-f]{40}' "$script_dir/scrub-known-versions.txt" 2>/dev/null || true)
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
  # The extractions, one function each, so the probe below runs exactly what the scan runs.
  # Portable sed only: BSD sed (macOS) has no \| \+ \? in a basic expression, and a GNU-only
  # form there silently matched no identity at all.
  # blob_paths_of / paths_of TREEFILE: "<sha> <path>" per blob, and every full path, from
  # ls-tree -z output. Each record is "<mode> <type> <sha><TAB><path>" and records end in NUL,
  # so they are read one at a time and split at the first tab; the NULs are not turned into
  # newlines first, because a path may itself hold a newline and the lines of one record would
  # then read as separate entries (a path cut short, or a fake entry after it, would give a
  # blob a path context it doesn't have). Output is one line per entry, so a path with a newline
  # still spans lines in paths_of, which is only scanned for terms. In blob_paths_of such a path
  # is written as a fixed placeholder, never as itself: the blob still counts as having a path
  # that gets no exemption, and no line of the output can be a pair that isn't a tree entry.
  blob_paths_of() {
    local rec meta path sha
    while IFS= read -r -d '' rec || [[ -n $rec ]]; do
      meta=${rec%%$'\t'*} path=${rec#*$'\t'} sha=${meta##* }
      if [[ $meta != *' blob '* ]]; then continue; fi
      if [[ $path == *$'\n'* ]]; then path='<path with a newline>'; fi
      printf '%s %s\n' "$sha" "$path"
    done < "$1"
  }
  paths_of() {
    local rec
    while IFS= read -r -d '' rec || [[ -n $rec ]]; do printf '%s\n' "${rec#*$'\t'}"; done < "$1"
  }
  # identities_of COMMIT / tagger_of TAG: "Name <email>" from each author and committer line,
  # or the tagger line.
  identities_of() { sed -En 's/^(author|committer) (.*) [0-9]+ [-+][0-9]{4}$/\2/p' "$1"; }
  tagger_of() { sed -n 's/^tagger \(.*\) [0-9][0-9]* [-+][0-9]\{4\}$/\1/p' "$1"; }
  # The probe's author name holds a byte (octal 351) that isn't valid UTF-8, so losing the C
  # locale above makes it fail here, at run time, on any system.
  # Fail closed: each extraction must give the known answer for a known commit, tag and tree
  # entry, or the scan refuses to run rather than pass a history it couldn't read.
  printf 'tree x\nauthor Probe\351 A <pa> 1700000000 +0000\ncommitter Probe C <pc> 1700000000 -0700\n\nm\n' > "$tmp/probe-commit"
  printf 'object x\ntype commit\ntag v\ntagger Probe T <pt> 1700000000 +0000\n\nm\n' > "$tmp/probe-tag"
  printf '%s\0' $'100644 blob 0a1b\tdir/probe\tname' > "$tmp/probe-tree"
  # A path that holds a newline and a fake entry must give one pair, never the fake one.
  printf '%s\0' $'100644 blob 0a1b\tdir/x\n100644 blob 2c3d\tpins/x.env' $'160000 commit 4e5f\tsub' $'100644 blob 6a7b\tok' > "$tmp/probe-tree-nl"
  probe_bad=""
  [[ $(identities_of "$tmp/probe-commit") == $'Probe\351 A <pa>\nProbe C <pc>' ]] || probe_bad+=" identities"
  [[ $(tagger_of "$tmp/probe-tag") == 'Probe T <pt>' ]] || probe_bad+=" tagger"
  [[ $(blob_paths_of "$tmp/probe-tree") == $'0a1b dir/probe\tname' ]] || probe_bad+=" blob-paths"
  [[ $(paths_of "$tmp/probe-tree") == $'dir/probe\tname' ]] || probe_bad+=" paths"
  [[ $(blob_paths_of "$tmp/probe-tree-nl") == $'0a1b <path with a newline>\n6a7b ok' ]] || probe_bad+=" blob-paths-newline"
  if [[ -n $probe_bad ]]; then
    echo "scrub: this system's sed or tr can't extract the history's${probe_bad}; refusing to scan (is a GNU-only form in tools/scrub.sh?)"
    exit 1
  fi
  # read_tree TREE: every full path in TREE into history:paths, and "<sha> <path>" for its blobs.
  read_tree() {
    git ls-tree -r -z --full-tree "$1" > "$tmp/tree"
    blob_paths_of "$tmp/tree" >> "$tmp/blob-paths"
    paths_of "$tmp/tree" >> "$tmp/streams/paths"
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
    identities_of "$tmp/commit" >> "$tmp/streams/identities"
    # A commit stored in another encoding (an "encoding" header) holds its message and names in
    # that encoding, so a non-ASCII term written in UTF-8 can't match the raw bytes: also read
    # them as git shows them, re-encoded to UTF-8 (#28).
    if [[ -n $(sed -n '1,/^$/s/^encoding //p' "$tmp/commit") ]]; then
      git show -s --encoding=UTF-8 --format='%B' "$c" >> "$tmp/streams/messages"
      git show -s --encoding=UTF-8 --format='%an <%ae>%n%cn <%ce>' "$c" >> "$tmp/streams/identities"
    fi
    sed -n '1,/^$/p' "$tmp/commit" | { grep -aEv "$known_commit" || nomatch_ok; } >> "$tmp/streams/commits"
  done < "$tmp/commits"
  git for-each-ref --format='%(refname)' > "$tmp/streams/refs"
  # Every ref, following annotated tags on any ref (and tags of tags); a ref or tag that points
  # at a tree has that tree's paths read too.
  git for-each-ref --format='%(objectname) %(objecttype)' | while read -r sha type; do
    while [[ $type == tag ]]; do
      git cat-file tag "$sha" > "$tmp/tag"
      sed '1,/^$/d' "$tmp/tag" >> "$tmp/streams/messages"
      tagger_of "$tmp/tag" >> "$tmp/streams/identities"
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
    # tools/scrub.sh is exempt (it holds the patterns) only when it is this very script, byte for
    # byte, or a reviewed version (known by blob SHA): the path alone proves nothing.
    if [[ $f == tools/scrub.sh ]] && { cmp -s -- "$f" "$script_path" || is_known_self "$(git hash-object --no-filters -- "$f")"; }; then self=1; fi
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
