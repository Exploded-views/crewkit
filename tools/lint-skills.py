#!/usr/bin/env python3
"""Lint the plugin layer: skill frontmatter, manifests, eval cases and relative links.

Stdlib only, so it runs in CI and in a pre-commit hook without installs.
Exit 0 = clean (warnings allowed), 1 = errors.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(subprocess.run(
    ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
).stdout.strip())
KEBAB = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
RESERVED_PREFIX = ("claude-", "anthropic-", "anthropics-", "cc-plugin-")
MAX_DESC = 1024          # stricter than Claude Code's listing limit, matches the Agent Skills spec
WARN_LINES, MAX_LINES = 150, 175
PLACEHOLDER_LINKS = ("PLAYBOOK_LESSONS_URL",)

errors, warnings = [], []


def err(path, msg):
    errors.append(f"{path.relative_to(ROOT)}: {msg}")


def warn(path, msg):
    warnings.append(f"{path.relative_to(ROOT)}: {msg}")


def frontmatter(path):
    """Parse the small YAML subset skills use: `key: value` and `key: >-` folded blocks."""
    lines = path.read_text(encoding="utf-8").split("\n")
    if not lines or lines[0] != "---":
        err(path, "frontmatter must start on line 1 with ---")
        return {}, lines
    try:
        end = lines.index("---", 1)
    except ValueError:
        err(path, "frontmatter is not closed with ---")
        return {}, lines
    fm, key = {}, None
    for raw in lines[1:end]:
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", raw)
        if m:
            key, val = m.group(1), m.group(2).strip()
            fm[key] = "" if val in (">-", ">", "|", "|-") else val.strip("'\"")
        elif key and raw.startswith("  "):
            fm[key] = (fm[key] + " " + raw.strip()).strip()
        elif raw.strip():
            err(path, f"unparseable frontmatter line: {raw[:40]!r}")
    return fm, lines[end + 1:]


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        err(path, f"invalid JSON ({e.__class__.__name__})")
        return None


def check_skill(skill_md):
    fm, body = frontmatter(skill_md)
    name, desc = fm.get("name", ""), fm.get("description", "")
    if not name:
        err(skill_md, "missing name")
    elif name != skill_md.parent.name:
        err(skill_md, f"name {name!r} != directory {skill_md.parent.name!r}")
    elif not KEBAB.match(name) or len(name) > 64:
        err(skill_md, "name must be kebab-case, at most 64 characters")
    if not desc:
        err(skill_md, "missing description")
    elif len(desc) > MAX_DESC:
        err(skill_md, f"description is {len(desc)} characters (max {MAX_DESC})")
    elif not re.search(r"\bUse (this|when)\b", desc):
        warn(skill_md, "description should say when to use the skill ('Use this when ...')")
    if not any(line.startswith("# ") for line in body):
        err(skill_md, "body has no top-level heading")
    total = len(skill_md.read_text(encoding="utf-8").rstrip("\n").split("\n"))
    if total > MAX_LINES:
        err(skill_md, f"{total} lines (max {MAX_LINES})")
    elif total > WARN_LINES:
        warn(skill_md, f"{total} lines (aim for under {WARN_LINES})")


def check_hooks(path):
    """Every hook entry needs a command, and plugin-relative paths must exist."""
    data = load_json(path)
    if not data:
        return
    for event, groups in data.get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                cmd = hook.get("command", "")
                if hook.get("type") != "command" or not cmd:
                    err(path, f"{event}: each hook needs type command and a command")
                for rel in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\"' ]+)", cmd):
                    if not (path.parent.parent / rel).exists():
                        err(path, f"{event}: {rel} not found in the plugin")


def check_plugin(pdir):
    manifest = pdir / ".claude-plugin" / "plugin.json"
    data = load_json(manifest) if manifest.exists() else None
    if data is None:
        if not manifest.exists():
            err(pdir, "missing .claude-plugin/plugin.json")
        return None
    name = data.get("name", "")
    if not KEBAB.match(name) or name.startswith(RESERVED_PREFIX):
        err(manifest, "name must be kebab-case and not use a reserved prefix")
    skills = sorted((pdir / "skills").glob("*/SKILL.md"))
    hooks = pdir / "hooks" / "hooks.json"
    if hooks.exists():
        check_hooks(hooks)
    if not skills and not hooks.exists():
        err(pdir, "no skills/<name>/SKILL.md or hooks/hooks.json found")
    for s in skills:
        check_skill(s)
    return name


def check_marketplace(plugin_names):
    mp = ROOT / ".claude-plugin" / "marketplace.json"
    data = load_json(mp)
    if not data:
        return
    for field in ("name", "owner", "plugins"):
        if field not in data:
            err(mp, f"missing {field}")
    if not KEBAB.match(data.get("name", "")):
        err(mp, "marketplace name should be kebab-case")
    if not isinstance(data.get("owner"), dict) or not data["owner"].get("name"):
        err(mp, "owner.name is required")
    listed = set()
    for entry in data.get("plugins", []):
        src, name = entry.get("source"), entry.get("name")
        listed.add(name)
        if isinstance(src, str):
            if not src.startswith("./") or ".." in src:
                err(mp, f"{name}: relative source must start with ./ and not use ..")
                continue
            if plugin_names.get((ROOT / src).resolve()) != name:
                err(mp, f"{name}: source {src} missing or its plugin.json name differs")
    for path, name in plugin_names.items():
        if name and name not in listed:
            err(mp, f"plugin {name} ({path.relative_to(ROOT)}) is not listed")


def check_evals():
    path = ROOT / "evals" / "cases.json"
    data = load_json(path)
    if not data:
        return
    skills = {p.parent.name for p in ROOT.glob("plugins/*/skills/*/SKILL.md")}
    seen = set()
    for case in data.get("cases", []):
        cid = case.get("id", "?")
        if cid in seen:
            err(path, f"duplicate id {cid}")
        seen.add(cid)
        for field in ("skill", "prompt", "must", "must_not"):
            if not case.get(field):
                err(path, f"{cid}: missing {field}")
        if case.get("skill") and case["skill"] not in skills:
            err(path, f"{cid}: unknown skill {case['skill']}")


ALL_TARGETS = [f"{o}_{a}" for o in ("linux", "darwin") for a in ("amd64", "arm64")]
PIN_TARGETS = {}  # tools not listed ship all four targets (bitc does since v0.1.0)


def check_pins():
    """pins/<tool>.env, read the way install.sh reads it.

    Unpinned is TAG=TODO with a blank URL and no hashes set. Pinned is an https URL with a
    host, vX.Y.Z, and a 64-hex sha256 for every target that tool ships. No duplicate keys, no
    CR line endings, no keys outside the tool's prefix.
    """
    for path in sorted((ROOT / "pins").glob("*.env")):
        text = path.read_bytes().decode("utf-8")
        if "\r" in text:
            err(path, "CR line endings (install.sh would misread the values); use LF")
            continue
        values = {}
        for raw in text.split("\n"):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            m = re.match(r"^([A-Z][A-Z0-9_]*_(URL|TAG|SHA256_(linux|darwin)_(amd64|arm64)))=(.*)$", raw)
            if not m:
                err(path, f"unexpected line: {raw[:40]!r} (only *_URL, *_TAG, *_SHA256_<os>_<arch>)")
                continue
            if m.group(1) in values:
                err(path, f"duplicate key {m.group(1)} (install.sh would use the last one)")
            values[m.group(1)] = m.group(5)
        tags = [k for k in values if k.endswith("_TAG")]
        if len(tags) != 1:
            err(path, "needs exactly one *_TAG")
            continue
        prefix, tag = tags[0][:-4], values[tags[0]]
        if any(not k.startswith(f"{prefix}_") for k in values):
            err(path, f"every key must start with {prefix}_")
        url = values.get(f"{prefix}_URL")
        shas = {k: v for k, v in values.items() if k.startswith(f"{prefix}_SHA256_")}
        if url is None:
            err(path, f"missing {prefix}_URL")
        if tag == "TODO":
            for k, v in [(f"{prefix}_URL", url or "")] + list(shas.items()):
                if v:
                    err(path, f"{k} is set but the tag is TODO")
            continue
        if not re.match(r"^v\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$", tag, re.ASCII):
            err(path, f"{tags[0]} must be vMAJOR.MINOR.PATCH or TODO")
        if url is not None and not re.match(r"^https://[A-Za-z0-9.-]+/[A-Za-z0-9./_-]+$", url, re.ASCII):
            err(path, f"{prefix}_URL must be an https URL with a host")
        for target in PIN_TARGETS.get(path.stem, ALL_TARGETS):
            if f"{prefix}_SHA256_{target}" not in shas:
                err(path, f"missing {prefix}_SHA256_{target}")
        for k, v in shas.items():
            if not re.match(r"^[0-9a-f]{64}$", v, re.ASCII):
                err(path, f"{k} must be a 64-character sha256")


SETUP_PAGES = ["README.md", "docs/install.md", "docs/getting-started.md"]
SHELL_LANGS = {"bash", "sh", "shell", "console", "zsh"}
PLACEHOLDER = re.compile(r"<[a-z][a-z0-9 ./_-]*>")
INPUT_BULLET = re.compile(r"^- `([A-Z][A-Z0-9_]*)` = `(\$HOME/)?(<[a-z][a-z0-9 ./_-]*>)`(.*)$")
PATH_WORDS = re.compile(r"\b(path|dir|directory|folder|clone)\b")
LONG_LITERAL = re.compile(r"\b[0-9a-f]{40,}\b|[A-Za-z0-9+/_=-]{48,}")


def check_inputs(pages=SETUP_PAGES):
    """Inputs first, DRY: the setup pages others follow by hand.

    - A `<placeholder>` in a shell block needs an `## Inputs` bullet
      "- `NAME` = `<placeholder>`" with a description (same line after ":", or the next line),
      and may appear in shell blocks only as its own `NAME="<placeholder>"` line (quoted);
      steps use $NAME.
    - Every input is used as $NAME in some shell block.
    - No bare /path/to/ or OWNER in shell blocks: make them inputs.
    - A long literal (a SHA, a key) appears at most once on the page, and no command line is
      repeated across shell blocks (define it once, vary the flag).
    `text` blocks (format illustrations) are exempt from the placeholder rules.
    """
    for rel in pages:
        path = ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        blocks, inputs, assign, in_inputs, i = [], {}, {}, False, 0
        while i < len(lines):
            line = lines[i]
            fence = re.match(r"^```(\w*)", line)
            if fence:
                lang, body = fence.group(1).lower(), []
                i += 1
                while i < len(lines) and not lines[i].startswith("```"):
                    body.append(lines[i])
                    i += 1
                blocks.append((lang, body))
            elif re.match(r"^#{1,6} ", line):
                in_inputs = re.match(r"^#{2,4} Inputs$", line.strip()) is not None
            elif in_inputs and line.startswith("- "):
                m = INPUT_BULLET.match(line)
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                desc = (m.group(4).lstrip(" :—-").strip() if m else "") or (nxt.strip() if nxt.startswith("  ") else "")
                if not m or not desc:
                    err(path, f"Inputs bullet must have the format \"- `NAME` = `<placeholder>`: description\": {line[:50]!r}")
                else:
                    name, home, ph = m.group(1), m.group(2) or "", m.group(3)
                    inputs[ph] = name
                    assign[ph] = f'{name}="{home}{ph}"'
                    if not home and PATH_WORDS.search(ph):
                        err(path, f'{name} is a path: write it as `$HOME/{ph}` and assign {name}="$HOME/{ph}"'
                                  " (a ~ inside quotes is not expanded)")
            i += 1
        shell = [b for lang, b in blocks if lang in SHELL_LANGS]
        used = set()
        for body in shell:
            for line in body:
                used.update(re.findall(r"\$\{?([A-Z][A-Z0-9_]*)", line))
                if "/path/to/" in line or re.search(r"\bOWNER\b", line):
                    err(path, f"shell block uses a bare /path/to/ or OWNER; declare it in ## Inputs: {line.strip()[:50]!r}")
                for ph in PLACEHOLDER.findall(line):
                    if not inputs and not re.search(r"^#{2,4} Inputs$", text, re.M):
                        err(path, f"{ph} in a shell block, but the page has no ## Inputs section")
                    elif ph not in inputs:
                        err(path, f"{ph} in a shell block is not declared in ## Inputs")
                    elif line.strip() == assign[ph].replace('"', ""):
                        err(path, f"quote the assignment: {assign[ph]} (a value with spaces breaks it)")
                    elif line.strip() != assign[ph]:
                        err(path, f"{ph} appears outside its assignment ({assign[ph]}); use ${inputs[ph]} in steps")
        for ph, name in inputs.items():
            if name not in used:
                err(path, f"input {name} is never used as ${name} in a shell block")
        seen = {}
        for lit in LONG_LITERAL.findall(text):
            seen[lit] = seen.get(lit, 0) + 1
        for lit, n in seen.items():
            if n > 1:
                err(path, f"a long literal ({lit[:8]}…) appears more than once ({n} times); set it once in a named variable")
        counts = {}
        for body in shell:
            for line in body:
                s = line.strip()
                if len(s) >= 20 and not s.startswith("#") and not re.match(r"^[A-Z][A-Z0-9_]*=", s):
                    counts[s] = counts.get(s, 0) + 1
        for s, n in counts.items():
            if n > 1:
                err(path, f"command repeated {n} times across shell blocks; define it once: {s[:50]!r}")


def settings_schema():
    """Documented keys from docs/settings.md, as regexes (`<name>` matches one dotted part)."""
    path = ROOT / "docs" / "settings.md"
    if not path.exists():
        return None
    keys = re.findall(r"^\| `([a-z0-9_.<>-]+)` \|", path.read_text(encoding="utf-8"), re.M)
    return [re.compile("^" + re.sub(r"<[a-z_]+>", "[a-z0-9_-]+", re.escape(k).replace(r"\<", "<").replace(r"\>", ">")) + "$")
            for k in keys]


RETIRED_KEYS = {  # key: what replaces it
    "log_dir": "state_dir", "decisions_log": "state_dir (decisions.md inside it)",
    "state_file": "state_dir (state.md inside it)",
}


def settings_lists():
    """lib/settings.sh's CREW_FILE_ONLY and CREW_ENV_OK as lists of entries (None if undeclared)."""
    text = (ROOT / "lib" / "settings.sh").read_text(encoding="utf-8")
    lists = {}
    for name in ("CREW_FILE_ONLY", "CREW_ENV_OK"):
        m = re.search(name + r"='([^']*)'", text, re.S)
        if not m:
            return None
        lists[name] = m.group(1).split()
    return lists


