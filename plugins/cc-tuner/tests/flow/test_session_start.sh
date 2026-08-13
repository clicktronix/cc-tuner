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

exit $fails
