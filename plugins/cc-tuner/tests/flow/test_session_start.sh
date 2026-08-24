#!/usr/bin/env bash
# session-start.sh: the hook that asks a fresh session to rebuild its task list from the plan.
#
# Every case is a real repository with a real commit and a real payload on stdin, because the
# questions are what git returns and what the hook decided -- neither is answerable by reading it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$FLOW_PLUGIN/hooks/session-start.sh"

# repo_with_plan <branch> <plan-basename> <plan body> -> repo path
repo_with_plan() {
  local r; r="$(flow_repo)"
  (
    cd "$r" || exit 1
    git checkout -q -b "$1"
    mkdir -p docs/task-plans
    printf '%s' "$3" > "docs/task-plans/$2"
    git add -A && git commit -q -m 'add plan'
  ) || { printf 'FATAL: setup failed\n'; exit 1; }
  printf '%s' "$r"
}

# fire <repo> -> the hook's raw stdout.
# --arg, not string interpolation into the jq program: a path is data, and one carrying a quote would
# otherwise rewrite the filter rather than land in it.
fire() {
  jq -c --arg cwd "$1" '.source = "startup" | .cwd = $cwd' "$FLOW_FIXTURES/sessionstart.json" \
    | bash "$HOOK" 2>/dev/null
}

# context <repo> -> just the additionalContext string
context() { fire "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

HALF='## Slice 1 — Seed the config
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] budget key exists

## Slice 2 — Wire the budget
Blocked by: 1
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] read from config
- [ ] exhaustion is observable

## Slice 3 — Ship it
Blocked by: 2
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] released
'

# --- a half-done plan restores the open slices, with their edges ---------------------------------
R="$(repo_with_plan feature/retry 2026-01-01-feature-retry.md "$HALF")"
C="$(context "$R")"
check "names-the-plan-file"   "docs/task-plans/2026-01-01-feature-retry.md" "$C"
check "emits-open-slice-2"    "Slice 2 — Wire the budget"              "$C"
check "emits-open-slice-3"    "Slice 3 — Ship it"                      "$C"
check "carries-the-edge"      "Blocked by: 1"                          "$C"
check "carries-the-later-edge" "Blocked by: 2"                         "$C"

# Criteria are per slice, and only the open ones are worth restoring.
check  "emits-open-criterion"    "exhaustion is observable" "$C"
absent "omits-ticked-criterion"  "read from config"         "$C"
absent "omits-other-ticked"      "budget key exists"        "$C"

# --- a finished slice that an open one depends on is emitted too ---------------------------------
# Restoring only the open slices leaves "Blocked by: 1" pointing at a task that does not exist, and
# the rebuilt graph is quietly wrong -- the failure is invisible, which is what makes it worth a test.
check "emits-referenced-done-blocker" "Slice 1 — Seed the config" "$C"
check "marks-it-already-done"         "already done"              "$C"

# --- the instruction is ordered and idempotent ---------------------------------------------------
check "tells-it-to-read-tasklist-first" "Read TaskList first" "$C"
check "orders-create-before-edges"      "1. TaskCreate"       "$C"
check "orders-edges-before-completion"  "2. TaskUpdate addBlockedBy" "$C"

# --- started from a subdirectory ------------------------------------------------------------------
# plan-path.sh prints a repo-relative path, so a hook that stayed in the payload's cwd resolved the
# plan and then could not open it -- reporting a perfectly good plan as unparsable. A wrong answer,
# not a missing one, and the common case: sessions start in subdirectories all the time.
mkdir -p "$R/src/deep"
SUB="$(jq -c --arg cwd "$R/src/deep" '.source = "startup" | .cwd = $cwd' "$FLOW_FIXTURES/sessionstart.json" \
  | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')"
check  "subdirectory-still-restores" "Slice 2 — Wire the budget" "$SUB"
absent "subdirectory-does-not-claim-broken" "does not parse"     "$SUB"

# --- completed blockers are followed transitively -------------------------------------------------
# done 1 -> done 2 -> open 3. Emitting only the direct blockers of open slices dropped Slice 1 and
# with it the 2 -> 1 edge: a graph that looks complete and is not.
CHAIN='## Slice 1 — Foundation
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] a

## Slice 2 — Middle
Blocked by: 1
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] b

## Slice 3 — Top
Blocked by: 2
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] c
'
R6="$(repo_with_plan feature/chain 2026-01-01-feature-chain.md "$CHAIN")"
C6="$(context "$R6")"
check "transitive-blocker-emitted"  "Slice 1 — Foundation" "$C6"
check "direct-blocker-emitted"      "Slice 2 — Middle"     "$C6"
check "open-slice-emitted"          "Slice 3 — Top"        "$C6"
# The node is not the graph. Restoring Slice 2 without its own "Blocked by: 1" gave back three tasks
# and one of the two edges -- a plan that looks whole and has lost a dependency. Assert the pairing,
# not a count: only one slice here has that edge, so counting proves nothing about which one carries it.
equals "transitive-blocker-keeps-its-edge" "Blocked by: 1" \
  "$(printf '%s' "$C6" | grep -A1 'Slice 2 — Middle' | sed -n '2p' | sed 's/^ *//')"
equals "done-blocker-with-no-edge-says-so" "Blocked by: -" \
  "$(printf '%s' "$C6" | grep -A1 'Slice 1 — Foundation' | sed -n '2p' | sed 's/^ *//')"

# --- silence is a correct output, and the common one ---------------------------------------------
DONE='## Slice 1 — Seed
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] a

