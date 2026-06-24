#!/usr/bin/env bash
# Pre-outward-facing guard (before CD / merge). Refuse if local-only operational
# artifacts are staged, then print the full change set INCLUDING untracked so
# nothing slips past the review. No git add -A anywhere upstream.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

# One pattern covers ALL local-only operational artifacts: journal, screenshots,
# and raw logs all live under .claude/execute-task-runs/<run-id>/ (see Conventions).
LOCAL_ONLY=".claude/execute-task-runs/"

STAGED="$(git diff --cached --name-only 2>/dev/null || true)"
BAD="$(printf '%s\n' "$STAGED" | grep -F "$LOCAL_ONLY" || true)"
if [ -n "$BAD" ]; then
  echo "REFUSE: operational artifacts are staged — unstage them (no git add -A):" >&2
  printf '%s\n' "$BAD" >&2
  exit 3
fi

echo "== change set to review before the outward-facing op (staged + unstaged + untracked) =="
git status --porcelain -uall
