#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
P="$DIR/preflight.sh"
R="$DIR/runctl.sh"
RUNS_REL=".claude/execute-task-runs"
fails=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s%s\n' "$1" "${2:+ ($2)}"; fails=1; }
runctl() { CLAUDE_PROJECT_DIR="$REPO" bash "$R" "$@"; }
evidence() {
  text="$1"; shift
  printf '%s\n' "$text" | runctl "$@"
}

make_repo() {
  REPO="$(mktemp -d)" || exit 1
  (
    cd "$REPO" && git init -q -b main && git config user.email test@example.com \
      && git config user.name test && mkdir -p docs && printf 'base\n' > file.txt \
      && printf '# Spec\n' > docs/spec.md && git add file.txt docs/spec.md \
      && git commit -qm init && git switch -qc task
  ) || exit 1
  CLAUDE_PROJECT_DIR="$REPO" bash "$P" run-1 main --expected-branch task >/dev/null \
    || exit 1
  runctl init run-1 --mode auto --spec docs/spec.md >/dev/null || exit 1
}

complete_readiness() {
  evidence "DoR commands and prerequisites verified" gate run-1 record dor pass >/dev/null \
    && runctl phase run-1 complete readiness >/dev/null \
    && runctl phase run-1 enter planning >/dev/null
}

create_plan() {
  evidence "Implement the scoped behavior and regression test" \
    task run-1 add implement-feature implementation >/dev/null \
    && runctl phase run-1 complete planning >/dev/null \
    && runctl phase run-1 enter implementation >/dev/null
}

complete_implementation() {
  runctl task run-1 start implement-feature >/dev/null \
    && evidence "Implementation and scoped test completed" \
      task run-1 complete implement-feature >/dev/null \
    && runctl phase run-1 complete implementation >/dev/null \
    && runctl phase run-1 enter testing >/dev/null
}

complete_testing_to_candidate() {
  evidence "targeted/full test commands passed" gate run-1 record testing pass >/dev/null \
    && runctl phase run-1 complete testing >/dev/null \
    && runctl phase run-1 enter acceptance >/dev/null \
    && evidence "machine acceptance passed" gate run-1 record acceptance pass >/dev/null \
    && runctl phase run-1 complete acceptance >/dev/null \
    && runctl phase run-1 enter candidate >/dev/null
}

record_candidate_and_enter_review() {
  SHA="$(git -C "$REPO" rev-parse HEAD)"
  runctl candidate run-1 record "$SHA" >/dev/null \
    && runctl phase run-1 complete candidate >/dev/null \
    && runctl phase run-1 enter review >/dev/null
}

approve_all() {
  SHA="$(git -C "$REPO" rev-parse HEAD)"
  for reviewer in deep-review mattpocock codex; do
    evidence "$reviewer approved exact candidate" \
      review run-1 record "$reviewer" APPROVE "$SHA" >/dev/null || return 1
  done
}

prepare_candidate() {
  complete_readiness && create_plan && complete_implementation || return 1
  printf 'implementation\n' >> "$REPO/file.txt"
  (cd "$REPO" && git add file.txt && git commit -qm implementation) || return 1
  complete_testing_to_candidate && record_candidate_and_enter_review
}

# State is adjacent to the journal, validates ownership, and init is idempotent.
make_repo
STATE="$REPO/$RUNS_REL/run-1.state.json"
if [ -f "$STATE" ] \
  && jq -e '.schema_version == 1 and .phase == {name:"readiness",status:"in_progress"} and
    .required_reviewers == ["deep-review","mattpocock","codex"]' "$STATE" >/dev/null \
  && runctl init run-1 --mode auto --spec docs/spec.md >/dev/null; then
  pass "state-init-idempotent"
else
  fail "state-init-idempotent"
fi

SCHEMA="$DIR/../../schemas/run-state.schema.json"
STATE_KEYS="$(jq -c 'keys | sort' "$STATE")"
SCHEMA_KEYS="$(jq -c '.required | sort' "$SCHEMA")"
STATE_CI_KEYS="$(jq -c '.ci | keys | sort' "$STATE")"
SCHEMA_CI_KEYS="$(jq -c '.properties.ci.required | sort' "$SCHEMA")"
if [ "$STATE_KEYS" = "$SCHEMA_KEYS" ] && [ "$STATE_CI_KEYS" = "$SCHEMA_CI_KEYS" ] \
    && jq -e '
      .properties.required_reviewers.const == ["deep-review","mattpocock","codex"] and
      (."$defs".task.properties.phase.enum | length) == 8 and
      (.properties.candidate.oneOf | length) == 2 and
      (.properties.ci.oneOf | length) == 3 and
      (.allOf | length) == 2
    ' "$SCHEMA" >/dev/null; then
  pass "runtime-state-keys-match-published-schema"
