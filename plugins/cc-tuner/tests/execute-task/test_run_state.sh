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
# that runctl refuses to accept a marker no installed plugin will confirm. The gate reads a fixed
# location, so the stub is installed by moving HOME rather than through a plugin-specific override —
# a delivery gate that takes its authority's address from a test hook is not a gate.
install_codex_stub() {
  CODEX_STUB="$(mktemp -d)" || return 1
  STUB_ROOT="$CODEX_STUB/root"
  mkdir -p "$STUB_ROOT/scripts" "$STUB_ROOT/commands" "$CODEX_STUB/.claude/plugins"
  cat > "$STUB_ROOT/scripts/review-state.sh" <<'STUB'
#!/usr/bin/env bash
# CC_CODEX_REQUIRED_REVIEW APPROVE — contract marker the resolver requires.
[ "${1:-}" = check ] || exit 1
# The real verifier reads its approval state from a directory CC_CODEX_STATE_DIR can redirect. If
# the gate passed that through, an ambient value would decide where the answer comes from.
[ -z "${CC_CODEX_STATE_DIR:-}" ] || { echo "state directory was redirected" >&2; exit 12; }
[ -n "${CC_TUNER_TEST_CODEX_APPROVAL:-}" ] || exit 10
printf '%s\n' "$CC_TUNER_TEST_CODEX_APPROVAL"
STUB
  chmod +x "$STUB_ROOT/scripts/review-state.sh"
  printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$STUB_ROOT/commands/review.md"
  jq -n --arg path "$STUB_ROOT" \
    '{plugins:{"cc-codex-triage@cc-codex-triage":[{scope:"user",installPath:$path}]}}' \
    > "$CODEX_STUB/.claude/plugins/installed_plugins.json" || return 1
  export HOME="$CODEX_STUB"
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
  && jq -e '.schema_version == 2 and .phase == {name:"readiness",status:"in_progress"} and
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

# Explicit block/unblock is the only non-terminal Stop escape for an auto run.
evidence "waiting for a user-owned migration" block run-1 >/dev/null
# /run calls `resume` at the top of every phase. If that cleared the block, an unattended run would
# walk straight past a hard stop nobody has resolved — so resume must report it and refuse.
OUT="$(runctl resume run-1 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'is blocked:' \
  && [ "$(jq -r '.status' "$STATE")" = "blocked" ]; } \
  && pass "resume-does-not-clear-a-block" \
  || fail "resume-does-not-clear-a-block" "rc=$rc out=$OUT"
CLAUDE_PROJECT_DIR="$REPO" bash "$P" run-2 main --expected-branch task >/dev/null || exit 1
runctl init run-2 --mode auto --spec docs/spec.md >/dev/null || exit 1
evidence "the user chose to continue" unblock run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "unblock-cannot-duplicate-active-owner" \
  || fail "unblock-cannot-duplicate-active-owner" "rc=$rc"
runctl unblock run-1 < /dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "unblock-requires-a-recorded-decision" \
  || fail "unblock-requires-a-recorded-decision" "rc=$rc"
evidence "release branch ownership" block run-2 >/dev/null
[ "$(jq -r '.status' "$STATE")" = "blocked" ] \
  && evidence "user resolved the migration" unblock run-1 >/dev/null \
  && [ "$(jq -r '.status' "$STATE")" = "active" ] \
  && pass "block-unblock-owned-state" || fail "block-unblock-owned-state"
# Unblocking nulls blocked_reason, so the state file alone cannot show a hard stop was walked past.
# The decision has to outlive the command that consumed it.
JOURNAL_FILE="$REPO/$RUNS_REL/run-1.md"
# The entry must record the decision without asserting a transition the command had not made when it
# was written — a crash between the two would otherwise leave a journal line that is simply false.
{ grep -qF 'user resolved the migration' "$JOURNAL_FILE" \
  && grep -qF 'waiting for a user-owned migration' "$JOURNAL_FILE" \
  && grep -qF 'state remains authoritative' "$JOURNAL_FILE"; } \
  && pass "unblock-decision-outlives-the-command" \
  || fail "unblock-decision-outlives-the-command"
evidence "already active" unblock run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "unblock-rejects-an-active-run" \
  || fail "unblock-rejects-an-active-run" "rc=$rc"
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
# A run opened without --spec cannot satisfy the required-review marker at all. Say that, instead of
# reporting a mismatch against an empty expected value.
SPEC_BACKUP="$(jq -r '.spec' "$REPO/$RUNS_REL/run-1.state.json")"
jq '.spec = null' "$REPO/$RUNS_REL/run-1.state.json" > "$REPO/state.tmp" \
  && mv "$REPO/state.tmp" "$REPO/$RUNS_REL/run-1.state.json"
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'has no spec path'; } \
  && pass "spec-less-run-names-the-missing-spec" \
  || fail "spec-less-run-names-the-missing-spec" "rc=$rc out=$OUT"
