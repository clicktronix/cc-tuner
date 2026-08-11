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

# `runctl prepare` owns a directory keyed by run id under TMPDIR, so it survives between suite runs.
# A leftover file from a previous run would make this suite depend on history — give it its own.
SUITE_TMP="$(mktemp -d)" || exit 1
export TMPDIR="$SUITE_TMP"
trap 'rm -rf "$SUITE_TMP"' EXIT

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
# The run asks runctl for the path; only that path is writable outside implementation.
PREPARED_PATH="$(runctl prepare hook-run commit-message)"
PREPARED_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$PREPARED_PATH" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$PREPARED_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "runctl-prepared-path-stays-writable" \
  || fail "runctl-prepared-path-stays-writable" "rc=$rc"
PREPARED_DIR_REAL="$(dirname "$PREPARED_PATH")"
printf 'not created by runctl\n' > "$PREPARED_DIR_REAL/unowned"
UNOWNED_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$PREPARED_DIR_REAL/unowned" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$UNOWNED_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "unowned-file-in-the-prepared-directory-is-fenced" \
  || fail "unowned-file-in-the-prepared-directory-is-fenced" "rc=$rc"
# An arbitrary path outside the repository is NOT a prepared file — that permission is what the
# symlink, hard-link and common-git-directory escapes all rode in on.
OUTSIDE_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$SCRATCH_DIR/commit-message.txt" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$OUTSIDE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "an-arbitrary-outside-path-is-not-a-prepared-file" \
  || fail "an-arbitrary-outside-path-is-not-a-prepared-file" "rc=$rc"
# ...and a path the hook cannot resolve is still fenced: unknown is not outside.
UNRESOLVABLE_INPUT="$(jq -cn --arg cwd "$REPO" '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:"relative/guess.txt"}}')"
hook pre-tool-use "$UNRESOLVABLE_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "unresolvable-path-stays-fenced" \
  || fail "unresolvable-path-stays-fenced" "rc=$rc"
# A symlink is resolved by the writing tool, so an outside-repo NAME pointing at a tracked file is
# still a task-path write.
ln -s "$REPO/file.txt" "$PREPARED_DIR_REAL/disguised.txt"
SYMLINK_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$PREPARED_DIR_REAL/disguised.txt" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$SYMLINK_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "symlink-into-the-repository-is-fenced" \
  || fail "symlink-into-the-repository-is-fenced" "rc=$rc"
# ...and so is a hard link: outside name, tracked inode. A freshly prepared file has one link.
ln "$REPO/file.txt" "$PREPARED_DIR_REAL/hardlinked.txt" 2>/dev/null
if [ -e "$PREPARED_DIR_REAL/hardlinked.txt" ]; then
  HARDLINK_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$PREPARED_DIR_REAL/hardlinked.txt" \
    '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
  hook pre-tool-use "$HARDLINK_INPUT" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && pass "hard-linked-tracked-file-is-fenced" \
    || fail "hard-linked-tracked-file-is-fenced" "rc=$rc"
  rm -f "$PREPARED_DIR_REAL/hardlinked.txt"
else
  fail "hard-linked-tracked-file-is-fenced" "could not create the fixture hard link"
fi

# Replacing the owned directory itself must not turn a repository directory into an allowed scratch
# location. The final target is deliberately a normal single-link tracked file.
mv "$PREPARED_DIR_REAL" "$PREPARED_DIR_REAL.saved"
ln -s "$REPO" "$PREPARED_DIR_REAL"
DIR_SYMLINK_INPUT="$(jq -cn --arg cwd "$REPO" --arg f "$PREPARED_DIR_REAL/file.txt" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
hook pre-tool-use "$DIR_SYMLINK_INPUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "symlinked-prepared-directory-is-fenced" \
  || fail "symlinked-prepared-directory-is-fenced" "rc=$rc"
unlink "$PREPARED_DIR_REAL"
mv "$PREPARED_DIR_REAL.saved" "$PREPARED_DIR_REAL"

# "Outside the worktree" is not "harmless". In a LINKED worktree the common Git directory lives
# outside the worktree entirely, and it holds the reviewer approval state this run's own delivery
# gate reads back — so an outside-the-worktree rule alone would let a run forge its own approval.
# A plain clone cannot show this: there .git is inside the tree and the repository-root test already
# covers it.
LINKED_PARENT="$(mktemp -d)"
LINKED="$LINKED_PARENT/wt"
git -C "$REPO" worktree add -q -b linked-task "$LINKED" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$LINKED" bash "$P" linked-run main --expected-branch linked-task >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$LINKED" bash "$R" init linked-run --mode auto >/dev/null 2>&1
LINKED_COMMON="$(git -C "$LINKED" rev-parse --git-common-dir 2>/dev/null)"
case "$LINKED_COMMON" in /*) ;; *) LINKED_COMMON="$LINKED/$LINKED_COMMON" ;; esac
LINKED_COMMON="$(CDPATH='' cd -- "$LINKED_COMMON" 2>/dev/null && pwd -P)"
case "$LINKED_COMMON" in
  /*) mkdir -p "$LINKED_COMMON/cc-codex-triage/threads" ;;
  *)  LINKED_COMMON="" ;;
esac
GITDIR_INPUT="$(jq -cn --arg cwd "$LINKED" --arg f "$LINKED_COMMON/cc-codex-triage/threads/review-linked-run.approved" \
  '{cwd:$cwd,tool_name:"Write",tool_input:{file_path:$f}}')"
if [ -z "$LINKED_COMMON" ] || [ ! -d "$LINKED" ]; then
  fail "linked-worktree-common-git-directory-is-fenced" "worktree fixture did not build"
else
  hook pre-tool-use "$GITDIR_INPUT" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && pass "linked-worktree-common-git-directory-is-fenced" \
    || fail "linked-worktree-common-git-directory-is-fenced" "rc=$rc"
fi
git -C "$REPO" worktree remove --force "$LINKED" >/dev/null 2>&1
rm -rf "$LINKED_PARENT"

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
    task hook-run add "$task_phase" "$task_phase" >/dev/null
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