def env_ok_only_by_prefix(lists, key):
    """True if KEY takes CREWKIT_* only because an env-OK prefix covers it (no exact entry, and
    no file-only prefix at least as long)."""
    if key in lists["CREW_FILE_ONLY"] or key in lists["CREW_ENV_OK"]:
        return False
    best = lambda entries: max((len(e) for e in entries if e.endswith(".*") and key.startswith(e[:-1])), default=0)
    return best(lists["CREW_ENV_OK"]) > best(lists["CREW_FILE_ONLY"])


def check_settings_classified(rows):
    """Every documented key is in exactly one of lib/settings.sh's CREW_FILE_ONLY and CREW_ENV_OK
    (exact entry first, then the longest prefix), and every entry names a documented key. A
    CREW_ENV_OK prefix may only decide placeholder families whose row says "Never gates a merge";
    any other key it covers must be listed exactly, so a new key can't skip classification."""
    keys = list(rows)
    lists = settings_lists()
    if lists is None:
        err(ROOT / "lib" / "settings.sh", "CREW_FILE_ONLY and CREW_ENV_OK must both be declared; every setting must be classified")
        return
    def best(entries, key):
        if key in entries:
            return 10_000
        return max((len(e) for e in entries if e.endswith(".*") and key.startswith(e[:-1])), default=0)
    for key in keys:
        sample = re.sub(r"<[a-z_]+>", "x", key)
        f, e = best(lists["CREW_FILE_ONLY"], sample), best(lists["CREW_ENV_OK"], sample)
        if not f and not e:
            err(ROOT / "docs" / "settings.md", f"setting `{key}` is in neither CREW_FILE_ONLY nor CREW_ENV_OK "
                                               "(lib/settings.sh); a gate setting is file-only")
        elif f == e:
            err(ROOT / "lib" / "settings.sh", f"setting `{key}` matches both CREW_FILE_ONLY and CREW_ENV_OK equally")
    for entry in (e for e in lists["CREW_ENV_OK"] if e.endswith(".*")):
        for key in keys:
            sample = re.sub(r"<[a-z_]+>", "x", key)
            if not sample.startswith(entry[:-1]) or sample in lists["CREW_FILE_ONLY"] + lists["CREW_ENV_OK"]:
                continue
            if "<" not in key:
                err(ROOT / "lib" / "settings.sh", f"setting `{key}` is only covered by the env-OK prefix `{entry}`; "
                                                   "list it exactly in CREW_FILE_ONLY or CREW_ENV_OK")
            elif "Never gates a merge" not in rows[key]:
                err(ROOT / "docs" / "settings.md", f"CREW_ENV_OK prefix `{entry}` covers `{key}`, whose row doesn't say "
                                                    "\"Never gates a merge\"; list its keys exactly instead")
    samples = [re.sub(r"<[a-z_]+>", "x", k) for k in keys]
    for name, entries in lists.items():
        for entry in entries:
            if not any(s == entry or (entry.endswith(".*") and s.startswith(entry[:-1])) for s in samples):
                err(ROOT / "lib" / "settings.sh", f"{name} entry `{entry}` matches no key in docs/settings.md")


