#!/usr/bin/env bash
# Semantic regression checks for the harness-neutral development-flow contract.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/skills/spec/SKILL.md"
RUN="$ROOT/plugins/cc-tuner/skills/run/SKILL.md"
PLAN_SKILL="$ROOT/plugins/cc-tuner/skills/plan/SKILL.md"
DEEP_REVIEW="$ROOT/plugins/cc-tuner/skills/deep-review/SKILL.md"
CONFIG="$ROOT/plugins/cc-tuner/assets/execute-task/config.template.md"
CONTRACT="$ROOT/plugins/cc-tuner/workflow-contract.json"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-please.yml"
# Change-detection for THIS repo's copy of the shared contract, nothing more: the constant is
# compared against the file it pins, so it cannot observe the sibling at all. Treat a failure here as
# "the contract changed — was codex-tuner updated in the same breath?", not as proof that it was.
# DIVERGENCE, WIDENED DELIBERATELY: this repo now carries 3.0.0 with 7 invariants. The 25 of 2.0.0
# described the state machine that was deleted -- phases, structured run state, resume-before-phase,
# an immutable candidate tree. Leaving them would have meant a green suite affirming two contracts
# that contradict each other. codex-tuner still carries 1.1.0 with 14 and now needs its own pass;
# that is a coordinated cross-repository change and is NOT done.
EXPECTED_SHARED_CONTRACT_SHA256="2e8b97a35406a2c46d1434f833028eadd33298ef27d71ff0317a1cf9b87e71e9"
fails=0

need() {
  name="$1"; pattern="$2"; file="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "PASS $name"
  else
    echo "FAIL $name (missing '$pattern' in ${file#$ROOT/})"
    fails=1
  fi
}

contract_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

actual_contract_sha256="$(contract_sha256 "$CONTRACT")"
[ "$actual_contract_sha256" = "$EXPECTED_SHARED_CONTRACT_SHA256" ] \
  && echo "PASS shared-contract-fingerprint" \
  || { echo "FAIL shared-contract-fingerprint (got '$actual_contract_sha256')"; fails=1; }

jq -e '
  .name == "clicktronix-development-flow" and
  .version == "3.0.0" and
  .tracker_values == ["gh"] and
  (has("lifecycle_order") | not) and
  .delivery_order == ["plan", "implement", "prove", "candidate", "review", "verdict",
                      "current_sha_ci", "definition_of_done", "merge", "reconcile"] and
  (.invariants | length) == 7 and
  ([.invariants[].id] | unique | length) == 7 and
  ([.invariants[].id] | contains(["spec-before-run", "one-spec-one-branch-one-pr",
    "red-green-regression-proof", "review-bound-to-candidate",
    "changes-invalidate-downstream-evidence", "current-sha-ci-verification",
    "definition-of-done-before-merge"])) and
  all(.invariants[]; (keys == ["id", "requirement"]) and (.requirement | length > 0))
' "$CONTRACT" >/dev/null 2>&1 \
  && echo "PASS semantic-contract" || { echo "FAIL semantic-contract"; fails=1; }

# Each surviving invariant has something that READS it at runtime, which is the ADR's whole test for
# whether an invariant earns its place:
#   spec-before-run, one-spec-one-branch-one-pr   -> plan-path.sh resolve, fail-closed on 0 and on >1
#   review-bound-to-candidate                     -> merge-guard.sh, verdict at the exact head SHA
#   current-sha-ci-verification                   -> merge-guard.sh, required checks on that SHA
#   changes-invalidate-downstream-evidence        -> merge-guard.sh, a moved head loses its verdict
#   red-green-regression-proof                    -> the run skill, asserted below
#   definition-of-done-before-merge               -> the run skill, asserted below

need "spec-prereq" 'prereq-check.sh' "$SPEC"
need "spec-eyes-schema" 'checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>' "$SPEC"
need "spec-dor" '## Definition of Ready' "$SPEC"
need "spec-first-failing-check" 'First failing check: <exact command>; expected failure:' "$SPEC"
need "spec-targeted-checks" 'Targeted checks: <exact commands>' "$SPEC"
need "spec-full-regression" 'Full regression: <exact command>' "$SPEC"
need "spec-dod" '## Definition of Done' "$SPEC"
need "spec-github-tracker" 'tracker: gh' "$SPEC"

# The branch must exist before grilling, because grilling invokes domain-modeling and that writes
# CONTEXT.md and ADRs -- committed artifacts, which must not land on the integration branch. Ordering
# is the whole rule, so the test is an ordering test, not a phrase test.
branch_line="$(grep -n '^## [0-9]*\. Create the task branch' "$SPEC" | head -1 | cut -d: -f1)"
grill_line="$(grep -n '^## [0-9]*\. Grill the problem' "$SPEC" | head -1 | cut -d: -f1)"
if [ -n "$branch_line" ] && [ -n "$grill_line" ] && [ "$branch_line" -lt "$grill_line" ]; then
  echo "PASS spec-branch-before-grilling"
