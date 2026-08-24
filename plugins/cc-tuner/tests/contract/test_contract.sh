#!/usr/bin/env bash
# Semantic regression checks for the seams no behavioural test can reach: load-bearing sentences in
# shipped skills, and the release workflow's own guarantees.
#
# What is NOT here any more: a sha256 pin and a jq shape check over workflow-contract.json. That file
# was a normative document nothing loaded at runtime -- the thresholds and sensitive surfaces it held
# now live in the skill that applies them, and its seven invariants are enforced by merge.sh,
# plan-path.sh and the greps below. Pinning a document no consumer reads only proved it had not been
# edited.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/skills/spec/SKILL.md"
RUN="$ROOT/plugins/cc-tuner/skills/run/SKILL.md"
PLAN_SKILL="$ROOT/plugins/cc-tuner/skills/plan/SKILL.md"
DEEP_REVIEW="$ROOT/plugins/cc-tuner/skills/deep-review/SKILL.md"
PLACEMENT="$ROOT/plugins/cc-tuner/skills/run/references/placement.md"
SETUP="$ROOT/plugins/cc-tuner/skills/setup/SKILL.md"
TASK_FLOW="$ROOT/plugins/cc-tuner/skills/task-flow/SKILL.md"
RULE_TEMPLATE="$ROOT/plugins/cc-tuner/assets/task-flow/rule.template.md"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-please.yml"
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
# What is left pins only what merge.sh reads. Its behaviour is covered by tests/flow/test_merge.sh;
# these assert that the skill still tells the agent to produce what the script requires. Supporting
# the scenario tier, never replacing it.
need "run-resolves-the-plan"        'plan-path.sh" resolve' "$RUN"
need "run-validates-the-plan"       'plan-lint.sh" check' "$RUN"
# The frontier is a program, not arithmetic the model does from the graph. Doing it by hand is how a
# blocked slice gets started under --auto, and it is also what made the Markdown-only fallback a
# promise with no implementation: /run defined its whole loop through TaskList.
need "run-asks-for-the-frontier"    'plan-lint.sh" frontier' "$RUN"
need "run-taskless-loop-unchanged"  'nothing about the loop changes' "$RUN"
need "plan-fallback-names-frontier" 'plan-lint.sh frontier' "$PLAN_SKILL"
need "run-ticks-the-plan-file"      '- [x]' "$RUN"
# Finding 3: all three commands commit, none of them said anything about attribution trailers, so
# every one fell through to the harness default in every repository cc-tuner is enabled in. The
# preference belongs to the repository, so the skills point at where it is written down.
need "run-trailers-from-the-repo"  'attribution trailers, comes from' "$RUN"
need "plan-trailers-from-the-repo" 'attribution trailers, comes from' "$PLAN_SKILL"
need "spec-trailers-from-the-repo" 'attribution trailers, comes from' "$SPEC"
need "task-flow-owns-the-trailer-rule" 'Attribution trailers are the repository' "$TASK_FLOW"
need "template-has-a-trailer-line"     '**Attribution trailers:**' "$RULE_TEMPLATE"
need "run-auto-refuses-blocked"     'refuse a task whose `blockedBy` is not empty' "$RUN"
need "run-verdict-marker"           'cc-tuner-verdict: APPROVE <candidate-sha>' "$RUN"
need "run-never-forges-approval"    'Never publish `APPROVE` for a review that did not' "$RUN"
need "run-merges-through-the-script" 'scripts/merge.sh' "$RUN"
need "run-codex-required-review"    '--required' "$RUN"
need "run-red-before-green"         'RED before GREEN' "$RUN"
need "run-mutation-proof"           'negative proof the spec assigned' "$RUN"
# The conditionality is the contract, not a nicety: requiring a mutation for every slice put a shell
# subsystem on the path of an ordinary one. Pin that it is spec-driven, and that the classes where a
# spec should ask for it are named.
need "run-mutation-proof-is-conditional" 'not one per slice'   "$RUN"
# The classes belong to /spec, which assigns the proof; /run only executes what is already committed.
# Pinned there, not here — an earlier revision pinned them in /run, which is advice arriving after the
# decision it is about.
need "spec-assigns-mutation-classes"     'fail-closed guards'  "$SPEC"
need "run-dod-before-merge"         'Definition of Done from the spec' "$RUN"
need "run-request-changes-loop"     'On `REQUEST_CHANGES`, loop' "$RUN"
need "run-reads-the-spec"           '$ARGUMENTS' "$RUN"
need "run-strategy-from-the-spec"   'the strategy the spec names' "$RUN"
need "spec-hands-off-to-plan"       '/cc-tuner:plan docs/PLANS' "$SPEC"
need "plan-two-pass-publication"    'addBlockedBy' "$PLAN_SKILL"
# The task tools are opt-in from Claude Code 2.1.233 on current models, and nothing the plugin ships
# can turn them on. Three eval sessions published no visible plan while their operator watched for
# one, so the skill has to name what is lost rather than mention it in passing.
need "plan-names-the-optin"        'CLAUDE_CODE_ENABLE_TODO_TOOLS' "$PLAN_SKILL"
need "plan-stops-for-an-answer"    'Then ask which, and wait' "$PLAN_SKILL"
need "plan-auto-still-reports"     "points in the run's first report" "$PLAN_SKILL"
need "plan-commits-the-plan"        'Commit the plan file' "$PLAN_SKILL"
# The pin is no longer the skill's to remember: merge.sh always adds it. What the skill must still
# say is that merges go through that script rather than a raw gh call.
need "run-no-raw-gh-merge" 'Do not replace it with a raw `gh pr merge`' "$RUN"
need "deep-review-no-cap" 'never stop at an arbitrary count' "$DEEP_REVIEW"
need "deep-review-always-runs" 'Always perform the review; small-diff thresholds only decide' "$DEEP_REVIEW"
# The numbers, not a pointer to them. They lived in workflow-contract.json, which nothing loaded, so
# the skill deferred to a boundary its reader could not see.
need "deep-review-names-the-thresholds" '50 lines across at most 5 files' "$DEEP_REVIEW"
need "deep-review-architecture" '**Architecture and systemic effects**' "$DEEP_REVIEW"
need "deep-review-exact-verdict" 'APPROVE <candidate SHA> <tree SHA>' "$DEEP_REVIEW"
# deep-review owns this policy. placement explains where independent lenses run, but copying the
# numbers there made a future threshold change a two-file edit under a one-rule-one-home contract.
if grep -Eq '50 (changed )?lines|5 files' "$PLACEMENT"; then
  echo "FAIL review-thresholds-have-two-homes"
  fails=1