def check_settings():
    """docs/settings.md is the schema: every key read or set must be documented there, and every
    plugin's vendored lib/settings.sh must be the canonical one, byte for byte."""
    schema = settings_schema()
    canonical = ROOT / "lib" / "settings.sh"
    if schema is None or not canonical.exists():
        return
    documented = lambda key: any(r.match(key) for r in schema)
    doc = (ROOT / "docs" / "settings.md").read_text(encoding="utf-8")
    rows = dict(re.findall(r"^\| `([^`]+)` \|(.*)$", doc, re.M))
    check_settings_classified(rows)
    lists = settings_lists()
    for path in sorted(ROOT.glob("plugins/*/**/*")):
        if not path.is_file():
            continue
        if path.parent.name == "lib" and path.parent.parent.parent.name == "plugins":
            # A file named like one in the repo's lib/ is a vendored copy and must match it byte
            # for byte; any other file is the plugin's own code and is left alone.
            source = ROOT / "lib" / path.name
            if source.exists() and path.read_bytes() != source.read_bytes():
                err(path, f"differs from lib/{path.name}; copy the canonical one (tools/vendor-lib.sh)")
            if source.exists():
                continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for old, new in RETIRED_KEYS.items():
            if re.search(r"\b" + old + r"\b", text):
                err(path, f"`{old}` is a retired setting; use {new}")
        for n, line in enumerate(text.splitlines(), 1):
            for m in re.finditer(r"crew_(?:setting|require|keys)\s+([^\s);|&]+)", line):
                token = m.group(1).strip("'\"")
                if re.fullmatch(r"[a-z0-9_.-]+", token):
                    keys = [] if token.endswith(".") else [token]
                else:
                    # Not a literal (a variable or a wrapper's "$1"): the line must name the keys
                    # it can read, so the lint can still check them.
                    tag = re.search(r"#\s*settings-keys:\s*(.+)$", line)
                    if not tag:
                        err(path, f"line {n}: setting key {m.group(1)} is not a literal; add "
                                  "`# settings-keys: <key> ...` naming the keys it reads")
                        continue
                    keys = [re.sub(r"<[a-z_]+>", "x", k) for k in tag.group(1).split()]
                for key in keys:
                    if not documented(key):
                        err(path, f"setting `{key}` is not documented in docs/settings.md")
                    elif lists and key not in rows and env_ok_only_by_prefix(lists, key):
                        err(path, f"line {n}: setting `{key}` takes CREWKIT_* only through an env-OK prefix; "
                                  "give it its own row in docs/settings.md and classify it exactly")
        if path.name.startswith("crewkit") and path.suffix == ".md":
            m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
            for line in (m.group(1).splitlines() if m else []):
                km = re.match(r"^([a-z0-9_.-]+):", line)
                if km and not documented(km.group(1)):
                    err(path, f"setting `{km.group(1)}` is not documented in docs/settings.md")


