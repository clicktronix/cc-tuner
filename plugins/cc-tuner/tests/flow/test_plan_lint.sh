#!/usr/bin/env bash
# plan-lint.sh: the plan format's validator and the parser the restore hook reads it back with.
#
# One parser, two modes. If the hook grew its own reader, a plan the linter accepted could still
# restore wrongly and nothing would say so -- which is why `slices` is asserted here beside `check`.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

LINT="$FLOW_PLUGIN/scripts/plan-lint.sh"
W="$(flow_workdir)"

# plan <name> <body> -> path to a plan file
plan() { printf '%s' "$2" > "$W/$1.md"; printf '%s' "$W/$1.md"; }

# lint <mode> <file> -> stdout+stderr then rc=<code>
lint() { out="$(bash "$LINT" "$1" "$2" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?"; }

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
check "lowercase-blocked-by-is-not-the-field" 'has no "Blocked by" line' "$OUT"

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

# --- frontier: the runner asks the file which slice may start ------------------------------------
# /cc-tuner:run drives from this, with or without the native task tools. The rule -- lowest-numbered
# open slice whose blockers are all done -- was prose in two skills and arithmetic done by hand, which
# is how a blocked slice gets started under --auto.
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
equals "frontier-refuses-a-blocked-slice" "SLICE	3	open	-	Independent" "$(bash "$LINT" frontier "$P")"

# With the blocker done, the blocked slice becomes the frontier -- and its edges come back normalised
# the same way `slices` emits them, so one reader parses both modes.
P="$(plan frontier_unblocked "$(printf '%s' "$FRONTIER" | sed 's/- \[ \] c/- [x] c/')")"
equals "frontier-releases-when-blockers-clear" "SLICE	2	open	1,3	Wire" "$(bash "$LINT" frontier "$P")"

# Nothing open means the loop is over, and that has to be distinguishable from an error.
P="$(plan frontier_done "$(printf '%s' "$FRONTIER" | sed 's/- \[ \] /- [x] /g')")"
OUT="$(lint frontier "$P")"
check "frontier-empty-when-all-done" "rc=0" "$OUT"
equals "frontier-prints-nothing-when-all-done" "" "$(bash "$LINT" frontier "$P")"

# A plan that does not parse gets no answer at all: half a graph would start the wrong slice.
P="$(plan frontier_invalid '## Slice 1 — A
Blocked by: slice-2
Owned paths: a/
Deciding check: t
Delivers: d

- [ ] a
')"
OUT="$(lint frontier "$P")"
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
SLICE	2	open	-	Beta" "$(bash "$LINT" frontier "$P")"

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
SLICE	3	open	-	Declared first" "$(bash "$LINT" frontier "$P")"

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

# --- the shipped template passes the shipped linter ----------------------------------------------
# The one claim about planning inside /cc-tuner:spec this tier can settle. That the SKILL produces a conforming plan
# is a claim about a model and belongs to the eval; that the thing it hands the model to fill in is
# itself valid is checkable here, and a template that fails the linter would send every user into a
# fix-it loop on their first run.
TPL="$FLOW_PLUGIN/skills/spec/plan-template.md"
OUT="$(lint check "$TPL")"
check "template-passes-lint" "rc=0" "$OUT"
# It has to parse into slices with an edge, or it is not demonstrating the format it teaches.
equals "template-has-an-edge" "1" \
  "$(bash "$LINT" slices "$TPL" | awk -F'\t' '$1=="SLICE" && $2==2 {print $4}')"

# --- refusals that are not about the format ------------------------------------------------------
OUT="$(lint check "$W/does-not-exist.md")"
check "missing-file-fails" "no such plan file" "$OUT"

out="$(bash "$LINT" bogus "$P" 2>&1)"; rc=$?
check  "unknown-mode-message" "usage:" "$out"
equals "unknown-mode-rc1"     "1"      "$rc"

exit $fails
