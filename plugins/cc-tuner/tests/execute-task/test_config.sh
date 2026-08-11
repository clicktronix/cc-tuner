#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
S="$HERE/config-init.sh"
TPL="$(cd "$(dirname "$0")/../../assets/execute-task" && pwd)/config.template.md"
fails=0

T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
( cd "$T" && git init -q ) || { echo "FATAL: fixture setup failed"; exit 1; }
# missing -> created from template, exit EXACTLY 2 (the STOP-and-fill signal)
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
# Assert on a FIELD, not the title: a title is prose and gets reworded, while the command fields are
# the thing the file exists to carry, so this pins that the scaffold really came from the template.
# Every field asserted here must still be READ by /run — a field no consumer reads is the drift this
# suite exists to catch, and `cheap_gate` reached exactly that state before it was removed.
if [ "$rc" -eq 2 ] && [ -f "$T/.claude/execute-task.md" ] \
  && grep -q "target_test" "$T/.claude/execute-task.md" \
  && grep -q "full_test" "$T/.claude/execute-task.md" \
  && ! find "$T/.claude" -name '.execute-task.*' -print -quit | grep -q .; then
  echo "PASS scaffold-created"; else echo "FAIL scaffold-created (rc=$rc, want 2)"; fails=1; fi
# present -> left untouched (sentinel preserved), exit EXACTLY 0 (proceed signal)
echo "SENTINEL" > "$T/.claude/execute-task.md"
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "SENTINEL" "$T/.claude/execute-task.md"; } \
  && echo "PASS scaffold-idempotent" || { echo "FAIL scaffold-idempotent (rc=$rc, want 0)"; fails=1; }

VICTIM="$T/victim"
printf 'UNCHANGED\n' > "$VICTIM"
rm "$T/.claude/execute-task.md"
ln -s "$VICTIM" "$T/.claude/execute-task.md"
CLAUDE_PROJECT_DIR="$T" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && grep -qx "UNCHANGED" "$VICTIM"; } \
  && echo "PASS scaffold-symlink-rejected" || { echo "FAIL scaffold-symlink-rejected (rc=$rc)"; fails=1; }

T_SYMLINK_DIR="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
OUTSIDE_DIR="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
( cd "$T_SYMLINK_DIR" && git init -q && ln -s "$OUTSIDE_DIR" .claude ) \
  || { echo "FATAL: symlink fixture setup failed"; exit 1; }
CLAUDE_PROJECT_DIR="$T_SYMLINK_DIR" bash "$S" "$TPL" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && [ ! -e "$OUTSIDE_DIR/execute-task.md" ]; } \
  && echo "PASS scaffold-directory-symlink-rejected" \
  || { echo "FAIL scaffold-directory-symlink-rejected (rc=$rc)"; fails=1; }

rm -rf "$T"
rm -rf "$T_SYMLINK_DIR"
rm -rf "$OUTSIDE_DIR"
exit $fails
