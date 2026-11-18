#!/usr/bin/env bash
# plan-lint.sh: the plan format's validator and the parser the restore hook reads it back with.
#
# One parser, four modes. If a caller grew its own reader, a plan the linter accepted could still
# restore or execute wrongly and nothing would say so.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LINT="$FLOW_PLUGIN/scripts/plan-lint.sh"
W="$(flow_workdir)"

check "help-owns-owned-path-grammar" "Owned paths: comma-separated repo-relative literal paths" \
  "$(bash "$LINT" --help)"

# plan <name> <body> -> path to a plan file with the canonical headers
plan() {
  printf '**Spec:** docs/PLANS/example.md\n**Branch:** feat/example\n\n%s' "$2" > "$W/$1.md"
  printf '%s' "$W/$1.md"
}
raw_plan() { printf '%s' "$2" > "$W/$1.md"; printf '%s' "$W/$1.md"; }

# lint <mode> <file> [args...] -> stdout+stderr then rc=<code>
lint() { local mode="$1" file="$2"; shift 2; out="$(bash "$LINT" "$mode" "$file" "$@" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?"; }

VALID='# Retry budget

## Slice 1 — Seed the config
Blocked by: none
Owned paths: src/config/
Deciding check: pnpm test tests/config
Delivers: the budget is readable from config.

- [x] budget key exists
- [x] default is documented

## Slice 2 — Wire the budget
Blocked by: 1
Owned paths: src/retry/
Deciding check: pnpm test tests/retry
Delivers: a request that exhausts its budget fails with one typed error.

- [x] budget is read from config, not hardcoded
- [ ] exhaustion is observable in the returned error
'

# --- a valid plan passes, and parses into the records the hook needs -----------------------------
P="$(plan valid "$VALID")"
OUT="$(lint check "$P")"
check "valid-plan-rc0" "rc=0" "$OUT"

S="$(bash "$LINT" slices "$P")"
equals "slice-1-record" "SLICE	1	done	-	Seed the config"  "$(printf '%s' "$S" | sed -n '1p')"
equals "slice-2-record" "SLICE	2	open	1	Wire the budget" "$(printf '%s' "$S" | sed -n '4p')"
# The criteria carry their own state, so a restore can emit only the open ones.
equals "open-criterion" "CRIT	2	open	exhaustion is observable in the returned error" \
  "$(printf '%s' "$S" | sed -n '6p')"
equals "record-count" "6" "$(printf '%s\n' "$S" | grep -c .)"

# Progress is derived, not stored: every criterion ticked is the only thing that makes a slice done.
# sed, not ${VALID//- [ ]/...}: brackets are a glob character class in parameter expansion, so the
# pattern silently matches nothing and the assertion tests the unmodified plan.
DONE="$(printf '%s' "$VALID" | sed 's/- \[ \] exhaustion/- [x] exhaustion/')"
P2="$(plan alldone "$DONE")"
equals "all-ticked-is-done" "done" \
  "$(bash "$LINT" slices "$P2" | awk -F'\t' '$1=="SLICE" && $2==2 {print $3}')"

# --- the three checks the plan names -------------------------------------------------------------
P="$(plan noblocked '## Slice 1 — A
Delivers: x

- [ ] a
')"
OUT="$(lint check "$P")"
check "missing-blocked-by-message" 'has no "Blocked by" line' "$OUT"
check "missing-blocked-by-rc1"     "rc=1"                     "$OUT"

P="$(plan dangling '## Slice 1 — A
Blocked by: 9

- [ ] a
')"
OUT="$(lint check "$P")"
check "dangling-blocker-message" "blocked by slice 9, which does not exist" "$OUT"
check "dangling-blocker-rc1"     "rc=1"                                     "$OUT"

# The orphan checkbox is the mistake that loses the graph: criteria read as slices, and the restore
# comes back with no titles and no edges.
P="$(plan orphan '- [ ] a criterion with no slice

## Slice 1 — A
Blocked by: none

- [ ] a
')"
OUT="$(lint check "$P")"
check "orphan-checkbox-message" "checkbox outside any slice" "$OUT"
check "orphan-checkbox-rc1"     "rc=1"                       "$OUT"

# --- checks beyond the three ---------------------------------------------------------------------
P="$(plan nocriteria '## Slice 1 — A
Blocked by: none
Delivers: x
')"
OUT="$(lint check "$P")"
check "no-criteria-message" "can never be done" "$OUT"

# Complete but for the self-edge, so the diagnostic count below is the count of THIS defect.
P="$(plan selfblock '## Slice 1 — A
Blocked by: 1
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
OUT="$(lint check "$P")"
# Self-blocking is the one-hop cycle, and is reported as one. It used to be flagged twice, and a
# substring assertion cannot tell those apart -- so count the diagnostics, not the phrase. Without
# the count, restoring the second report leaves this suite green.
check  "self-block-message" "part of a blocking cycle" "$OUT"
equals "self-block-reported-once" "1" "$(printf '%s\n' "$OUT" | grep -c '^plan-lint: slice 1 ')"

P="$(plan duplicate '## Slice 1 — A
Blocked by: none

- [ ] a

## Slice 1 — B
Blocked by: none

