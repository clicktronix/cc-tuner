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
    task run-1 add implement-feature implementation --ui-task-id ui-implement-feature >/dev/null \
    && evidence "Run targeted, full, static, and runtime verification" \
      task run-1 add verify-tests testing --ui-task-id ui-verify-tests >/dev/null \
    && evidence "Prove every acceptance criterion" \
      task run-1 add verify-acceptance acceptance --ui-task-id ui-verify-acceptance >/dev/null \
    && evidence "Stage and commit the tested candidate" \
      task run-1 add finalize-candidate candidate --ui-task-id ui-finalize-candidate >/dev/null \
    && evidence "Complete every exact-candidate review" \
      task run-1 add review-candidate review --ui-task-id ui-review-candidate >/dev/null \
    && evidence "Publish, verify CI and DoD, then reconcile" \
      task run-1 add deliver-candidate delivery --ui-task-id ui-deliver-candidate >/dev/null \
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
  runctl task run-1 start verify-tests >/dev/null \
    && evidence "targeted/full test commands passed" \
      task run-1 complete verify-tests >/dev/null \
    && evidence "targeted/full test commands passed" gate run-1 record testing pass >/dev/null \
    && runctl phase run-1 complete testing >/dev/null \
    && runctl phase run-1 enter acceptance >/dev/null \
    && runctl task run-1 start verify-acceptance >/dev/null \
    && evidence "machine acceptance passed" \
      task run-1 complete verify-acceptance >/dev/null \
    && evidence "machine acceptance passed" gate run-1 record acceptance pass >/dev/null \
    && runctl phase run-1 complete acceptance >/dev/null \
    && runctl phase run-1 enter candidate >/dev/null
}

record_candidate_and_enter_review() {
  SHA="$(git -C "$REPO" rev-parse HEAD)"
  runctl candidate run-1 record "$SHA" >/dev/null \
    && runctl task run-1 start finalize-candidate >/dev/null \
    && evidence "tested clean candidate recorded at $SHA" \
      task run-1 complete finalize-candidate >/dev/null \
    && runctl phase run-1 complete candidate >/dev/null \
    && runctl phase run-1 enter review >/dev/null
}

approve_all() {
  SHA="$(git -C "$REPO" rev-parse HEAD)"
  for reviewer in deep-review mattpocock; do
    evidence "$reviewer approved exact candidate" \
      review run-1 record "$reviewer" APPROVE "$SHA" >/dev/null || return 1
  done
  codex_stub_agrees
  evidence "$(codex_approval_marker)" \
    review run-1 record codex APPROVE "$SHA" >/dev/null \
    && runctl task run-1 start review-candidate >/dev/null \
    && evidence "all required reviews approved $SHA" \
      task run-1 complete review-candidate >/dev/null
}

codex_approval_marker() {
  state="$REPO/$RUNS_REL/run-1.state.json"
  sha="$(git -C "$REPO" rev-parse HEAD)"
  tree="$(jq -r '.candidate.tree_sha' "$state")"
  base="$(jq -r '.base_sha' "$state")"
  spec="$(jq -r '.spec' "$state")"
  printf 'CC_CODEX_REQUIRED_REVIEW APPROVE thread=review-run-1 head=%s tree=%s fingerprint=%040d base_sha=%s spec_path=%s\n' \
    "$sha" "$tree" 0 "$base" "$spec"
}

# A stub cc-codex-triage installation. It stands in for the plugin whose OWN suite proves that a
# marker is only produced for an attributable exact-candidate APPROVE; what is under test here is
# that runctl refuses to accept a marker no installed plugin will confirm.
install_codex_stub() {
  CODEX_STUB="$(mktemp -d)" || return 1
  mkdir -p "$CODEX_STUB/root/scripts"
  cat > "$CODEX_STUB/root/scripts/review-state.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = check ] || exit 1
[ -n "${CC_TUNER_TEST_CODEX_APPROVAL:-}" ] || exit 10
printf '%s\n' "$CC_TUNER_TEST_CODEX_APPROVAL"
STUB
  chmod +x "$CODEX_STUB/root/scripts/review-state.sh"
  jq -n --arg path "$CODEX_STUB/root" \
    '{plugins:{"cc-codex-triage@cc-codex-triage":[{scope:"user",installPath:$path}]}}' \
    > "$CODEX_STUB/installed_plugins.json" || return 1
  export CLAUDE_PLUGIN_CACHE="$CODEX_STUB"
}

