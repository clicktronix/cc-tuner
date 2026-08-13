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

P="$(plan selfblock '## Slice 1 — A
Blocked by: 1

- [ ] a
')"
OUT="$(lint check "$P")"
check "self-block-message" "blocked by itself" "$OUT"

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

# --- "none" and "-" both mean no blockers --------------------------------------------------------
P="$(plan dash '## Slice 1 — A
Blocked by: -
Owned paths: src/
Deciding check: make test
Delivers: behaviour

- [ ] a
')"
equals "dash-means-none" "-" "$(bash "$LINT" slices "$P" | awk -F'\t' '$1=="SLICE" {print $4}')"

# --- the shipped template passes the shipped linter ----------------------------------------------
# The one claim about /cc-tuner:plan this tier can settle. That the SKILL produces a conforming plan
# is a claim about a model and belongs to the eval; that the thing it hands the model to fill in is
# itself valid is checkable here, and a template that fails the linter would send every user into a
# fix-it loop on their first run.
TPL="$FLOW_PLUGIN/skills/plan/plan-template.md"
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
