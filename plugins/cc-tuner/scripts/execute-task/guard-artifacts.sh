#!/usr/bin/env bash
# Refuse outward-facing actions when local run artifacts entered Git.
# Usage: guard-artifacts.sh <run-id>
set -u
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
execute_task_init_root

execute_task_validate_run_id "${1:-}"
execute_task_prepare_state allow-tracked
META="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.meta"
execute_task_assert_run_owner "$META"
ANCHOR="$(execute_task_read_meta target_sha "$META")"
[ -n "$ANCHOR" ] || execute_task_die "target SHA missing for run '$EXECUTE_TASK_RUN_ID'"
if [ "$ANCHOR" != "(unborn)" ]; then
  case "$ANCHOR" in *[!0-9A-Fa-f]*) execute_task_die "invalid stored target SHA" ;; esac
  case "${#ANCHOR}" in 40|64) ;; *) execute_task_die "invalid stored target SHA" ;; esac
fi

STAGED="$(git diff --cached --name-only -- "$EXECUTE_TASK_RUNS_REL" 2>/dev/null)" \
  || execute_task_die "staged diff query failed"
TRACKED="$(git ls-files -- "$EXECUTE_TASK_RUNS_REL" 2>/dev/null)" \
  || execute_task_die "tracked-files query failed"
HISTORY=""
if [ "$ANCHOR" = "(unborn)" ]; then
  if git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
    HISTORY="$(git log --format='%h %s' HEAD -- "$EXECUTE_TASK_RUNS_REL" 2>/dev/null)" \
      || execute_task_die "history query failed"
  fi
else
  git rev-parse --verify -q "$ANCHOR^{commit}" >/dev/null 2>&1 \
    || execute_task_die "stored target SHA '$ANCHOR' is unavailable"
  HISTORY="$(git log --format='%h %s' "$ANCHOR..HEAD" -- "$EXECUTE_TASK_RUNS_REL" 2>/dev/null)" \
    || execute_task_die "history query failed"
fi

if [ -n "$STAGED" ] || [ -n "$TRACKED" ] || [ -n "$HISTORY" ]; then
  echo "REFUSE: local run artifacts are staged, tracked, or present in branch history" >&2
  printf '%s\n' "$STAGED" "$TRACKED" "$HISTORY" | awk 'NF' | sort -u >&2
  exit 3
fi

echo "== change set before outward-facing action =="
git status --porcelain -uall