def check_links():
    tracked = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    for rel in tracked:
        path = ROOT / rel
        if not path.exists():
            continue
        text = re.sub(r"```.*?```", "", path.read_text(encoding="utf-8"), flags=re.S)
        for target in re.findall(r"\]\(([^)\s]+)\)", text):
            if re.match(r"^[a-z]+:", target) or target.startswith("#") or target.startswith(PLACEHOLDER_LINKS):
                continue
            if not (path.parent / target.split("#", 1)[0]).exists():
                err(path, f"broken relative link: {target}")


def check_mutant_matrix():
    """CI runs every mutation spec: each tests/mutants/*.json is listed in the `spec` matrix of
    ci.yml's `mutants` job, and every listed spec exists."""
    specs = {p.name for p in (ROOT / "tests" / "mutants").glob("*.json")}
    ci = ROOT / ".github" / "workflows" / "ci.yml"
    if not specs:
        return
    listed, job, in_spec = set(), None, False
    for line in (ci.read_text(encoding="utf-8").splitlines() if ci.exists() else []):
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            job, in_spec = m.group(1), False
            continue
        if job != "mutants":
            continue
        if re.match(r"^\s+spec:\s*$", line):
            in_spec = True
            continue
        item = re.match(r"^\s+-\s+([A-Za-z0-9_.-]+\.json)\s*$", line)
        if in_spec and item:
            listed.add(item.group(1))
        elif in_spec and line.strip():
            in_spec = False
    for name in sorted(specs - listed):
        err(ci, f"tests/mutants/{name} is not in the `mutants` job's spec matrix, so CI never runs it")
    for name in sorted(listed - specs):
        err(ci, f"the `mutants` job lists {name}, but tests/mutants/{name} does not exist")


