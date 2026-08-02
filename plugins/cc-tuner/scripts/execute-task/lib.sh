#!/usr/bin/env bash
# Shared state and validation helpers for the spec/run lifecycle scripts.

EXECUTE_TASK_RUNS_REL=".claude/execute-task-runs"

execute_task_die() {
  echo "execute-task: $*" >&2
  exit 1
}

execute_task_init_root() {
  local requested git_root
  requested="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
  [ -n "$requested" ] || execute_task_die "run inside a Git repository"
  cd "$requested" 2>/dev/null || execute_task_die "cannot enter project directory '$requested'"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || execute_task_die "not a Git repository: '$requested'"
  EXECUTE_TASK_ROOT="$(pwd -P)" || execute_task_die "cannot canonicalize project directory"
  git_root="$(CDPATH='' cd -- "$git_root" 2>/dev/null && pwd -P)" \
    || execute_task_die "cannot canonicalize Git root"
  case "$EXECUTE_TASK_ROOT" in
    "$git_root"|"$git_root"/*) ;;
    *) execute_task_die "project directory escapes Git root: $EXECUTE_TASK_ROOT" ;;
  esac
  EXECUTE_TASK_PREFIX="$(git rev-parse --show-prefix 2>/dev/null)" \
    || execute_task_die "cannot resolve project prefix"
  EXECUTE_TASK_RUNS_DIR="$EXECUTE_TASK_ROOT/$EXECUTE_TASK_RUNS_REL"
}

execute_task_validate_run_id() {
  local value="$1"
  [ -n "$value" ] || execute_task_die "run-id is required"
  [ "${#value}" -le 80 ] || execute_task_die "run-id exceeds 80 characters"
  case "$value" in
    [A-Za-z0-9]*) ;;
    *) execute_task_die "run-id must start with an ASCII letter or digit" ;;
  esac
  case "$value" in
    *[!A-Za-z0-9._-]*) execute_task_die "run-id may contain only ASCII letters, digits, dot, underscore, and hyphen" ;;
  esac
  EXECUTE_TASK_RUN_ID="$value"
}

execute_task_prepare_state() {
  local allow_tracked="${1:-}" path resolved tracked exclude_file pattern temporary

  for path in "$EXECUTE_TASK_ROOT/.claude" "$EXECUTE_TASK_RUNS_DIR"; do
    [ ! -L "$path" ] || execute_task_die "refusing symlinked state path: $path"
    [ ! -e "$path" ] || [ -d "$path" ] || execute_task_die "state path is not a directory: $path"
    mkdir -p "$path" || execute_task_die "cannot create state directory '$path'"
  done

  resolved="$(CDPATH='' cd -- "$EXECUTE_TASK_RUNS_DIR" 2>/dev/null && pwd -P)" \
    || execute_task_die "cannot canonicalize state directory"
  case "$resolved" in
    "$EXECUTE_TASK_ROOT"/*) ;;
    *) execute_task_die "state directory escapes project: $resolved" ;;
  esac

  tracked="$(git ls-files -- "$EXECUTE_TASK_RUNS_REL" 2>/dev/null)" \
    || execute_task_die "cannot inspect tracked state paths"
  if [ -n "$tracked" ] && [ "$allow_tracked" != "allow-tracked" ]; then
    execute_task_die "refusing tracked state directory: $EXECUTE_TASK_RUNS_REL"
  fi

  if [ "$allow_tracked" != "allow-tracked" ]; then
    exclude_file="$(git rev-parse --git-path info/exclude 2>/dev/null)" \
      || execute_task_die "cannot resolve Git exclude file"
    pattern="/$EXECUTE_TASK_PREFIX$EXECUTE_TASK_RUNS_REL/"
    [ ! -L "$exclude_file" ] || execute_task_die "refusing symlinked Git exclude file"
    mkdir -p "$(dirname "$exclude_file")" || execute_task_die "cannot create Git info directory"
    if ! grep -qxF "$pattern" "$exclude_file" 2>/dev/null; then
      temporary="$exclude_file.tmp.$$"
      {
        [ ! -s "$exclude_file" ] || cat "$exclude_file"
        if [ -s "$exclude_file" ] && [ -n "$(tail -c1 "$exclude_file" 2>/dev/null)" ]; then
          printf '\n'
        fi
        printf '%s\n' "$pattern"
      } > "$temporary" || execute_task_die "cannot prepare Git exclude file"
      mv "$temporary" "$exclude_file" || execute_task_die "cannot install Git exclude file"
    fi
    git check-ignore -q "$EXECUTE_TASK_RUNS_REL/probe" 2>/dev/null \
      || execute_task_die "state directory is not ignored: $EXECUTE_TASK_RUNS_REL"
  fi
}

execute_task_assert_regular_or_missing() {
  local path="$1"
  [ ! -L "$path" ] || execute_task_die "refusing symlinked state file: $path"
  [ ! -e "$path" ] || [ -f "$path" ] || execute_task_die "state path is not a regular file: $path"
}
