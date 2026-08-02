#!/usr/bin/env bash
set -u

SCRIPTS="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
GUARD="$SCRIPTS/guard-artifacts.sh"
PREFLIGHT="$SCRIPTS/preflight.sh"
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
CLAUDE_PROJECT_DIR="$REPO" bash "$PREFLIGHT" staged main >/dev/null
(cd "$REPO" && git add -f "$RUNS_REL/staged.md")
CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" staged >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] && echo "PASS staged-artifact-refused" \
  || { echo "FAIL staged-artifact-refused (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
CLAUDE_PROJECT_DIR="$REPO" bash "$PREFLIGHT" history main >/dev/null
(
  cd "$REPO" && git add -f "$RUNS_REL/history.md" \
    && git commit -qm "add local artifact" \
    && git rm -q "$RUNS_REL/history.md" \
    && git commit -qm "remove local artifact"
)
CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" history >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] && echo "PASS history-artifact-refused" \
  || { echo "FAIL history-artifact-refused (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
CLAUDE_PROJECT_DIR="$REPO" bash "$PREFLIGHT" normal main >/dev/null
printf 'change\n' >> "$REPO/file.txt"
CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" normal >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && echo "PASS normal-change-allowed" \
  || { echo "FAIL normal-change-allowed (rc=$rc)"; failures=1; }
rm -rf "$REPO"

make_repo
CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" missing >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && echo "PASS missing-metadata-fails-closed" \
  || { echo "FAIL missing-metadata-fails-closed (rc=$rc)"; failures=1; }
rm -rf "$REPO"

exit "$failures"