def check_mutant_suites():
    """A bats suite in a mutation spec runs with --abort: a killed mutant then stops at its first
    failing test instead of running the whole suite, which keeps each CI matrix job in time."""
    for spec in sorted((ROOT / "tests" / "mutants").glob("*.json")):
        try:
            suite = json.loads(spec.read_text(encoding="utf-8")).get("suite")
        except (OSError, ValueError, AttributeError):
            err(spec, "not a readable mutation spec (JSON object with target, suite, mutants)")
            continue
        if isinstance(suite, list) and suite[:1] == ["bats"] and "--abort" not in suite[1:]:
            err(spec, "its bats suite has no --abort, so every killed mutant runs the whole suite")


def check_mutants_apply():
    """Every mutant's old text occurs exactly once in its target (what tools/mutate.py needs), so
    an edit to a guarded line that breaks its mutant fails the lint instead of a mutation run."""
    for spec in sorted((ROOT / "tests" / "mutants").glob("*.json")):
        try:
            d = json.loads(spec.read_text(encoding="utf-8"))
            target = ROOT / d["target"]
        except (OSError, ValueError, KeyError, TypeError):
            continue  # check_mutant_suites reports an unreadable spec
        if not target.is_file():
            err(spec, f"its target {d['target']} does not exist")
            continue
        text = target.read_text(encoding="utf-8")
        for m in d.get("mutants", []):
            n = text.count(m.get("old", ""))
            if n != 1:
                err(spec, f"mutant {m.get('name')!r}: its old text occurs {n} times in {d['target']}, not once")


