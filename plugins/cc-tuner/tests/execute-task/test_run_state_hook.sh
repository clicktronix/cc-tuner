#!/usr/bin/env bash
set -u

PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
P="$PLUGIN/scripts/execute-task/preflight.sh"
R="$PLUGIN/scripts/execute-task/runctl.sh"
H="$PLUGIN/hooks/run-state-hook.sh"
fails=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s%s\n' "$1" "${2:+ ($2)}"; fails=1; }
runctl() { CLAUDE_PROJECT_DIR="$REPO" bash "$R" "$@"; }
hook() { event="$1"; input="$2"; printf '%s\n' "$input" | bash "$H" "$event"; }
evidence() { text="$1"; shift; printf '%s\n' "$text" | runctl "$@"; }

REPO="$(mktemp -d)" || exit 1
(
  cd "$REPO" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && printf 'base\n' > file.txt && git add file.txt \
    && git commit -qm init && git switch -qc task
) || exit 1
CLAUDE_PROJECT_DIR="$REPO" bash "$P" hook-run main --expected-branch task >/dev/null || exit 1
runctl init hook-run --mode auto >/dev/null || exit 1

STOP_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:false}')"
OUT="$(hook stop "$STOP_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; } \
  && pass "auto-stop-blocked-while-active" \
  || fail "auto-stop-blocked-while-active" "rc=$rc out=$OUT"

# Interactive readiness is not a boundary: /run must publish its visible plan before stopping.
REPO_INTERACTIVE="$(mktemp -d)" || exit 1
(
  cd "$REPO_INTERACTIVE" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && printf 'base\n' > file.txt && git add file.txt \
    && git commit -qm init && git switch -qc task
) || exit 1
CLAUDE_PROJECT_DIR="$REPO_INTERACTIVE" bash "$P" plan-run main --expected-branch task >/dev/null || exit 1
REPO_SAVED="$REPO"; REPO="$REPO_INTERACTIVE"
runctl init plan-run --mode interactive >/dev/null || exit 1
evidence "DoR ready" gate plan-run record dor pass >/dev/null
runctl phase plan-run complete readiness >/dev/null
PLAN_STOP_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:false}')"
OUT="$(hook stop "$PLAN_STOP_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; } \
  && pass "interactive-readiness-cannot-stop-before-plan" \
  || fail "interactive-readiness-cannot-stop-before-plan" "rc=$rc out=$OUT"
REPO="$REPO_SAVED"
rm -rf "$REPO_INTERACTIVE"

# Official runaway protection: the retry caused by this hook is allowed to stop rather than loop.
ACTIVE_STOP_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,hook_event_name:"Stop",stop_hook_active:true}')"
OUT="$(hook stop "$ACTIVE_STOP_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$OUT" ]; } && pass "stop-hook-active-breaks-loop" \
  || fail "stop-hook-active-breaks-loop" "rc=$rc out=$OUT"

NONMERGE_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"git status --short"}}')"
hook pre-tool-use "$NONMERGE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "non-merge-bash-allowed" || fail "non-merge-bash-allowed" "rc=$rc"

EDIT_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"file.txt"}}')"
OUT="$(hook pre-tool-use "$EDIT_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$OUT" | grep -q 'only during implementation'; } \
  && pass "edit-before-planning-blocked" \
  || fail "edit-before-planning-blocked" "rc=$rc out=$OUT"

mkdir -p "$REPO/packages/app"
NESTED_EDIT_INPUT="$(jq -cn --arg cwd "$REPO/packages/app" \
  '{cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"packages/app/file.txt"}}')"
OUT="$(hook pre-tool-use "$NESTED_EDIT_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$OUT" | grep -q 'only during implementation'; } \
  && pass "subdirectory-hook-finds-repo-wide-state" \
  || fail "subdirectory-hook-finds-repo-wide-state" "rc=$rc out=$OUT"

# The fence guards task paths. A prepared commit message or PR body lives outside the repository,
# cannot reach the candidate tree, and is consumed in phases that deny edits — so it has to stay
# writable, or the playbook's own "recreate them after a resume" is impossible.
SCRATCH_DIR="$(mktemp -d)"
OUTSIDE_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$SCRATCH_DIR/commit-message.txt" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$OUTSIDE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "prepared-file-outside-the-repository-stays-writable" \
  || fail "prepared-file-outside-the-repository-stays-writable" "rc=$rc"
