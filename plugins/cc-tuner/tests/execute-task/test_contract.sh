#!/usr/bin/env bash
# Semantic regression checks for the harness-neutral development-flow contract.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/commands/spec.md"
RUN="$ROOT/plugins/cc-tuner/commands/run.md"
DEEP_REVIEW="$ROOT/plugins/cc-tuner/skills/deep-review/SKILL.md"
CONFIG="$ROOT/plugins/cc-tuner/assets/execute-task/config.template.md"
CONTRACT="$ROOT/plugins/cc-tuner/workflow-contract.json"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-please.yml"
# Keep this value identical to codex-tuner and update it only in coordinated contract PRs.
# This constant only proves THIS repo's file is unchanged: it is compared against itself, so it
# cannot detect that the sibling has diverged. codex-tuner is still on contract 1.1.0 with 14
# invariants and must be updated to this 2.0.0 contract before the pledge above is true again.
EXPECTED_SHARED_CONTRACT_SHA256="7a4fdb14d2b4ff94b3701f2e0eb344f5333e9a460e5bf8942205847c30216906"
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
  .version == "2.0.0" and
  .defaults.small_diff == {"max_changed_lines": 50, "max_changed_files": 5} and
  .tracker_values == ["gh", "none"] and
  .lifecycle_order == ["readiness", "planning", "implementation", "testing", "acceptance", "candidate", "review", "delivery", "completion"] and
  .delivery_order == ["stage", "guard", "commit_candidate", "review_candidate", "push", "pull_request", "current_sha_ci", "definition_of_done", "merge", "reconcile"] and
  .review_lenses == [
    "correctness and edge cases",
    "specification and scope",
    "repository standards",
    "architecture and systemic effects",
    "security and data safety",
    "tests and operability"
  ] and
  .sensitive_surfaces == [
    "authentication, authorization, secrets, and cryptography",
    "migrations and destructive data operations",
    "public APIs, persisted schemas, and cross-service contracts",
    "money, payments, pricing, billing, and entitlements",
    "infrastructure, CI, deployment, and release configuration",
    "security-relevant input handling: injection, SSRF, path traversal, unsafe deserialization, and server-side allowlists"
  ] and
  (.invariants | length) == 25 and
  ([.invariants[].id] | unique | length) == 25 and
  ([.invariants[].id] | contains(["structured-run-state", "visible-plan-before-mutation", "red-green-regression-proof", "implementation-only-fanout", "immutable-candidate-before-review", "exhaustive-review-no-cap", "reviewer-hard-stop-is-not-approval", "changes-invalidate-downstream-evidence", "definition-of-done-before-merge", "post-merge-reconciliation-only"])) and
  all(.invariants[]; (keys == ["id", "requirement"]) and (.requirement | length > 0))
' "$CONTRACT" >/dev/null 2>&1 \
  && echo "PASS semantic-contract" || { echo "FAIL semantic-contract"; fails=1; }

