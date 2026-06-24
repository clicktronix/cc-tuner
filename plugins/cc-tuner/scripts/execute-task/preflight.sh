#!/usr/bin/env bash
# Preflight before autonomous edits. Branch CREATION is the agent's job (per the
# repo's branch policy); this script does the deterministic, low-freedom parts:
#   1) ensure local-only run artifacts are git-ignored,
#   2) assert a clean working tree (excluding the runs dir),
#   3) open a run-journal recording base SHA / branch / target.
# usage: preflight.sh <run-id> [<target-branch>]
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

RAW="${1:?usage: preflight.sh <run-id> [target-branch]}"
RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"   # strip '/' etc → can't escape RUNS_DIR
[ -n "$RUN_ID" ] || { echo "invalid run-id: '$RAW'" >&2; exit 1; }
TARGET="${2:-}"
RUNS_DIR=".claude/execute-task-runs"

# 1) ignore coverage via the repo's REAL exclude file. git rev-parse --git-path
#    resolves it correctly even in a linked worktree (where .git is a file).
if ! git check-ignore -q "$RUNS_DIR/x" 2>/dev/null; then
  EX="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  if [ -n "$EX" ]; then
    mkdir -p "$(dirname "$EX")"
    grep -qxF "$RUNS_DIR/" "$EX" 2>/dev/null || echo "$RUNS_DIR/" >> "$EX"
  fi
fi

# 2) clean tree (the runs dir itself is excluded from the check)
DIRTY="$(git status --porcelain -uall 2>/dev/null | grep -vF "$RUNS_DIR/" || true)"
if [ -n "$DIRTY" ]; then
  echo "DIRTY working tree — commit/stash first (or allow via branch policy):" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

# 3) open the run-journal with base state
mkdir -p "$RUNS_DIR"
JOURNAL="$RUNS_DIR/$RUN_ID.md"
BASE_SHA="$(git rev-parse HEAD 2>/dev/null || echo '(unborn)')"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(detached)')"
{
  echo "# execute-task run: $RUN_ID"
  echo
  echo "- started: $(date -u +%FT%TZ)"
  echo "- branch: $BRANCH"
  echo "- target: ${TARGET:-?}"
  echo "- base SHA: $BASE_SHA"
  echo
  echo "## log"
} > "$JOURNAL"
echo "$JOURNAL"