# ...and a path the hook cannot resolve is still fenced: unknown is not outside.
UNRESOLVABLE_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:"relative/guess.txt"}}')"
hook pre-tool-use "$UNRESOLVABLE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "unresolvable-path-stays-fenced" \
  || fail "unresolvable-path-stays-fenced" "rc=$rc"
# An absolute path INSIDE the repository is a task path, whatever phase claims otherwise.
INSIDE_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$REPO/file.txt" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$INSIDE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "absolute-path-inside-the-repository-is-fenced" \
  || fail "absolute-path-inside-the-repository-is-fenced" "rc=$rc"
rm -rf "$SCRATCH_DIR"

MERGE_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr merge 123 --squash"}}')"
OUT="$(hook pre-tool-use "$MERGE_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$OUT" | grep -q 'blocked gh pr merge'; } \
  && pass "premature-gh-merge-blocked" \
  || fail "premature-gh-merge-blocked" "rc=$rc out=$OUT"

# Legacy/corrupt duplicate states still allow a Bash recovery command, but never merge or task completion.
STATE_DIR="$REPO/.claude/execute-task-runs"
cp "$STATE_DIR/hook-run.state.json" "$STATE_DIR/duplicate.state.json"
hook pre-tool-use "$NONMERGE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "multiple-state-recovery-bash-allowed" \
  || fail "multiple-state-recovery-bash-allowed" "rc=$rc"
OUT="$(hook pre-tool-use "$MERGE_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$OUT" | grep -q 'refusing merge'; } \
  && pass "multiple-state-merge-blocked" \
  || fail "multiple-state-merge-blocked" "rc=$rc out=$OUT"
DUP_TASK_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,hook_event_name:"TaskCompleted",task_id:"task-123"}')"
hook task-completed "$DUP_TASK_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "multiple-state-task-completion-blocked" \
  || fail "multiple-state-task-completion-blocked" "rc=$rc"
rm -f "$STATE_DIR/duplicate.state.json"

# TaskCompleted is enforced only for an explicit run-state <-> Claude task binding.
evidence "DoR ready" gate hook-run record dor pass >/dev/null
runctl phase hook-run complete readiness >/dev/null
runctl phase hook-run enter planning >/dev/null
evidence "Bound implementation task" task hook-run add implementation implementation --ui-task-id task-123 >/dev/null
for task_phase in testing acceptance candidate review delivery; do
  evidence "Bound $task_phase lifecycle task" \
    task hook-run add "$task_phase" "$task_phase" --ui-task-id "task-$task_phase" >/dev/null
done
runctl phase hook-run complete planning >/dev/null
runctl phase hook-run enter implementation >/dev/null
runctl task hook-run start implementation >/dev/null
hook pre-tool-use "$EDIT_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "edit-during-implementation-allowed" \
  || fail "edit-during-implementation-allowed" "rc=$rc"
TASK_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,hook_event_name:"TaskCompleted",task_id:"task-123"}')"
OUT="$(hook task-completed "$TASK_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$OUT" | grep -q 'lacks completed run-state evidence'; } \
  && pass "ui-task-without-evidence-blocked" \
  || fail "ui-task-without-evidence-blocked" "rc=$rc out=$OUT"
evidence "implementation evidence" task hook-run complete implementation >/dev/null
hook task-completed "$TASK_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "ui-task-with-evidence-allowed" \
  || fail "ui-task-with-evidence-allowed" "rc=$rc"

# A deliberate blocked state is a legitimate terminal point for the current turn.
evidence "waiting for user" block hook-run >/dev/null
OUT="$(hook stop "$STOP_INPUT" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$OUT" ]; } && pass "blocked-run-can-stop" \
  || fail "blocked-run-can-stop" "rc=$rc out=$OUT"

# Hook registration uses documented event names and a Bash matcher for the tool guard.
if jq -e '
  any(.hooks.PreToolUse[]; .matcher == "Bash") and
  any(.hooks.PreToolUse[]; .matcher == "Write|Edit|MultiEdit|NotebookEdit") and
  (.hooks.TaskCompleted | length) == 1 and
  (.hooks.Stop | length) == 2
' "$PLUGIN/hooks/hooks.json" >/dev/null; then
  pass "run-state-hooks-registered"
else
  fail "run-state-hooks-registered"
fi

rm -rf "$REPO"
exit "$fails"
