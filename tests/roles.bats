#!/usr/bin/env bats
# tools/lint-roles.py: the front matter of every roles/ file has the keys the role spec requires.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  LINT="$REPO/tools/lint-roles.py"
  R="$BATS_TEST_TMPDIR/roles"
  mkdir -p "$R/_template" "$R/worker/solo"
  printf -- '---\nkind: <name>\nlead: <lead>\nmodel: <m>\npermission_mode: <p>\nruns_as: session\n---\n\n# t\n' > "$R/_template/kind.md"
  printf -- '---\nkind: <kind>\nvariant: <name>\npermission_mode: <p>\n---\n\n# t\n' > "$R/_template/role.md"
  printf -- '---\nkind: worker\nlead: boss\nmodel: mid\npermission_mode: auto\nruns_as: session\n---\n\n# worker\n' > "$R/worker/kind.md"
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\n---\n\n# worker/solo\n' > "$R/worker/solo/role.md"
}

# fm FILE KEY...: rewrite FILE's front matter without the lines of the given keys.
drop_key() {
  local f=$1 k=$2
  grep -v "^$k:" "$f" > "$f.new" && mv "$f.new" "$f"
}

@test "the roles/ tree of this repo passes" {
  run python3 "$LINT"
  [ "$status" -eq 0 ]
}

@test "a well-formed tree passes, template placeholders and all" {
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "a variant role.md without variant: fails and names the file and the key" {
  drop_key "$R/worker/solo/role.md" variant
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md"* && $output == *"variant"* ]]
}

@test "a variant with an empty variant: fails" {
  printf -- '---\nkind: worker\nvariant:\npermission_mode: auto\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"variant"* ]]
}

@test "a variant that does not name its own folder fails" {
  sed 's/^variant: solo/variant: other/' "$R/worker/solo/role.md" > "$R/x" && mv "$R/x" "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"variant"* && $output == *"solo"* ]]
}

@test "a variant whose kind is not its parent folder fails" {
  sed 's/^kind: worker/kind: boss/' "$R/worker/solo/role.md" > "$R/x" && mv "$R/x" "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"kind"* && $output == *"worker"* ]]
}

@test "a variant must restate permission_mode" {
  drop_key "$R/worker/solo/role.md" permission_mode
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"permission_mode"* ]]
}

@test "a base kind.md needs each of kind, lead, model, permission_mode and runs_as" {
  local k
  for k in kind lead model permission_mode runs_as; do
    printf -- '---\nkind: worker\nlead: boss\nmodel: mid\npermission_mode: auto\nruns_as: session\n---\n' > "$R/worker/kind.md"
    drop_key "$R/worker/kind.md" "$k"
    run python3 "$LINT" "$R"
    [ "$status" -eq 1 ]
    [[ $output == *"worker/kind.md"* && $output == *"$k"* ]]
  done
}

@test "a base kind.md whose kind is not its folder fails" {
  sed 's/^kind: worker/kind: other/' "$R/worker/kind.md" > "$R/x" && mv "$R/x" "$R/worker/kind.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/kind.md"* ]]
}

@test "a permission_mode outside the known set fails" {
  sed 's/^permission_mode: auto/permission_mode: yolo/' "$R/worker/solo/role.md" > "$R/x" && mv "$R/x" "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"permission_mode"* && $output == *"yolo"* ]]
}

@test "every known permission_mode passes" {
  local m
  for m in plan dontAsk manual acceptEdits auto none; do
    printf -- '---\nkind: worker\nvariant: solo\npermission_mode: %s\npermission_detail:\n  allow: [Read]\n---\n' "$m" > "$R/worker/solo/role.md"
    run python3 "$LINT" "$R"
    [ "$status" -eq 0 ]
  done
}

@test "a runs_as outside the known set fails" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nruns_as: forever\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"runs_as"* && $output == *"forever"* ]]
}

@test "cron and timer roles need a schedule; other runs_as do not" {
  local r
  for r in cron timer; do
    printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nruns_as: %s\n---\n' "$r" > "$R/worker/solo/role.md"
    run python3 "$LINT" "$R"
    [ "$status" -eq 1 ]
    [[ $output == *"schedule"* ]]
    printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nruns_as: %s\nschedule: "hourly"\n---\n' "$r" > "$R/worker/solo/role.md"
    run python3 "$LINT" "$R"
    [ "$status" -eq 0 ]
  done
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nruns_as: service\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "dontAsk needs permission_detail, in a variant and in a base kind" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: dontAsk\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"permission_detail"* ]]
  printf -- '---\nkind: worker\nlead: boss\nmodel: mid\npermission_mode: dontAsk\nruns_as: session\n---\n' > "$R/worker/kind.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/kind.md"* && $output == *"permission_detail"* ]]
}

