#!/usr/bin/env bash
# Preflight before autonomous edits. Branch CREATION is the agent's job (per the
# repo's branch policy); this script does the deterministic, low-freedom parts:
#   1) ensure local-only run artifacts are git-ignored,
#   2) assert a clean working tree (excluding the runs dir),
#   3) open (or, on a re-run, preserve and extend) the run-journal.
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

# 1) ignore coverage. Resolve the repo's REAL exclude file (correct in linked
#    worktrees, where .git is a file). The pattern is anchored to the runs dir's
#    ACTUAL repo-root-relative path (--show-prefix), so it still matches when
#    CLAUDE_PROJECT_DIR is a monorepo subdir. Guarantee a trailing newline first
#    so a no-final-newline exclude file isn't corrupted by concatenation.
if ! git check-ignore -q "$RUNS_DIR/x" 2>/dev/null; then
  EX="$(git rev-parse --git-path info/exclude 2>/dev/null)"
  PREFIX="$(git rev-parse --show-prefix 2>/dev/null)"   # '' at root, 'packages/app/' in a subdir
  PATTERN="/$PREFIX$RUNS_DIR/"
  if [ -n "$EX" ]; then
    mkdir -p "$(dirname "$EX")"
    if ! grep -qxF "$PATTERN" "$EX" 2>/dev/null; then
      [ -s "$EX" ] && [ -n "$(tail -c1 "$EX" 2>/dev/null)" ] && printf '\n' >> "$EX"
      printf '%s\n' "$PATTERN" >> "$EX"
    fi
  fi
fi

# 2) clean tree. Exclude the runs dir with a git PATHSPEC (anchored to the path,
#    NOT a substring) so a real source path that merely contains the marker
#    string is not silently dropped. -unormal: we only need a boolean "dirty?".
DIRTY="$(git status --porcelain -unormal -- . ":(exclude)$RUNS_DIR" 2>/dev/null || true)"
if [ -n "$DIRTY" ]; then
  echo "DIRTY working tree — commit/stash first (or allow via branch policy):" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

# 3) open (re-run: preserve) the run-journal.
mkdir -p "$RUNS_DIR"
JOURNAL="$RUNS_DIR/$RUN_ID.md"
BASE_SHA="$(git rev-parse HEAD 2>/dev/null || echo '(unborn)')"
# symbolic-ref gives the branch name for a normal OR unborn branch, and fails
# (→ '(detached)') only on a true detached HEAD — unlike abbrev-ref, which prints
# 'HEAD' when detached and errors on an unborn branch.
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
if [ -f "$JOURNAL" ]; then
  # Re-run for the same run-id: keep the prior audit trail, mark a restart.
  {
    echo
    echo "## restarted: $(date -u +%FT%TZ)  (branch $BRANCH, base $BASE_SHA)"
  } >> "$JOURNAL"
else
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
fi
echo "$JOURNAL"