jq --arg spec "$SPEC_BACKUP" '.spec = $spec' "$REPO/$RUNS_REL/run-1.state.json" > "$REPO/state.tmp" \
  && mv "$REPO/state.tmp" "$REPO/$RUNS_REL/run-1.state.json"

# Precedence is a total order — local, then project, then user — so entry order in the manifest
# cannot change the answer. Only the root expected to win answers correctly, so an approval proves
# which one was chosen. Two cases, because a fixture with a single loser would stay green under any
# ordering that merely puts that loser last.
SAVED_HOME_PRECEDENCE="$HOME"
REPO_REAL="$(cd "$REPO" && pwd -P)"

# $1 = scope expected to win; remaining args = the other scopes present.
assert_precedence_winner() {
  winner="$1"; shift
  MULTI="$(mktemp -d)" || return 1
  mkdir -p "$MULTI/.claude/plugins"
  for scope in "$winner" "$@"; do
    mkdir -p "$MULTI/$scope/scripts" "$MULTI/$scope/commands"
    printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$MULTI/$scope/commands/review.md"
    if [ "$scope" = "$winner" ]; then
      printf '#!/usr/bin/env bash\n# CC_CODEX_REQUIRED_REVIEW APPROVE\n[ "${1:-}" = check ] || exit 1\nprintf %%s\\\\n "$CC_TUNER_TEST_CODEX_APPROVAL"\n' \
        > "$MULTI/$scope/scripts/review-state.sh"
    else
      printf '#!/usr/bin/env bash\n# CC_CODEX_REQUIRED_REVIEW APPROVE\n[ "${1:-}" = check ] || exit 1\nprintf %%s\\\\n "wrong-root-%s"\n' \
        "$scope" > "$MULTI/$scope/scripts/review-state.sh"
    fi
    chmod +x "$MULTI/$scope/scripts/review-state.sh"
  done
  # Listed worst-first on purpose: a resolver that took manifest order would pick the wrong one.
  entries=""
  for scope in user project local; do
    case " $winner $* " in *" $scope "*) ;; *) continue ;; esac
    if [ "$scope" = user ]; then
      entries="$entries{\"scope\":\"user\",\"installPath\":\"$MULTI/user\"},"
    else
      entries="$entries{\"scope\":\"$scope\",\"projectPath\":\"$REPO_REAL\",\"installPath\":\"$MULTI/$scope\"},"
    fi
  done
  printf '{"plugins":{"cc-codex-triage@cc-codex-triage":[%s]}}' "${entries%,}" \
    > "$MULTI/.claude/plugins/installed_plugins.json"
  export HOME="$MULTI"
  export CC_TUNER_TEST_CODEX_APPROVAL="$(codex_approval_marker)"
  evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" >/dev/null 2>&1
  precedence_rc=$?
  export HOME="$SAVED_HOME_PRECEDENCE"
  rm -rf "$MULTI"
  return "$precedence_rc"
}

assert_precedence_winner local project user \
  && pass "local-install-outranks-project-and-user" \
  || fail "local-install-outranks-project-and-user"
assert_precedence_winner project user \
  && pass "project-install-outranks-user" \
  || fail "project-install-outranks-user"