# The happy path only exists when the authority agrees with the pasted marker.
codex_stub_agrees() { export CC_TUNER_TEST_CODEX_APPROVAL="$(codex_approval_marker)"; }
codex_stub_silent() { unset CC_TUNER_TEST_CODEX_APPROVAL; }

prepare_candidate() {
  complete_readiness && create_plan || return 1
  # Task-path content must be final BEFORE implementation completes: everything after that point
  # is verification, and the testing gate now refuses a tree that moved since.
  printf 'implementation\n' >> "$REPO/file.txt"
  complete_implementation || return 1
  (cd "$REPO" && git add file.txt && git commit -qm implementation) || return 1
  complete_testing_to_candidate && record_candidate_and_enter_review
}

install_codex_stub || exit 1

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
runctl init run-1 --mode auto --spec ./docs/spec.md >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(jq -r '.spec' "$STATE")" = "docs/spec.md" ]; then
  pass "spec-path-is-canonicalized"
else
  fail "spec-path-is-canonicalized" "rc=$rc spec=$(jq -r '.spec' "$STATE")"
fi

SCHEMA="$DIR/../../schemas/run-state.schema.json"
STATE_KEYS="$(jq -c 'keys | sort' "$STATE")"
SCHEMA_KEYS="$(jq -c '.required | sort' "$SCHEMA")"
STATE_CI_KEYS="$(jq -c '.ci | keys | sort' "$STATE")"
SCHEMA_CI_KEYS="$(jq -c '.properties.ci.required | sort' "$SCHEMA")"
if [ "$STATE_KEYS" = "$SCHEMA_KEYS" ] && [ "$STATE_CI_KEYS" = "$SCHEMA_CI_KEYS" ] \
    && jq -e '
      .properties.required_reviewers.const == ["deep-review","mattpocock","codex"] and
      .properties.fix_round.maximum == 999999 and
      (."$defs".task.properties.phase.enum | length) == 6 and
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

# Project subdirectories in one worktree share one repo-wide run owner.
REPO="$(mktemp -d)" || exit 1
(
  cd "$REPO" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && mkdir -p docs packages/a packages/b \
    && printf 'base\n' > file.txt && printf '# Spec\n' > docs/spec.md \
    && printf 'a\n' > packages/a/a.txt && printf 'b\n' > packages/b/b.txt \
    && git add . && git commit -qm init && git switch -qc task
) || exit 1
CLAUDE_PROJECT_DIR="$REPO/packages/a" bash "$P" sub-a main --expected-branch task >/dev/null \
  || exit 1
CLAUDE_PROJECT_DIR="$REPO/packages/a" bash "$R" init sub-a --mode auto --spec docs/spec.md >/dev/null \
  || exit 1
CLAUDE_PROJECT_DIR="$REPO/packages/b" bash "$P" sub-b main --expected-branch task >/dev/null \
  || exit 1
CLAUDE_PROJECT_DIR="$REPO/packages/b" bash "$R" init sub-b --mode auto --spec docs/spec.md >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ] \
  && [ "$(find "$REPO/$RUNS_REL" -name '*.state.json' -type f | wc -l | tr -d ' ')" -eq 1 ] \
  && [ ! -e "$REPO/packages/a/.claude" ] && [ ! -e "$REPO/packages/b/.claude" ]; then
  pass "subdirectories-share-repo-wide-run-owner"
else
  fail "subdirectories-share-repo-wide-run-owner" "rc=$rc"
fi
rm -rf "$REPO"