@test "remove: without a ruling fails; with one it passes" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nremove:\n  never: ["a bullet"]\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"ruling"* ]]
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nremove:\n  never: ["a bullet"]\nruling: r-1\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "an empty ruling: does not satisfy remove:" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\nremove:\n  never: ["a bullet"]\nruling:\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"ruling"* ]]
}

@test "a key indented under another key does not count as a top-level key" {
  printf -- '---\nkind: worker\npermission_mode: auto\npermission_detail:\n  variant: solo\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"missing required key: variant"* ]]
}

@test "a key given twice fails, so the last value cannot hide the first" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: yolo\npermission_mode: auto\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"permission_mode"* && $output == *"twice"* ]]
}

@test "a trailing comment on a value does not hide the key or become part of it" {
  printf -- '---\nkind: worker   # the kind\nvariant: solo   # the folder\npermission_mode: auto   # restated\n---\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "a file with no front matter fails" {
  printf '# worker/solo\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md"* && $output == *"front matter"* ]]
}

@test "front matter that never closes fails" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"front matter"* ]]
}

@test "a key that appears only below the front matter does not count" {
  printf -- '---\nkind: worker\npermission_mode: auto\n---\n\nvariant: solo\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"variant"* ]]
}

@test "a kind folder without kind.md fails, and so does a variant folder without role.md" {
  rm "$R/worker/kind.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker"* && $output == *"kind.md"* ]]
  printf -- '---\nkind: worker\nlead: boss\nmodel: mid\npermission_mode: auto\nruns_as: session\n---\n' > "$R/worker/kind.md"
  rm "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo"* && $output == *"role.md"* ]]
}

@test "the template must carry the required keys too" {
  drop_key "$R/_template/role.md" variant
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"_template/role.md"* && $output == *"variant"* ]]
}

@test "every problem is reported, not just the first" {
  drop_key "$R/worker/solo/role.md" variant
  drop_key "$R/worker/kind.md" lead
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"variant"* && $output == *"lead"* ]]
}

@test "a missing roles directory is a usage error" {
  run python3 "$LINT" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 64 ]
}

@test "an empty roles directory fails rather than passing for nothing" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  run python3 "$LINT" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 1 ]
}

# ---- layout: the repo's markdown lint (blanks around headings and lists) --------------------------

# body FILE TEXT...: write TEXT lines under a valid front matter into FILE.
body() {
  local f=$1
  shift
  { printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\n---\n'; printf '%s\n' "$@"; } > "$f"
}

@test "a heading with a list right below it fails, and says which line" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' '## May' '- read it' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md:9: heading needs a blank line below it"* ]]
  # the list is reported too, as the hosted lint does (MD022 and MD032 both fire here)
  [[ $output == *"worker/solo/role.md:10: list needs a blank line above it"* ]]
}

@test "a heading with no blank line above it fails" {
  body "$R/worker/solo/role.md" '' '# worker/solo' 'text' '## May' '' 'text'
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md:9: heading needs a blank line above it"* ]]
}

@test "a list with no blank line above it fails" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' 'Some text:' '- one' '- two' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md:10: list"* ]]
}

@test "a heading right below a list fails (the heading rule, with the line)" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' '- one' '- two' '## Next' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"worker/solo/role.md:11: heading needs a blank line above it"* ]]
}

@test "a list that ends the file, headings with blanks around them and a lazy continuation pass" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' 'Intro.' '' '## May' '' '- read it' '  and then some' '- write it' '' '## Never' '' '- delete it'
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "headings and list items inside a fenced code block are not checked" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' '```' '# not a heading' '- not a list' '```' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "a hash sign or a dash inside a line is not a heading or a list" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' 'a line with # and - and #hash' 'next line' '#hashtag' '-5 degrees' '--flag' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "a list right above a code fence fails" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' '- one' '```' 'code' '```' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"list needs a blank line below it"* ]]
}

@test "checking resumes after a code fence is closed" {
  body "$R/worker/solo/role.md" '' '# worker/solo' '' '```' 'code' '```' '' 'text' '## Next' ''
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"heading needs a blank line above it"* ]]
}

@test "a heading right below the front matter is fine" {
  body "$R/worker/solo/role.md" '# worker/solo' '' 'text'
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "the front matter is not checked as markdown" {
  printf -- '---\nkind: worker\nvariant: solo\npermission_mode: auto\npermission_detail:\n  # what it may read\n  allow: [Read]\n---\n\n# worker/solo\n' > "$R/worker/solo/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 0 ]
}

@test "the template's layout is checked too: it is what new role files are copied from" {
  printf -- '---\nkind: <kind>\nvariant: <name>\npermission_mode: <p>\n---\n\n# t\n## May\n- x\n' > "$R/_template/role.md"
  run python3 "$LINT" "$R"
  [ "$status" -eq 1 ]
  [[ $output == *"_template/role.md"* && $output == *"heading"* ]]
}