# preflight and the gate must agree on what counts as an installation. A root that carries
# review-state.sh but not the required-review contract is one the prerequisite check rejects, so the
# gate cannot accept it either — otherwise preflight passes on one install and approval comes from
# another.
SAVED_HOME="$HOME"
HALF_HOME="$(mktemp -d)"
mkdir -p "$HALF_HOME/root/scripts" "$HALF_HOME/.claude/plugins"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HALF_HOME/root/scripts/review-state.sh"
jq -n --arg path "$HALF_HOME/root" \
  '{plugins:{"cc-codex-triage@cc-codex-triage":[{scope:"user",installPath:$path}]}}' \
  > "$HALF_HOME/.claude/plugins/installed_plugins.json"
export HOME="$HALF_HOME"
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cannot locate an installed cc-codex-triage'; } \
  && pass "root-without-the-required-review-contract-is-not-an-installation" \
  || fail "root-without-the-required-review-contract-is-not-an-installation" "rc=$rc out=$OUT"
rm -rf "$HALF_HOME"

export HOME="$REPO/no-such-home"
OUT="$(evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cannot locate an installed cc-codex-triage'; } \
  && pass "absent-reviewer-plugin-fails-closed" \
  || fail "absent-reviewer-plugin-fails-closed" "rc=$rc out=$OUT"
export HOME="$SAVED_HOME"
codex_stub_agrees
# The reviewer's own state override must not survive into the gate's call.
export CC_CODEX_STATE_DIR="$REPO/redirected-review-state"
evidence "$(codex_approval_marker)" review run-1 record codex APPROVE "$SHA" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "ambient-state-override-does-not-reach-the-verifier" \
  || fail "ambient-state-override-does-not-reach-the-verifier" "rc=$rc"
unset CC_CODEX_STATE_DIR
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

# Prepared commit/PR text needs a home that is neither the shell nor the candidate tree. The run asks
# for one instead of inventing a path, so the fence never has to judge an arbitrary outside path.
make_repo
PREPARED="$(runctl prepare run-1 commit-message)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$PREPARED" ]; } && pass "prepare-returns-a-usable-path" \
  || fail "prepare-returns-a-usable-path" "rc=$rc path=$PREPARED"