# Evidence arrives on stdin, and stdin can be a pipe nobody closes. Reading it while holding the
# state mutex would wedge the run behind a LIVE pid, which no staleness rule ever clears.
make_repo
complete_readiness && create_plan || exit 1
FIFO="$REPO/blocking-stdin"
mkfifo "$FIFO" || exit 1
( exec 9>"$FIFO"; sleep 30 ) & fifo_holder=$!
( runctl task run-1 complete implement-feature < "$FIFO" >/dev/null 2>&1 ) & blocked_writer=$!
sleep 1
# Bounded on purpose: the regression this guards against is a wedge, and a test that reproduces a
# wedge by wedging reports nothing. Probe in the background and treat "still running" as the failure.
( runctl task run-1 start implement-feature >"$REPO/probe.out" 2>&1; printf '%s\n' "$?" > "$REPO/probe.rc" ) &
probe=$!
waited=0
while [ ! -f "$REPO/probe.rc" ] && [ "$waited" -lt 20 ]; do sleep 0.5; waited=$((waited + 1)); done
kill "$probe" "$fifo_holder" "$blocked_writer" 2>/dev/null
wait "$probe" "$fifo_holder" "$blocked_writer" 2>/dev/null
rc="$(cat "$REPO/probe.rc" 2>/dev/null || printf 'still-blocked')"
if [ "$rc" = "0" ]; then
  pass "blocked-stdin-does-not-hold-the-state-lock"
else
  fail "blocked-stdin-does-not-hold-the-state-lock" "rc=$rc out=$(cat "$REPO/probe.out" 2>/dev/null)"
fi
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

# A dead initialization lock used to let several stale-lock contenders remove one another's fresh
# generation and all enter the critical section. Repeated eight-way contention must still produce
# exactly one active run per repository.
lock_race_ok=1
lock_race_trial=1
while [ "$lock_race_trial" -le 20 ]; do
  REPO="$(mktemp -d)" || exit 1
  RESULTS="$(mktemp -d)" || exit 1
  (
    cd "$REPO" && git init -q -b main && git config user.email test@example.com \
      && git config user.name test && mkdir -p docs && printf 'base\n' > file.txt \
      && printf '# Spec\n' > docs/spec.md && git add file.txt docs/spec.md \
      && git commit -qm init && git switch -qc task
  ) || exit 1
  for n in 1 2 3 4 5 6 7 8; do
    CLAUDE_PROJECT_DIR="$REPO" bash "$P" "race-$n" main --expected-branch task >/dev/null \
      || exit 1
  done
  mkdir "$REPO/$RUNS_REL/.init.lock"
  printf '999999999999\n' > "$REPO/$RUNS_REL/.init.lock/pid"
  for n in 1 2 3 4 5 6 7 8; do
    (
      runctl init "race-$n" --mode auto --spec docs/spec.md >/dev/null 2>&1
      printf '%s\n' "$?" > "$RESULTS/$n"
    ) &
  done
  wait
  successes="$(awk '$1 == 0 { total++ } END { print total + 0 }' "$RESULTS"/*)"
  active="$(find "$REPO/$RUNS_REL" -type f -name '*.state.json' | wc -l | tr -d ' ')"
  if [ "$successes" -ne 1 ] || [ "$active" -ne 1 ]; then
    lock_race_ok=0
    break
  fi
  rm -rf "$REPO" "$RESULTS"
  lock_race_trial=$((lock_race_trial + 1))
done
if [ "$lock_race_ok" -eq 1 ]; then
  pass "stale-init-lock-contention-is-serialized"
else
  fail "stale-init-lock-contention-is-serialized" \
    "trial=$lock_race_trial successes=$successes active=$active"
  rm -rf "$REPO" "$RESULTS"
fi

# Specs move from the planning area to the archive while implementation owns mutations. State
# follows only a staged/committed relocation; a copy that leaves the old tracked path cannot pass.
make_repo
complete_readiness || exit 1
evidence "Impossible late readiness task" task run-1 add late-readiness readiness >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "past-phase-task-is-rejected" \
  || fail "past-phase-task-is-rejected" "rc=$rc"
evidence "Reserved fix task" task run-1 add review-fix-1 implementation >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "fix-task-namespace-is-reserved" \
  || fail "fix-task-namespace-is-reserved" "rc=$rc"
