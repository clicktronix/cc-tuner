#!/usr/bin/env bash
# Semantic regression checks for the harness-neutral development-flow contract.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/commands/spec.md"
RUN="$ROOT/plugins/cc-tuner/commands/run.md"
CONFIG="$ROOT/plugins/cc-tuner/assets/execute-task/config.template.md"
CONTRACT="$ROOT/plugins/cc-tuner/workflow-contract.json"
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

jq -e '
  .name == "clicktronix-development-flow" and
  .version == "1.1.0" and
  .defaults.small_diff == {"max_changed_lines": 50, "max_changed_files": 5} and
  .tracker_values == ["gh", "none"] and
  .delivery_order == ["stage", "guard", "commit", "push", "pull_request", "current_sha_ci", "merge", "reconcile"] and
  .sensitive_surfaces == [
    "authentication, authorization, secrets, and cryptography",
    "migrations and destructive data operations",
    "public APIs, persisted schemas, and cross-service contracts",
    "money, payments, pricing, billing, and entitlements",
    "infrastructure, CI, deployment, and release configuration",
    "security-relevant input handling: injection, SSRF, path traversal, unsafe deserialization, and server-side allowlists"
  ] and
  (.invariants | length) == 14 and
  ([.invariants[].id] | unique | length) == 14 and
  ([.invariants[].id] | contains(["owned-run-state", "post-merge-reconciliation-only"])) and
  all(.invariants[]; (keys == ["id", "requirement"]) and (.requirement | length > 0))
' "$CONTRACT" >/dev/null 2>&1 \
  && echo "PASS semantic-contract" || { echo "FAIL semantic-contract"; fails=1; }

need "spec-prereq" 'prereq-check.sh' "$SPEC"
need "spec-eyes-schema" 'checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>' "$SPEC"
need "spec-github-tracker" 'tracker: gh|none' "$SPEC"
need "run-loads-contract" '${CLAUDE_PLUGIN_ROOT}/workflow-contract.json' "$RUN"
need "run-loads-tiering-reference" '${CLAUDE_PLUGIN_ROOT}/references/tiering.md' "$RUN"
need "run-append-command" 'journal.sh" append <literal-run-id>' "$RUN"
need "run-owned-preflight" '--expected-branch <literal-branch>' "$RUN"
need "run-explicit-stage" 'git add -- <path-1> <path-2>' "$RUN"
need "run-explicit-pr-base" 'gh pr create --base <literal-target> --head <literal-branch>' "$RUN"
need "run-current-sha-ci" 'remote head equals that SHA' "$RUN"
need "run-reconciliation-only" 'only board/spec/branch/' "$RUN"
need "release-pr-status" 'context=release-pr/validate' "$RELEASE_WORKFLOW"
need "release-pr-exact-sha" 'ref: ${{ steps.release-pr.outputs.sha }}' "$RELEASE_WORKFLOW"
need "release-pr-runs-suite" 'run: bash tests/run.sh' "$RELEASE_WORKFLOW"
need "release-pr-fails-workflow" '[ "$state" = success ]' "$RELEASE_WORKFLOW"

resume_count="$(grep -cF 'journal.sh" resume <literal-run-id>' "$RUN")"
[ "$resume_count" -eq 8 ] && echo "PASS resume-count" \
  || { echo "FAIL resume-count (got $resume_count, want 8)"; fails=1; }

if grep -En 'glab|effort_tiering|small_diff_budget|assets/tiering|≤50 changed lines|≤5 files' "$SPEC" "$RUN" "$CONFIG" >/dev/null; then
  echo "FAIL ignored-or-duplicated-policy"
  fails=1
else
  echo "PASS no-ignored-or-duplicated-policy"
fi

last_line=0
order_ok=1
for pattern in \
  'git add -- <path-1> <path-2>' \
  'guard-artifacts.sh' \
  'git commit -m' \
  'git push -u origin' \
  'gh pr view <literal-branch>' \
  'remote head equals that SHA' \
  '## Phase 7 — merge and clean up' \
  'Then switch to the literal target branch'; do
  line="$(grep -nF -- "$pattern" "$RUN" | head -1 | cut -d: -f1)"
  if [ -z "$line" ] || [ "$line" -le "$last_line" ]; then order_ok=0; break; fi
  last_line="$line"
done
[ "$order_ok" -eq 1 ] \
  && echo "PASS delivery-order" || { echo "FAIL delivery-order"; fails=1; }

exit "$fails"
