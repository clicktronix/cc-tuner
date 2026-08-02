#!/usr/bin/env bash
# Static regression checks for the harness-neutral development-flow contract.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SPEC="$ROOT/plugins/cc-tuner/commands/spec.md"
RUN="$ROOT/plugins/cc-tuner/commands/run.md"
CONTRACT="$ROOT/workflow-contract.json"
fails=0

need() {
  name="$1"; pattern="$2"; file="$3"
  if grep -qF "$pattern" "$file"; then
    echo "PASS $name"
  else
    echo "FAIL $name (missing '$pattern' in ${file#$ROOT/})"
    fails=1
  fi
}

jq -e '.version == "1.0.0" and (.invariants | length == 14)' "$CONTRACT" >/dev/null 2>&1 \
  && echo "PASS contract-manifest" || { echo "FAIL contract-manifest"; fails=1; }

need "spec-creates-branch" "Create the task branch" "$SPEC"
need "spec-auto-ready" "auto_ready: yes|no" "$SPEC"
need "spec-no-main-commit" "Never commit the spec directly" "$SPEC"
need "run-honors-auto-ready-no" '`auto_ready: no` is authoritative' "$RUN"
need "run-hitl-boundary" "HITL boundary" "$RUN"
need "run-explicit-stage" "git add -- <path-1> <path-2>" "$RUN"
need "run-commit" 'git commit -m' "$RUN"
need "run-push" "git push -u origin" "$RUN"
need "run-opens-pr" "gh pr create --body-file" "$RUN"
need "run-current-sha-ci" "remote PR head equals that SHA" "$RUN"
need "run-auto-stops-after-merge" "outward action after merge" "$RUN"

exit "$fails"
