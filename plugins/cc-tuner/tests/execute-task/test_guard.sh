#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/guard-artifacts.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  ( cd "$T" && git init -q && git config user.email a@b.c \
    && git config user.name t && echo x > f && git add f && git commit -qm init \
    && mkdir -p .claude/execute-task-runs && echo j > .claude/execute-task-runs/run1.md ) \
    || { echo "FATAL: fixture setup failed"; exit 1; }
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

# artifact committed THEN deleted -> gone from index/tree, still in HISTORY.
# guard WITH the merge target refuses (a non-squash merge would publish it).
mkrepo
BASE="$(cd "$T" && git rev-parse HEAD)"
( cd "$T" && git add -f .claude/execute-task-runs/run1.md && git commit -qm "add artifact" \
  && git rm -q .claude/execute-task-runs/run1.md && git commit -qm "delete artifact" )
CLAUDE_PROJECT_DIR="$T" bash "$S" "$BASE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && echo "PASS history-artifact" || { echo "FAIL history-artifact (rc=$rc, want 3)"; fails=1; }
# without a base ref, history is not scanned -> same repo passes (exit 0)
CLAUDE_PROJECT_DIR="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && echo "PASS history-needs-base" || { echo "FAIL history-needs-base (rc=$rc, want 0)"; fails=1; }
rm -rf "$T"

# a SUPPLIED but invalid merge target must NOT silently skip the scan -> fail closed (exit 1)
mkrepo
CLAUDE_PROJECT_DIR="$T" bash "$S" definitely-not-a-real-ref >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS invalid-base-fails-closed" || { echo "FAIL invalid-base-fails-closed (rc=$rc, want 1)"; fails=1; }
rm -rf "$T"
exit $fails
