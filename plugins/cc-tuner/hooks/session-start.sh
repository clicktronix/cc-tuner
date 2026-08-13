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

emit() {  # emit <context text> -- jq builds the JSON so the text cannot break out of the string
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

PLAN="$(bash "$SCRIPTS/plan-path.sh" resolve 2>/dev/null)" || exit 0

if ! SLICES="$(bash "$SCRIPTS/plan-lint.sh" slices "$PLAN" 2>/dev/null)"; then
  # A committed plan that does not parse is not nothing, and staying quiet about it would let the
  # branch look like it has no plan at all.
  emit "cc-tuner: $PLAN does not parse, so the task list was not restored. Run:
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
    any = 1
    if (blocked[s] != "-") {
      m = split(blocked[s], b, /[ \t]*,[ \t]*/)
      for (j = 1; j <= m; j++) if (state[b[j]] == "done") need[b[j]] = 1
    }
  }
  if (!any) exit 0

  for (i = 1; i <= n; i++) {
    s = order[i]
    if (!(s in need)) continue
    printf "Slice %s — %s [already done: create it completed so the edges below resolve]\n", s, title[s]
  }
  for (i = 1; i <= n; i++) {
    s = order[i]
    if (state[s] != "open") continue
    printf "Slice %s — %s\n    Blocked by: %s%s\n", s, title[s], blocked[s], open_crit[s]
  }
}')"

[ -n "$BODY" ] || exit 0

emit "cc-tuner: this branch has a committed plan with unfinished slices, and a task list that does
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
