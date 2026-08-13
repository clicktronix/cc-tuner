#!/usr/bin/env bash
# Every command hooks.json registers must actually run the way Claude Code runs it.
#
# This exists because it did not. merge-guard.sh and session-start.sh shipped mode 100644 while
# hooks.json invoked them directly, so both exited 126, permission denied — the merge guard and the
# whole recovery path never ran in a live session. Every other suite passed, because every other
# suite invoked them as `bash "$HOOK"`, which ignores the executable bit.
#
# That is the defect this whole tier was built to prevent, committed inside the tier itself: a test
# that exercises the code by a route the product does not use is testing something the product is not
# doing. So the assertions below execute the registered command string, and nothing here may call
# bash on a hook path.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOKS_JSON="$FLOW_PLUGIN/hooks/hooks.json"

# Every command hooks.json declares, with ${CLAUDE_PLUGIN_ROOT} resolved.
COMMANDS="$(jq -r '.hooks | to_entries[] | .value[].hooks[].command' "$HOOKS_JSON" \
  | sed "s|\"\${CLAUDE_PLUGIN_ROOT}\"|$FLOW_PLUGIN|g; s|\${CLAUDE_PLUGIN_ROOT}|$FLOW_PLUGIN|g")"

n=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  n=$((n + 1))
  script="${cmd%% *}"
  name="$(basename "$script")"

  if [ -f "$script" ]; then pass "exists: $name"; else fail "exists: $name ($script)"; continue; fi
  if [ -x "$script" ]; then pass "executable: $name"; else fail "executable: $name is not chmod +x, so the platform gets rc=126"; fi

  # Run it the way the platform does: the command string, not `bash <path>`. An empty JSON object is
  # a payload every hook here must survive without an error exit.
  out="$(printf '%s' '{}' | eval "$cmd" 2>&1)"; rc=$?
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    fail "runs: $name (rc=$rc — not executable or not found: $out)"
  else
    pass "runs: $name"
  fi
done <<EOF
$COMMANDS
EOF

[ "$n" -gt 0 ] && pass "found $n registered hook commands" \
                || fail "hooks.json declares no commands, so this suite proved nothing"

exit $fails