REPO_REAL_PREP="$(cd "$REPO" && pwd -P)"
case "$PREPARED" in
  "$REPO_REAL_PREP"/*) fail "prepared-file-is-outside-the-repository" "$PREPARED" ;;
  /*) pass "prepared-file-is-outside-the-repository" ;;
  *) fail "prepared-file-is-outside-the-repository" "not absolute: $PREPARED" ;;
esac
printf 'subject\n' > "$PREPARED"
[ "$(runctl prepare run-1 commit-message)" = "$PREPARED" ] \
  && pass "prepare-is-stable-across-a-resume" || fail "prepare-is-stable-across-a-resume"
[ "$(cat "$PREPARED")" = "subject" ] && pass "prepare-does-not-truncate-a-reused-path" \
  || fail "prepare-does-not-truncate-a-reused-path"
runctl prepare run-1 arbitrary-note >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "prepare-allows-only-owned-workflow-files" \
  || fail "prepare-allows-only-owned-workflow-files" "rc=$rc"
runctl prepare run-1 '../escape' >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "prepare-rejects-a-traversing-name" \
  || fail "prepare-rejects-a-traversing-name" "rc=$rc"

# `prepare` itself is a Bash command, so the hook cannot protect a destination it follows while
# creating the file. An existing hard link must be rejected without touching its other name.
PREPARED_DIR="$(dirname "$PREPARED")"
FILE_BEFORE="$(cat "$REPO/file.txt")"
ln "$REPO/file.txt" "$PREPARED_DIR/pr-body" 2>/dev/null
runctl prepare run-1 pr-body >/dev/null 2>&1; rc=$?
if [ -e "$PREPARED_DIR/pr-body" ]; then
  { [ "$rc" -eq 1 ] && [ "$(cat "$REPO/file.txt")" = "$FILE_BEFORE" ]; } \
    && pass "prepare-refuses-a-hard-linked-destination-without-truncating" \
    || fail "prepare-refuses-a-hard-linked-destination-without-truncating" "rc=$rc"
  rm -f "$PREPARED_DIR/pr-body"
else
  fail "prepare-refuses-a-hard-linked-destination-without-truncating" "could not create fixture"
fi

# Reject an unsafe scratch root before mkdir or redirection can dirty the candidate tree.
IN_REPO_TMP="$REPO/in-repo-tmp"
mkdir -p "$IN_REPO_TMP"
TMPDIR="$IN_REPO_TMP" runctl prepare run-1 pr-body >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$(find "$IN_REPO_TMP" -mindepth 1 -print -quit)" ]; then
  pass "prepare-rejects-an-in-repo-tmpdir-without-side-effects"
else
  fail "prepare-rejects-an-in-repo-tmpdir-without-side-effects" "rc=$rc"
fi

# A run id is unique only inside one repository. Repository identity must therefore participate in
# the scratch namespace, or two simultaneous `run-1` lifecycles overwrite one another's text.
FIRST_REPO="$REPO"
SECOND_REPO="$(mktemp -d)" || exit 1
(
  cd "$SECOND_REPO" && git init -q -b main && git config user.email test@example.com \
    && git config user.name test && mkdir -p docs && printf 'other\n' > file.txt \
    && printf '# Spec\n' > docs/spec.md && git add file.txt docs/spec.md \
    && git commit -qm init && git switch -qc task
) || exit 1
CLAUDE_PROJECT_DIR="$SECOND_REPO" bash "$P" run-1 main --expected-branch task >/dev/null \
  || exit 1
CLAUDE_PROJECT_DIR="$SECOND_REPO" bash "$R" init run-1 --mode auto --spec docs/spec.md >/dev/null \
  || exit 1
SECOND_PREPARED="$(CLAUDE_PROJECT_DIR="$SECOND_REPO" bash "$R" prepare run-1 commit-message)"
[ "$SECOND_PREPARED" != "$PREPARED" ] && pass "prepared-path-is-repository-bound" \
  || fail "prepared-path-is-repository-bound" "$SECOND_PREPARED"
rm -rf "$SECOND_REPO"
REPO="$FIRST_REPO"

evidence "stop here" block run-1 >/dev/null
runctl prepare run-1 commit-message >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "prepare-refuses-a-blocked-run" \
  || fail "prepare-refuses-a-blocked-run" "rc=$rc"
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
# The published schema declares completed_phases uniqueItems. The runtime validator has to agree, or
# the schema is decoration: nothing else reads it.
jq '.fix_round = 0 | .completed_phases = ["readiness","planning","readiness"]' "$STATE" \
  > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
runctl status run-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "duplicate-completed-phase-invalidates-state" \
  || fail "duplicate-completed-phase-invalidates-state" "rc=$rc"
jq -e '.properties.completed_phases.uniqueItems == true' \
  "$DIR/../../schemas/run-state.schema.json" >/dev/null \
  && pass "schema-still-declares-the-rule-the-validator-enforces" \
  || fail "schema-still-declares-the-rule-the-validator-enforces"
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
DELIVERY_PREPARED="$(runctl prepare run-1 pr-body)"
printf 'sensitive PR body\n' > "$DELIVERY_PREPARED"
DELIVERY_PREPARED_DIR="$(dirname "$DELIVERY_PREPARED")"
# Every name `prepare` hands out has to be a name cleanup knows. A leftover one is not ignored — the
# teardown rmdir dies on it — so a run that used the plan file could never finish.
DELIVERY_PREPARED_PLAN="$(runctl prepare run-1 plan)"
printf '[]\n' > "$DELIVERY_PREPARED_PLAN"
SHA="$(git -C "$REPO" rev-parse HEAD)"
WRONG_SHA="$(git -C "$REPO" rev-parse main)"

GH_STUB="$(mktemp -d)" || exit 1
cat > "$GH_STUB/gh" <<'GH_STUB_SCRIPT'
#!/usr/bin/env bash
case "$1:$2" in
  pr:view) printf '{"number":42,"state":"%s","headRefOid":"%s","baseRefName":"main","mergeCommit":{"oid":"merge-sha"}}\n' "${GH_TEST_PR_STATE:-OPEN}" "$GH_TEST_SHA" ;;
  pr:checks)
    # Real `gh pr checks` exits 1 and reports on stderr when the branch requires nothing; it never
    # returns an empty array. A stub that returns [] tests a CLI that does not exist.
    if [ "$GH_TEST_CHECKS" = "none" ]; then
      echo "no checks reported on the 'task' branch" >&2
      exit 1
    fi
    printf '%s\n' "$GH_TEST_CHECKS"
    ;;
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
export GH_TEST_CHECKS='none'
# No required checks is a repository configuration answer, not a failed check. Asserting
# only rc=1 here passed before that distinction existed, so the message is the assertion.
OUT="$(evidence "no required checks" ci run-1 record success "$SHA" --pr 42 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'no required checks configured on GitHub'; } \
  && pass "absent-required-checks-names-the-configuration-gap" \
  || fail "absent-required-checks-names-the-configuration-gap" "rc=$rc out=$OUT"
export GH_TEST_CHECKS='[{"bucket":"fail","name":"test","state":"FAILURE"}]'
OUT="$(evidence "red required check" ci run-1 record success "$SHA" --pr 42 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'missing, pending, skipped, cancelled, or failed'; } \
  && pass "red-required-check-is-reported-as-a-check-failure" \
  || fail "red-required-check-is-reported-as-a-check-failure" "rc=$rc out=$OUT"
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
[ ! -e "$DELIVERY_PREPARED" ] && [ ! -d "$DELIVERY_PREPARED_DIR" ] \
  && pass "finish-removes-prepared-files" || fail "finish-removes-prepared-files"
rm -rf "$GH_STUB"
rm -rf "$REPO"

# --- canonical task graph -------------------------------------------------------------------------
# The graph is durable state or it is decoration. Every case below asserts a specific message or a
# specific state effect rather than "exited non-zero": before `plan` exists every one of these
# commands exits non-zero anyway, so a bare exit-code assertion would pass while proving nothing.


# The canonical valid graph: two implementation slices with a real edge between them, then one task
# per remaining lifecycle phase. Callers break one thing at a time with jq.
plan_json() {
  cat <<'PLANJSON'
[
  {"id":"auth-boundary","title":"Auth boundary","phase":"implementation",
   "delivers":"An unauthenticated call is rejected at the boundary",
   "owned_paths":["src/auth/"],"acceptance":["unauthenticated call is rejected"],
   "checks":["make test-auth"],"blocked_by":[]},
  {"id":"authenticated-api","title":"Authenticated API","phase":"implementation",
   "delivers":"An authenticated request succeeds end to end",
   "owned_paths":["src/api/"],"acceptance":["authenticated request returns 200"],
   "checks":["make test-api"],"blocked_by":["auth-boundary"]},
  {"id":"verify-tests","title":"Verify tests","phase":"testing",
   "delivers":"Targeted and full checks pass on the branch",
   "owned_paths":[],"acceptance":["full suite green"],"checks":["make test"],
   "blocked_by":["authenticated-api"]},
  {"id":"verify-acceptance","title":"Verify acceptance","phase":"acceptance",
   "delivers":"Every acceptance criterion is proven",
   "owned_paths":[],"acceptance":["all criteria proven"],"checks":["make accept"],
   "blocked_by":["verify-tests"]},
  {"id":"finalize-candidate","title":"Finalize candidate","phase":"candidate",
   "delivers":"A tested candidate commit exists",
   "owned_paths":[],"acceptance":["candidate recorded"],"checks":["git status --porcelain"],
   "blocked_by":["verify-acceptance"]},
  {"id":"review-candidate","title":"Review candidate","phase":"review",
   "delivers":"Every reviewer approved the exact candidate",
   "owned_paths":[],"acceptance":["three approvals on the candidate SHA"],"checks":["true"],
   "blocked_by":["finalize-candidate"]},
  {"id":"deliver-candidate","title":"Deliver candidate","phase":"delivery",
   "delivers":"The reviewed candidate is published with green CI",
   "owned_paths":[],"acceptance":["PR head equals the reviewed SHA"],"checks":["true"],
   "blocked_by":["review-candidate"]}
]
PLANJSON
}

# Writes a graph to a file and echoes its path. With a jq program, applies it first.
plan_file() {
  path="$REPO/plan-under-test.json"
  if [ "$#" -eq 0 ]; then plan_json > "$path"; else plan_json | jq "$1" > "$path"; fi
  printf '%s\n' "$path"
}

graph_repo() {
  make_repo && complete_readiness
  GRAPH_STATE="$REPO/$RUNS_REL/run-1.state.json"
}

# 1. A blocker that names nothing in the import is a broken graph, and the message has to name it —
#    "invalid plan" sends the author looking through every task.
graph_repo
OUT="$(runctl plan run-1 import "$(plan_file '(.[1].blocked_by) = ["nope"]')" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'nope'; } \
  && pass "unknown-blocker-rejected" || fail "unknown-blocker-rejected" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 2. A task blocked by itself can never start; accepting it would produce a run that deadlocks with
#    no cycle to report.
graph_repo
OUT="$(runctl plan run-1 import "$(plan_file '(.[0].blocked_by) = ["auth-boundary"]')" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'self'; } \
  && pass "self-reference-rejected" || fail "self-reference-rejected" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 3. A cycle names every id in it: the author has to see the loop, not one arbitrary member.
graph_repo
OUT="$(runctl plan run-1 import \
  "$(plan_file '(.[0].blocked_by) = ["authenticated-api"]')" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'cycle' \
  && printf '%s' "$OUT" | grep -q 'auth-boundary' \
  && printf '%s' "$OUT" | grep -q 'authenticated-api'; } \
  && pass "cycle-rejected" || fail "cycle-rejected" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 4. A duplicate blocker is a typo that silently changes nothing; refusing it keeps the graph the
#    author can read the same as the graph runctl enforces.
graph_repo
OUT="$(runctl plan run-1 import \
  "$(plan_file '(.[1].blocked_by) = ["auth-boundary","auth-boundary"]')" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'duplicate'; } \
  && pass "duplicate-blocker-rejected" || fail "duplicate-blocker-rejected" "rc=$rc out=$OUT"
rm -rf "$REPO"

# Helper: an imported graph carries no visible ids, and `visible-plan-before-mutation` requires one
# before a task may start. Binding every task isolates the frontier cases from the binding case.
bind_graph_ui() {
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    runctl task run-1 bind-ui "$tid" "ui-$tid" >/dev/null 2>&1
  done <<EOF
$(jq -r '.tasks[].id' "$GRAPH_STATE")
EOF
}

enter_graph_implementation() {
  runctl plan run-1 import "$1" >/dev/null 2>&1
  bind_graph_ui
  runctl phase run-1 complete planning >/dev/null 2>&1
  runctl phase run-1 enter implementation >/dev/null 2>&1
}

# 5. The whole point: an open blocker stops the task from starting even when everything else about it
#    is in order — bound to a visible task, right phase, still pending.
graph_repo
enter_graph_implementation "$(plan_file)"
OUT="$(runctl task run-1 start authenticated-api 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'blocked by auth-boundary'; } \
  && pass "blocked-task-cannot-start" || fail "blocked-task-cannot-start" "rc=$rc out=$OUT"

# 6. The frontier is exactly what may start now — not everything unfinished.
FRONTIER="$(runctl plan run-1 frontier 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
[ "$FRONTIER" = "auth-boundary" ] \
  && pass "frontier-lists-only-startable-tasks" \
  || fail "frontier-lists-only-startable-tasks" "got '$FRONTIER'"

# 7. A completed task is not startable again; re-running it would overwrite recorded evidence.
runctl task run-1 start auth-boundary >/dev/null 2>&1
evidence "boundary implemented" task run-1 complete auth-boundary >/dev/null 2>&1
OUT="$(runctl task run-1 start auth-boundary 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  && pass "completed-task-cannot-restart" || fail "completed-task-cannot-restart" "rc=$rc out=$OUT"

# 8. Once the blocker completes, the task that was refused above starts. Without this the frontier
#    check could be refusing everything and case 5 would still pass.
runctl task run-1 start authenticated-api >/dev/null 2>&1
[ "$(jq -r '.tasks[] | select(.id=="authenticated-api") | .status' "$GRAPH_STATE")" = "in_progress" ] \
  && pass "frontier-releases-a-task-when-its-blocker-completes" \
  || fail "frontier-releases-a-task-when-its-blocker-completes"

# 8b. An imported graph carries no visible ids, and `visible-plan-before-mutation` forbids starting
#     work the user cannot see. Planning is where that is enforced for a planned task — an unbound
#     task in implementation only arises from `phase fix`, which
#     `fix-task-cannot-start-before-visible-binding` above already covers.
graph_repo
runctl plan run-1 import "$(plan_file)" >/dev/null 2>&1
OUT="$(runctl phase run-1 complete planning 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'bound to a visible Claude task'; } \
  && pass "planning-cannot-complete-with-unbound-tasks" \
  || fail "planning-cannot-complete-with-unbound-tasks" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 9. Recovery path: rebind a task whose visible id was lost, and it keeps working.
graph_repo
enter_graph_implementation "$(plan_file)"
runctl task run-1 bind-ui auth-boundary ui-stale >/dev/null 2>&1
runctl task run-1 bind-ui auth-boundary ui-fresh >/dev/null 2>&1
{ [ "$(jq -r '.tasks[] | select(.id=="auth-boundary") | .ui_task_id' "$GRAPH_STATE")" = "ui-fresh" ] \
  && runctl task run-1 start auth-boundary >/dev/null 2>&1; } \
  && pass "lost-ui-task-can-be-rebound" || fail "lost-ui-task-can-be-rebound"
rm -rf "$REPO"

# 10. Resume re-imports the same graph. That must be a no-op, not a second copy of every task.
graph_repo
PLAN="$(plan_file)"
runctl plan run-1 import "$PLAN" >/dev/null 2>&1
BEFORE="$(jq -r '.tasks | length' "$GRAPH_STATE")"
OUT="$(runctl plan run-1 import "$PLAN" 2>&1)"; rc=$?
AFTER="$(jq -r '.tasks | length' "$GRAPH_STATE")"
{ [ "$rc" -eq 0 ] && [ "$BEFORE" = "$AFTER" ] && [ "$AFTER" = "7" ] \
  && printf '%s' "$OUT" | grep -q 'PLAN UNCHANGED'; } \
  && pass "resume-does-not-duplicate-tasks" \
  || fail "resume-does-not-duplicate-tasks" "rc=$rc before=$BEFORE after=$AFTER out=$OUT"
rm -rf "$REPO"

# 11. Two tasks may both be startable and still not be parallel work: overlapping owned paths mean
#     one worktree writing over another.
graph_repo
runctl plan run-1 import \
  "$(plan_file '(.[1].blocked_by) = [] | (.[1].owned_paths) = ["src/auth/"]')" >/dev/null 2>&1
runctl phase run-1 complete planning >/dev/null 2>&1
runctl phase run-1 enter implementation >/dev/null 2>&1
BOTH="$(runctl plan run-1 frontier 2>/dev/null | grep -c .)"
ONE="$(runctl plan run-1 frontier --parallel 2>/dev/null | grep -c .)"
{ [ "$BOTH" = "2" ] && [ "$ONE" = "1" ]; } \
  && pass "overlapping-owned-paths-not-in-one-frontier-batch" \
  || fail "overlapping-owned-paths-not-in-one-frontier-batch" "frontier=$BOTH parallel=$ONE"
rm -rf "$REPO"

# 11b. The duplicate-id message has to name the id that repeats. The duplicated id is deliberately
#      NOT the first in the graph: with `auth-boundary` duplicated, a message that printed the first
#      id would read identically and the test could not tell the two apart.
graph_repo
OUT="$(runctl plan run-1 import "$(plan_file '(.[3].id) = "authenticated-api"')" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'duplicate task id authenticated-api'; } \
  && pass "duplicate-id-message-names-the-repeated-id" \
  || fail "duplicate-id-message-names-the-repeated-id" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 11c. `prepare` owns the plan file too: the model needs a path the mutation fence permits, and
#      cleanup has to know that name or the run's own scratch file blocks its teardown.
graph_repo
PREPARED_PLAN="$(runctl prepare run-1 plan)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$PREPARED_PLAN" ] && [ "$(basename "$PREPARED_PLAN")" = "plan" ]; } \
  && pass "prepare-owns-the-plan-file" || fail "prepare-owns-the-plan-file" "rc=$rc path=$PREPARED_PLAN"
plan_json > "$PREPARED_PLAN"
runctl plan run-1 import "$PREPARED_PLAN" >/dev/null 2>&1 \
  && pass "a-prepared-plan-file-imports" || fail "a-prepared-plan-file-imports"

# 11d. Publishing is recorded once, refuses an empty plan, and does not restamp on a second call.
OUT="$(runctl plan run-1 publish 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'PLAN PUBLISHED' \
  && jq -e 'any(.gates[]; .id == "plan-published" and .status == "pass")' "$GRAPH_STATE" >/dev/null; } \
  && pass "publish-records-the-plan-gate" || fail "publish-records-the-plan-gate" "rc=$rc out=$OUT"
FIRST_STAMP="$(jq -r '.gates[] | select(.id=="plan-published") | .recorded_at' "$GRAPH_STATE")"
OUT="$(runctl plan run-1 publish 2>&1)"
{ printf '%s' "$OUT" | grep -q 'ALREADY PUBLISHED' \
  && [ "$(jq -r '.gates[] | select(.id=="plan-published") | .recorded_at' "$GRAPH_STATE")" = "$FIRST_STAMP" ]; } \
  && pass "publish-keeps-the-first-publication" || fail "publish-keeps-the-first-publication" "out=$OUT"
# The gate says "this graph was published". Importing a different graph makes that false, so the
# record goes with it rather than dating a plan the run no longer holds.
runctl plan run-1 import "$(plan_file '(.[1].delivers) = "a different outcome"')" >/dev/null 2>&1
jq -e 'all(.gates[]; .id != "plan-published")' "$GRAPH_STATE" >/dev/null \
  && pass "a-changed-import-clears-the-published-record" \
  || fail "a-changed-import-clears-the-published-record"
# Nothing else may write that gate; one writer is what makes the record mean anything.
runctl plan run-1 publish >/dev/null 2>&1
OUT="$(evidence "hand-written" gate run-1 record plan-published pass 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'cannot be recorded by hand'; } \
  && pass "plan-published-has-one-writer" || fail "plan-published-has-one-writer" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 11e. An empty plan is not publishable: a published record with nothing behind it is the exact claim
#      the gate exists to prevent.
graph_repo
OUT="$(runctl plan run-1 publish 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'empty plan'; } \
  && pass "publish-refuses-an-empty-plan" || fail "publish-refuses-an-empty-plan" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 11f. The graph rules are a durable invariant, not just an import gate. `plan import` refuses a
#      dangling blocker, but a state file that acquired one some other way must be refused too —
#      otherwise the persisted graph is weaker than the door it came through, and a task would refuse
#      to start for a reason nothing reports.
graph_repo
runctl plan run-1 import "$(plan_file)" >/dev/null 2>&1
jq '(.tasks[] | select(.id=="verify-tests") | .blocked_by) = ["nope"]' "$GRAPH_STATE" \
  > "$GRAPH_STATE.hand" && mv "$GRAPH_STATE.hand" "$GRAPH_STATE"
OUT="$(runctl plan run-1 frontier 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -q 'invalid or foreign state'; } \
  && pass "a-dangling-blocker-on-disk-is-refused" \
  || fail "a-dangling-blocker-on-disk-is-refused" "rc=$rc out=$OUT"
rm -rf "$REPO"

# 12. A rejected import leaves the previous graph exactly as it was. A half-written plan would be a
#     state whose frontier answers from tasks whose blockers do not exist.
graph_repo
runctl plan run-1 import "$(plan_file)" >/dev/null 2>&1
SNAP_BEFORE="$(jq -S -c '.tasks' "$GRAPH_STATE")"
runctl plan run-1 import "$(plan_file '(.[3].blocked_by) = ["nope"]')" >/dev/null 2>&1
SNAP_AFTER="$(jq -S -c '.tasks' "$GRAPH_STATE")"
# The snapshot has to be the imported graph, not an empty list: two failed imports also leave
# `.tasks` identical, and comparing nothing to nothing proves nothing.
{ [ "$SNAP_BEFORE" = "$SNAP_AFTER" ] \
  && [ "$(printf '%s' "$SNAP_BEFORE" | jq -r 'length')" = "7" ]; } \
  && pass "partial-import-is-not-representable" \
  || fail "partial-import-is-not-representable" "len=$(printf '%s' "$SNAP_BEFORE" | jq -r 'length')"
rm -rf "$REPO"

exit "$fails"
