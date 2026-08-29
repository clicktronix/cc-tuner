#!/usr/bin/env bash
# SessionStart: ask the agent to rebuild this branch's task list from its committed plan.
#
# ASK, not do. A command hook cannot call TaskCreate -- it emits JSON and nothing else -- so recovery
# has exactly the standing the plan itself has: advisory, and dependent on the agent following it.
# Anything that claims a session "will" restore its tasks is claiming something about a model.
#
# Registered for `startup` and `clear` only. Section 4 of docs/spike-native-flow.md measured the task
# graph surviving /compact and resume byte for byte, so asking there would duplicate every row. The
# instruction below is idempotent anyway -- read TaskList first, create only what is missing -- because
# a rule that depends on the trigger being exactly right is one trigger change away from doubling the
# plan.
#
# Silence is a correct output, and the common one: no plan, or nothing left open.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

# Then to the repository root, because plan-path.sh prints a repo-relative path. Without this, a
# session started in a subdirectory resolved the plan and then failed to open it, and reported a
# perfectly good plan as unparsable -- a wrong answer, not a missing one.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" 2>/dev/null || exit 0

emit() {  # emit <context text> -- jq builds the JSON so the text cannot break out of the string
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# A leftover run-state file means this repository is mid-flight on a runtime that was deleted. Say so
# before anything else, and say it even when there is no plan at all -- that combination is the most
# likely one, and staying silent about it is how a broken repository looks like an idle one.
#
# ADVISORY, and named that. SessionStart cannot block: the reference says "Can block? No -- shows
# stderr to user only." The refusal lives in merge.sh, where there is something to refuse.
#
# The advice is conditional on what the file records, not fixed. It said "delete the directory and
# re-plan" in every case; the live instance had a committed plan that passed the linter, and
# re-planning would have thrown away a correct one. The agent noticed and pushed back, and was right.
# The predicate: a run that never reached implementation and never recorded a candidate changed
# nothing, so there is nothing to re-plan. Anything else -- including a file this cannot read --
# takes the cautious branch, because advising a bare delete over work that was done is the costly
# error, and the opposite only wastes a re-plan.
LEGACY=""
for legacy in "$ROOT"/.claude/execute-task-runs/*.state.json; do
  [ -e "$legacy" ] || continue
  if jq -e '((.candidate.sha // null) == null)
            and ((((.completed_phases // []) - ["readiness", "planning"]) | length) == 0)' \
       "$legacy" >/dev/null 2>&1; then
    disposal="delete the directory — it recorded no implementation work and no candidate, so there is
nothing to re-plan"
  else
    disposal="delete the directory and re-plan — it recorded work this version cannot continue"
  fi
  LEGACY="cc-tuner: .claude/execute-task-runs/ still holds run state from a removed runtime (${legacy##*/}).
This version does not implement it, so nothing will advance that run. Finish it under the plugin
version that created it, or $disposal. Merges are refused until it is gone.
"
  break
done

if ! PLAN="$(bash "$SCRIPTS/plan-path.sh" resolve 2>/dev/null)"; then
  [ -z "$LEGACY" ] || emit "$LEGACY"
  exit 0
fi

if ! SLICES="$(bash "$SCRIPTS/plan-lint.sh" slices "$PLAN" 2>/dev/null)"; then
  # A committed plan that does not parse is not nothing, and staying quiet about it would let the
  # branch look like it has no plan at all.
  emit "${LEGACY}cc-tuner: $PLAN does not parse, so the task list was not restored. Run:
  plan-lint.sh check $PLAN"
  exit 0
fi

# Open slices, plus every done slice an open one is blocked by. Restoring only the open ones leaves
# those edges pointing at tasks that do not exist, and the rebuilt graph is quietly wrong.
BODY="$(printf '%s\n' "$SLICES" | awk -F'\t' '
$1 == "SLICE" { state[$2] = $3; blocked[$2] = $4; title[$2] = $5; order[++n] = $2 }
$1 == "CRIT" && $3 == "open" { open_crit[$2] = open_crit[$2] "\n    - [ ] " $4 }
END {
  for (i = 1; i <= n; i++) {
    s = order[i]
    if (state[s] != "open") continue
    if (blocked[s] != "-") {
      m = split(blocked[s], b, /[ \t]*,[ \t]*/)
      for (j = 1; j <= m; j++) if (state[b[j]] == "done") need[b[j]] = 1
    }
  }

  # Transitively, because a done slice can be blocked by another done slice. Restoring only the
  # direct blockers of open slices dropped `done 1 -> done 2 -> open 3` back to two rows and lost the
  # 2 -> 1 edge -- a graph that looks complete and is not.
  do {
    added = 0
    for (s in need) {
      if (blocked[s] == "-") continue
      m = split(blocked[s], b, /[ \t]*,[ \t]*/)
      for (j = 1; j <= m; j++)
        if (state[b[j]] == "done" && !(b[j] in need)) { need[b[j]] = 1; added = 1 }
    }
  } while (added)

  for (i = 1; i <= n; i++) {
    s = order[i]
    if (!(s in need)) continue
    # With its edges. Emitting the title alone brought the node back and left its own Blocked by
    # behind, so `done 1 -> done 2 -> open 3` restored three tasks and one of the two edges.
    printf "Slice %s — %s [already done: create it completed, then wire its edges below]\n    Blocked by: %s\n", s, title[s], blocked[s]
  }
  for (i = 1; i <= n; i++) {
    s = order[i]
    if (state[s] != "open") continue
    printf "Slice %s — %s\n    Blocked by: %s%s\n", s, title[s], blocked[s], open_crit[s]
  }
}')"

if [ -z "$BODY" ]; then
  [ -z "$LEGACY" ] || emit "$LEGACY"
  exit 0
fi

emit "${LEGACY}cc-tuner: this branch has a committed plan with unfinished slices, and a task list that does
not carry them yet. Rebuild it from $PLAN before doing anything else.

Read TaskList first and create only what is missing -- this may run in a session that already has
some of these. Then, in this order, because an edge cannot be added to a task that does not exist and
marking first leaves the wiring to a pass that may not happen:

  1. TaskCreate every slice below that is not already in the list
  2. TaskUpdate addBlockedBy for every \"Blocked by\" edge
  3. TaskUpdate status completed for the slices marked already done

$BODY

Tick \`- [ ]\` to \`- [x]\` in $PLAN as criteria are met, and commit it. The file is the store; the task
list does not survive this session."