- [ ] b
')"
OUT="$(lint check "$P")"
check "duplicate-slice-message" "declared twice" "$OUT"

# A cycle has no frontier at all: nothing can ever start, and the restore hook would resurrect the
# whole graph every session. Self-blocking, caught before, is only its one-hop case.
P="$(plan cycle '## Slice 1 — A
Blocked by: 2
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — B
Blocked by: 1
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b
')"
OUT="$(lint check "$P")"
check "cycle-message" "part of a blocking cycle" "$OUT"
check "cycle-rc1"     "rc=1"                     "$OUT"

# Owned paths is load-bearing: /cc-tuner:run decides what may run in parallel by whether they overlap.
P="$(plan missingfields '## Slice 1 — A
Blocked by: none

- [ ] a
')"
OUT="$(lint check "$P")"
check "requires-owned-paths"    'has no "Owned paths" line'    "$OUT"
check "requires-deciding-check" 'has no "Deciding check" line' "$OUT"
check "requires-delivers"       'has no "Delivers" line'       "$OUT"

P="$(plan empty '# A plan with prose and nothing else
')"
OUT="$(lint check "$P")"
check "no-slices-message" "no slices found" "$OUT"

# --- slices refuses an invalid plan --------------------------------------------------------------
# Restoring half a graph is worse than restoring none: the second is visible, the first is not.
P="$(plan broken '## Slice 1 — A
Blocked by: 9

- [ ] a
')"
OUT="$(lint slices "$P")"
check  "slices-refuses-invalid"      "refusing to parse an invalid plan" "$OUT"
check  "slices-refuses-invalid-rc1"  "rc=1"                              "$OUT"
absent "slices-emits-nothing-on-bad" "SLICE	1"                          "$OUT"

# --- owned: the Owned-paths grammar leaves this file exactly once ---------------------------------
# shard-diff.sh groups a candidate diff by these paths. If it parsed the plan itself, a plan this
# linter accepted could shard along different lines from the ones it is scheduled on.
P="$(plan owned-order '## Slice 1 — A
Blocked by: none
Owned paths: src/config/ , tests/config/config.test.ts
Deciding check: true
Delivers: a.

- [x] a

## Slice 2 — B
Blocked by: 1
Owned paths: src/retry/
Deciding check: true
Delivers: b.

