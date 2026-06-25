#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
S="$HERE/config-init.sh"
TPL="$(cd "$(dirname "$0")/../../assets/execute-task" && pwd)/config.template.md"
fails=0

T="$(mktemp -d)"; ( cd "$T" && git init -q )
# missing -> created from template, exit EXACTLY 2 (the STOP-and-fill signal)
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ -f "$T/.claude/execute-task.md" ] && grep -q "execute-task config" "$T/.claude/execute-task.md"; then
  echo "PASS scaffold-created"; else echo "FAIL scaffold-created (rc=$rc, want 2)"; fails=1; fi
# present -> left untouched (sentinel preserved), exit EXACTLY 0 (proceed signal)
echo "SENTINEL" > "$T/.claude/execute-task.md"
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "SENTINEL" "$T/.claude/execute-task.md"; } \
  && echo "PASS scaffold-idempotent" || { echo "FAIL scaffold-idempotent (rc=$rc, want 0)"; fails=1; }
rm -rf "$T"
exit $fails