else
  echo "PASS review-thresholds-have-one-home"
fi

# `board: none` has to be decided before project scope is mentioned. Doctor deliberately reports the
# scope as WARN because it cannot know whether a board applies; reverting setup to the old unconditional
# refusal must make this ordering check fail.
board_skip_line="$(grep -nF 'skip the whole step' "$SETUP" | head -1 | cut -d: -f1)"
project_scope_line="$(grep -nF 'Only then is the `project` scope required' "$SETUP" | head -1 | cut -d: -f1)"
if [ -n "$board_skip_line" ] && [ -n "$project_scope_line" ] \
   && [ "$board_skip_line" -lt "$project_scope_line" ]; then
  echo "PASS setup-board-none-precedes-project-scope"
else
  echo "FAIL setup-board-none-precedes-project-scope (skip=$board_skip_line scope=$project_scope_line)"
  fails=1
fi
need "setup-auth-miss-is-login" '`gh auth login` — an interactive browser flow' "$SETUP"
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
# thing with no phases cannot be repaired, only deleted. What replaced their subject -- merge.sh --
# is covered by tests/flow/test_merge.sh against its actual argument boundary, which is a stronger
# check than any of them were.

if grep -En 'glab|effort_tiering|small_diff_budget|assets/tiering|cheap_gate|≤50 changed lines|≤5 files' "$SPEC" "$RUN" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

exit "$fails"