def check_ci_ok():
    """ci.yml's ci-ok job (main's ruleset requires a check named ci-ok) is named ci-ok, runs
    `if: always()`, and needs every other job and nothing else, so a new job can't skip it."""
    ci = ROOT / ".github" / "workflows" / "ci.yml"
    if not ci.exists():
        return
    jobs, current, block, in_jobs = {}, None, None, False
    for line in ci.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\S", line):
            in_jobs, current = line.rstrip() == "jobs:", None
            continue
        if not in_jobs:
            continue
        if re.match(r"^  \S", line) and not line.lstrip().startswith("#"):
            # A job key, maybe quoted, maybe with a trailing comment; anything else at this indent
            # (an anchor, a flow mapping) is a line the lint can't follow, and fails rather than
            # letting a job escape ci-ok.
            m = re.match(r"""^  (["']?)([A-Za-z0-9_-]+)\1:\s*(#.*)?$""", line)
            if not m:
                err(ci, f"can't follow the job line {line.strip()!r} under jobs:; write it as `  <job-id>:`")
                current = None
                continue
            current, block = m.group(2), None
            jobs[current] = {"name": None, "if": None, "needs": []}
            continue
        if current is None or not line.startswith("    "):
            continue
        if block == "needs":
            item = re.match(r"^      - ([A-Za-z0-9_-]+)\s*$", line)
            if item:
                jobs[current]["needs"].append(item.group(1))
                continue
            block = None
        m = re.match(r"^    (name|if|needs):\s*(.*?)\s*$", line)
        if not m:
            continue
        key, value = m.groups()
        if key == "needs" and not value:
            block = "needs"
        elif key == "needs":
            jobs[current]["needs"] = [v.strip() for v in value.strip("[]").split(",") if v.strip()]
        else:
            jobs[current][key] = value.strip("'\"")
    if "ci-ok" not in jobs:
        err(ci, "no ci-ok job: main's ruleset requires a check named ci-ok that needs every other job")
        return
    job = jobs["ci-ok"]
    if job["name"] != "ci-ok":
        err(ci, f"the ci-ok job's name is {job['name']!r}; the required check is named ci-ok")
    if job["if"] != "always()":
        err(ci, "the ci-ok job must run `if: always()`, or a failed job would skip it instead of failing it")
    others = set(jobs) - {"ci-ok"}
    for name in sorted(others - set(job["needs"])):
        err(ci, f"job {name} is not in ci-ok's needs, so the required check doesn't wait for it")
    for name in sorted(set(job["needs"]) - others):
        err(ci, f"ci-ok needs {name}, which is not a job")