evidence "Implementation only" task run-1 add implement-only implementation >/dev/null
runctl phase run-1 complete planning >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "planning-requires-full-lifecycle" \
  || fail "planning-requires-full-lifecycle" "rc=$rc"
rm -rf "$REPO"

# A complete lifecycle plan is still not visible until every structured task is bound to the UI.
make_repo
complete_readiness || exit 1
for item in \
  "implement-feature implementation" \
  "verify-tests testing" \
  "verify-acceptance acceptance" \
  "finalize-candidate candidate" \
  "review-candidate review" \
  "deliver-candidate delivery"; do
  set -- $item
  evidence "Lifecycle task $1" task run-1 add "$1" "$2" >/dev/null
done
runctl phase run-1 complete planning >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "planning-requires-visible-task-bindings" \
  || fail "planning-requires-visible-task-bindings" "rc=$rc"
for task_id in implement-feature verify-tests verify-acceptance finalize-candidate review-candidate deliver-candidate; do
  runctl task run-1 bind-ui "$task_id" "ui-$task_id" >/dev/null || exit 1
done
runctl phase run-1 complete planning >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "bound-visible-plan-completes" \
  || fail "bound-visible-plan-completes" "rc=$rc"
rm -rf "$REPO"

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
runctl task run-1 start review-candidate >/dev/null
evidence "review task completed for gate validation" \
  task run-1 complete review-candidate >/dev/null
runctl phase run-1 complete review >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "missing-codex-review-blocks" \
  || fail "missing-codex-review-blocks" "rc=$rc"

# Approval is invalid as soon as either HEAD or the worktree differs from the candidate.
evidence "codex approved" review run-1 record codex APPROVE "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "codex-approval-requires-self-verified-marker" \
  || fail "codex-approval-requires-self-verified-marker" "rc=$rc"
bad_marker="$(codex_approval_marker | sed 's/fingerprint=/digest=/')"
evidence "$bad_marker" review run-1 record codex APPROVE "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "codex-approval-requires-fingerprint-label" \
  || fail "codex-approval-requires-fingerprint-label" "rc=$rc"

# Every field of the marker is a value this process already knows, and the fingerprint is only
# shape-checked — so a well-formed marker is text an agent can type. It counts as approval only
# when the installed reviewer plugin still holds that exact approval.
codex_stub_silent
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'no gate-eligible approval'; } \
  && pass "well-formed-marker-without-authoritative-approval-rejected" \
  || fail "well-formed-marker-without-authoritative-approval-rejected" "rc=$rc out=$OUT"
export CC_TUNER_TEST_CODEX_APPROVAL="$(codex_approval_marker | sed 's/fingerprint=0/fingerprint=1/')"
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'does not match the approval'; } \
  && pass "marker-must-equal-the-authoritative-approval" \
  || fail "marker-must-equal-the-authoritative-approval" "rc=$rc out=$OUT"
SAVED_PLUGIN_CACHE="$CLAUDE_PLUGIN_CACHE"
export CLAUDE_PLUGIN_CACHE="$REPO/no-such-plugin-cache"
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cannot locate an installed cc-codex-triage'; } \
  && pass "absent-reviewer-plugin-fails-closed" \
  || fail "absent-reviewer-plugin-fails-closed" "rc=$rc out=$OUT"
export CLAUDE_PLUGIN_CACHE="$SAVED_PLUGIN_CACHE"
codex_stub_agrees
evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" >/dev/null
printf 'post-review mutation\n' >> "$REPO/file.txt"
runctl can-advance run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "dirty-tree-invalidates-review" \
  || fail "dirty-tree-invalidates-review" "rc=$rc"
(cd "$REPO" && git add file.txt && git commit -qm post-review-mutation) >/dev/null 2>&1
runctl can-advance run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "new-head-invalidates-review" \
  || fail "new-head-invalidates-review" "rc=$rc"
rm -rf "$REPO"

