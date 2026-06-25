#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
J="$DIR/journal.sh"; P="$DIR/preflight.sh"
fails=0

T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
  && git config user.name t && echo x > f && git add f && git commit -qm init )
CLAUDE_PROJECT_DIR="$T" bash "$P" run1 main >/dev/null 2>&1

# path
[ "$(CLAUDE_PROJECT_DIR="$T" bash "$J" path run1)" = ".claude/execute-task-runs/run1.md" ] \
  && echo "PASS path" || { echo "FAIL path"; fails=1; }
# append adds a line
CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 "step 2 APPROVE r3" >/dev/null 2>&1
grep -q "step 2 APPROVE r3" "$T/.claude/execute-task-runs/run1.md" \
  && echo "PASS append" || { echo "FAIL append"; fails=1; }
# append with NO message -> rejected (exit exactly 1), no blank bullet written
before="$(wc -l < "$T/.claude/execute-task-runs/run1.md")"
CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 >/dev/null 2>&1; rc=$?
after="$(wc -l < "$T/.claude/execute-task-runs/run1.md")"
{ [ "$rc" -eq 1 ] && [ "$before" = "$after" ]; } \
  && echo "PASS append-empty-rejected" || { echo "FAIL append-empty-rejected (rc=$rc, lines $before->$after)"; fails=1; }
# append to missing journal -> exit exactly 1
CLAUDE_PROJECT_DIR="$T" bash "$J" append nope "x" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS append-missing" || { echo "FAIL append-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$T"
exit $fails
