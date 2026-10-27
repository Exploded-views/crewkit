#!/usr/bin/env bash
# coverage-py.sh: line coverage of the plugins' Python tools (plugins/*/bin/*) under coverage.py,
# measured while the bats suites and the Python unit tests run them as subprocesses. Writes
# .cache/coverage-py/report.json in the shape tools/coverage-floors.py reads.
#
#   COVERAGE_VENV=<venv with coverage installed> tools/coverage-py.sh
#
# CI makes the venv and installs coverage.py from tools/requirements-coverage.txt (pinned by
# sha256, --require-hashes) on the hosted runner. The script adds a startup hook (a .pth file) to
# that venv's site-packages, so every Python the suites start from the venv is measured; it
# refuses a venv whose site-packages lies outside it, so it never writes to a system Python.
# Exit 0 = report written, 1 = the suites failed, 2 = usage.
set -euo pipefail
venv=${COVERAGE_VENV:-}
[[ -n $venv && -x $venv/bin/python ]] ||
  { echo "coverage-py: set COVERAGE_VENV to a venv with coverage installed (tools/requirements-coverage.txt)" >&2; exit 2; }
venv=$(cd "$venv" && pwd -P)
root=$(git rev-parse --show-toplevel)
site=$("$venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
site=$(cd "$site" 2>/dev/null && pwd -P) || site=""
[[ -n $site && $site == "$venv"/* ]] ||
  { echo "coverage-py: the venv's site-packages (${site:-unknown}) is not inside $venv; refusing to add a startup hook there" >&2; exit 2; }

out=$root/.cache/coverage-py
rm -rf "$out"
mkdir -p "$out"
printf 'import coverage; coverage.process_startup()\n' > "$site/crewkit-coverage.pth"
cat > "$out/coveragerc" <<EOF
[run]
parallel = True
data_file = $out/.coverage
include = $root/plugins/*/bin/*
EOF
export COVERAGE_PROCESS_START=$out/coveragerc
# The tools' shebang is `#!/usr/bin/env python3`, so the venv first on PATH runs them.
if ! PATH="$venv/bin:$PATH" "$root/tests/run.sh" >"$out/bats.log" 2>&1; then
  grep -E '^(not ok|# )' "$out/bats.log" | head -40 || tail -20 "$out/bats.log"
  echo "coverage-py: the suites failed (full output: ${out#"$root"/}/bats.log)"
  exit 1
fi
# The Python unit tests start some tools themselves (shared-index, with sys.executable), so they
# run with the venv's Python too.
if ! (cd "$root" && "$venv/bin/python" -m unittest discover -s tests -p 'test_*.py') >"$out/unittest.log" 2>&1; then
  tail -20 "$out/unittest.log"
  echo "coverage-py: the unit tests failed (full output: ${out#"$root"/}/unittest.log)"
  exit 1
fi
"$venv/bin/python" -m coverage combine --rcfile "$out/coveragerc" -q
"$venv/bin/python" -m coverage json --rcfile "$out/coveragerc" -o "$out/coverage-py.json" -q
python3 "$root/tools/coverage-py-report.py" "$out/coverage-py.json" "$out/report.json" "$root"
echo "coverage-py report: ${out#"$root"/}/report.json"
python3 - "$out/report.json" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print("  %6s%%  %s" % (f["percent_covered"], f["file"]))
PY
