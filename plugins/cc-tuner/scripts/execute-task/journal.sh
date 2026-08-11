#!/usr/bin/env bash
# Read or write a run journal.
# Usage: journal.sh append <run-id> < message.txt
#        journal.sh path|read <run-id>
#        journal.sh resume <run-id> [n]
set -u
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
execute_task_init_root

SUBCOMMAND="${1:-}"
execute_task_validate_run_id "${2:-}"
case "$SUBCOMMAND" in
  path)
    echo "$EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
    exit 0
    ;;
  append|read|resume) ;;
  *) execute_task_die "unknown subcommand '$SUBCOMMAND' (use append|path|read|resume)" ;;
esac

execute_task_prepare_state
JOURNAL="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.md"
META="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.meta"
execute_task_assert_regular_or_missing "$JOURNAL"
execute_task_assert_regular_or_missing "$META"

case "$SUBCOMMAND" in
  append)
    shift 2
    if [ "$#" -gt 0 ]; then
      # Compatibility for callers shipped before the stdin contract. Shell expansion has already
      # happened by the time argv reaches this script, so this form cannot make Markdown containing
      # backticks or $() safe. Keep it for one migration window, but make the safe interface noisy.
      echo "execute-task: warning: journal append arguments are deprecated; pass the message via stdin" >&2
      MESSAGE="$*"
    else
      [ ! -t 0 ] || execute_task_die "journal message must be piped on stdin"
      MESSAGE="$(cat)" || execute_task_die "cannot read journal message from stdin"
    fi
    [ -n "$MESSAGE" ] || execute_task_die "journal message required"
    [ -f "$JOURNAL" ] || execute_task_die "journal not found: $EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
    execute_task_assert_run_owner "$META"
    printf -- '- [%s] %s\n' "$(date -u +%FT%TZ)" "$MESSAGE" >> "$JOURNAL" \
      || execute_task_die "cannot append journal for run '$EXECUTE_TASK_RUN_ID'"
    ;;
  read)
    [ -f "$JOURNAL" ] || execute_task_die "journal not found: $EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
    execute_task_assert_run_owner "$META"
    cat "$JOURNAL"
    ;;
  resume)
    [ -f "$JOURNAL" ] || execute_task_die "journal not found: $EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
    execute_task_assert_run_owner "$META"
    N="${3:-20}"
    case "$N" in ''|*[!0123456789]*) execute_task_die "resume line count must be a non-negative integer, got '$N'" ;; esac
    [ "${#N}" -le 7 ] \
      || execute_task_die "resume line count must contain at most 7 digits"
    if grep -q '^## log$' "$JOURNAL"; then
      sed -n '1,/^## log$/p' "$JOURNAL"
      LAST_RESTART="$(grep '^## restarted:' "$JOURNAL" | tail -1)"
      [ -z "$LAST_RESTART" ] || printf '%s\n' "$LAST_RESTART  <- current base, supersedes the header above"
      LOG="$(sed -n '/^## log$/,$p' "$JOURNAL" | sed '1d')"
    else
      LOG="$(cat "$JOURNAL")"
    fi
    TOTAL="$(printf '%s\n' "$LOG" | grep -c '')"
    if [ "$N" -gt 0 ] && [ "$TOTAL" -gt "$N" ]; then
      echo "...(earlier $((TOTAL - N)) lines omitted — 'journal.sh read' for the full record)"
    fi
    [ "$N" -gt 0 ] && printf '%s\n' "$LOG" | tail -n "$N"
    exit 0
    ;;
esac