- [ ] b
')"
equals "owned-one-line-per-slice-in-plan-order" "OWNED	1	src/config/,tests/config/config.test.ts
OWNED	2	src/retry/" "$(bash "$LINT" owned "$P")"
absent "owned-emits-no-slice-records" "SLICE" "$(bash "$LINT" owned "$P")"
OUT="$(lint owned "$(plan owned-broken '## Slice 1 — A
Blocked by: 9

- [ ] a
')")"
check  "owned-refuses-invalid"     "refusing to parse an invalid plan" "$OUT"
check  "owned-refuses-invalid-rc1" "rc=1"                              "$OUT"
absent "owned-emits-nothing-on-bad" "OWNED	1"                         "$OUT"
check  "help-names-owned"          "owned: one OWNED"                  "$(bash "$LINT" --help)"
OUT="$(lint owned "$(raw_plan owned-nohdr '## Slice 1 — A
Blocked by: none
Owned paths: src/
Deciding check: true
Delivers: a.

- [ ] a
')")"
check  "owned-requires-headers-like-check" "refusing to parse an invalid plan" "$OUT"
check  "owned-requires-headers-rc1"        "rc=1"             "$OUT"

# --- the grammar is exact, and every near-miss is refused -----------------------------------------
# Each of these was accepted at some point. Leniency here is not kindness: the writer is a model, and
# whatever it sees accepted is what the next plan will be written in, until the file says three
# things and means one. Every case below fails if the corresponding leniency comes back.
P="$(plan lowerheading '## slice 1 — A
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
OUT="$(lint check "$P")"
check "lowercase-slice-heading-is-not-a-slice" "no slices found" "$OUT"

P="$(plan lowerblocked '## Slice 1 — A
blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
OUT="$(lint check "$P")"
check "lowercase-blocked-by-is-not-the-field" 'write "Blocked by: <value>" at the start of the line' "$OUT"
check "lowercase-blocked-by-rc1" "rc=1" "$OUT"

P="$(plan capitalnone '## Slice 1 — A
Blocked by: None
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
OUT="$(lint check "$P")"
check "capital-None-is-refused" 'the only accepted spelling is "none"' "$OUT"
check "capital-None-rc1"        "rc=1"                                 "$OUT"

P="$(plan emptyblocked '## Slice 1 — A
Blocked by:
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
OUT="$(lint check "$P")"
check "empty-blocked-by-is-refused" 'has an empty "Blocked by" line' "$OUT"
check "empty-blocked-by-rc1"        "rc=1"                           "$OUT"

# Reading "-" back was leniency for an input neither the template nor either skill produces.
P="$(plan none '## Slice 1 — A
Blocked by: none
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
equals "none-emits-the-dash-sentinel" "-" "$(bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE" {print $4}')"

P="$(plan dash '## Slice 1 — A
Blocked by: -
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
check "a-literal-dash-is-not-a-blocker-list" "not a slice number" "$(lint check "$P")"

# Blocker tokens are numbers, not prose from which the parser can salvage a number. The old parser
# stripped every non-digit, so `slice-1` validated and was silently restored as edge `1`.
P="$(plan proseblocker '## Slice 1 — A
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — B
Blocked by: slice-1
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b
')"
check "blocker-token-is-exact" "not a slice number" "$(lint check "$P")"

# Two heading shapes, one rule. A bare `## Slice 1` and a joined `## Slice 1Title` both fail the
# separator check, so the linter reports one error for one defect rather than one per symptom.
P="$(plan notitle '## Slice 1
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
OUT="$(lint check "$P")"
check "bare-heading-needs-a-separator" "heading needs a separator and title" "$OUT"
equals "one-error-per-malformed-heading" "1" "$(printf '%s' "$OUT" | grep -c '^plan-lint: ')"

P="$(plan joinedtitle '## Slice 1Title
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
check "slice-heading-needs-a-separator" "heading needs a separator and title" "$(lint check "$P")"

# A criterion is done when its box is ticked, not when its text happens to contain one. Scanning the
# whole line marked this slice done, and the restore hook then stops resurrecting a slice nobody did.
P="$(plan literalbox '## Slice 1 — A
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] handle the [x] flag in the parser
')"
equals "criterion-text-is-not-a-tick" "open" \
  "$(bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE" {print $3}')"

P="$(plan duplicateblocked '## Slice 1 — A
Blocked by: none
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
check "blocked-by-is-one-record" 'more than one "Blocked by" line' "$(lint check "$P")"

# --- readiness: the runner asks the file which slice may start -----------------------------------
# /cc-tuner:run drives from `ready-batches`, with or without the native task tools. The rule -- open
# slices whose blockers are all done -- was prose in two skills and arithmetic done by hand, which is
# how a blocked slice gets started under --auto. ready <plan> prints the SLICE records of the batch.
ready() { bash "$LINT" ready-batches "$1" | grep '^SLICE'; }
FRONTIER='## Slice 1 — Seed
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [x] a

## Slice 2 — Wire
Blocked by:  1 , 3
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b

## Slice 3 — Independent
Blocked by: none
Owned paths: c/
Deciding check: t
Delivers: d

- [ ] c
'
P="$(plan frontier "$FRONTIER")"
# Slice 2 is the lowest-numbered OPEN slice, and it is exactly the one that must not be handed back:
# slice 3 blocks it and is not done. A frontier that just took the first open slice would return 2.
equals "frontier-refuses-a-blocked-slice" "SLICE	3	open	-	Independent" "$(ready "$P")"

# With the blocker done, the blocked slice becomes the frontier -- and its edges come back normalised
# the same way `slices` emits them, so one reader parses both modes.
P="$(plan frontier_unblocked "$(printf '%s' "$FRONTIER" | sed 's/- \[ \] c/- [x] c/')")"
equals "frontier-releases-when-blockers-clear" "SLICE	2	open	1,3	Wire" "$(ready "$P")"

# Nothing open means the loop is over, and that has to be distinguishable from an error.
P="$(plan frontier_done "$(printf '%s' "$FRONTIER" | sed 's/- \[ \] /- [x] /g')")"
OUT="$(lint ready-batches "$P")"
check "frontier-empty-when-all-done" "rc=0" "$OUT"
equals "frontier-prints-nothing-when-all-done" "" "$(bash "$LINT" ready-batches "$P")"

# A plan that does not parse gets no answer at all: half a graph would start the wrong slice.
P="$(plan frontier_invalid '## Slice 1 — A
Blocked by: slice-2
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
OUT="$(lint ready-batches "$P")"
check "frontier-refuses-an-invalid-plan" "refusing to parse an invalid plan" "$OUT"
check "frontier-invalid-rc1"             "rc=1"                              "$OUT"

# Every ready slice, not the first one. `references/placement.md` fans work out across independent
# slices; a frontier that returned one made that unreachable, because the second could not be had
# without finishing the first.
P="$(plan frontier_many '## Slice 1 — Alpha
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — Beta
Blocked by: none
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b

## Slice 3 — Gamma
Blocked by: 1
Owned paths: c/
Deciding check: t
Delivers: d

- [ ] c
')"
equals "frontier-emits-every-ready-slice" "SLICE	1	open	-	Alpha
SLICE	2	open	-	Beta" "$(ready "$P")"

# By slice number, not by the order the file declares them. Nothing stops a plan writing Slice 3
# above Slice 1, and the loop was promised the lowest number first.
P="$(plan frontier_order '## Slice 3 — Declared first
Blocked by: none
Owned paths: c/
Deciding check: t
Delivers: d

- [ ] c

## Slice 1 — Declared second
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
equals "frontier-orders-by-number-not-by-file" "SLICE	1	open	-	Declared second
SLICE	3	open	-	Declared first" "$(ready "$P")"

# --- ready batches: parallelism is an executable decision ---------------------------------------
P="$(plan ready_batches '## Slice 1 — Retry
Blocked by: none
Owned paths: src/retry/, tests/retry/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — Logging
Blocked by: none
Owned paths: src/logging/, tests/logging/
Deciding check: t
Delivers: d

- [ ] b

## Slice 3 — Retry telemetry
Blocked by: none
Owned paths: src/retry/telemetry.ts
Deciding check: t
Delivers: d

- [ ] c
')"
equals "ready-batch-groups-only-proven-disjoint-slices" "BATCH	1,2	parallel	owned paths proven disjoint
SLICE	1	open	-	Retry
SLICE	2	open	-	Logging" "$(bash "$LINT" ready-batches "$P")"

P="$(plan component_boundary '## Slice 1 — Retry
Blocked by: none
Owned paths: src/retry/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — Retrying
Blocked by: none
Owned paths: src/retrying/
Deciding check: t
Delivers: d

- [ ] b
')"
check "component-boundary-is-not-a-prefix-overlap" "BATCH	1,2	parallel" \
  "$(bash "$LINT" ready-batches "$P")"

for owned_path in 'src/**/*.ts' '/abs/path/' '., src/' './src/' '../other/' 'src/{a,b}/' 'src//double/'; do
  P="$(plan bad_owned "## Slice 1 — A
Blocked by: none
Owned paths: $owned_path
Deciding check: t
Delivers: d

- [ ] a
")"
  OUT="$(lint check "$P")"
  check "non-literal-owned-path-$owned_path" "non-literal Owned path" "$OUT"
  check "non-literal-owned-path-rc1-$owned_path" "rc=1" "$OUT"
done

# App Router directory names are literal: `[locale]` and `(shell)` are real directories, not globs.
# Refusing them sent agents to widen ownership to `src/app`, which voided the disjointness proof.
P="$(plan app_router '## Slice 1 — Locale layout
Blocked by: none
Owned paths: src/app/(shell)/[locale]/layout.tsx, src/app/@modal/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — Settings page
Blocked by: none
Owned paths: src/app/(shell)/[locale]/settings/
Deciding check: t
Delivers: d

- [ ] b
')"
check "app-router-literal-paths-pass" "rc=0" "$(lint check "$P")"
check "app-router-paths-stay-disjoint" "BATCH	1,2	parallel" "$(bash "$LINT" ready-batches "$P")"

# The header comparison is the only guard against running plan A with spec B's DoD and merge shape.
# This is fixture data, not repository state. A frozen eval runs from a detached worktree, where
# `git branch --show-current` is empty and used to make the suite fail before testing the validator.
BRANCH="feat/fixture-branch"
P="$(raw_plan expected_headers "**Spec:** README.md
**Branch:** $BRANCH

## Slice 1 — A
Blocked by: none
Owned paths: src/a/
Deciding check: t
Delivers: d

- [ ] a
")"
check "matching-spec-and-branch-pass" "rc=0" \
  "$(lint check "$P" --spec README.md --branch "$BRANCH" --local-only)"
# One path, two spellings: the caller's `./README.md` is the plan's `README.md`, and the other way round.
check "dot-slash-spec-is-the-same-path" "rc=0" \
  "$(lint check "$P" --spec ./README.md --branch "$BRANCH" --local-only)"
sed 's|^\*\*Spec:\*\* |&./|' "$P" > "$P.dot"
check "dot-slash-in-the-plan-header-too" "rc=0" \
  "$(lint check "$P.dot" --spec README.md --branch "$BRANCH" --local-only)"
check "mismatched-spec-is-refused" "expected \"CHANGELOG.md\"" \
  "$(lint check "$P" --spec CHANGELOG.md --branch "$BRANCH" --local-only)"
check "mismatched-branch-is-refused" "expected \"not-this-branch\"" \
  "$(lint check "$P" --spec README.md --branch not-this-branch --local-only)"
# /spec lints the plan before committing spec and plan together, so a spec that exists but is not
# tracked yet is accepted; a missing one is still refused.
UR="$(flow_repo)"
mkdir -p "$UR/docs/PLANS" "$UR/docs/task-plans"
printf '# fixture\n' > "$UR/docs/PLANS/untracked.md"
printf '**Spec:** docs/PLANS/untracked.md\n**Branch:** %s\n\n## Slice 1 — A\nBlocked by: none\nOwned paths: src/\nDeciding check: t\nDelivers: d\n\n- [ ] a\n' "$BRANCH" > "$UR/docs/task-plans/p.md"
OUT="$(cd "$UR" && lint check docs/task-plans/p.md --spec docs/PLANS/untracked.md --branch "$BRANCH" --local-only)"
check "untracked-spec-accepted" "rc=0" "$OUT"
OUT="$(cd "$UR" && lint check docs/task-plans/p.md --spec docs/PLANS/absent.md --branch "$BRANCH" --local-only)"
check "missing-spec-refused" "does not exist" "$OUT"
# full_test_cadence is a closed set /run reads: a misspelling would silently mean the default.
printf '# fixture\nfull_test_cadence: per-batch — cheap suite\n' > "$UR/docs/PLANS/untracked.md"
OUT="$(cd "$UR" && lint check docs/task-plans/p.md --spec docs/PLANS/untracked.md --branch "$BRANCH" --local-only)"
check "known-cadence-accepted" "rc=0" "$OUT"
printf '# fixture\nfull_test_cadence: nightly\n' > "$UR/docs/PLANS/untracked.md"
OUT="$(cd "$UR" && lint check docs/task-plans/p.md --spec docs/PLANS/untracked.md --branch "$BRANCH" --local-only)"
check "unknown-cadence-refused" 'full_test_cadence to "nightly"' "$OUT"
check "unknown-cadence-rc1"     "rc=1" "$OUT"
printf '# fixture\nfull_test_cadence: per-batch\nfull_test_cadence: per-candidate\n' > "$UR/docs/PLANS/untracked.md"
OUT="$(cd "$UR" && lint check docs/task-plans/p.md --spec docs/PLANS/untracked.md --branch "$BRANCH" --local-only)"
check "duplicate-cadence-refused" "more than one full_test_cadence" "$OUT"
printf '# fixture\n' > "$UR/docs/PLANS/untracked.md"
check "empty-expected-spec-is-refused" "--spec requires a non-empty path" \
  "$(lint check "$P" --spec '' --branch "$BRANCH" --local-only)"
check "empty-expected-branch-is-refused" "--branch requires a non-empty name" \
  "$(lint check "$P" --spec README.md --branch '')"

P="$(raw_plan missing_headers '## Slice 1 — A
Blocked by: none
Owned paths: src/a/
Deciding check: t
Delivers: d

- [ ] a
')"
OUT="$(lint check "$P")"
check "missing-spec-header-is-refused" "needs one non-empty **Spec:**" "$OUT"
check "missing-branch-header-is-refused" "needs one non-empty **Branch:**" "$OUT"

# Numeric order needs one canonical spelling. Without this check `01` and `1` are distinct awk map
# keys but equal sort keys, so the plan can declare the same logical number twice and make ordering
# depend on file position again.
P="$(plan leading_zero '## Slice 01 — Leading
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a

## Slice 1 — Canonical
Blocked by: none
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b
')"
OUT="$(lint check "$P")"
check "leading-zero-slice-is-refused" "has a leading zero; use the canonical number 1" "$OUT"
check "leading-zero-slice-rc1"       "rc=1"                                           "$OUT"

# --- the shipped template makes required replacement executable ----------------------------------
# An unfilled Owned-path slot must fail. Once it is filled, the template itself demonstrates the edge
# grammar it teaches.
TPL="$FLOW_PLUGIN/skills/spec/plan-template.md"
OUT="$(lint check "$TPL")"
check "template-requires-owned-path-replacement" "non-literal Owned path" "$OUT"
FILLED_TPL="$W/filled-template.md"
sed 's/<REPLACE_ME>/src\/example/g' "$TPL" > "$FILLED_TPL"
check "filled-template-passes-lint" "rc=0" "$(lint check "$FILLED_TPL")"
equals "template-has-an-edge" "1" \
  "$(bash "$LINT" slices "$FILLED_TPL" | awk -F'\t' '$1=="SLICE" && $2==2 {print $4}')"

# --- the active set: the plan knows open/done, only the caller knows running -----------------------
# A ready slice already handed to a unit is still "open", so a bare ready-batches would hand it out
# again. --active names the running slices; the parser excludes them and, for ready-batches, anything
# whose Owned paths overlap theirs. Slice 4 shares a prefix with running slice 2 on purpose.
ACTIVE_PLAN='# Rolling

## Slice 1 — A, fast, done
Blocked by: none
Owned paths: src/a/
Deciding check: true
Delivers: a.

- [x] a1

## Slice 2 — B, slow, running
Blocked by: none
Owned paths: src/b/
Deciding check: true
Delivers: b.

- [ ] b1

## Slice 3 — C, needs only A
Blocked by: 1
Owned paths: src/c/
Deciding check: true
Delivers: c.

- [ ] c1

## Slice 4 — D, needs A, overlaps B
Blocked by: 1
Owned paths: src/b/sub/
Deciding check: true
Delivers: d.

- [ ] d1
'
P="$(plan active "$ACTIVE_PLAN")"
# Without --active the parser cannot know 2 is running, so it returns it again: the defect the flag exists for.
equals "without-active-relaunches-the-running-slice" "BATCH	2,3	parallel	owned paths proven disjoint" \
  "$(bash "$LINT" ready-batches "$P" | sed -n '1p')"
# With --active 2: 2 is excluded, 4 is excluded because its paths overlap 2's, 3 alone remains.
equals "active-excludes-running-and-its-path-neighbours" "BATCH	3	serial	no second ready slice has proven-disjoint owned paths" \
  "$(bash "$LINT" ready-batches "$P" --active 2 | sed -n '1p')"
equals "active-batch-lists-only-the-safe-slice" "1" \
  "$(bash "$LINT" ready-batches "$P" --active 2 | grep -c '^SLICE')"
# Everything ready is running or path-blocked: empty stdout, rc 0, and a stderr line saying it is not completion.
OUT="$(lint ready-batches "$P" --active 2,3)"
check "all-active-is-not-completion-message" "this is not completion" "$OUT"
check "all-active-rc0"                       "rc=0"                   "$OUT"
equals "all-active-emits-no-batch" "0" "$(bash "$LINT" ready-batches "$P" --active 2,3 2>/dev/null | grep -c '^BATCH')"
# A stale active set is the state that launches a duplicate writer, so it is refused, never ignored.
OUT="$(lint ready-batches "$P" --active 9)"
check "unknown-active-slice-message" "active slice 9 does not exist" "$OUT"
check "unknown-active-slice-rc1"     "rc=1"                          "$OUT"
OUT="$(lint ready-batches "$P" --active 1)"
check "done-active-slice-message" "active slice 1 is already done" "$OUT"
check "done-active-slice-rc1"     "rc=1"                            "$OUT"
OUT="$(lint ready-batches "$P" --active 2,,3)"
check "malformed-active-list-message" "slice numbers separated by commas" "$OUT"
check "malformed-active-list-rc1"     "rc=1"                              "$OUT"
OUT="$(lint check "$P" --active 2)"
check "active-refused-outside-readiness-modes" "applies to ready-batches only" "$OUT"
check "active-refused-rc1"                     "rc=1"                                       "$OUT"
check "help-names-the-active-set" "An empty result with --active does not mean the plan is done" "$(bash "$LINT" --help)"

# `frontier` was a second readiness mode with no caller, and one that did not check paths.
OUT="$(lint frontier "$P")"
check "frontier-mode-is-gone" "usage:" "$OUT"
check "frontier-mode-rc1"     "rc=1"   "$OUT"
absent "help-does-not-offer-frontier" "frontier" "$(bash "$LINT" --help)"

# --- where a slice ends ---------------------------------------------------------------------------
# A slice used to run to the next slice heading or the end of the file, so a checkbox in a closing
# section belonged to the last slice: fully ticked, it stayed open, ready-batches offered it again and
# the restore hook resurrected it every session.
SLICE_ONE='## Slice 1 — Seed
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [x] a
- [x] b
'
P="$(plan trailing "$SLICE_ONE"'
## Deliver
Blocked by: whoever picks these up
- [x] PR opened
- [ ] merged by squash

## Follow-ups
- [ ] consider a metrics counter later
')"
OUT="$(lint check "$P")"
check  "trailing-section-is-valid" "rc=0" "$OUT"
# The work those sections track is not dropped: their unticked boxes come back as OPEN records, after
# the slices, so the restore hook can still name them. Real plans end in `## Verify`, `## Deliver`.
equals "trailing-checkbox-is-not-a-criterion" "SLICE	1	done	-	Seed
CRIT	1	done	a
CRIT	1	done	b
OPEN	Deliver	merged by squash
OPEN	Follow-ups	consider a metrics counter later" "$(bash "$LINT" slices "$P")"
equals "finished-slice-is-not-offered-again" "" "$(bash "$LINT" ready-batches "$P")"
# A deeper heading is part of the slice, and its checkboxes still count.
P="$(plan subheading "$SLICE_ONE"'
### Edge cases
- [ ] c
')"
check "subheading-stays-in-the-slice" "CRIT	1	open	c" "$(bash "$LINT" slices "$P")"

# A fenced block is an example. Its heading used to become a phantom slice and its checkbox a criterion.
P="$(plan fenced "$SLICE_ONE"'
```markdown
## Slice 2 — Example
- [ ] example criterion
```
~~~
- [ ] another example
~~~
')"
check  "fenced-example-is-valid"     "rc=0"    "$(lint check "$P")"
equals "fenced-example-adds-nothing" "1 done"  "$(bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE"{print $2, $3}')"
equals "fenced-checkbox-is-not-a-criterion" "2" "$(bash "$LINT" slices "$P" | grep -c '^CRIT')"

# --- a near miss names the grammar ---------------------------------------------------------------
# `### Slice 1: Title` was skipped as an unknown line and the report was about its criteria:
# "checkbox outside any slice", which names the symptom.
for near in '### Slice 1 — Seed' '# Slice 1 — Seed' '## slice 1 — Seed' '##Slice 1 — Seed' '## Slice #1 — Seed'; do
  P="$(plan near "$near"'
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
  OUT="$(lint check "$P")"
  check  "near-miss-heading-refused ($near)"  "is not a slice heading; write \"## Slice <n> — <title>\"" "$OUT"
  check  "near-miss-heading-quoted ($near)"   "\"$near\""                    "$OUT"
  absent "near-miss-no-orphan-cascade ($near)" "checkbox outside any slice"   "$OUT"
  check  "near-miss-rc1 ($near)"              "rc=1"                         "$OUT"
done
for near in '## Slice 1: Seed' '## Slice 1 -' '## Slice 1:'; do
  P="$(plan near2 "$near"'
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
  check "near-miss-separator-names-grammar ($near)" "use \"## Slice 1 — Title\"" "$(lint check "$P")"
done

# A field line with a bullet or emphasis was skipped too, and reported as a field the slice lacks.
P="$(plan decorated '## Slice 1 — Seed
- **Blocked by:** none
- **Owned paths:** `a/`
**Deciding check:** t
* delivers: d

- [ ] a
')"
OUT="$(lint check "$P")"
check  "bulleted-field-names-the-grammar" "write \"Owned paths: <value>\" at the start of the line" "$OUT"
check  "bulleted-field-is-quoted"         "\"- **Owned paths:** \`a/\`\" is not read as a field"     "$OUT"
check  "bold-field-names-the-grammar"     "write \"Deciding check: <value>\""  "$OUT"
check  "lowercase-field-names-the-grammar" "write \"Delivers: <value>\""       "$OUT"
check  "bulleted-blocker-names-the-grammar" "write \"Blocked by: <value>\""    "$OUT"
absent "decorated-field-not-also-missing" "has no \""                         "$OUT"
equals "one-error-per-decorated-field" "4" "$(printf '%s' "$OUT" | grep -c '^plan-lint: ')"
# A criterion or a note that mentions a field name is prose when the slice has the field, and a
# heading that merely starts with the word is an ordinary heading. Both are in committed plans.
P="$(raw_plan mentions '# Slice unit cap — plan

**Spec:** docs/PLANS/example.md
**Branch:** feat/example

'"$SLICE_ONE"'- [ ] Delivers: the doc says so
- Deciding check: `git diff --check` → clean
')"
check "prose-mentioning-a-field-is-valid" "rc=0" "$(lint check "$P")"

# --- the dash under a byte-oriented awk ----------------------------------------------------------
# A bracket expression holding the em dash matched one of its three bytes in the C locale (and in mawk
# everywhere), so the restored title began with the other two.
P="$(plan dashes '## Slice 1 — Em
Blocked by: none
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 – En
Blocked by: Slice 1
Owned paths: b/
Deciding check: t
Delivers: d

- [ ] b

## Slice 3 - Hyphen
Blocked by: slice 1, 2
Owned paths: c/
Deciding check: t
Delivers: d

- [ ] c
')"
equals "c-locale-titles-are-whole" "Em|En|Hyphen" \
  "$(LC_ALL=C bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE"{print $5}' | paste -sd'|' -)"
equals "utf8-locale-titles-are-whole" "Em|En|Hyphen" \
  "$(LC_ALL=en_US.UTF-8 bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE"{print $5}' | paste -sd'|' -)"
# `Blocked by: Slice 1` is the number 1, and every mode emits the number.
check  "slice-word-blocker-is-valid" "rc=0" "$(lint check "$P")"
equals "slice-word-blocker-is-normalised" "-|1|1,2" \
  "$(bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE"{print $4}' | paste -sd'|' -)"

# --- refusals that are not about the format ------------------------------------------------------
OUT="$(lint check "$W/does-not-exist.md")"
check "missing-file-fails" "no such plan file" "$OUT"

out="$(bash "$LINT" bogus "$P" 2>&1)"; rc=$?
check  "unknown-mode-message" "usage:" "$out"
equals "unknown-mode-rc1"     "1"      "$rc"

# Both recovery and the peers claim test consume this fixture.
P="$FLOW_FIXTURES/plan-section-boundaries.md"
EXPECTED="$(printf 'SLICE\t1\tdone\t-\tDone\nCRIT\t1\tdone\told work\nSLICE\t2\topen\t1\tOpen\nCRIT\t2\topen\tpublish report\nOPEN\tDeliver\tpublish release')"
equals "shared-plan-recovers-exactly-the-real-tasks" "$EXPECTED" "$(bash "$LINT" slices "$P")"
check "shared-plan-keeps-literal-owned-paths" "docs/My File.md,docs/отчёт.md" "$(bash "$LINT" owned "$P")"
check "shared-plan-only-schedules-the-real-open-slice" "BATCH	2	serial" "$(bash "$LINT" ready-batches "$P")"

P="$(plan duplicate_owned '## Slice 1 — A
Blocked by: none
Owned paths: a.md
Owned paths: b.md
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — B
Blocked by: none
Owned paths: a.md
Deciding check: t
Delivers: d

- [ ] b
')"
check "duplicate-owned-is-rejected" 'more than one "Owned paths" line' "$(lint check "$P")"
check "duplicate-owned-cannot-schedule" "rc=1" "$(lint ready-batches "$P")"

P="$(plan spaces_unicode '## Slice 1 — A
Blocked by: none
Owned paths: docs/My Folder/, docs/отчёт.md
Deciding check: t
Delivers: d

- [ ] a

## Slice 2 — B
Blocked by: none
Owned paths: docs/My Folder/Part B.md
Deciding check: t
Delivers: d

- [ ] b

## Slice 3 — C
Blocked by: none
Owned paths: docs/приложение.md
Deciding check: t
Delivers: d

- [ ] c
')"
check "spaces-and-unicode-preserve-prefix-overlaps" "BATCH	1,3	parallel" "$(bash "$LINT" ready-batches "$P")"
check "spaces-and-unicode-preserve-active-overlaps" "BATCH	3	serial" "$(bash "$LINT" ready-batches "$P" --active 1)"

ROOT_SLICE='## Slice 1 — Rename files
Blocked by: none
Owned paths: .
Deciding check: test -f "a,b.md" && test -f " edge.md "
Delivers: Files with unusual names.

- [ ] both names work
'
P="$(plan whole_repository "$ROOT_SLICE")"
check "whole-repository-slice-is-valid" "rc=0" "$(lint check "$P")"
check "whole-repository-slice-runs-alone" "BATCH	1	serial" "$(bash "$LINT" ready-batches "$P")"
equals "whole-repository-path-is-emitted" "OWNED	1	." "$(bash "$LINT" owned "$P")"
P="$(plan whole_repository_and_other "$ROOT_SLICE
## Slice 2 — Other work
Blocked by: none
Owned paths: src/unrelated/
Deciding check: true
Delivers: Other work.

- [ ] other work
")"
check "whole-repository-slice-excludes-ready-neighbour" "BATCH	1	serial" "$(bash "$LINT" ready-batches "$P")"
equals "active-ordinary-slice-blocks-whole-repository-slice" "" "$(bash "$LINT" ready-batches "$P" --active 2 2>/dev/null)"
equals "active-whole-repository-slice-blocks-ordinary-slice" "" "$(bash "$LINT" ready-batches "$P" --active 1 2>/dev/null)"

CR="$(flow_repo)"
COMMITTED_PLAN='docs/task-plans/2026-01-01-main.md'
COMMITTED_SPEC='docs/PLANS/Spec report.md'
mkdir -p "$CR/docs/task-plans" "$CR/docs/PLANS"
sed -e "s|^\*\*Spec:.*|**Spec:** $COMMITTED_SPEC|" -e 's/^\*\*Branch:.*/**Branch:** main/' \
  "$FLOW_FIXTURES/plan-section-boundaries.md" > "$CR/$COMMITTED_PLAN"
printf '# Spec\n' > "$CR/$COMMITTED_SPEC"
check_git_plan() {
  ( cd "$CR" && lint check "$COMMITTED_PLAN" --spec "$COMMITTED_SPEC" --branch main "$@" )
}
( cd "$CR" && git add -- "$COMMITTED_PLAN" "$COMMITTED_SPEC" )
check "staged-only-plan-is-uncommitted" 'plan is not a regular file in HEAD' "$(check_git_plan)"
check "staged-only-plan-is-usable-in-local-mode" 'rc=0' "$(check_git_plan --local-only)"
( cd "$CR" && git commit -q -m 'commit plan and spec' )
check "committed-plan-and-spec-pass" 'rc=0' "$(check_git_plan)"
# Execute the actual /run startup block from a nested checkout directory.
mkdir "$CR/service"
startup="$(sed -n '/^ROOT=$(git rev-parse --show-toplevel) /,/^```$/p' \
  "$FLOW_PLUGIN/skills/run/SKILL.md" | sed '$d')"
run_startup() (
  cd "$CR/service" || exit 1
  export CLAUDE_PLUGIN_ROOT="$FLOW_PLUGIN" SPEC="$COMMITTED_SPEC"
  [ -n "$startup" ] || exit 1
  bash -c 'plan_mode=("$@"); '"$startup" -- "$@"
)
if run_startup; then pass "run-from-nested-checkout"; else fail "run-from-nested-checkout"; fi

( cd "$CR" && git config filter.plan_probe.clean 'touch called-plan-filter; cat'
  printf 'docs/** filter=plan_probe\n' >> .git/info/attributes
  for path in "$COMMITTED_PLAN" "$COMMITTED_SPEC"; do
    git show "HEAD:$path" | sed $'s/$/\r/' > "$path"
  done
)
check "crlf-checkout-keeps-committed-identity" 'rc=0' "$(check_git_plan)"
equals "committed-check-runs-no-git-filter" "no" "$([ -e "$CR/called-plan-filter" ] && echo yes || echo no)"
( cd "$CR" && rm .git/info/attributes
  git show "HEAD:$COMMITTED_PLAN" > "$COMMITTED_PLAN"
  git show "HEAD:$COMMITTED_SPEC" > "$COMMITTED_SPEC"
)
printf '\nChanged on disk.\n' >> "$CR/$COMMITTED_PLAN"
check "unstaged-plan-version-refused" 'plan differs from HEAD' "$(check_git_plan)"
( cd "$CR" && git add -- "$COMMITTED_PLAN" )
check "staged-plan-version-refused" 'plan differs from HEAD' "$(check_git_plan)"
check "dirty-plan-local-mode-passes" 'rc=0' "$(check_git_plan --local-only)"
( cd "$CR" && git show "HEAD:$COMMITTED_PLAN" > "$COMMITTED_PLAN" )
check "worktree-matching-head-used-even-if-index-differs" 'rc=0' "$(check_git_plan)"
printf '\nChanged on disk.\n' >> "$CR/$COMMITTED_SPEC"
check "unstaged-spec-version-refused" 'spec differs from HEAD' "$(check_git_plan)"
( cd "$CR" && git add -- "$COMMITTED_SPEC" )
check "staged-spec-version-refused" 'spec differs from HEAD' "$(check_git_plan)"

if run_startup --local-only; then pass "nested-local-handoff"; else fail "nested-local-handoff"; fi
if run_startup >/dev/null 2>&1; then fail "uncommitted-spec-is-not-publishable"; else pass "uncommitted-spec-is-not-publishable"; fi
( cd "$CR" && git add -- "$COMMITTED_PLAN" "$COMMITTED_SPEC" && git commit -q -m 'apply approved plan edits' )
if run_startup; then pass "committed-replan-ready-to-resume"; else fail "committed-replan-ready-to-resume"; fi

exit $fails
