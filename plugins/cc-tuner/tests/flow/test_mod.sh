#!/usr/bin/env bash
# The hooks module hooks/hooks.json names under "modules" (hooks/register.ts) runs inside Claude Code,
# not as a command, so the only honest test is the engine's own: `claude plugin validate` reads the
# module the way a session loads it, and `claude plugin test` runs hooks/*.test.ts against the real
# hook chain. Neither needs a signed-in account. A missing `claude` fails instead of skipping: a
# suite that passes when it could not run is the gap tests/run.sh exists to close.
# Neither command type-checks. The engine writes the module API types and a tsconfig into
# .claude-plugin/types/ only when an interactive session loads the plugin from a folder
# (`claude --plugin-dir`); `validate`, `test` and CI never do, and the generated declarations are
# Claude Code's, not ours to commit. So tsc runs where those types exist, a developer's machine
# after such a load, and elsewhere the run says plainly that no type check happened.
# tests/flow/CLAUDE_CODE_VERSION is the one place the Claude Code version is pinned; CI installs it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is not on PATH; install @anthropic-ai/claude-code to test hooks/register.ts"
  exit $fails
fi

modules="$(jq -r '.modules // [] | .[]' "$FLOW_PLUGIN/hooks/hooks.json")"
check "hooks.json names the module" "./register.ts" "$modules"

out="$(claude plugin validate "$FLOW_PLUGIN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "plugin validates"; else fail "plugin validate rc=$rc: $(printf '%s' "$out" | grep -E '✘|❯' | head -5)"; fi
check "module hooks Bash and TaskStop calls and session end" "hooks: tool.call{tool=Bash}, tool.call{tool=TaskStop}, session.end" "$out"

out="$(cd "$FLOW_PLUGIN" && claude plugin test . 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "module tests pass"; else fail "plugin test rc=$rc: $(printf '%s' "$out" | grep -E '\(fail\)|error' | head -5)"; fi
absent "no module test failed" "(fail)" "$out"

tsconfig="$FLOW_PLUGIN/.claude-plugin/types/tsconfig.json"
if [ ! -f "$tsconfig" ]; then
  printf 'NOTE type check not run: no engine-written types (load the plugin once with claude --plugin-dir)\n'
else
  out="$(npx -y -p typescript@5.6.3 tsc -p "$tsconfig" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "hooks module type-checks"; else fail "tsc rc=$rc: $(printf '%s' "$out" | head -5)"; fi
fi

pass "tested with claude $(claude --version 2>&1 | head -1) (pinned $(cat "$FLOW_LIB_DIR/CLAUDE_CODE_VERSION"))"

exit $fails