# REQUEST_CHANGES blocks review, but a reviewer may approve the same immutable candidate after a
# documented refutation/defer disposition. Both verdicts remain auditable in review_history.
make_repo
prepare_candidate || { fail "request-changes-fixture"; rm -rf "$REPO"; exit "$fails"; }
SHA="$(git -C "$REPO" rev-parse HEAD)"
evidence "deep review requested changes" review run-1 record deep-review REQUEST_CHANGES "$SHA" >/dev/null
evidence "matt approved" review run-1 record mattpocock APPROVE "$SHA" >/dev/null
codex_stub_agrees
evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" >/dev/null
runctl task run-1 start review-candidate >/dev/null
evidence "review attempt completed with blocking verdict" \
  task run-1 complete review-candidate >/dev/null
runctl phase run-1 complete review >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "request-changes-blocks-review" \
  || fail "request-changes-blocks-review" "rc=$rc"
evidence "Refuted finding with file.txt:1 evidence; same tree remains valid" \
  review run-1 record deep-review APPROVE "$SHA" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && jq -e --arg sha "$SHA" '
    (.reviews[] | select(.reviewer == "deep-review")) |
      .verdict == "APPROVE" and .sha == $sha
  ' "$REPO/$RUNS_REL/run-1.state.json" >/dev/null \
  && jq -e --arg sha "$SHA" '
    [.review_history[] | select(.reviewer == "deep-review" and .sha == $sha) | .verdict] ==
      ["REQUEST_CHANGES", "APPROVE"]
  ' "$REPO/$RUNS_REL/run-1.state.json" >/dev/null \
  && runctl phase run-1 complete review >/dev/null; then
  pass "same-candidate-disposition-allows-fresh-approval"
else
  fail "same-candidate-disposition-allows-fresh-approval" "rc=$rc"
fi
rm -rf "$REPO"

# A finding that requires source/test changes returns through the explicit fix loop and invalidates
# every candidate-bound downstream gate.
make_repo
prepare_candidate || { fail "review-fix-fixture"; rm -rf "$REPO"; exit "$fails"; }
SHA="$(git -C "$REPO" rev-parse HEAD)"
evidence "deep review found a source defect" \
  review run-1 record deep-review REQUEST_CHANGES "$SHA" >/dev/null
FIX_OUT="$(evidence "address deep review findings" phase run-1 fix)"; rc=$?
if jq -e '.phase == {name:"implementation",status:"in_progress"} and
    .candidate.sha == null and all(.reviews[]; .verdict == "PENDING") and .ci.status == "pending" and
    any(.tasks[]; .id == "review-candidate" and .status == "pending" and .evidence == null)' \
    "$REPO/$RUNS_REL/run-1.state.json" >/dev/null \
  && [ "$rc" -eq 0 ] && [ "$FIX_OUT" = "FIX_TASK id=review-fix-1 phase=implementation" ]; then
  pass "review-fix-invalidates-downstream"
else
  fail "review-fix-invalidates-downstream" "rc=$rc out=$FIX_OUT"
fi
runctl task run-1 start review-fix-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "fix-task-cannot-start-before-visible-binding" \
  || fail "fix-task-cannot-start-before-visible-binding" "rc=$rc"
runctl task run-1 bind-ui review-fix-1 ui-review-fix-1 >/dev/null \
  && runctl task run-1 start review-fix-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "bound-fix-task-can-start" \
  || fail "bound-fix-task-can-start" "rc=$rc"
rm -rf "$REPO"

# The PreToolUse hook only sees the tools it matches, so a Bash heredoc, `sed -i`, or a formatter
# can mutate task paths in a phase that forbids it. The state machine has to catch that itself:
# whatever content implementation ended with is what testing is allowed to verify.
make_repo
complete_readiness && create_plan || exit 1
printf 'tested implementation\n' >> "$REPO/file.txt"
complete_implementation || exit 1
IMPL_TREE="$(jq -r '[.gates[] | select(.id == "implementation-tree")][-1].tree_sha' \
  "$REPO/$RUNS_REL/run-1.state.json")"
case "$IMPL_TREE" in
  [0-9a-f]*) pass "implementation-completion-records-worktree-content" ;;
  *) fail "implementation-completion-records-worktree-content" "tree=$IMPL_TREE" ;;