else
  fail "runtime-state-keys-match-published-schema" \
    "state=$STATE_KEYS schema=$SCHEMA_KEYS ci=$STATE_CI_KEYS ci_schema=$SCHEMA_CI_KEYS"
fi

# Phase order is executable, not prose.
runctl phase run-1 enter implementation >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "illegal-transition-rejected" \
  || fail "illegal-transition-rejected" "rc=$rc"

# Active resume is the idempotent phase-entry read used at every /run boundary.
OUT="$(runctl resume run-1 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | jq -e '.status == "active" and .phase.name == "readiness"' >/dev/null 2>&1; } \
  && pass "active-resume-is-idempotent" \
  || fail "active-resume-is-idempotent" "rc=$rc out=$OUT"

# One branch cannot have two authoritative active runs.
CLAUDE_PROJECT_DIR="$REPO" bash "$P" run-2 main --expected-branch task >/dev/null || exit 1
runctl init run-2 --mode auto --spec docs/spec.md >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "second-active-run-on-branch-rejected" \
  || fail "second-active-run-on-branch-rejected" "rc=$rc"

# Read/status operations re-check branch ownership.
(cd "$REPO" && git switch -qc other) >/dev/null 2>&1
runctl status run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "cross-branch-state-rejected" \
  || fail "cross-branch-state-rejected" "rc=$rc"
(cd "$REPO" && git switch -q task) >/dev/null 2>&1

# Explicit block/resume is the only non-terminal Stop escape for an auto run.
evidence "waiting for a user-owned migration" block run-1 >/dev/null
CLAUDE_PROJECT_DIR="$REPO" bash "$P" run-2 main --expected-branch task >/dev/null || exit 1
runctl init run-2 --mode auto --spec docs/spec.md >/dev/null || exit 1
runctl resume run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "resume-cannot-duplicate-active-owner" \
  || fail "resume-cannot-duplicate-active-owner" "rc=$rc"
evidence "release branch ownership" block run-2 >/dev/null
[ "$(jq -r '.status' "$STATE")" = "blocked" ] && runctl resume run-1 >/dev/null \
  && [ "$(jq -r '.status' "$STATE")" = "active" ] \
  && pass "block-resume-owned-state" || fail "block-resume-owned-state"
rm -rf "$REPO"

# Concurrent initialization is serialized across run IDs, so exactly one state can become active.
REPO="$(mktemp -d)" || exit 1
(
  cd "$REPO" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && mkdir -p docs && printf 'base\n' > file.txt \
    && printf '# Spec\n' > docs/spec.md && git add file.txt docs/spec.md \
    && git commit -qm init && git switch -qc task
) || exit 1
for run_id in parallel-a parallel-b; do
  CLAUDE_PROJECT_DIR="$REPO" bash "$P" "$run_id" main --expected-branch task >/dev/null \
    || exit 1
done
(runctl init parallel-a --mode auto --spec docs/spec.md >/dev/null 2>&1) & pid_a=$!
(runctl init parallel-b --mode auto --spec docs/spec.md >/dev/null 2>&1) & pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 1 ]; } \
    || { [ "$rc_a" -eq 1 ] && [ "$rc_b" -eq 0 ]; }; then
  pass "concurrent-init-allows-one-active-run"
else
  fail "concurrent-init-allows-one-active-run" "rc_a=$rc_a rc_b=$rc_b"
fi
rm -rf "$REPO"

# Specs move from the planning area to the archive while implementation owns mutations. State
# follows only a staged/committed relocation; a copy that leaves the old tracked path cannot pass.
make_repo
complete_readiness && create_plan || exit 1
mkdir -p "$REPO/docs/archive"
cp "$REPO/docs/spec.md" "$REPO/docs/archive/spec-copy.md"
(cd "$REPO" && git add docs/archive/spec-copy.md) >/dev/null 2>&1
runctl spec run-1 relocate docs/archive/spec-copy.md >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "spec-copy-is-not-relocation" \
  || fail "spec-copy-is-not-relocation" "rc=$rc"
(cd "$REPO" && git reset -q docs/archive/spec-copy.md && rm -f docs/archive/spec-copy.md \
  && git mv docs/spec.md docs/archive/spec.md) >/dev/null 2>&1
runctl spec run-1 relocate docs/archive/spec.md >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
  && [ "$(jq -r '.spec' "$REPO/$RUNS_REL/run-1.state.json")" = "docs/archive/spec.md" ]; then
  pass "tracked-spec-relocation-updates-state"
else
  fail "tracked-spec-relocation-updates-state" "rc=$rc"
fi
rm -rf "$REPO"