def check_scrub_known_version():
    """tools/scrub.sh's current blob SHA is in tools/scrub-known-versions.txt: the history scan
    exempts only listed (reviewed) versions of the script from its own rules."""
    scrub, listing = ROOT / "tools" / "scrub.sh", ROOT / "tools" / "scrub-known-versions.txt"
    if not scrub.exists():
        return
    sha = subprocess.run(["git", "hash-object", str(scrub)], capture_output=True, text=True).stdout.strip()
    listed = set(re.findall(r"^[0-9a-f]{40}", listing.read_text(encoding="utf-8"), re.M)) if listing.exists() else set()
    if sha not in listed:
        err(listing, f"tools/scrub.sh's blob {sha[:12]} isn't listed; review the change and add `git hash-object tools/scrub.sh`")


def check_conflict_markers():
    """No merge left its conflict markers in a tracked file. A <<<<<<< or >>>>>>> line always
    counts; a ======= line counts only in a file that has one of those, since alone it is also a
    Markdown heading underline. tools/conflict-markers-allowed.txt lists fixtures that need
    markers (one path per line, # for comments); an entry for a file that doesn't exist fails."""
    allow_file = ROOT / "tools" / "conflict-markers-allowed.txt"
    allowed = set()
    if allow_file.exists():
        for line in allow_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                allowed.add(line)
                if not (ROOT / line).is_file():
                    err(allow_file, f"allows {line}, which doesn't exist")
    edge = re.compile(r"^(<<<<<<<|>>>>>>>)( |$)")
    middle = re.compile(r"^=======( |$)")
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    for rel in sorted(filter(None, tracked.decode("utf-8", "surrogateescape").split("\0"))):
        path = ROOT / rel
        if rel in allowed or not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue   # binary files carry no text markers
        if not any(edge.match(line) for line in lines):
            continue
        for n, line in enumerate(lines, 1):
            if edge.match(line) or middle.match(line):
                err(path, f"conflict marker at line {n}; resolve the merge")


def main():
    plugin_names = {}
    for pdir in sorted((ROOT / "plugins").iterdir()):
        if pdir.is_dir():
            plugin_names[pdir.resolve()] = check_plugin(pdir)
    check_marketplace(plugin_names)
    check_evals()
    check_pins()
    check_inputs()
    check_settings()
    check_mutant_matrix()
    check_mutant_suites()
    check_mutants_apply()
    check_ci_ok()
    check_scrub_known_version()
    check_conflict_markers()
    check_links()
    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    n_skills = len(list(ROOT.glob("plugins/*/skills/*/SKILL.md")))
    print(f"lint-skills: {n_skills} skills, {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
