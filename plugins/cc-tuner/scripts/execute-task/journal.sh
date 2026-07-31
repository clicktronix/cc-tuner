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
    # Clamp before any arithmetic: a 21-digit value passes the digits-only check above and
    # then overflows `[`, which drops the entire log and reports an error instead — and a
    # merely huge one gets `tail` OOM-killed on BSD. Bounded output is the whole promise.
    [ "${#N}" -le 7 ] || N=9999999
    # Header = everything before the first '## log'. Printed in full: it carries the base
    # SHA and target branch, which is what stops a resuming agent rebasing onto the wrong
    # thing. A journal with no marker (hand-edited, or from another tool) would make the
    # sed range run to EOF and print the file unbounded, so fall back to a plain tail.
    if grep -q '^## log$' "$JOURNAL"; then
      sed -n '1,/^## log$/p' "$JOURNAL"
      # `preflight.sh` records a re-run by APPENDING a '## restarted:' line, which lands
      # inside the log region — so the header above still shows the ORIGINAL base SHA.
      # Surface the latest restart explicitly: a resumed run acting on the first run's
      # base SHA is exactly the mistake the header exists to prevent.
      LAST_RESTART="$(grep '^## restarted:' "$JOURNAL" | tail -1)"
      [ -n "$LAST_RESTART" ] && printf '%s\n' "$LAST_RESTART  <- current base, supersedes the header above"
      # Tail of the log via sed after the marker, not `tail` on the file, so a long header
      # can never crowd the log entries out of the window.
      LOG="$(sed -n '/^## log$/,$p' "$JOURNAL" | sed '1d')"
    else
      LOG="$(cat "$JOURNAL")"
    fi
    # grep -c '' counts LINES, so blanks and '## restarted:' markers count too — the number
    # is an upper bound on entries, not an exact count. It also returns 1 for an empty LOG,
    # because printf emits a trailing newline; harmless only while the -gt 0 guard below
    # hides that case, so do not remove the guard without revisiting this.
    TOTAL="$(printf '%s\n' "$LOG" | grep -c '')"
    if [ "$N" -gt 0 ] && [ "$TOTAL" -gt "$N" ]; then
      echo "...(earlier $((TOTAL - N)) lines omitted — 'journal.sh read' for the full record)"
    fi
    # Explicit exit: with `[ "$N" -gt 0 ] && ...` as the branch's last command, n=0 made the
    # whole script exit 1 on a request it had just accepted as valid.
    [ "$N" -gt 0 ] && printf '%s\n' "$LOG" | tail -n "$N"
    exit 0
    ;;
  *) echo "unknown subcommand: $SUB (use append|path|read|resume)" >&2; exit 1 ;;
esac
