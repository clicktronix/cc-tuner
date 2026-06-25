#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/guard-artifacts.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
    && git config user.name t && echo x > f && git add f && git commit -qm init \
    && mkdir -p .claude/execute-task-runs && echo j > .claude/execute-task-runs/run1.md )
}

# operational artifact staged -> exit exactly 3
mkrepo
( cd "$T" && git add -f .claude/execute-task-runs/run1.md )
CLAUDE_PROJECT_DIR="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && echo "PASS staged-artifact" || { echo "FAIL staged-artifact (rc=$rc, want 3)"; fails=1; }
rm -rf "$T"

# clean staging (only a real source change) -> exit 0 and status shown
mkrepo
( cd "$T" && echo y >> f && git add f )
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" 2>/dev/null)"; rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$OUT" | grep -q " f"; } \
  && echo "PASS clean-staging" || { echo "FAIL clean-staging (rc=$rc)"; fails=1; }
rm -rf "$T"

# already-COMMITTED operational artifact -> exit exactly 3 (catches tracked, not just staged)
mkrepo
( cd "$T" && git add -f .claude/execute-task-runs/run1.md && git commit -qm "oops committed artifact" )
CLAUDE_PROJECT_DIR="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && echo "PASS committed-artifact" || { echo "FAIL committed-artifact (rc=$rc, want 3)"; fails=1; }
rm -rf "$T"

# a real source path that merely CONTAINS the marker substring -> NOT a false refuse (exit 0)
mkrepo
( cd "$T" && mkdir -p src/.claude/execute-task-runs && echo code > src/.claude/execute-task-runs/x.py \
  && git add src/.claude/execute-task-runs/x.py )
CLAUDE_PROJECT_DIR="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && echo "PASS substring-not-false-refuse" || { echo "FAIL substring-not-false-refuse (rc=$rc, want 0)"; fails=1; }
rm -rf "$T"
exit $fails
