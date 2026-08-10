#!/usr/bin/env bash
# Shared state and validation helpers for the spec/run lifecycle scripts.

EXECUTE_TASK_RUNS_REL=".claude/execute-task-runs"

execute_task_die() {
  echo "execute-task: $*" >&2
  exit 1
}

execute_task_init_root() {
  local requested requested_root git_root
  requested="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
  [ -n "$requested" ] || execute_task_die "run inside a Git repository"
  cd "$requested" 2>/dev/null || execute_task_die "cannot enter project directory '$requested'"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || execute_task_die "not a Git repository: '$requested'"
  requested_root="$(pwd -P)" || execute_task_die "cannot canonicalize project directory"
  git_root="$(CDPATH='' cd -- "$git_root" 2>/dev/null && pwd -P)" \
    || execute_task_die "cannot canonicalize Git root"
  case "$requested_root" in
    "$git_root"|"$git_root"/*) ;;
    *) execute_task_die "project directory escapes Git root: $requested_root" ;;
  esac
  cd "$git_root" 2>/dev/null || execute_task_die "cannot enter Git root '$git_root'"
  EXECUTE_TASK_ROOT="$git_root"
  EXECUTE_TASK_RUNS_DIR="$EXECUTE_TASK_ROOT/$EXECUTE_TASK_RUNS_REL"
}

execute_task_validate_run_id() {
  local value="$1"
  [ -n "$value" ] || execute_task_die "run-id is required"
  [ "${#value}" -le 80 ] || execute_task_die "run-id exceeds 80 characters"
  case "$value" in
    [abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) execute_task_die "run-id must start with a lowercase ASCII letter or digit" ;;
  esac
  case "$value" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) execute_task_die "run-id may contain only lowercase ASCII letters, digits, dot, underscore, and hyphen" ;;
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
    pattern="/$EXECUTE_TASK_RUNS_REL/"
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

execute_task_read_meta() {
  local key="$1" path="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$path"
}

execute_task_current_branch() {
  git symbolic-ref --short HEAD 2>/dev/null || printf '%s\n' '(detached)'
}

execute_task_assert_run_owner() {
  local meta="$1" stored_run_id stored_branch current_branch
  execute_task_assert_regular_or_missing "$meta"
  [ -f "$meta" ] || execute_task_die "metadata not found for run '$EXECUTE_TASK_RUN_ID'"
  stored_run_id="$(execute_task_read_meta run_id "$meta")"
  stored_branch="$(execute_task_read_meta branch "$meta")"
  current_branch="$(execute_task_current_branch)"
  [ "$stored_run_id" = "$EXECUTE_TASK_RUN_ID" ] \
    || execute_task_die "metadata run-id '$stored_run_id' does not match '$EXECUTE_TASK_RUN_ID'"
  [ -n "$stored_branch" ] || execute_task_die "branch missing for run '$EXECUTE_TASK_RUN_ID'"
  [ "$stored_branch" = "$current_branch" ] \
    || execute_task_die "run '$EXECUTE_TASK_RUN_ID' belongs to branch '$stored_branch', not '$current_branch'"
}

execute_task_validate_item_id() {
  local kind="$1" value="$2"
  [ -n "$value" ] || execute_task_die "$kind is required"
  [ "${#value}" -le 120 ] || execute_task_die "$kind exceeds 120 characters"
  case "$value" in
    [abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) execute_task_die "$kind must start with a lowercase ASCII letter or digit" ;;
  esac
  case "$value" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*)
      execute_task_die "$kind may contain only lowercase ASCII letters, digits, dot, underscore, and hyphen"
      ;;
  esac
}

execute_task_current_sha() {
  git rev-parse --verify HEAD 2>/dev/null \
    || execute_task_die "run requires an existing HEAD commit"
}

execute_task_current_tree_sha() {
  git rev-parse --verify HEAD^{tree} 2>/dev/null \
    || execute_task_die "cannot resolve the current tree SHA"
}

execute_task_assert_clean_tree() {
  local dirty
  dirty="$(git status --porcelain -uall 2>/dev/null)" \
    || execute_task_die "git status failed; refusing to assume a clean tree"
  [ -z "$dirty" ] || execute_task_die "working tree must be clean for an immutable candidate"
}

# Install paths of a plugin that is ACTIVE for this project, from the manifest Claude Code
# publishes. One copy of this selection rule: the prerequisite check and the required-review verifier
# answer different questions about the same installation, and two filters would eventually disagree
# about which version is installed. Usage: execute_task_manifest_roots <manifest> <key> <project>
execute_task_manifest_roots() {
  local manifest="$1" key="$2" project="$3"
  [ -f "$manifest" ] && [ -n "$project" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.plugins | type == "object"' "$manifest" >/dev/null 2>&1 || return 1
  jq -r --arg key "$key" --arg project "$project" '
    .plugins[$key] // [] |
    if type == "array" then
      .[]? |
      select(
        .scope == "user" or
        ((.scope == "project" or .scope == "local") and .projectPath == $project)
      ) |
      .installPath // empty
    else empty end
  ' "$manifest" 2>/dev/null
}

# Resolve the ACTIVE cc-codex-triage installation, so a required-review approval can be verified
# against that plugin's own state instead of trusting text the model pasted back. The manifest is
# authoritative when it exists: falling back to a stale cache directory would let an uninstalled
# plugin answer for a delivery gate. Without a manifest at all (older Claude Code) cache discovery is
# the only option, so the candidate must at least carry the required-review contract — an ancient
# cached copy cannot answer for a gate it never implemented.
execute_task_codex_plugin_root() {
  local cache manifest roots root
  cache="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins}"
  manifest="$cache/installed_plugins.json"
  if [ -e "$manifest" ]; then
    roots="$(execute_task_manifest_roots "$manifest" \
      'cc-codex-triage@cc-codex-triage' "$EXECUTE_TASK_ROOT")" || return 1
    while IFS= read -r root; do
      [ -n "$root" ] && [ -f "$root/scripts/review-state.sh" ] && { printf '%s\n' "$root"; return 0; }
    done <<EOF
$roots
EOF
    return 1
  fi
  for root in "$cache"/cache/*/cc-codex-triage/*; do
    [ -f "$root/scripts/review-state.sh" ] || continue
    grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$root/scripts/review-state.sh" || continue
    printf '%s\n' "$root"
    return 0
  done
  return 1
}

# Build the tree object represented by the complete working tree without touching the user's index.
# This lets a pre-commit testing gate bind to the exact content later recorded as the candidate.
execute_task_worktree_tree_sha() {
  local real_index temporary_index tree
  real_index="$(git rev-parse --git-path index 2>/dev/null)" \
    || execute_task_die "cannot resolve Git index"
  temporary_index="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-index.XXXXXX")" \
    || execute_task_die "cannot create temporary Git index"
  if [ -f "$real_index" ]; then
    cp "$real_index" "$temporary_index" || {
      rm -f "$temporary_index"
      execute_task_die "cannot copy Git index"
    }
  else
    rm -f "$temporary_index"
    GIT_INDEX_FILE="$temporary_index" git read-tree HEAD >/dev/null 2>&1 || {
      rm -f "$temporary_index"
      execute_task_die "cannot initialize temporary Git index"
    }
  fi
  GIT_INDEX_FILE="$temporary_index" git add -A -- :/ >/dev/null 2>&1 || {
    rm -f "$temporary_index"
    execute_task_die "cannot snapshot working tree"
  }
  tree="$(GIT_INDEX_FILE="$temporary_index" git write-tree 2>/dev/null)" || {
    rm -f "$temporary_index"
    execute_task_die "cannot write working-tree snapshot"
  }
  rm -f "$temporary_index"
  printf '%s\n' "$tree"
}
