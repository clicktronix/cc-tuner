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
# The plan grammar spells "no blockers" `none`; plan-lint's `-` is its own tab-record placeholder and
# must not leak into text the agent reads back as plan syntax.
equals "done-blocker-with-no-edge-says-none" "Blocked by: none" \
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
check  "invalid-plan-names-lint"  "plan-lint.sh\" check"  "$C4"
# The printed command must run as printed: an absolute script path, not a bare name that is on no PATH.
LINT_CMD="$(printf '%s' "$C4" | sed -n 's/^  \(bash .*\)$/\1/p')"
check  "invalid-plan-command-is-absolute" "bash \"$FLOW_PLUGIN/scripts/plan-lint.sh\" check" "$LINT_CMD"
equals "invalid-plan-command-runs" "plan-lint:" \
  "$(cd "$R4" && eval "$LINT_CMD" 2>&1 | head -1 | cut -d' ' -f1)"
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

# --- a session without the task tools ------------------------------------------------------------
# TaskCreate is off by default on current models. The instruction used to name only the tool calls,
# so a session without them had an order it could not follow and no word about the plan file.
R6="$(repo_with_plan feature/notools 2026-01-01-feature-notools.md "$HALF")"
check "names-the-fallback-without-task-tools" "If TaskCreate is not in your tool list, skip the rebuild and work from docs/task-plans/2026-01-01-feature-notools.md" "$(context "$R6")"

# --- checkboxes outside the slices ----------------------------------------------------------------
# Plans end in `## Verify`, `## Review`, `## Deliver` sections with their own checkboxes. Those are
# not the last slice's criteria (that kept it open after its work was done), and they are not
# dropped either: the hook lists them by section.
TAIL='
## Deliver
- [x] PR opened
- [ ] merged by squash

## Follow-ups
- [ ] metrics counter
'
R7="$(repo_with_plan feature/tail 2026-01-01-feature-tail.md "$HALF$TAIL")"
C7="$(context "$R7")"
check  "open-slice-still-restored"        "Slice 3 — Ship it"                    "$C7"
check  "outside-checkboxes-are-listed"    "Open checkboxes outside the slices"   "$C7"
check  "outside-checkbox-under-its-section" "Deliver
    - [ ] merged by squash"                                                       "$C7"
check  "second-section-listed"            "Follow-ups
    - [ ] metrics counter"                                                        "$C7"
absent "ticked-outside-checkbox-not-listed" "PR opened"                          "$C7"
absent "outside-checkbox-is-not-a-criterion" "released
    - [ ] merged"                                                                 "$C7"
# Every slice done, delivery still open: the plan is not finished, and silence would lose it.
DONE_SLICES="$(printf '%s' "$HALF" | sed 's/- \[ \] /- [x] /g')"
R8="$(repo_with_plan feature/deliver 2026-01-01-feature-deliver.md "$DONE_SLICES$TAIL")"
C8="$(context "$R8")"
check  "done-slices-open-delivery-speaks"  "every slice in this branch's committed plan is done" "$C8"
check  "done-slices-lists-the-open-box"    "    - [ ] merged by squash"   "$C8"
absent "done-slices-ask-for-no-rebuild"    "TaskCreate"                   "$C8"
equals "done-slices-output-is-json" "0" "$(fire "$R8" | jq -e . >/dev/null 2>&1; echo $?)"
# Nothing open anywhere is still silence.
R9="$(repo_with_plan feature/alldone 2026-01-01-feature-alldone.md "$DONE_SLICES$(printf '%s' "$TAIL" | sed 's/- \[ \] /- [x] /g')")"
equals "all-ticked-everywhere-is-silent" "" "$(fire "$R9")"

# A plan already present in the remote default branch is finished work: a branch reused after its
# merge must not be told to rebuild it (field: a finished epic's plan was pushed into a new session).
R_LANDED="$(repo_with_plan feat/landed 2026-01-01-feat-landed.md "**Spec:** docs/PLANS/s.md
**Branch:** feat/landed

