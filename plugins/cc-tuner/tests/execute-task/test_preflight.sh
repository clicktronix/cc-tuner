#!/usr/bin/env bash
set -u

SCRIPT="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/preflight.sh"
RUNS_REL=".claude/execute-task-runs"
failures=0

make_repo() {
  REPO="$(mktemp -d)" || exit 1
  (
    cd "$REPO" && git init -q -b main && git config user.email test@example.com \
      && git config user.name test && printf 'base\n' > file.txt && git add file.txt \
      && git commit -qm init
  ) || exit 1
}

make_repo
JOURNAL="$(CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" run-1 main)"
SHA="$(cd "$REPO" && git rev-parse HEAD)"
if [ -f "$REPO/$JOURNAL" ] \
  && [ -f "$REPO/$RUNS_REL/run-1.meta" ] \
  && grep -qxF "target_sha=$SHA" "$REPO/$RUNS_REL/run-1.meta" \
  && (cd "$REPO" && git check-ignore -q "$JOURNAL"); then
  echo "PASS clean-preflight"
else
  echo "FAIL clean-preflight"
  failures=1
fi
rm -rf "$REPO"

make_repo
printf 'change\n' >> "$REPO/file.txt"
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" dirty main >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && echo "PASS dirty-blocks" || { echo "FAIL dirty-blocks (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" 'same/id' main >/dev/null 2>&1
slash_rc=$?
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" same-id main >/dev/null 2>&1
plain_rc=$?
if [ "$slash_rc" -eq 1 ] && [ "$plain_rc" -eq 0 ]; then
  echo "PASS colliding-run-id-rejected"
else
  echo "FAIL colliding-run-id-rejected (slash=$slash_rc plain=$plain_rc)"
  failures=1
fi
rm -rf "$REPO"

make_repo
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" shared-run main >/dev/null
(cd "$REPO" && git switch -qc feature)
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" shared-run main >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS cross-branch-reuse-rejected" \
  || { echo "FAIL cross-branch-reuse-rejected (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
WORKTREE_PARENT="$(mktemp -d)" || exit 1
WORKTREE="$WORKTREE_PARENT/wt"
(cd "$REPO" && git worktree add -q "$WORKTREE" -b worktree-branch)
CLAUDE_PROJECT_DIR="$WORKTREE" bash "$SCRIPT" worktree main >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && (cd "$WORKTREE" && git check-ignore -q "$RUNS_REL/worktree.md"); then
  echo "PASS linked-worktree-ignore"
else
  echo "FAIL linked-worktree-ignore (rc=$rc)"
  failures=1
fi
(cd "$REPO" && git worktree remove --force "$WORKTREE" >/dev/null 2>&1)
rm -rf "$WORKTREE_PARENT" "$REPO"

make_repo
OUTSIDE="$(mktemp -d)" || exit 1
ln -s "$OUTSIDE" "$REPO/.claude"
CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPT" symlink main >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] && [ ! -e "$OUTSIDE/execute-task-runs/symlink.md" ]; then
  echo "PASS symlinked-state-rejected"
else
  echo "FAIL symlinked-state-rejected (rc=$rc)"
  failures=1
fi
rm -rf "$OUTSIDE" "$REPO"

NOGIT="$(mktemp -d)" || exit 1
CLAUDE_PROJECT_DIR="$NOGIT" bash "$SCRIPT" bad-root main >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS bad-root" || { echo "FAIL bad-root (rc=$rc)"; failures=1; }
rm -rf "$NOGIT"

UNBORN="$(mktemp -d)" || exit 1
(cd "$UNBORN" && git init -qb main)
JOURNAL="$(CLAUDE_PROJECT_DIR="$UNBORN" bash "$SCRIPT" unborn 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] && grep -qF "base SHA: (unborn)" "$UNBORN/$JOURNAL"; then
  echo "PASS unborn-base"
else
  echo "FAIL unborn-base (rc=$rc)"
  failures=1
fi
rm -rf "$UNBORN"

exit "$failures"
