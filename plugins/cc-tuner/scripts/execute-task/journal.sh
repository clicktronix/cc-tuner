#!/usr/bin/env bash
# Append a timestamped entry to a run-journal, or print its path.
# usage: journal.sh append <run-id> <text...>   |   journal.sh path <run-id>
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
RUNS_DIR=".claude/execute-task-runs"
SUB="${1:?usage: journal.sh append|path <run-id> [text]}"
RAW="${2:?run-id required}"
RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"   # SAME sanitize as preflight → same file
[ -n "$RUN_ID" ] || { echo "invalid run-id: '$RAW'" >&2; exit 1; }
JOURNAL="$RUNS_DIR/$RUN_ID.md"
case "$SUB" in
  path) echo "$JOURNAL" ;;
  append)
    shift 2
    [ -f "$JOURNAL" ] || { echo "journal not found: $JOURNAL (run preflight first)" >&2; exit 1; }
    printf -- '- [%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$JOURNAL"
    ;;
  *) echo "unknown subcommand: $SUB (use append|path)" >&2; exit 1 ;;
esac