else
  echo "FAIL spec-branch-before-grilling (branch=$branch_line grill=$grill_line)"
  fails=1
fi
# The old run.md was 434 lines describing a state machine, and the assertions below used to pin
# thirty of its phrases. That machine is gone, so those assertions went with it -- a phrase test whose
# subject no longer exists is not a weakened test, it is a test of nothing.
#
# What is left pins only what the merge guard READS. The guard's own behaviour is covered by
# tests/flow/test_merge_guard.sh against real payloads; these assert that the skill still tells the
# agent to produce what that guard requires. Supporting the scenario tier, never replacing it.
need "run-resolves-the-plan"        'plan-path.sh" resolve' "$RUN"
need "run-validates-the-plan"       'plan-lint.sh" check' "$RUN"
need "run-ticks-the-plan-file"      '- [x]' "$RUN"
need "run-auto-refuses-blocked"     'refuse a task whose `blockedBy` is not empty' "$RUN"
need "run-verdict-marker"           'cc-tuner-verdict: APPROVE $CANDIDATE_SHA' "$RUN"
need "run-never-forges-approval"    'Never publish `APPROVE` for a review that did not' "$RUN"
need "run-pins-the-merge-head"      '--match-head-commit "$CANDIDATE_SHA"' "$RUN"
need "run-approval-is-terminal"     'terminal for its SHA' "$RUN"
need "run-codex-required-review"    '--required' "$RUN"
need "run-red-before-green"         'RED before GREEN' "$RUN"
need "run-mutation-proof"           'Prove the guard by removing it' "$RUN"
need "run-dod-before-merge"         'Definition of Done from the spec' "$RUN"
need "run-request-changes-loop"     'On `REQUEST_CHANGES`, loop' "$RUN"
need "run-reads-the-spec"           '$ARGUMENTS' "$RUN"
need "run-strategy-from-the-spec"   'the strategy the spec names' "$RUN"
need "spec-hands-off-to-plan"       '/cc-tuner:plan docs/PLANS' "$SPEC"
need "plan-two-pass-publication"    'addBlockedBy' "$PLAN_SKILL"
need "plan-commits-the-plan"        'Commit the plan file' "$PLAN_SKILL"
need "run-atomic-merge-head" '--match-head-commit "$CANDIDATE_SHA"' "$RUN"
need "deep-review-no-cap" 'never stop at an arbitrary count' "$DEEP_REVIEW"
need "deep-review-always-runs" 'Always perform the review; small-diff thresholds only decide' "$DEEP_REVIEW"
need "deep-review-architecture" '**Architecture and systemic effects**' "$DEEP_REVIEW"
need "deep-review-exact-verdict" 'APPROVE <candidate SHA> <tree SHA>' "$DEEP_REVIEW"
need "release-pr-status" 'context=release-pr/validate' "$RELEASE_WORKFLOW"
need "release-pr-exact-sha" 'ref: ${{ steps.release-pr.outputs.sha }}' "$RELEASE_WORKFLOW"
need "release-pr-runs-suite" 'run: bash tests/run.sh' "$RELEASE_WORKFLOW"
need "release-pr-fails-workflow" '[ "$state" = success ]' "$RELEASE_WORKFLOW"
need "release-pr-create-update-gate" 'prs_created is true when a release PR is created or updated' "$RELEASE_WORKFLOW"

release_pr_gate_count="$(grep -cF "steps.release.outputs.prs_created == 'true'" "$RELEASE_WORKFLOW")"
[ "$release_pr_gate_count" -eq 4 ] && echo "PASS release-pr-gate-count" \
  || { echo "FAIL release-pr-gate-count (got $release_pr_gate_count, want 4)"; fails=1; }

# Three checks stood here: a nine-phase count, an index of twenty contract invariants named in
# run.md's Verification section, and a walk asserting nine phrases appeared in delivery order. All
# three measured the shape of the state machine. It is gone, and a test that counts the phases of a
# thing with no phases cannot be repaired, only deleted. What replaced their subject -- the guard --
# is covered by tests/flow/test_merge_guard.sh against real payloads, which is a stronger check than
# any of them were.

if grep -En 'glab|effort_tiering|small_diff_budget|assets/tiering|cheap_gate|≤50 changed lines|≤5 files' "$SPEC" "$RUN" "$CONFIG" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

exit "$fails"