$HALF")"
(
  cd "$R_LANDED" || exit 1
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
)
equals "landed-plan-is-silent" "" "$(fire "$R_LANDED")"
# A landed plan that this branch extended with a new open slice is open work, not landed work.
R_EXT="$(repo_with_plan feat/extended 2026-01-01-feat-extended.md "**Spec:** docs/PLANS/s.md
**Branch:** feat/extended

$HALF")"
(
  cd "$R_EXT" || exit 1
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '\n## Slice 4 — Extension\nBlocked by: 3\nOwned paths: src/\nDeciding check: t\nDelivers: d\n\n- [ ] new\n' >> docs/task-plans/2026-01-01-feat-extended.md
  git commit -qam extend
)
check "extended-landed-plan-restored" "Slice 4 — Extension" "$(context "$R_EXT")"
# The same plan not yet on the default branch is still restored, and the wording is advisory.
R_OPEN="$(repo_with_plan feat/open 2026-01-01-feat-open.md "**Spec:** docs/PLANS/s.md
**Branch:** feat/open

$HALF")"
( cd "$R_OPEN" && git update-ref refs/remotes/origin/main HEAD^ && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main )
C_OPEN="$(context "$R_OPEN")"
check  "unlanded-plan-restored"   "Slice 2 — Wire the budget" "$C_OPEN"
check  "restore-is-advisory"      "if the session is about something else, ignore this" "$C_OPEN"
absent "no-before-anything-else"  "before doing anything else" "$C_OPEN"

# A different index or working file cannot silently become the branch's committed task list.
(
  cd "$R_OPEN" || exit 1
  P=docs/task-plans/2026-01-01-feat-open.md
  sed 's/Wire the budget/Staged version/' "$P" > "$P.new"
  mv "$P.new" "$P"
  git add "$P"
  sed 's/Staged version/Working version/' "$P" > "$P.new"
  mv "$P.new" "$P"
)
C_DIRTY="$(context "$R_OPEN")"
check "dirty-plan-restores-head-version" "Slice 2 — Wire the budget" "$C_DIRTY"
absent "staged-version-not-restored" "Staged version" "$C_DIRTY"
absent "unstaged-version-not-restored" "Working version" "$C_DIRTY"
# The working copy is named, since a --local-only run keeps its ticks there; a clean one is not.
check  "dirty-plan-names-the-working-copy" "differs from HEAD" "$C_DIRTY"
absent "clean-plan-says-nothing-about-the-working-copy" "differs from HEAD" "$(context "$R")"

# --- a plan that exists only on disk (a --local-only run) is restored from the file ----------------
# plan-path.sh found it with --local-only and /run worked from it, but the hook asked HEAD alone and
# said nothing: the run lost its plan at every /clear, compaction and new session.
R_LOCAL="$(flow_repo)"
(
  cd "$R_LOCAL" || exit 1
  git checkout -q -b feature/local
  mkdir -p docs/task-plans
  printf '%s' "$HALF" > docs/task-plans/2026-01-01-feature-local.md
) || { printf 'FATAL: setup failed\n'; exit 1; }
C_LOCAL="$(context "$R_LOCAL")"
check  "local-only-plan-is-restored"          "Slice 2 — Wire the budget"   "$C_LOCAL"
check  "local-only-plan-keeps-open-criteria"  "exhaustion is observable"    "$C_LOCAL"
check  "local-only-plan-is-named-uncommitted" "an uncommitted plan on disk" "$C_LOCAL"
check  "local-only-plan-names-the-resume"     "/cc-tuner:run --local-only"  "$C_LOCAL"
absent "local-only-plan-is-not-told-to-commit" "and commit it"              "$C_LOCAL"
# Committed afterwards, the same plan is HEAD's again and is described as such.
( cd "$R_LOCAL" && git add -A && git commit -q -m 'add plan' )
C_NOW="$(context "$R_LOCAL")"
check  "committed-later-plan-is-a-committed-plan" "a committed plan with unfinished slices" "$C_NOW"
absent "committed-later-plan-has-no-local-wording" "uncommitted plan on disk" "$C_NOW"

exit $fails