# A candidate cannot pass review without every required exact-SHA verdict.
make_repo
prepare_candidate || { fail "candidate-fixture"; rm -rf "$REPO"; exit "$fails"; }
SHA="$(git -C "$REPO" rev-parse HEAD)"
evidence "deep review approved" review run-1 record deep-review APPROVE "$SHA" >/dev/null
evidence "mattpocock approved" review run-1 record mattpocock APPROVE "$SHA" >/dev/null
runctl phase run-1 complete review >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "missing-codex-review-blocks" \
  || fail "missing-codex-review-blocks" "rc=$rc"

# Approval is invalid as soon as either HEAD or the worktree differs from the candidate.
evidence "codex approved" review run-1 record codex APPROVE "$SHA" >/dev/null
printf 'post-review mutation\n' >> "$REPO/file.txt"
runctl can-advance run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "dirty-tree-invalidates-review" \
  || fail "dirty-tree-invalidates-review" "rc=$rc"
(cd "$REPO" && git add file.txt && git commit -qm post-review-mutation) >/dev/null 2>&1
runctl can-advance run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "new-head-invalidates-review" \
  || fail "new-head-invalidates-review" "rc=$rc"
rm -rf "$REPO"

# REQUEST_CHANGES is a blocking current verdict and leaves review only through the explicit fix loop.
make_repo
prepare_candidate || { fail "request-changes-fixture"; rm -rf "$REPO"; exit "$fails"; }
SHA="$(git -C "$REPO" rev-parse HEAD)"
evidence "deep review requested changes" review run-1 record deep-review REQUEST_CHANGES "$SHA" >/dev/null
evidence "matt approved" review run-1 record mattpocock APPROVE "$SHA" >/dev/null
evidence "codex approved" review run-1 record codex APPROVE "$SHA" >/dev/null
runctl phase run-1 complete review >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "request-changes-blocks-review" \
  || fail "request-changes-blocks-review" "rc=$rc"
evidence "same candidate reconsidered" review run-1 record deep-review APPROVE "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "request-changes-cannot-be-overwritten" \
  || fail "request-changes-cannot-be-overwritten" "rc=$rc"
evidence "address deep review findings" phase run-1 fix >/dev/null
if jq -e '.phase == {name:"implementation",status:"in_progress"} and
    .candidate.sha == null and all(.reviews[]; .verdict == "PENDING") and .ci.status == "pending"' \
    "$REPO/$RUNS_REL/run-1.state.json" >/dev/null; then
  pass "review-fix-invalidates-downstream"
else
  fail "review-fix-invalidates-downstream"
fi
rm -rf "$REPO"

# Candidate content must be exactly the content that passed testing, even though the test gate can
# be recorded before the candidate commit exists.
make_repo
complete_readiness && create_plan && complete_implementation || exit 1
printf 'tested implementation\n' >> "$REPO/file.txt"
evidence "tests passed on this worktree" gate run-1 record testing pass >/dev/null
runctl phase run-1 complete testing >/dev/null
runctl phase run-1 enter acceptance >/dev/null
evidence "acceptance passed" gate run-1 record acceptance pass >/dev/null
runctl phase run-1 complete acceptance >/dev/null
runctl phase run-1 enter candidate >/dev/null
printf 'untested mutation\n' >> "$REPO/file.txt"
(cd "$REPO" && git add file.txt && git commit -qm untested-mutation) >/dev/null 2>&1
SHA="$(git -C "$REPO" rev-parse HEAD)"
runctl candidate run-1 record "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "candidate-must-match-tested-tree" \
  || fail "candidate-must-match-tested-tree" "rc=$rc"
rm -rf "$REPO"

# A testing/acceptance/candidate/review/delivery failure returns only through the explicit fix loop.
make_repo
complete_readiness && create_plan && complete_implementation || exit 1
evidence "targeted test failed" gate run-1 record testing fail >/dev/null
evidence "same state claimed green" gate run-1 record testing pass >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "failed-testing-gate-cannot-be-overwritten" \
  || fail "failed-testing-gate-cannot-be-overwritten" "rc=$rc"
evidence "test exposed another implementation defect" phase run-1 fix >/dev/null
if jq -e '.phase == {name:"implementation",status:"in_progress"} and .fix_round == 1 and
    any(.tasks[]; .id == "review-fix-1" and .status == "pending") and
    .candidate.sha == null and .ci.status == "pending"' \
    "$REPO/$RUNS_REL/run-1.state.json" >/dev/null; then
  pass "testing-fix-loop-creates-task-and-invalidates"
else
  fail "testing-fix-loop-creates-task-and-invalidates"
fi
rm -rf "$REPO"

# Delivery accepts CI and DoD only for the immutable reviewed candidate.
make_repo
prepare_candidate && approve_all \
  && runctl phase run-1 complete review >/dev/null \
  && runctl phase run-1 enter delivery >/dev/null || exit 1