esac
printf 'bash-only mutation the hook cannot see\n' >> "$REPO/file.txt"
OUT="$(evidence "tests passed" gate run-1 record testing pass 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'changed after implementation completed'; } \
  && pass "post-implementation-mutation-blocks-testing-gate" \
  || fail "post-implementation-mutation-blocks-testing-gate" "rc=$rc out=$OUT"
# The recorded content is the state machine's own, not an evidence field an agent may write.
OUT="$(evidence "hand-written tree" gate run-1 record implementation-tree pass 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cannot be recorded by hand'; } \
  && pass "implementation-tree-gate-is-reserved" \
  || fail "implementation-tree-gate-is-reserved" "rc=$rc out=$OUT"
# Reverting the unauthorised change restores the tested content, so the gate opens again.
(cd "$REPO" && git checkout -- file.txt && printf 'tested implementation\n' >> file.txt) \
  >/dev/null 2>&1
evidence "tests passed on this worktree" gate run-1 record testing pass >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "reverted-tree-reopens-testing-gate" \
  || fail "reverted-tree-reopens-testing-gate" "rc=$rc"
runctl task run-1 start verify-tests >/dev/null
evidence "testing task completed" task run-1 complete verify-tests >/dev/null
runctl phase run-1 complete testing >/dev/null
runctl phase run-1 enter acceptance >/dev/null
evidence "acceptance passed" gate run-1 record acceptance pass >/dev/null
runctl task run-1 start verify-acceptance >/dev/null
evidence "acceptance task completed" task run-1 complete verify-acceptance >/dev/null
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
FIX_OUT="$(evidence "test exposed another implementation defect" phase run-1 fix)"; rc=$?
if jq -e '.phase == {name:"implementation",status:"in_progress"} and .fix_round == 1 and
    any(.tasks[]; .id == "review-fix-1" and .status == "pending") and
    .candidate.sha == null and .ci.status == "pending"' \
    "$REPO/$RUNS_REL/run-1.state.json" >/dev/null \
  && [ "$rc" -eq 0 ] && [ "$FIX_OUT" = "FIX_TASK id=review-fix-1 phase=implementation" ]; then
  pass "testing-fix-loop-creates-task-and-invalidates"
else
  fail "testing-fix-loop-creates-task-and-invalidates" "rc=$rc out=$FIX_OUT"
fi
rm -rf "$REPO"

# The persisted fix-loop counter is bounded before Bash arithmetic can wrap.
make_repo
complete_readiness && create_plan && complete_implementation || exit 1
STATE="$REPO/$RUNS_REL/run-1.state.json"
jq '.fix_round = 999999' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
evidence "one more fix" phase run-1 fix >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [ "$(jq -r '.fix_round' "$STATE")" -eq 999999 ]; then
  pass "fix-loop-limit-rejected-before-arithmetic"
else
  fail "fix-loop-limit-rejected-before-arithmetic" "rc=$rc round=$(jq -r '.fix_round' "$STATE")"
fi
jq '.fix_round = 1000000' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
runctl status run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "out-of-range-fix-counter-invalidates-state" \
  || fail "out-of-range-fix-counter-invalidates-state" "rc=$rc"
rm -rf "$REPO"

# Delivery accepts CI and DoD only for the immutable reviewed candidate.
make_repo
prepare_candidate && approve_all \
  && runctl phase run-1 complete review >/dev/null \
  && runctl phase run-1 enter delivery >/dev/null || exit 1
runctl task run-1 start deliver-candidate >/dev/null
evidence "delivery attempt completed for CI gate validation" \
  task run-1 complete deliver-candidate >/dev/null
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
runctl task run-1 start deliver-candidate >/dev/null
evidence "PR, current-SHA CI, and DoD verified" \
  task run-1 complete deliver-candidate >/dev/null
runctl phase run-1 complete delivery >/dev/null
evidence "late CI failure" ci run-1 record failure "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "completed-delivery-ci-is-immutable" \
  || fail "completed-delivery-ci-is-immutable" "rc=$rc"
evidence "late DoD failure" gate run-1 record dod fail --sha "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "completed-delivery-dod-is-immutable" \
  || fail "completed-delivery-dod-is-immutable" "rc=$rc"
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