need "spec-prereq" 'prereq-check.sh' "$SPEC"
need "spec-eyes-schema" 'checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>' "$SPEC"
need "spec-dor" '## Definition of Ready' "$SPEC"
need "spec-first-failing-check" 'First failing check: <exact command>; expected failure:' "$SPEC"
need "spec-targeted-checks" 'Targeted checks: <exact commands>' "$SPEC"
need "spec-full-regression" 'Full regression: <exact command>' "$SPEC"
need "spec-dod" '## Definition of Done' "$SPEC"
need "spec-github-tracker" 'tracker: gh|none' "$SPEC"
need "run-loads-contract" '${CLAUDE_PLUGIN_ROOT}/workflow-contract.json' "$RUN"
need "run-loads-tiering-reference" '${CLAUDE_PLUGIN_ROOT}/references/tiering.md' "$RUN"
need "run-structured-state" 'runctl.sh` is the source of truth' "$RUN"
need "run-exact-phase-completion" 'phase "$RUN_ID" complete "$PHASE"' "$RUN"
need "run-safe-journal-stdin" "<<'CC_TUNER_EVIDENCE'" "$RUN"
need "run-owned-preflight" '--expected-branch "$BRANCH"' "$RUN"
need "run-visible-task-plan" 'create the visible Claude task plan with `TaskCreate`' "$RUN"
need "run-task-state-binding" '--ui-task-id "$CLAUDE_TASK_ID"' "$RUN"
need "run-safe-shell-data" 'spec, issue, Git, or reviewer as data: pass them as quoted arguments' "$RUN"
need "run-implementation-only-parallel" 'Parallelize only independent code-writing units' "$RUN"
need "run-isolated-worktrees" 'use one isolated git worktree per unit' "$RUN"
need "run-testing-phase" '## Phase 3 — Testing & Code Verification' "$RUN"
need "run-negative-proof" 'negative/mutation proof' "$RUN"
need "run-explicit-stage" 'git add -- "${TASK_PATHS[@]}"' "$RUN"
need "run-candidate-before-review" 'runctl.sh" candidate "$RUN_ID" record "$(git rev-parse HEAD)"' "$RUN"
need "run-deep-review" 'invoke `cc-tuner:deep-review`' "$RUN"
need "run-three-reviews" 'record "$REVIEWER" "$VERDICT" "$CANDIDATE_SHA"' "$RUN"
need "run-codex-required-review" '/cc-codex-triage:review --required --base <literal-base-sha> --spec <current-repo-relative-spec>' "$RUN"
need "run-codex-approval-marker" 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$RUN"
need "run-codex-marker-enforced" 'compares the marker with `review-state.sh check`' "$RUN"
need "run-reviewer-hard-stop" '`CAP_REACHED` or `DIVERGED` is a terminal answer' "$RUN"
need "run-reviewer-literal-ids" 'literal reviewer id `deep-review`, `mattpocock`, or `codex`' "$RUN"
need "run-prepared-files-outside-worktree" 'outside the repository worktree' "$RUN"
need "run-required-github-checks" 'reads `gh pr checks --required`' "$RUN"
need "run-review-fix-invalidates" 'A new commit invalidates all prior testing, acceptance, review, CI, and DoD' "$RUN"
need "run-explicit-pr-create" 'gh pr create --base "$TARGET" --head "$BRANCH" --title "$PR_TITLE" --body-file "$PR_BODY_FILE"' "$RUN"
need "run-current-sha-ci" 'Missing, skipped, stale, cancelled, billing-blocked,' "$RUN"
need "run-can-merge" 'require both `runctl can-advance` and' "$RUN"
need "run-ci-pr-binding" 'ci "$RUN_ID" record success "$CANDIDATE_SHA" --pr "$PR_NUMBER"' "$RUN"
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

if grep -qF 'bundled `/code-review`' "$RUN"; then
  echo "PASS no-bundled-code-review (explicit prohibition)"
else
  echo "FAIL no-bundled-code-review"
  fails=1
fi

phase_count="$(grep -cE '^## Phase [0-8] —' "$RUN")"
[ "$phase_count" -eq 9 ] && echo "PASS phase-count" \
  || { echo "FAIL phase-count (got $phase_count, want 9)"; fails=1; }

verification_ids="$(sed -n '/^## Verification$/,$p' "$RUN" | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u)"
unknown_ids=0
for id in $verification_ids; do
  jq -e --arg id "$id" 'any(.invariants[]; .id == $id)' "$CONTRACT" >/dev/null 2>&1 || {
    echo "FAIL verification-index-names-unknown-invariant ($id)"; fails=1; unknown_ids=1; }
done
covered="$(printf '%s\n' "$verification_ids" | grep -c .)"
if [ "$unknown_ids" -eq 0 ] && [ "$covered" -ge 20 ]; then
  echo "PASS verification-indexes-the-contract ($covered invariants)"
else
  echo "FAIL verification-indexes-the-contract (covered=$covered)"; fails=1
fi

if grep -En 'glab|effort_tiering|small_diff_budget|assets/tiering|cheap_gate|≤50 changed lines|≤5 files' "$SPEC" "$RUN" "$CONFIG" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

last_line=0
order_ok=1
for pattern in \
  'git add -- "${TASK_PATHS[@]}"' \
  'guard-artifacts.sh' \
  'git commit -F "$COMMIT_MESSAGE_FILE"' \
  '## Phase 6 — review the immutable candidate' \
  'git push -u origin' \
  'gh pr view "$BRANCH"' \
  'record success "$CANDIDATE_SHA" --pr "$PR_NUMBER"' \
  '## Phase 8 — merge and reconcile' \
  'Switch to the literal target'; do
  line="$(grep -nF -- "$pattern" "$RUN" | head -1 | cut -d: -f1)"
  if [ -z "$line" ] || [ "$line" -le "$last_line" ]; then order_ok=0; break; fi
  last_line="$line"
done
[ "$order_ok" -eq 1 ] \
  && echo "PASS delivery-order" || { echo "FAIL delivery-order"; fails=1; }

exit "$fails"