SHA="$(git -C "$REPO" rev-parse HEAD)"
WRONG_SHA="$(git -C "$REPO" rev-parse main)"
evidence "stale CI run" ci run-1 record success "$WRONG_SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "wrong-ci-sha-rejected" \
  || fail "wrong-ci-sha-rejected" "rc=$rc"
evidence "required checks failed" ci run-1 record failure "$SHA" >/dev/null
runctl phase run-1 complete delivery >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "failed-ci-blocks-delivery" \
  || fail "failed-ci-blocks-delivery" "rc=$rc"
evidence "same candidate CI retried green" ci run-1 record success "$SHA" --pr 42 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "failed-ci-cannot-be-overwritten" \
  || fail "failed-ci-cannot-be-overwritten" "rc=$rc"
rm -rf "$REPO"

# A fresh candidate may record live hosted CI; the state remains bound to that PR until merge.
make_repo
prepare_candidate && approve_all \
  && runctl phase run-1 complete review >/dev/null \
  && runctl phase run-1 enter delivery >/dev/null || exit 1
SHA="$(git -C "$REPO" rev-parse HEAD)"
WRONG_SHA="$(git -C "$REPO" rev-parse main)"

GH_STUB="$(mktemp -d)" || exit 1
cat > "$GH_STUB/gh" <<'GH_STUB_SCRIPT'
#!/usr/bin/env bash
case "$1:$2" in
  pr:view) printf '{"number":42,"state":"%s","headRefOid":"%s","baseRefName":"main","mergeCommit":{"oid":"merge-sha"}}\n' "${GH_TEST_PR_STATE:-OPEN}" "$GH_TEST_SHA" ;;
  pr:checks) printf '%s\n' "$GH_TEST_CHECKS" ;;
  *) exit 1 ;;
esac
GH_STUB_SCRIPT
chmod +x "$GH_STUB/gh"
export GH_TEST_SHA="$WRONG_SHA"
export GH_TEST_CHECKS='[{"bucket":"pass","name":"test","state":"SUCCESS"}]'
PATH="$GH_STUB:$PATH"
evidence "checks passed on stale PR head" ci run-1 record success "$SHA" --pr 42 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "stale-pr-head-not-green" \
  || fail "stale-pr-head-not-green" "rc=$rc"
export GH_TEST_SHA="$SHA"
export GH_TEST_CHECKS='[]'
evidence "no required checks" ci run-1 record success "$SHA" --pr 42 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "absent-required-checks-not-green" \
  || fail "absent-required-checks-not-green" "rc=$rc"
export GH_TEST_CHECKS='[{"bucket":"pass","name":"test","state":"SUCCESS"}]'
evidence "required checks passed" ci run-1 record success "$SHA" --pr 42 >/dev/null
[ "$(jq -r '.ci.pr_number' "$REPO/$RUNS_REL/run-1.state.json")" = "42" ] \
  && pass "successful-ci-is-bound-to-pr" || fail "successful-ci-is-bound-to-pr"
export GH_TEST_CHECKS='[{"bucket":"fail","name":"test","state":"FAILURE"}]'
runctl phase run-1 complete delivery >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "ci-regression-blocks-delivery-at-use-time" \
  || fail "ci-regression-blocks-delivery-at-use-time" "rc=$rc"
export GH_TEST_CHECKS='[{"bucket":"pass","name":"test","state":"SUCCESS"}]'
evidence "DoD verified on candidate" gate run-1 record dod pass --sha "$SHA" >/dev/null
runctl phase run-1 complete delivery >/dev/null
export GH_TEST_SHA="$WRONG_SHA"
runctl can-merge run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "pr-head-move-blocks-merge-time-check" \
  || fail "pr-head-move-blocks-merge-time-check" "rc=$rc"
export GH_TEST_SHA="$SHA"
OUT="$(runctl can-merge run-1 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q "$SHA"; } \
  && pass "exact-sha-delivery-can-merge" \
  || fail "exact-sha-delivery-can-merge" "rc=$rc out=$OUT"
evidence "premature completion claim" finish run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "finish-requires-merged-pr" \
  || fail "finish-requires-merged-pr" "rc=$rc"
export GH_TEST_PR_STATE="MERGED"
evidence "PR merged; issue/spec/branch reconciled" finish run-1 >/dev/null
[ "$(jq -r '.status + ":" + .phase.name' "$REPO/$RUNS_REL/run-1.state.json")" = "completed:done" ] \
  && [ "$(jq -r '.completion_evidence' "$REPO/$RUNS_REL/run-1.state.json")" = "PR merged; issue/spec/branch reconciled" ] \
  && pass "finish-marks-terminal" || fail "finish-marks-terminal"
rm -rf "$GH_STUB"
rm -rf "$REPO"

exit "$fails"
