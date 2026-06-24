#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/preflight.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)"; ( cd "$T" && git init -q && git config user.email a@b.c \
    && git config user.name t && echo x > f && git add f && git commit -qm init )
}

# clean tree -> journal created with base SHA, runs dir gitignored
mkrepo
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" run1 main 2>/dev/null)"
SHA="$(cd "$T" && git rev-parse HEAD)"
if [ -f "$T/.claude/execute-task-runs/run1.md" ] \
   && grep -qF "$SHA" "$T/.claude/execute-task-runs/run1.md" \
   && ( cd "$T" && git check-ignore -q .claude/execute-task-runs/run1.md ); then
  echo "PASS clean-preflight"; else echo "FAIL clean-preflight"; fails=1; fi
[ "$OUT" = ".claude/execute-task-runs/run1.md" ] \
  && echo "PASS prints-journal-path" || { echo "FAIL prints-journal-path ($OUT)"; fails=1; }
rm -rf "$T"

# dirty tree -> exit exactly 2
mkrepo
echo change >> "$T/f"
CLAUDE_PROJECT_DIR="$T" bash "$S" run2 main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && echo "PASS dirty-blocks" || { echo "FAIL dirty-blocks (rc=$rc, want 2)"; fails=1; }
rm -rf "$T"

# unsafe run-id ('/', '..') -> sanitized, journal stays INSIDE the runs dir
mkrepo
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$S" "DEV-1/../escape" main 2>/dev/null)"
case "$OUT" in .claude/execute-task-runs/*) echo "PASS runid-sanitized" ;; *) echo "FAIL runid-sanitized ($OUT)"; fails=1 ;; esac
{ [ -n "$OUT" ] && [ -f "$T/$OUT" ]; } && echo "PASS runid-file-in-dir" || { echo "FAIL runid-file-in-dir"; fails=1; }
rm -rf "$T"

# linked worktree (.git is a FILE, not a dir) -> ignore-coverage still works
mkrepo
WT="$(mktemp -d)/wt"
( cd "$T" && git worktree add -q "$WT" -b wtbranch >/dev/null 2>&1 )
CLAUDE_PROJECT_DIR="$WT" bash "$S" runwt main >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ( cd "$WT" && git check-ignore -q .claude/execute-task-runs/runwt.md ); } \
  && echo "PASS worktree-ignore" || { echo "FAIL worktree-ignore (rc=$rc)"; fails=1; }
( cd "$T" && git worktree remove --force "$WT" >/dev/null 2>&1 ); rm -rf "$WT" "$T"

# bad CLAUDE_PROJECT_DIR (not a git repo) -> exit 1, never a silent wrong-dir run
NOGIT="$(mktemp -d)"
CLAUDE_PROJECT_DIR="$NOGIT" bash "$S" run3 main >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS bad-root" || { echo "FAIL bad-root (rc=$rc, want 1)"; fails=1; }
rm -rf "$NOGIT"

exit $fails
