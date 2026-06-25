#!/usr/bin/env bash
# Pre-outward-facing guard (before CD / merge). Refuse if local-only operational
# artifacts are staged, already tracked, OR present in branch history (which a
# non-squash merge would publish); then print the full change set INCLUDING
# untracked so nothing slips past the review. No git add -A upstream.
# usage: guard-artifacts.sh [<target-ref>]
#   <target-ref> (optional): the merge target. When given, also scan
#   <target-ref>..HEAD history for runs-dir touches (catches add-then-delete).
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }

BASE="${1:-}"
# All local-only operational artifacts (journal, screenshots, raw logs) live under
# this dir. Match it with a git PATHSPEC, not a substring grep, so a real source
# path that merely contains the marker string does not trip the guard.
RUNS_DIR=".claude/execute-task-runs"

# Fail CLOSED: a git query ERROR (bad index, lock) must not be read as "no artifacts".
STAGED_BAD="$(git diff --cached --name-only -- "$RUNS_DIR" 2>/dev/null)" \
  || { echo "execute-task: 'git diff --cached' failed — refusing the outward-facing op" >&2; exit 1; }
TRACKED_BAD="$(git ls-files -- "$RUNS_DIR" 2>/dev/null)" \
  || { echo "execute-task: 'git ls-files' failed — refusing the outward-facing op" >&2; exit 1; }
HIST_BAD=""
if [ -n "$BASE" ]; then
  # A target was supplied → it MUST resolve. A typo'd/missing ref must NOT silently
  # skip the history scan — that would re-open the exact gap this arg exists to close.
  # (Omitting the arg entirely is the intentional "no history scan" path.)
  git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 \
    || { echo "execute-task: merge target '$BASE' is not a valid ref — refusing (cannot scan history)" >&2; exit 1; }
  HIST_BAD="$(git log --format='%h %s' "$BASE..HEAD" -- "$RUNS_DIR" 2>/dev/null)" \
    || { echo "execute-task: 'git log' failed — refusing the outward-facing op" >&2; exit 1; }
fi

if [ -n "$STAGED_BAD" ] || [ -n "$TRACKED_BAD" ] || [ -n "$HIST_BAD" ]; then
  echo "REFUSE: operational artifacts under $RUNS_DIR/ are staged, committed, or in branch history" >&2
  echo "(a non-squash merge would publish them). Unstage/uncommit — or rewrite history first:" >&2
  printf '%s\n' "$STAGED_BAD" "$TRACKED_BAD" "$HIST_BAD" | grep . | sort -u >&2
  exit 3
fi

echo "== change set to review before the outward-facing op (staged + unstaged + untracked) =="
git status --porcelain -uall
