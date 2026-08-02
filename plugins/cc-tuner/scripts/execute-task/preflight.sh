#!/usr/bin/env bash
# Open or resume a clean-tree run journal with branch/target ownership metadata.
# Usage: preflight.sh <run-id> <target-ref> --expected-branch <branch>
set -u
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
execute_task_init_root

execute_task_validate_run_id "${1:-}"
shift
TARGET=""
EXPECTED_BRANCH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-branch)
      [ "$#" -ge 2 ] || execute_task_die "--expected-branch requires a value"
      EXPECTED_BRANCH="$2"
      shift
      ;;
    --*) execute_task_die "unknown option '$1'" ;;
    *) [ -z "$TARGET" ] || execute_task_die "multiple target refs provided"; TARGET="$1" ;;
  esac
  shift
done
[ -n "$TARGET" ] || execute_task_die "target ref is required"
[ -n "$EXPECTED_BRANCH" ] || execute_task_die "--expected-branch is required"
case "$TARGET" in -*) execute_task_die "target ref must not start with '-'" ;; esac
case "$EXPECTED_BRANCH" in -*) execute_task_die "expected branch must not start with '-'" ;; esac
git check-ref-format "refs/heads/$TARGET" >/dev/null 2>&1 \
  || execute_task_die "target must be a literal branch name, got '$TARGET'"

execute_task_prepare_state
JOURNAL="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.md"
META="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.meta"
execute_task_assert_regular_or_missing "$JOURNAL"
execute_task_assert_regular_or_missing "$META"

if ! DIRTY="$(git status --porcelain -unormal 2>/dev/null)"; then
  execute_task_die "git status failed; refusing to assume a clean tree"
fi
if [ -n "$DIRTY" ]; then
  echo "DIRTY working tree — commit or stash before /run:" >&2
  printf '%s\n' "$DIRTY" >&2
  exit 2
fi

BASE_SHA="$(git rev-parse --verify HEAD 2>/dev/null || echo '(unborn)')"
BRANCH="$(execute_task_current_branch)"
[ "$BRANCH" != "(detached)" ] || execute_task_die "run requires a named task branch"
[ "$BRANCH" = "$EXPECTED_BRANCH" ] \
  || execute_task_die "expected branch '$EXPECTED_BRANCH', not '$BRANCH'"
[ "$BRANCH" != "$TARGET" ] || execute_task_die "task branch must differ from target '$TARGET'"
if git rev-parse --verify -q "refs/remotes/origin/$TARGET^{commit}" >/dev/null 2>&1; then
  TARGET_SHA="$(git rev-parse --verify "refs/remotes/origin/$TARGET^{commit}")" \
    || execute_task_die "cannot resolve remote target '$TARGET'"
else
  TARGET_SHA="$(git rev-parse --verify "refs/heads/$TARGET^{commit}" 2>/dev/null)" \
    || execute_task_die "target branch '$TARGET' is unavailable locally and on origin"
fi

if [ -e "$JOURNAL" ] || [ -e "$META" ]; then
  [ -f "$JOURNAL" ] || execute_task_die "journal missing for existing run '$EXECUTE_TASK_RUN_ID'"
  execute_task_assert_run_owner "$META"
  STORED_TARGET="$(execute_task_read_meta target_ref "$META")"
  [ "$STORED_TARGET" = "$TARGET" ] \
    || execute_task_die "run '$EXECUTE_TASK_RUN_ID' targets '$STORED_TARGET', not '$TARGET'"
  {
    echo
    echo "## restarted: $(date -u +%FT%TZ) (branch $BRANCH, base $BASE_SHA)"
  } >> "$JOURNAL" || execute_task_die "cannot append $JOURNAL"
else
  META_TMP="$(mktemp "$META.tmp.XXXXXX")" || execute_task_die "cannot create metadata temp file"
  JOURNAL_TMP="$(mktemp "$JOURNAL.tmp.XXXXXX")" || {
    rm -f "$META_TMP"
    execute_task_die "cannot create journal temp file"
  }
  {
    echo "version=1"
    echo "run_id=$EXECUTE_TASK_RUN_ID"
    echo "branch=$BRANCH"
    echo "base_sha=$BASE_SHA"
    echo "target_ref=$TARGET"
    echo "target_sha=$TARGET_SHA"
  } > "$META_TMP" || {
    rm -f "$META_TMP" "$JOURNAL_TMP"
    execute_task_die "cannot write run metadata"
  }
  {
    echo "# execute-task run: $EXECUTE_TASK_RUN_ID"
    echo
    echo "- started: $(date -u +%FT%TZ)"
    echo "- branch: $BRANCH"
    echo "- target: $TARGET"
    echo "- target SHA: $TARGET_SHA"
    echo "- base SHA: $BASE_SHA"
    echo "- baseline worktree: clean"
    echo
    echo "## log"
  } > "$JOURNAL_TMP" || {
    rm -f "$META_TMP" "$JOURNAL_TMP"
    execute_task_die "cannot write run journal"
  }
  mv "$JOURNAL_TMP" "$JOURNAL" || {
    rm -f "$META_TMP" "$JOURNAL_TMP"
    execute_task_die "cannot install run journal"
  }
  mv "$META_TMP" "$META" || {
    rm -f "$META_TMP" "$JOURNAL"
    execute_task_die "cannot install run metadata"
  }
fi

echo "$EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.md"
