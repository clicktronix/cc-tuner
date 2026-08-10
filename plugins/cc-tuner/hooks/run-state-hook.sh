#!/usr/bin/env bash
# Defense-in-depth hooks for runctl state. No state file means no gate, so the foundation remains
# backward-compatible until /run explicitly initializes the structured lifecycle.
set -u

EVENT="${1:-}"
INPUT="$(cat 2>/dev/null || true)"

allow() { exit 0; }
deny_tool() { printf '%s\n' "$1" >&2; exit 2; }
block_stop() {
  reason="$(printf '%s' "$1" | tr -d '"\\' | tr -s '[:cntrl:]' ' ')"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
}

command -v jq >/dev/null 2>&1 || allow
if [ "$EVENT" = "stop" ]; then
  STOP_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
  [ "$STOP_ACTIVE" = "true" ] && allow
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT_DIR" ] || allow
cd "$PROJECT_DIR" 2>/dev/null || allow
PROJECT_DIR="$(pwd -P 2>/dev/null || true)"
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$PROJECT_DIR" ] && [ -n "$GIT_ROOT" ] || allow
GIT_ROOT="$(CDPATH='' cd -- "$GIT_ROOT" 2>/dev/null && pwd -P || true)"
case "$PROJECT_DIR" in "$GIT_ROOT"|"$GIT_ROOT"/*) ;; *) allow ;; esac

RUNS="$GIT_ROOT/.claude/execute-task-runs"
[ -d "$RUNS" ] && [ ! -L "$RUNS" ] || allow
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || allow

ACTIVE=""
for state in "$RUNS"/*.state.json; do
  [ -f "$state" ] && [ ! -L "$state" ] || continue
  if jq -e --arg branch "$BRANCH" \
      '.schema_version == 1 and .branch == $branch and .status == "active"' \
      "$state" >/dev/null 2>&1; then
    ACTIVE="${ACTIVE}${ACTIVE:+
}$state"
  fi
done
[ -n "$ACTIVE" ] || allow

ACTIVE_COUNT="$(printf '%s\n' "$ACTIVE" | grep -c .)"
if [ "$ACTIVE_COUNT" -ne 1 ]; then
  case "$EVENT" in
    pre-tool-use)
      TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
      if [ "$TOOL_NAME" = "Bash" ]; then
        COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        printf '%s\n' "$COMMAND" \
          | grep -Eq '(^|[;&|][;&|]?[[:space:]]*)(command[[:space:]]+)?([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
          && deny_tool "cc-tuner: multiple active run states own branch '$BRANCH'; refusing merge"
        allow
      fi
      deny_tool "cc-tuner: multiple active run states own branch '$BRANCH'; mutation ownership is ambiguous"
      ;;
    stop) block_stop "cc-tuner: multiple active run states own branch '$BRANCH'; block or finish all but one" ;;
    task-completed) deny_tool "cc-tuner: multiple active run states own branch '$BRANCH'; task ownership is ambiguous" ;;
    *) allow ;;
  esac
fi

STATE="$ACTIVE"
RUN_ID="$(jq -r '.run_id // empty' "$STATE" 2>/dev/null)"
[ -n "$RUN_ID" ] || allow
PLUGIN_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd || true)"
RUNCTL="$PLUGIN_ROOT/scripts/execute-task/runctl.sh"
[ -x "$RUNCTL" ] || [ -f "$RUNCTL" ] || allow
if ! CLAUDE_PROJECT_DIR="$GIT_ROOT" bash "$RUNCTL" status "$RUN_ID" >/dev/null 2>&1; then
  case "$EVENT" in
    pre-tool-use) deny_tool "cc-tuner: invalid run state for '$RUN_ID'; refusing merge" ;;
    stop) block_stop "cc-tuner: invalid run state for '$RUN_ID'; repair or explicitly remove it before stopping" ;;
    *) deny_tool "cc-tuner: invalid run state for '$RUN_ID'" ;;
  esac
fi

case "$EVENT" in
  pre-tool-use)
    TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
    case "$TOOL_NAME" in
      Write|Edit|MultiEdit|NotebookEdit)
        PHASE="$(jq -r '.phase.name' "$STATE")"
        [ "$PHASE" = "implementation" ] \
          || deny_tool "cc-tuner: $TOOL_NAME may mutate task paths only during implementation; current phase is '$PHASE'. Return through 'runctl.sh phase $RUN_ID fix' to reopen implementation, or 'runctl.sh block $RUN_ID' to stop the run and edit freely."
        allow
        ;;
    esac
    COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$COMMAND" ] || allow
    # This is a guardrail, not a shell parser. runctl can-merge remains the authoritative explicit
    # gate. Match ordinary direct, path-qualified, `command gh`, and chained invocations.
    printf '%s\n' "$COMMAND" \
      | grep -Eq '(^|[;&|][;&|]?[[:space:]]*)(command[[:space:]]+)?([^[:space:];&|]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' \
      || allow
    CANDIDATE="$(jq -r '.candidate.sha // empty' "$STATE")"
    PR_NUMBER="$(jq -r '.ci.pr_number // empty' "$STATE")"
    [ -n "$CANDIDATE" ] && [ -n "$PR_NUMBER" ] \
      || deny_tool "cc-tuner blocked gh pr merge for run '$RUN_ID': delivery is not bound to a PR/candidate"
    printf '%s\n' "$COMMAND" | grep -Eq -- "--match-head-commit([=][[:space:]]*|[[:space:]]+)$CANDIDATE([[:space:];&|]|$)" \
      || deny_tool "cc-tuner blocked gh pr merge for run '$RUN_ID': use --match-head-commit $CANDIDATE"
    printf '%s\n' "$COMMAND" | grep -Eq "(^|[[:space:]])$PR_NUMBER([[:space:];&|]|$)" \
      || deny_tool "cc-tuner blocked gh pr merge for run '$RUN_ID': merge the recorded PR #$PR_NUMBER explicitly"
    if OUT="$(CLAUDE_PROJECT_DIR="$GIT_ROOT" bash "$RUNCTL" can-merge "$RUN_ID" 2>&1)"; then
      allow
    fi
    deny_tool "cc-tuner blocked gh pr merge for run '$RUN_ID': $OUT"
    ;;

  task-completed)
    UI_TASK_ID="$(printf '%s' "$INPUT" | jq -r '.task_id // empty' 2>/dev/null)"
    [ -n "$UI_TASK_ID" ] || allow
    MATCHES="$(jq --arg ui "$UI_TASK_ID" '[.tasks[] | select(.ui_task_id == $ui)] | length' "$STATE" 2>/dev/null)"
    [ "$MATCHES" = "1" ] || allow
    jq -e --arg ui "$UI_TASK_ID" \
      'any(.tasks[]; .ui_task_id == $ui and .status == "completed" and (.evidence | type == "string") and (.evidence | length > 0))' \
      "$STATE" >/dev/null 2>&1 \
      || deny_tool "cc-tuner: task '$UI_TASK_ID' lacks completed run-state evidence for run '$RUN_ID'"
    allow
    ;;

  stop)
    STATUS="$(jq -r '.status' "$STATE")"
    case "$STATUS" in blocked|completed) allow ;; esac
    MODE="$(jq -r '.mode' "$STATE")"
    PHASE="$(jq -r '.phase.name' "$STATE")"
    PHASE_STATUS="$(jq -r '.phase.status' "$STATE")"
    if [ "$MODE" = "interactive" ] && [ "$PHASE_STATUS" = "completed" ] \
      && [ "$PHASE" != "readiness" ]; then
      allow
    fi
    block_stop "cc-tuner run '$RUN_ID' is active at $PHASE/$PHASE_STATUS. Record evidence and complete the phase, or explicitly block the run before stopping."
    ;;

  *) allow ;;
esac
