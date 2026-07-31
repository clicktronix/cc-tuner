#!/usr/bin/env bash
# Read or write a run-journal.
#
# usage: journal.sh append <run-id> <text...>   append a timestamped entry
#        journal.sh path   <run-id>             print the journal path
#        journal.sh read   <run-id>             print the whole journal
#        journal.sh resume <run-id> [n]         print the header + last n log lines (default 20)
#
# `read`/`resume` exist because the journal was write-only for its first three
# releases: eight append call sites, no way to get anything back. After a
# compaction the playbook survives (it is in the command file) but the progress
# does not, so the agent re-derives where it is from context that no longer
# holds it — the "agent forgets what it was doing" failure. `resume` is the cheap
# re-orientation read: bounded output, safe to run at the top of every phase.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
RUNS_DIR=".claude/execute-task-runs"
SUB="${1:?usage: journal.sh append|path|read|resume <run-id> [text|n]}"
RAW="${2:?run-id required}"
RUN_ID="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9_.-' '-')"   # SAME sanitize as preflight → same file
[ -n "$RUN_ID" ] || { echo "invalid run-id: '$RAW'" >&2; exit 1; }
JOURNAL="$RUNS_DIR/$RUN_ID.md"
case "$SUB" in
  path) echo "$JOURNAL" ;;
  append)
    shift 2
    MSG="$*"
    [ -n "$MSG" ] || { echo "journal append: message text required (got empty)" >&2; exit 1; }
    [ -f "$JOURNAL" ] || { echo "journal not found: $JOURNAL (run preflight first)" >&2; exit 1; }
    printf -- '- [%s] %s\n' "$(date -u +%FT%TZ)" "$MSG" >> "$JOURNAL"
    ;;
  read)
    # Missing journal is an ERROR, not empty output: "no progress recorded" and
    # "I could not find the record" must not look identical to the caller.
    [ -f "$JOURNAL" ] || { echo "journal not found: $JOURNAL (run preflight first)" >&2; exit 1; }
    cat "$JOURNAL"
    ;;
  resume)
    [ -f "$JOURNAL" ] || { echo "journal not found: $JOURNAL (run preflight first)" >&2; exit 1; }
    N="${3:-20}"
    case "$N" in ''|*[!0-9]*) echo "resume: line count must be a non-negative integer, got '$N'" >&2; exit 1 ;; esac
    # Header = everything before the first '## log'. Printed in full: it carries the
    # base SHA and target branch, which is what a resuming agent needs to not
    # rebase onto the wrong thing.
    sed -n '1,/^## log$/p' "$JOURNAL"
    # Then the tail of the log. `sed` after the marker, not `tail` on the file, so
    # a long header can never crowd the log entries out of the window.
    LOG="$(sed -n '/^## log$/,$p' "$JOURNAL" | sed '1d')"
    TOTAL="$(printf '%s\n' "$LOG" | grep -c '' )"
    if [ "$N" -gt 0 ] && [ "$TOTAL" -gt "$N" ]; then
      echo "...(earlier $((TOTAL - N)) entries omitted — 'journal.sh read' for the full record)"
    fi
    [ "$N" -gt 0 ] && printf '%s\n' "$LOG" | tail -n "$N"
    ;;
  *) echo "unknown subcommand: $SUB (use append|path|read|resume)" >&2; exit 1 ;;
esac
