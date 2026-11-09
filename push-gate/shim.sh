# shim.sh: sourced (POSIX sh) by the one-line shim that push-gate.sh shim adds to the pre-push
# of a repository whose own core.hooksPath bypasses the global dispatcher. It runs the gate on
# git's pre-push lines, then gives the same lines to the rest of that hook on stdin. A refusal,
# or any failure here, exits the hook with 1.
_pg_gate="$HOME/.local/share/crewkit/gate/push-gate/push-gate.sh"
if [ ! -x "$_pg_gate" ]; then
  echo "push-gate shim: the gate isn't installed at ~/.local/share/crewkit/gate (push-gate.sh install --yes); refusing the push" >&2
  exit 1
fi
_pg_in=$(mktemp) || exit 1
cat > "$_pg_in" || { rm -f "$_pg_in"; exit 1; }
"$_pg_gate" hook "$1" "$2" < "$_pg_in" || { rm -f "$_pg_in"; exit 1; }
exec < "$_pg_in"
rm -f "$_pg_in"
unset _pg_in _pg_gate
