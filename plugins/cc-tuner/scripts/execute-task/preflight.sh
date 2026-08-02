#!/usr/bin/env bash
# Open or resume a clean-tree run journal with branch/target metadata.
# Usage: preflight.sh <run-id> [target-ref]
set -u
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
execute_task_init_root

execute_task_validate_run_id "${1:-}"
TARGET="${2:-}"
execute_task_prepare_state
JOURNAL="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.md"
META="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.meta"
execute_task_assert_regular_or_missing "$JOURNAL"
execute_task_assert_regular_or_missing "$META"

if ! DIRTY="$(git status --porcelain -unormal -- . ":(exclude)$EXECUTE_TASK_RUNS_REL" 2>/dev/null)"; then
  execute_task_die "git status failed; refusing to assume a clean tree"
fi
if [ -n "$DIRTY" ]; then
  echo "DIRTY working tree — commit or stash before /run:" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

BASE_SHA="$(git rev-parse --verify HEAD 2>/dev/null || echo '(unborn)')"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
TARGET_SHA="$BASE_SHA"
if [ -n "$TARGET" ]; then
  case "$TARGET" in -*) execute_task_die "target ref must not start with '-'" ;; esac
  TARGET_SHA="$(git rev-parse --verify "$TARGET^{commit}" 2>/dev/null)" \
    || execute_task_die "target '$TARGET' is not a valid commit"
fi

if [ -f "$JOURNAL" ]; then
  [ -f "$META" ] || execute_task_die "metadata missing for existing run '$EXECUTE_TASK_RUN_ID'"
  STORED_BRANCH="$(awk -F= '$1 == "branch" {print substr($0, index($0, "=") + 1); exit}' "$META")"
  STORED_TARGET="$(awk -F= '$1 == "target_ref" {print substr($0, index($0, "=") + 1); exit}' "$META")"
  [ "$STORED_BRANCH" = "$BRANCH" ] \
    || execute_task_die "run '$EXECUTE_TASK_RUN_ID' belongs to branch '$STORED_BRANCH', not '$BRANCH'"
  [ "$STORED_TARGET" = "$TARGET" ] \
    || execute_task_die "run '$EXECUTE_TASK_RUN_ID' targets '$STORED_TARGET', not '$TARGET'"
  {
    echo
    echo "## restarted: $(date -u +%FT%TZ) (branch $BRANCH, base $BASE_SHA)"
  } >> "$JOURNAL" || execute_task_die "cannot append $JOURNAL"
else
  [ ! -e "$META" ] || execute_task_die "metadata exists without journal for '$EXECUTE_TASK_RUN_ID'"
  META_TMP="$META.tmp.$$"
  {
    echo "version=1"
    echo "run_id=$EXECUTE_TASK_RUN_ID"
    echo "branch=$BRANCH"
    echo "base_sha=$BASE_SHA"
    echo "target_ref=$TARGET"
    echo "target_sha=$TARGET_SHA"
  } > "$META_TMP" || execute_task_die "cannot write run metadata"
  mv "$META_TMP" "$META" || execute_task_die "cannot install run metadata"
  {
    echo "# execute-task run: $EXECUTE_TASK_RUN_ID"
    echo
    echo "- started: $(date -u +%FT%TZ)"
    echo "- branch: $BRANCH"
    echo "- target: ${TARGET:-?}"
    echo "- target SHA: $TARGET_SHA"
    echo "- base SHA: $BASE_SHA"
    echo
    echo "## log"
  } > "$JOURNAL" || execute_task_die "cannot write $JOURNAL"
fi

echo "$EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
