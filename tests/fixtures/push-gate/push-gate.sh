#!/usr/bin/env bash
# TEST FIXTURE, not the push gate. A stand-in for crewkit-gate's real push-gate.sh until that
# lands on main; Task 9 extends it. It follows the real interface exactly (the contract is
# docs/push-gate.md#doctor-output on crewkit-gate's branch) and changes nothing on the machine.
#
#   push-gate.sh install [--yes]    a dry run (exit 0, one line) without --yes; with it, exit 0
#                                   and one line, or 78 when PG_DENYLIST_MISSING=1
#   push-gate.sh status --json      {"installed":true|false,"denylist":true|false}, from
#                                   PG_INSTALLED=1 and PG_DENYLIST=1
#   push-gate.sh --doctor           one line per check on stdout, "<check-id> <ok|FAIL> <detail>",
#                                   ids in this order: global-gate dispatcher denylist gitleaks
#                                   root. Exit 0 when all are ok, 1 when any is FAIL, 2 on its own
#                                   error. PG_DOCTOR_FAIL=<id> makes that one check FAIL; PG_DOCTOR_REPO=<path> adds a
#                                   last line "repo:<path> FAIL ..." (and exit 1).
set -euo pipefail

case ${1:-} in
  install)
    # Like the real script: a dry run unless --yes, and 78 when the denylist is missing.
    if [[ ${2:-} != --yes ]]; then echo "push gate: dry run, would install (fixture)"; exit 0; fi
    [[ ${PG_DENYLIST_MISSING:-0} != 1 ]] || { echo "push-gate.sh: denylist missing" >&2; exit 78; }
    echo "push gate: installed (fixture)"
    ;;
  status)
    [[ ${2:-} == --json ]] || { echo "push-gate.sh: status takes --json" >&2; exit 2; }
    printf '{"installed":%s,"denylist":%s}\n' \
      "$([[ ${PG_INSTALLED:-0} == 1 ]] && echo true || echo false)" \
      "$([[ ${PG_DENYLIST:-0} == 1 ]] && echo true || echo false)"
    ;;
  --doctor)
    rc=0
    for id in global-gate dispatcher denylist gitleaks root; do
      if [[ ${PG_DOCTOR_FAIL:-} == "$id" ]]; then
        echo "$id FAIL fixture: $id made to fail"
        rc=1
      else
        echo "$id ok fixture"
      fi
    done
    if [[ -n ${PG_DOCTOR_REPO:-} ]]; then
      echo "repo:$PG_DOCTOR_REPO FAIL fixture: repo made to fail"
      rc=1
    fi
    exit "$rc"
    ;;
  *)
    echo "push-gate.sh: unknown command '${1:-}'" >&2
    exit 2
    ;;
esac
