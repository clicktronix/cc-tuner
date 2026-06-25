#!/usr/bin/env bash
# Pre-outward-facing guard (before CD / merge). Refuse if local-only operational
# artifacts are staged OR already tracked/committed, then print the full change
# set INCLUDING untracked so nothing slips past the review. No git add -A upstream.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

# All local-only operational artifacts (journal, screenshots, raw logs) live under
# this dir. Match it with a git PATHSPEC, not a substring grep, so a real source
# path that merely contains the marker string does not trip the guard.
RUNS_DIR=".claude/execute-task-runs"

STAGED_BAD="$(git diff --cached --name-only -- "$RUNS_DIR" 2>/dev/null || true)"
TRACKED_BAD="$(git ls-files -- "$RUNS_DIR" 2>/dev/null || true)"
if [ -n "$STAGED_BAD" ] || [ -n "$TRACKED_BAD" ]; then
  echo "REFUSE: operational artifacts are staged or committed under $RUNS_DIR/ — unstage/uncommit them (no git add -A):" >&2
  { [ -n "$STAGED_BAD" ] && printf '%s\n' "$STAGED_BAD"; [ -n "$TRACKED_BAD" ] && printf '%s\n' "$TRACKED_BAD"; } | sort -u >&2
  exit 3
fi

echo "== change set to review before the outward-facing op (staged + unstaged + untracked) =="
git status --porcelain -uall