## Slice 2 — Wire
Blocked by: 1
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [x] b
'
R2="$(repo_with_plan feature/done 2026-01-01-feature-done.md "$DONE")"
equals "finished-plan-emits-nothing" "" "$(fire "$R2")"

R3="$(flow_repo)"
( cd "$R3" && git checkout -q -b feature/planless )
equals "no-plan-emits-nothing" "" "$(fire "$R3")"

# --- a committed plan that does not parse is not nothing -----------------------------------------
# Staying quiet here would let a branch with a broken plan look like a branch with no plan.
BROKEN='## Slice 1 — A
Blocked by: 9

- [ ] a
'
R4="$(repo_with_plan feature/broken 2026-01-01-feature-broken.md "$BROKEN")"
C4="$(context "$R4")"
check  "invalid-plan-is-reported" "does not parse"        "$C4"
check  "invalid-plan-names-lint"  "plan-lint.sh check"    "$C4"
absent "invalid-plan-emits-no-slices" "Slice 1 — A"       "$C4"

# --- the output is valid JSON in the shape the platform reads ------------------------------------
equals "emits-valid-json"  "0"             "$(fire "$R" | jq -e . >/dev/null 2>&1; echo $?)"
equals "names-the-event"   "SessionStart"  "$(fire "$R" | jq -r '.hookSpecificOutput.hookEventName')"

# A plan whose text carries quotes and backslashes must not break out of the JSON string. jq builds
# the object precisely so this cannot happen; the assertion is what keeps it that way.
NASTY='## Slice 1 — He said "run \\ now"
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a "quoted" \\ backslashed criterion
'
R5="$(repo_with_plan feature/quotes 2026-01-01-feature-quotes.md "$NASTY")"
equals "quotes-do-not-break-json" "0" "$(fire "$R5" | jq -e . >/dev/null 2>&1; echo $?)"
check  "quoted-text-survives" 'He said "run' "$(context "$R5")"

# --- a repository mid-flight on the deleted runtime ----------------------------------------------
# Advisory, and asserted as advisory: SessionStart cannot block, so the wording must not read as a
# gate, and the refusal is merge.sh's (tests/flow/test_merge.sh). What this must not do is stay
# quiet -- a repository holding state for a runtime that no longer exists otherwise looks idle.
legacy() { mkdir -p "$1/.claude/execute-task-runs"
           printf '{"schema_version":1}\n' > "$1/.claude/execute-task-runs/old.state.json"; }

# No plan at all is the likeliest pairing, and the path that used to exit before saying anything.
R6="$(flow_repo)"; legacy "$R6"
C6="$(context "$R6")"
check "legacy-without-a-plan-is-reported" "removed runtime" "$C6"
check "legacy-names-the-leftover-file"    "old.state.json"  "$C6"
equals "legacy-without-a-plan-is-json" "0" "$(fire "$R6" | jq -e . >/dev/null 2>&1; echo $?)"

# With a plan, both must arrive: reporting one and dropping the other is how a session acts on a
# plan whose repository cannot deliver it.
R7="$(repo_with_plan feature/legacy 2026-01-01-feature-legacy.md "$HALF")"; legacy "$R7"
C7="$(context "$R7")"
check "legacy-and-plan-both-reported" "removed runtime"  "$C7"
check "legacy-does-not-eat-the-plan"  "Rebuild it from"  "$C7"

# The disposal advice is conditional on what the leftover state records. It used to say "delete and
# re-plan" in every case; the live instance had a committed plan that passed the linter, and
# re-planning would have discarded a correct one.
#
# R6 and R7 above carry `{"schema_version":1}` -- a run that reached nothing -- so they must get the
# bare delete.
check  "untouched-run-is-a-bare-delete" "nothing to re-plan" "$C6"
absent "untouched-run-does-not-say-replan" "and re-plan —" "$C6"

# A run that recorded a candidate changed the tree, so its state is not disposable on its own.
R9="$(flow_repo)"; mkdir -p "$R9/.claude/execute-task-runs"
printf '{"schema_version":1,"candidate":{"sha":"%s","tree_sha":null,"recorded_at":null}}\n' \
  "0123456789012345678901234567890123456789" > "$R9/.claude/execute-task-runs/old.state.json"
C9="$(context "$R9")"
check  "candidate-run-says-replan"      "and re-plan —"     "$C9"
absent "candidate-run-not-bare-delete"  "nothing to re-plan" "$C9"

# So does one that got past planning, even with no candidate recorded yet.
R10="$(flow_repo)"; mkdir -p "$R10/.claude/execute-task-runs"
printf '{"schema_version":1,"completed_phases":["readiness","planning","implementation"]}\n' \
  > "$R10/.claude/execute-task-runs/old.state.json"
check "implemented-run-says-replan" "and re-plan —" "$(context "$R10")"

# A file this cannot read takes the cautious branch: advising a bare delete over work that was done
# is the costly error, and the opposite only wastes a re-plan.
R11="$(flow_repo)"; mkdir -p "$R11/.claude/execute-task-runs"
printf 'not json at all\n' > "$R11/.claude/execute-task-runs/old.state.json"
check "unreadable-state-fails-toward-replan" "and re-plan —" "$(context "$R11")"

# A repository with neither must stay silent. Without this, a warning that fired unconditionally
# would pass every assertion above.
R8="$(flow_repo)"
absent "no-legacy-no-warning" "removed runtime" "$(context "$R8")"

exit $fails
