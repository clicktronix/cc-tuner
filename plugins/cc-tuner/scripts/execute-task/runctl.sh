#!/usr/bin/env bash
# Authoritative state machine for /cc-tuner:run.
# Human-readable progress belongs in journal.sh; decisions and gates belong here.
set -u
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
execute_task_init_root

LOCK_DIRS=""

usage() {
  cat >&2 <<'EOF'
usage: runctl.sh init <run-id> [--mode interactive|auto] [--spec <path>]
       runctl.sh status <run-id>
       runctl.sh spec <run-id> relocate <repo-relative-new-path>
       runctl.sh phase <run-id> enter <phase>
       runctl.sh phase <run-id> complete [<phase>]
       runctl.sh phase <run-id> fix < reason.txt
       runctl.sh task <run-id> add <task-id> <phase> [--ui-task-id <id>] < description.txt
       runctl.sh task <run-id> start|complete|block <task-id> [< evidence.txt]
       runctl.sh task <run-id> bind-ui <task-id> <ui-task-id>
       runctl.sh gate <run-id> record <gate-id> pass|fail [--sha <commit>] < evidence.txt
       runctl.sh candidate <run-id> record <commit>
       runctl.sh review <run-id> record <reviewer> APPROVE|REQUEST_CHANGES <commit> < evidence.txt
       runctl.sh ci <run-id> record success|failure <commit> [--pr <number>] < evidence.txt
       runctl.sh can-advance|can-merge <run-id>
       runctl.sh block <run-id> < reason.txt
       runctl.sh resume <run-id>
       runctl.sh finish <run-id> < post-merge-evidence.txt
EOF
  exit 1
}

cleanup_lock() {
  local lock_dir
  [ -n "$LOCK_DIRS" ] || return
  while IFS= read -r lock_dir; do
    [ -n "$lock_dir" ] || continue
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
  done <<EOF
$LOCK_DIRS
EOF
}
trap cleanup_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

phase_index() {
  case "$1" in
    readiness) echo 0 ;;
    planning) echo 1 ;;
    implementation) echo 2 ;;
    testing) echo 3 ;;
    acceptance) echo 4 ;;
    candidate) echo 5 ;;
    review) echo 6 ;;
    delivery) echo 7 ;;
    *) return 1 ;;
  esac
}

validate_phase() {
  phase_index "$1" >/dev/null 2>&1 || execute_task_die "unknown phase '$1'"
}

read_evidence() {
  local label="$1"
  [ ! -t 0 ] || execute_task_die "$label must be piped on stdin"
  EVIDENCE="$(cat)" || execute_task_die "cannot read $label from stdin"
  [ -n "$EVIDENCE" ] || execute_task_die "$label is required on stdin"
}

resolve_commit() {
  local value="$1" resolved
  [ -n "$value" ] || execute_task_die "commit is required"
  case "$value" in -*) execute_task_die "commit must not start with '-'" ;; esac
  resolved="$(git rev-parse --verify "$value^{commit}" 2>/dev/null)" \
    || execute_task_die "cannot resolve commit '$value'"
  printf '%s\n' "$resolved"
}

validate_repo_relative_path() {
  local label="$1" value="$2"
  [ -n "$value" ] || execute_task_die "$label is required"
  case "$value" in
    /*|../*|*/../*|*/..|.|'') execute_task_die "$label must be a repository-relative path" ;;
  esac
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    execute_task_die "$label must not contain control characters"
  fi
}

validate_review_spec_path() {
  local value="$1"
  validate_repo_relative_path "spec" "$value"
  case "$value" in
    *[!a-zA-Z0-9_./-]*)
      execute_task_die "spec path must use [a-zA-Z0-9_./-] for the required-review marker"
      ;;
  esac
}

assert_repo_regular_tracked() {
  local label="$1" value="$2" git_root parent parent_real full
  validate_repo_relative_path "$label" "$value"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || execute_task_die "cannot resolve Git root"
  git_root="$(CDPATH='' cd -- "$git_root" 2>/dev/null && pwd -P)" \
    || execute_task_die "cannot canonicalize Git root"
  parent="$git_root/$(dirname -- "$value")"
  parent_real="$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P)" \
    || execute_task_die "$label parent does not exist: $value"
  case "$parent_real" in "$git_root"|"$git_root"/*) ;; *) execute_task_die "$label escapes Git root" ;; esac
  full="$git_root/$value"
  [ ! -L "$full" ] || execute_task_die "$label must not be a symlink: $value"
  [ -f "$full" ] || execute_task_die "$label must be a regular file: $value"
  git -C "$git_root" ls-files --error-unmatch -- "$value" >/dev/null 2>&1 \
    || execute_task_die "$label must be tracked in the Git index: $value"
}

validate_codex_approval_evidence() {
  local marker marker_count word1 word2 thread_field head_field tree_field fp_field
  local base_field spec_field extra fingerprint candidate_tree base_sha spec_path
  marker_count="$(printf '%s\n' "$EVIDENCE" | grep -c '^CC_CODEX_REQUIRED_REVIEW APPROVE ' || true)"
  [ "$marker_count" -eq 1 ] \
    || execute_task_die "Codex APPROVE evidence must contain exactly one required-review marker"
  marker="$(printf '%s\n' "$EVIDENCE" | grep '^CC_CODEX_REQUIRED_REVIEW APPROVE ')"
  IFS=' ' read -r word1 word2 thread_field head_field tree_field fp_field base_field spec_field extra <<EOF
$marker
EOF
  candidate_tree="$(jq -r '.candidate.tree_sha // empty' "$STATE")"
  base_sha="$(jq -r '.base_sha' "$STATE")"
  spec_path="$(jq -r '.spec // empty' "$STATE")"
  fingerprint="${fp_field#fingerprint=}"
  [ "$word1" = "CC_CODEX_REQUIRED_REVIEW" ] \
    && [ "$word2" = "APPROVE" ] \
    && [ "$thread_field" = "thread=review-$EXECUTE_TASK_RUN_ID" ] \
    && [ "$head_field" = "head=$SHA" ] \
    && [ "$tree_field" = "tree=$candidate_tree" ] \
    && [ "$base_field" = "base_sha=$base_sha" ] \
    && [ -n "$spec_path" ] && [ "$spec_field" = "spec_path=$spec_path" ] \
    && [ -z "$extra" ] \
    || execute_task_die "Codex required-review marker does not match this run and candidate"
  case "$fingerprint" in
    *[!0-9a-f]*|'') execute_task_die "Codex required-review marker has an invalid fingerprint" ;;
  esac
  [ "${#fingerprint}" -eq 64 ] \
    || execute_task_die "Codex required-review marker has an invalid fingerprint"
}

state_paths() {
  execute_task_validate_run_id "$1"
  execute_task_prepare_state
  META="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.meta"
  JOURNAL="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.md"
  STATE="$EXECUTE_TASK_RUNS_DIR/$EXECUTE_TASK_RUN_ID.state.json"
  execute_task_assert_regular_or_missing "$STATE"
  execute_task_assert_run_owner "$META"
}

assert_no_other_active_run() {
  local other current_branch other_run
  current_branch="$(execute_task_current_branch)"
  for other in "$EXECUTE_TASK_RUNS_DIR"/*.state.json; do
    [ -f "$other" ] && [ ! -L "$other" ] && [ "$other" != "$STATE" ] || continue
    if jq -e --arg branch "$current_branch" \
        '.schema_version == 1 and .branch == $branch and .status == "active"' \
        "$other" >/dev/null 2>&1; then
      other_run="$(jq -r '.run_id // "unknown"' "$other" 2>/dev/null)"
      execute_task_die "branch '$current_branch' already has active run '$other_run'"
    fi
  done
}

validate_state_shape() {
  local checked_state stored_branch stored_target stored_base
  checked_state="${1:-$STATE}"
  stored_branch="$(execute_task_read_meta branch "$META")"
  stored_target="$(execute_task_read_meta target_ref "$META")"
  stored_base="$(execute_task_read_meta base_sha "$META")"
  jq -e \
    --arg run "$EXECUTE_TASK_RUN_ID" \
    --arg branch "$stored_branch" \
    --arg target "$stored_target" \
    --arg base "$stored_base" '
      def id: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,119}$");
      def sha: type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$");
      def nullable_sha: . == null or sha;
      keys == ["base_sha", "blocked_reason", "branch", "candidate", "ci", "completed_at",
        "completed_phases", "completion_evidence", "created_at", "fix_round", "gates", "invalidations",
        "mode", "phase", "required_reviewers",
        "review_history", "reviews", "run_id", "schema_version", "spec", "status", "target_ref",
        "target_sha", "tasks", "updated_at"] and
      .schema_version == 1 and
      .run_id == $run and .branch == $branch and .target_ref == $target and .base_sha == $base and
      (.run_id | id) and (.target_sha | sha) and
      (.spec == null or (.spec | type == "string" and test("^[a-zA-Z0-9_./-]+$"))) and
      (.mode == "interactive" or .mode == "auto") and
      (.status == "active" or .status == "blocked" or .status == "completed") and
      (if .status == "blocked" then (.blocked_reason | type == "string" and length > 0)
       else .blocked_reason == null end) and
      (if .status == "completed" then
        .phase == {name: "done", status: "completed"} and
        (.completion_evidence | type == "string" and length > 0) and
        (.completed_at | type == "string" and length > 0)
       else .phase.name != "done" and .completion_evidence == null and .completed_at == null end) and
      (.phase | keys == ["name", "status"]) and
      (.phase.name as $phase | ["readiness", "planning", "implementation", "testing", "acceptance",
        "candidate", "review", "delivery", "done"] | index($phase) != null) and
      (.phase.status == "in_progress" or .phase.status == "completed") and
      (.completed_phases | type == "array") and (.tasks | type == "array") and
      ([.tasks[].id] | unique | length) == (.tasks | length) and
      ([.tasks[].ui_task_id | select(. != null)] | unique | length) ==
        ([.tasks[].ui_task_id | select(. != null)] | length) and
      (.gates | type == "array") and
      ([.gates[].id] | unique | length) == (.gates | length) and
      .required_reviewers == ["deep-review", "mattpocock", "codex"] and
      (.reviews | type == "array" and length == 3) and
      ([.reviews[].reviewer] | sort) == ([.required_reviewers[]] | sort) and
      (.review_history | type == "array") and
      (.invalidations | type == "array") and
      (.fix_round | type == "number" and . >= 0 and floor == .) and
      all(.tasks[];
        keys == ["description", "evidence", "id", "phase", "status", "ui_task_id", "updated_at"] and
        (.id | id) and (.description | type == "string" and length > 0) and
        (.phase as $task_phase | ["readiness", "planning", "implementation", "testing", "acceptance",
          "candidate", "review", "delivery"] | index($task_phase) != null) and
        (.status as $task_status | ["pending", "in_progress", "blocked", "completed"] |
          index($task_status) != null)) and
      all(.gates[];
        keys == ["evidence", "id", "recorded_at", "sha", "status", "tree_sha"] and
        (.id | id) and (.sha | nullable_sha) and (.tree_sha | nullable_sha) and
        (.status == "pass" or .status == "fail") and (.evidence | type == "string" and length > 0)) and
      all(.reviews[], .review_history[];
        keys == ["evidence", "recorded_at", "reviewer", "sha", "verdict"] and
        (.reviewer | id) and (.sha | nullable_sha) and
        (.verdict as $verdict | ["PENDING", "APPROVE", "REQUEST_CHANGES"] | index($verdict) != null)) and
      (.candidate | keys == ["recorded_at", "sha", "tree_sha"]) and
      (.candidate.sha | nullable_sha) and (.candidate.tree_sha | nullable_sha) and
      ((.candidate.sha == null and .candidate.tree_sha == null and .candidate.recorded_at == null) or
        (.candidate.sha != null and .candidate.tree_sha != null and
          (.candidate.recorded_at | type == "string" and length > 0))) and
      (.ci | keys == ["evidence", "pr_number", "recorded_at", "sha", "status"]) and
      (.ci.sha | nullable_sha) and
      (.ci.pr_number == null or
        (.ci.pr_number | type == "number" and . > 0 and floor == .)) and
      (.ci.status as $ci_status | ["pending", "success", "failure"] | index($ci_status) != null) and
      (if .ci.status == "pending" then
        .ci.sha == null and .ci.pr_number == null and .ci.evidence == null and .ci.recorded_at == null
       else .ci.sha != null and (.ci.evidence | type == "string" and length > 0) and
        (.ci.recorded_at | type == "string" and length > 0) and
        (if .ci.status == "success" then .ci.pr_number != null else .ci.pr_number == null end) end)
    ' "$checked_state" >/dev/null 2>&1
}

load_state() {
  [ -f "$STATE" ] || execute_task_die "state not found for run '$EXECUTE_TASK_RUN_ID'; run 'runctl.sh init $EXECUTE_TASK_RUN_ID'"
  validate_state_shape \
    || execute_task_die "invalid or foreign state file for run '$EXECUTE_TASK_RUN_ID'"
}

acquire_lock() {
  local requested_lock="$1" label="$2" owner
  [ ! -L "$requested_lock" ] || execute_task_die "refusing symlinked $label lock"
  if mkdir "$requested_lock" 2>/dev/null; then
    LOCK_DIRS="${LOCK_DIRS}${LOCK_DIRS:+
}$requested_lock"
    printf '%s\n' "$$" > "$requested_lock/pid" 2>/dev/null \
      || execute_task_die "cannot record $label lock owner"
    return
  fi
  [ ! -L "$requested_lock" ] && [ -d "$requested_lock" ] \
    || execute_task_die "invalid $label lock"
  [ ! -L "$requested_lock/pid" ] \
    || execute_task_die "refusing symlinked $label lock owner"
  owner="$(cat "$requested_lock/pid" 2>/dev/null || true)"
  case "$owner" in
    ''|*[!0-9]*) ;;
    *)
      if ! kill -0 "$owner" 2>/dev/null; then
        rm -f "$requested_lock/pid" 2>/dev/null || true
        rmdir "$requested_lock" 2>/dev/null || true
        if mkdir "$requested_lock" 2>/dev/null; then
          LOCK_DIRS="${LOCK_DIRS}${LOCK_DIRS:+
}$requested_lock"
          printf '%s\n' "$$" > "$requested_lock/pid" 2>/dev/null \
            || execute_task_die "cannot record $label lock owner"
          return
        fi
      fi
      ;;
  esac
  execute_task_die "$label is held by another process"
}

lock_state() {
  acquire_lock "$STATE.lock" "state for run '$EXECUTE_TASK_RUN_ID'"
}

lock_initialization() {
  acquire_lock "$EXECUTE_TASK_RUNS_DIR/.init.lock" "run initialization"
}

update_state() {
  local filter="$1" now temporary
  shift
  now="$(date -u +%FT%TZ)"
  temporary="$(mktemp "$STATE.tmp.XXXXXX")" || execute_task_die "cannot create state temp file"
  if ! jq "$@" --arg updated_at "$now" \
      "($filter) | .updated_at = \$updated_at" "$STATE" > "$temporary"; then
    rm -f "$temporary"
    execute_task_die "cannot update state for run '$EXECUTE_TASK_RUN_ID'"
  fi
  if ! validate_state_shape "$temporary"; then
    rm -f "$temporary"
    execute_task_die "refusing invalid state update for run '$EXECUTE_TASK_RUN_ID'"
  fi
  chmod 600 "$temporary" 2>/dev/null || true
  mv "$temporary" "$STATE" || {
    rm -f "$temporary"
    execute_task_die "cannot install state for run '$EXECUTE_TASK_RUN_ID'"
  }
}

assert_active() {
  local status
  status="$(jq -r '.status' "$STATE")"
  [ "$status" = "active" ] || execute_task_die "run '$EXECUTE_TASK_RUN_ID' is $status"
}

assert_current_candidate() {
  local candidate tree current current_tree
  candidate="$(jq -r '.candidate.sha // empty' "$STATE")"
  tree="$(jq -r '.candidate.tree_sha // empty' "$STATE")"
  [ -n "$candidate" ] || execute_task_die "candidate commit is not recorded"
  execute_task_assert_clean_tree
  current="$(execute_task_current_sha)"
  current_tree="$(execute_task_current_tree_sha)"
  [ "$current" = "$candidate" ] \
    || execute_task_die "candidate is stale: recorded $candidate, current HEAD $current"
  [ "$current_tree" = "$tree" ] \
    || execute_task_die "candidate tree is stale: recorded $tree, current tree $current_tree"
}

assert_phase_tasks_complete() {
  local phase="$1"
  jq -e --arg phase "$phase" '
    all(.tasks[] | select(.phase == $phase); .status == "completed")
  ' "$STATE" >/dev/null 2>&1 \
    || execute_task_die "phase '$phase' has unfinished tasks"
}

assert_gate_passed() {
  local gate="$1" sha="${2:-}"
  if [ -n "$sha" ]; then
    jq -e --arg gate "$gate" --arg sha "$sha" '
      any(.gates[]; .id == $gate and .status == "pass" and .sha == $sha)
    ' "$STATE" >/dev/null 2>&1 \
      || execute_task_die "gate '$gate' has no passing evidence for candidate $sha"
  else
    jq -e --arg gate "$gate" 'any(.gates[]; .id == $gate and .status == "pass")' \
      "$STATE" >/dev/null 2>&1 \
      || execute_task_die "gate '$gate' has no passing evidence"
  fi
}

assert_reviews_approved() {
  local candidate
  candidate="$(jq -r '.candidate.sha // empty' "$STATE")"
  [ -n "$candidate" ] || execute_task_die "candidate commit is not recorded"
  jq -e --arg sha "$candidate" '
    ([.required_reviewers[] as $required |
      any(.reviews[]; .reviewer == $required and .verdict == "APPROVE" and .sha == $sha)] | all)
  ' "$STATE" >/dev/null 2>&1 \
    || execute_task_die "all required reviewers must APPROVE candidate $candidate"
}

verify_hosted_ci() {
  local candidate pr_number pr_json checks_json final_pr_json
  candidate="${1:-$(jq -r '.candidate.sha // empty' "$STATE")}"
  pr_number="${2:-$(jq -r '.ci.pr_number // empty' "$STATE")}"
  [ -n "$candidate" ] && [ -n "$pr_number" ] \
    || execute_task_die "successful CI is not bound to a candidate PR"
  command -v gh >/dev/null 2>&1 || execute_task_die "gh is required to verify hosted CI"
  pr_json="$(gh pr view "$pr_number" --json number,state,headRefOid 2>/dev/null)" \
    || execute_task_die "cannot read PR #$pr_number for CI verification"
  jq -e --arg sha "$candidate" --argjson number "$pr_number" \
    '.number == $number and .state == "OPEN" and .headRefOid == $sha' \
    >/dev/null 2>&1 <<EOF \
    || execute_task_die "PR #$pr_number is not open at candidate $candidate"
$pr_json
EOF
  checks_json="$(gh pr checks "$pr_number" --required --json bucket,name,state 2>/dev/null)" \
    || execute_task_die "required checks are not green for PR #$pr_number"
  jq -e 'length > 0 and all(.[]; .bucket == "pass")' >/dev/null 2>&1 <<EOF \
    || execute_task_die "PR #$pr_number has missing, pending, skipped, cancelled, or failed required checks"
$checks_json
EOF
  final_pr_json="$(gh pr view "$pr_number" --json number,state,headRefOid 2>/dev/null)" \
    || execute_task_die "cannot re-read PR #$pr_number after CI verification"
  jq -e --arg sha "$candidate" --argjson number "$pr_number" \
    '.number == $number and .state == "OPEN" and .headRefOid == $sha' \
    >/dev/null 2>&1 <<EOF \
    || execute_task_die "PR #$pr_number moved while required checks were verified"
$final_pr_json
EOF
}

verify_merged_pr() {
  local candidate pr_number target pr_json
  candidate="$(jq -r '.candidate.sha // empty' "$STATE")"
  pr_number="$(jq -r '.ci.pr_number // empty' "$STATE")"
  target="$(jq -r '.target_ref' "$STATE")"
  [ -n "$candidate" ] && [ -n "$pr_number" ] \
    || execute_task_die "completed delivery is not bound to a candidate PR"
  command -v gh >/dev/null 2>&1 || execute_task_die "gh is required to verify the merged PR"
  pr_json="$(gh pr view "$pr_number" --json number,state,headRefOid,baseRefName,mergeCommit 2>/dev/null)" \
    || execute_task_die "cannot read merged PR #$pr_number"
  jq -e --arg sha "$candidate" --arg base "$target" --argjson number "$pr_number" '
    .number == $number and .state == "MERGED" and .headRefOid == $sha and
    .baseRefName == $base and (.mergeCommit.oid | type == "string" and length > 0)
  ' >/dev/null 2>&1 <<EOF \
    || execute_task_die "PR #$pr_number is not a merged delivery of candidate $candidate into $target"
$pr_json
EOF
}

validate_delivery_state() {
  local candidate
  assert_current_candidate
  candidate="$(jq -r '.candidate.sha' "$STATE")"
  assert_reviews_approved
  assert_gate_passed dod "$candidate"
  jq -e --arg sha "$candidate" '.ci.status == "success" and .ci.sha == $sha' \
    "$STATE" >/dev/null 2>&1 \
    || execute_task_die "CI must succeed on candidate $candidate"
  jq -e 'all(.tasks[]; .status == "completed")' "$STATE" >/dev/null 2>&1 \
    || execute_task_die "all run tasks must be completed before delivery"
}

validate_phase_completion() {
  local phase="$1" candidate
  assert_phase_tasks_complete "$phase"
  case "$phase" in
    readiness) assert_gate_passed dor ;;
    planning)
      jq -e 'any(.tasks[]; .phase == "implementation")' "$STATE" >/dev/null 2>&1 \
        || execute_task_die "planning must create at least one implementation task"
      ;;
    implementation)
      jq -e 'any(.tasks[]; .phase == "implementation")' "$STATE" >/dev/null 2>&1 \
        || execute_task_die "implementation has no tasks"
      ;;
    testing) assert_gate_passed testing ;;
    acceptance) assert_gate_passed acceptance ;;
    candidate) assert_current_candidate ;;
    review)
      assert_current_candidate
      assert_reviews_approved
      ;;
    delivery)
      validate_delivery_state
      verify_hosted_ci
      ;;
  esac
}

SUBCOMMAND="${1:-}"
[ -n "$SUBCOMMAND" ] || usage

case "$SUBCOMMAND" in
  init)
    RUN_ID="${2:-}"
    shift 2 2>/dev/null || usage
    MODE="interactive"
    MODE_SET=0
    SPEC=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --mode)
          [ "$#" -ge 2 ] || execute_task_die "--mode requires a value"
          MODE="$2"; MODE_SET=1; shift
          ;;
        --spec)
          [ "$#" -ge 2 ] || execute_task_die "--spec requires a value"
          SPEC="$2"; shift
          ;;
        *) execute_task_die "unknown init option '$1'" ;;
      esac
      shift
    done
    case "$MODE" in interactive|auto) ;; *) execute_task_die "mode must be interactive or auto" ;; esac
    state_paths "$RUN_ID"
    lock_state
    lock_initialization
    assert_no_other_active_run
    [ -f "$JOURNAL" ] || execute_task_die "journal not found for run '$EXECUTE_TASK_RUN_ID'; run preflight first"
    if [ -n "$SPEC" ]; then
      validate_review_spec_path "$SPEC"
      assert_repo_regular_tracked "spec" "$SPEC"
    fi
    if [ -f "$STATE" ]; then
      load_state
      current_mode="$(jq -r '.mode' "$STATE")"
      current_spec="$(jq -r '.spec // empty' "$STATE")"
      [ "$MODE_SET" -eq 1 ] || MODE="$current_mode"
      if [ "$current_mode" != "$MODE" ] || { [ -n "$SPEC" ] && [ "$current_spec" != "$SPEC" ]; }; then
        jq -e '.phase.name == "readiness" and .phase.status == "in_progress" and
          (.completed_phases | length) == 0 and (.tasks | length) == 0 and (.gates | length) == 0' \
          "$STATE" >/dev/null 2>&1 \
          || execute_task_die "mode/spec cannot change after run progress exists"
        load_state
        update_state '.mode = $mode | if ($spec | length) > 0 then .spec = $spec else . end' \
          --arg mode "$MODE" --arg spec "$SPEC"
      fi
      printf '%s\n' "$EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.state.json"
      exit 0
    fi
    NOW="$(date -u +%FT%TZ)"
    BRANCH="$(execute_task_read_meta branch "$META")"
    TARGET="$(execute_task_read_meta target_ref "$META")"
    BASE="$(execute_task_read_meta base_sha "$META")"
    TARGET_SHA="$(execute_task_read_meta target_sha "$META")"
    TEMP="$(mktemp "$STATE.tmp.XXXXXX")" || execute_task_die "cannot create state temp file"
    jq -n \
      --arg now "$NOW" --arg run "$EXECUTE_TASK_RUN_ID" --arg mode "$MODE" --arg spec "$SPEC" \
      --arg branch "$BRANCH" --arg target "$TARGET" --arg base "$BASE" --arg target_sha "$TARGET_SHA" \
      --argjson reviewers '["deep-review","mattpocock","codex"]' '
      {
        schema_version: 1,
        run_id: $run,
        mode: $mode,
        status: "active",
        blocked_reason: null,
        completion_evidence: null,
        completed_at: null,
        spec: (if ($spec | length) == 0 then null else $spec end),
        branch: $branch,
        target_ref: $target,
        target_sha: $target_sha,
        base_sha: $base,
        phase: {name: "readiness", status: "in_progress"},
        completed_phases: [],
        tasks: [],
        gates: [],
        required_reviewers: $reviewers,
        reviews: ($reviewers | map({reviewer: ., verdict: "PENDING", sha: null, evidence: null, recorded_at: null})),
        review_history: [],
        candidate: {sha: null, tree_sha: null, recorded_at: null},
        ci: {status: "pending", sha: null, pr_number: null, evidence: null, recorded_at: null},
        fix_round: 0,
        invalidations: [],
        created_at: $now,
        updated_at: $now
      }
    ' > "$TEMP" || { rm -f "$TEMP"; execute_task_die "cannot create run state"; }
    validate_state_shape "$TEMP" || { rm -f "$TEMP"; execute_task_die "refusing invalid initial state"; }
    chmod 600 "$TEMP" 2>/dev/null || true
    mv "$TEMP" "$STATE" || { rm -f "$TEMP"; execute_task_die "cannot install run state"; }
    printf '%s\n' "$EXECUTE_TASK_RUNS_REL/$EXECUTE_TASK_RUN_ID.state.json"
    ;;

  status)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; load_state
    jq . "$STATE"
    ;;

  spec)
    [ "$#" -eq 4 ] || usage
    [ "$3" = "relocate" ] || execute_task_die "unknown spec action '$3'"
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "implementation" ] \
      || execute_task_die "spec may be relocated only in implementation phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "spec path is immutable after implementation completes"
    OLD_SPEC="$(jq -r '.spec // empty' "$STATE")"
    NEW_SPEC="$4"
    [ -n "$OLD_SPEC" ] || execute_task_die "run has no spec path to relocate"
    validate_repo_relative_path "stored spec" "$OLD_SPEC"
    validate_review_spec_path "$NEW_SPEC"
    [ "$NEW_SPEC" != "$OLD_SPEC" ] || execute_task_die "new spec path must differ from the current path"
    assert_repo_regular_tracked "new spec" "$NEW_SPEC"
    GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || execute_task_die "cannot resolve Git root"
    [ ! -e "$GIT_ROOT/$OLD_SPEC" ] && [ ! -L "$GIT_ROOT/$OLD_SPEC" ] \
      || execute_task_die "old spec path still exists; relocate it instead of copying: $OLD_SPEC"
    if git -C "$GIT_ROOT" ls-files --error-unmatch -- "$OLD_SPEC" >/dev/null 2>&1; then
      execute_task_die "old spec path is still tracked; stage or commit the relocation first: $OLD_SPEC"
    fi
    update_state '.spec = $spec' --arg spec "$NEW_SPEC"
    ;;

  phase)
    [ "$#" -ge 3 ] || usage
    state_paths "$2"; lock_state; load_state; assert_active
    ACTION="$3"
    case "$ACTION" in
      enter)
        [ "$#" -eq 4 ] || usage
        NEXT="$4"; validate_phase "$NEXT"
        CURRENT="$(jq -r '.phase.name' "$STATE")"
        CURRENT_STATUS="$(jq -r '.phase.status' "$STATE")"
        [ "$CURRENT_STATUS" = "completed" ] \
          || execute_task_die "phase '$CURRENT' must be completed before entering '$NEXT'"
        CURRENT_INDEX="$(phase_index "$CURRENT")"; NEXT_INDEX="$(phase_index "$NEXT")"
        [ "$NEXT_INDEX" -eq $((CURRENT_INDEX + 1)) ] \
          || execute_task_die "illegal phase transition: $CURRENT -> $NEXT"
        update_state '.phase = {name: $next, status: "in_progress"}' --arg next "$NEXT"
        ;;
      complete)
        [ "$#" -le 4 ] || usage
        CURRENT="$(jq -r '.phase.name' "$STATE")"
        EXPECTED="${4:-$CURRENT}"
        [ "$CURRENT" = "$EXPECTED" ] \
          || execute_task_die "current phase is '$CURRENT', not '$EXPECTED'"
        [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
          || execute_task_die "phase '$CURRENT' is already completed"
        validate_phase_completion "$CURRENT"
        update_state '.phase.status = "completed" |
          .completed_phases += [$phase]' --arg phase "$CURRENT"
        ;;
      fix)
        [ "$#" -eq 3 ] || usage
        CURRENT="$(jq -r '.phase.name' "$STATE")"
        case "$CURRENT" in
          testing|acceptance|candidate|review|delivery) ;;
          *) execute_task_die "fix loop may start only from testing, acceptance, candidate, review, or delivery" ;;
        esac
        read_evidence "fix-loop reason"
        ROUND=$(( $(jq -r '.fix_round' "$STATE") + 1 ))
        FIX_ID="review-fix-$ROUND"
        update_state '
          .invalidations += [{at: $updated_at, reason: $reason, candidate_sha: .candidate.sha}] |
          .fix_round = $round |
          .phase = {name: "implementation", status: "in_progress"} |
          .completed_phases = [.completed_phases[] | select(. == "readiness" or . == "planning")] |
          .tasks += [{id: $task, phase: "implementation", description: $reason,
            status: "pending", ui_task_id: null, evidence: null, updated_at: $updated_at}] |
          .gates = [.gates[] | select(.id != "testing" and .id != "acceptance" and .id != "dod")] |
          .reviews = [.required_reviewers[] as $reviewer |
            {reviewer: $reviewer, verdict: "PENDING", sha: null, evidence: null, recorded_at: null}] |
          .candidate = {sha: null, tree_sha: null, recorded_at: null} |
          .ci = {status: "pending", sha: null, pr_number: null, evidence: null, recorded_at: null}
        ' --arg reason "$EVIDENCE" --arg task "$FIX_ID" --argjson round "$ROUND"
        ;;
      *) execute_task_die "unknown phase action '$ACTION'" ;;
    esac
    ;;

  task)
    [ "$#" -ge 4 ] || usage
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "task evidence is immutable after the current phase completes"
    ACTION="$3"; TASK_ID="$4"; execute_task_validate_item_id "task-id" "$TASK_ID"
    case "$ACTION" in
      add)
        [ "$#" -ge 5 ] || usage
        TASK_PHASE="$5"; validate_phase "$TASK_PHASE"
        UI_TASK_ID=""
        shift 5
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --ui-task-id) [ "$#" -ge 2 ] || execute_task_die "--ui-task-id requires a value"; UI_TASK_ID="$2"; shift ;;
            *) execute_task_die "unknown task option '$1'" ;;
          esac
          shift
        done
        [ "$(jq -r '.phase.name' "$STATE")" = "planning" ] \
          || execute_task_die "tasks may be added only during planning (fix tasks are created by 'phase fix')"
        read_evidence "task description"
        jq -e --arg id "$TASK_ID" 'all(.tasks[]; .id != $id)' "$STATE" >/dev/null 2>&1 \
          || execute_task_die "task '$TASK_ID' already exists"
        update_state '.tasks += [{id: $id, phase: $phase, description: $description,
          status: "pending", ui_task_id: (if ($ui | length) == 0 then null else $ui end),
          evidence: null, updated_at: $updated_at}]' \
          --arg id "$TASK_ID" --arg phase "$TASK_PHASE" --arg description "$EVIDENCE" --arg ui "$UI_TASK_ID"
        ;;
      start)
        [ "$#" -eq 4 ] || usage
        CURRENT="$(jq -r '.phase.name' "$STATE")"
        jq -e --arg id "$TASK_ID" --arg phase "$CURRENT" '
          any(.tasks[]; .id == $id and .phase == $phase and (.status == "pending" or .status == "blocked"))
        ' "$STATE" >/dev/null 2>&1 || execute_task_die "task '$TASK_ID' is not startable in phase '$CURRENT'"
        update_state '(.tasks[] | select(.id == $id)) |=
          (.status = "in_progress" | .evidence = null | .updated_at = $updated_at)' --arg id "$TASK_ID"
        ;;
      complete|block)
        [ "$#" -eq 4 ] || usage
        read_evidence "task $ACTION evidence"
        CURRENT="$(jq -r '.phase.name' "$STATE")"
        jq -e --arg id "$TASK_ID" --arg phase "$CURRENT" '
          any(.tasks[]; .id == $id and .phase == $phase and .status == "in_progress")
        ' "$STATE" >/dev/null 2>&1 || execute_task_die "task '$TASK_ID' is not in progress in phase '$CURRENT'"
        [ "$ACTION" = "complete" ] && NEW_STATUS="completed" || NEW_STATUS="blocked"
        update_state '(.tasks[] | select(.id == $id)) |=
          (.status = $status | .evidence = $evidence | .updated_at = $updated_at)' \
          --arg id "$TASK_ID" --arg status "$NEW_STATUS" --arg evidence "$EVIDENCE"
        ;;
      bind-ui)
        [ "$#" -eq 5 ] || usage
        UI_TASK_ID="$5"; [ -n "$UI_TASK_ID" ] || execute_task_die "ui-task-id is required"
        jq -e --arg id "$TASK_ID" 'any(.tasks[]; .id == $id)' "$STATE" >/dev/null 2>&1 \
          || execute_task_die "task '$TASK_ID' not found"
        jq -e --arg ui "$UI_TASK_ID" 'all(.tasks[]; (.ui_task_id // "") != $ui)' "$STATE" >/dev/null 2>&1 \
          || execute_task_die "ui-task-id '$UI_TASK_ID' is already bound"
        update_state '(.tasks[] | select(.id == $id)).ui_task_id = $ui' \
          --arg id "$TASK_ID" --arg ui "$UI_TASK_ID"
        ;;
      *) execute_task_die "unknown task action '$ACTION'" ;;
    esac
    ;;

  gate)
    [ "$#" -ge 5 ] || usage
    [ "$3" = "record" ] || execute_task_die "unknown gate action '$3'"
    state_paths "$2"; lock_state; load_state; assert_active
    GATE_ID="$4"; execute_task_validate_item_id "gate-id" "$GATE_ID"
    GATE_STATUS="$5"; case "$GATE_STATUS" in pass|fail) ;; *) execute_task_die "gate status must be pass or fail" ;; esac
    shift 5; GATE_SHA=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --sha) [ "$#" -ge 2 ] || execute_task_die "--sha requires a value"; GATE_SHA="$(resolve_commit "$2")"; shift ;;
        *) execute_task_die "unknown gate option '$1'" ;;
      esac
      shift
    done
    CURRENT="$(jq -r '.phase.name' "$STATE")"
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "gate evidence is immutable after phase '$CURRENT' completes"
    case "$GATE_ID:$CURRENT" in
      dor:readiness|testing:testing|acceptance:acceptance|dod:delivery) ;;
      dor:*|testing:*|acceptance:*|dod:*) execute_task_die "gate '$GATE_ID' cannot be recorded in phase '$CURRENT'" ;;
      *) ;;
    esac
    if [ "$GATE_ID" = "dod" ]; then
      CANDIDATE="$(jq -r '.candidate.sha // empty' "$STATE")"
      [ -n "$GATE_SHA" ] && [ "$GATE_SHA" = "$CANDIDATE" ] \
        || execute_task_die "DoD evidence must name the exact candidate SHA"
    fi
    if [ "$GATE_STATUS" = "pass" ]; then
      case "$GATE_ID" in
        testing|acceptance|dod)
          jq -e --arg id "$GATE_ID" 'any(.gates[]; .id == $id and .status == "fail")' \
            "$STATE" >/dev/null 2>&1 \
            && execute_task_die "gate '$GATE_ID' already failed; use phase fix before recording a pass"
          ;;
      esac
    fi
    read_evidence "gate evidence"
    GATE_TREE=""
    if [ "$GATE_ID" = "testing" ] && [ "$GATE_STATUS" = "pass" ]; then
      GATE_TREE="$(execute_task_worktree_tree_sha)"
    fi
    update_state '.gates = ([.gates[] | select(.id != $id)] +
      [{id: $id, status: $status, sha: (if ($sha | length) == 0 then null else $sha end),
        tree_sha: (if ($tree | length) == 0 then null else $tree end),
        evidence: $evidence, recorded_at: $updated_at}])' \
      --arg id "$GATE_ID" --arg status "$GATE_STATUS" --arg sha "$GATE_SHA" \
      --arg tree "$GATE_TREE" --arg evidence "$EVIDENCE"
    ;;

  candidate)
    [ "$#" -eq 4 ] || usage
    [ "$3" = "record" ] || execute_task_die "unknown candidate action '$3'"
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "candidate" ] \
      || execute_task_die "candidate may be recorded only in candidate phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "candidate evidence is immutable after candidate phase completes"
    SHA="$(resolve_commit "$4")"; execute_task_assert_clean_tree
    CURRENT_SHA="$(execute_task_current_sha)"
    [ "$SHA" = "$CURRENT_SHA" ] || execute_task_die "candidate must be the exact current HEAD ($CURRENT_SHA)"
    TREE_SHA="$(execute_task_current_tree_sha)"
    TESTED_TREE="$(jq -r '[.gates[] | select(.id == "testing" and .status == "pass")][-1].tree_sha // empty' "$STATE")"
    [ -n "$TESTED_TREE" ] || execute_task_die "testing gate has no working-tree fingerprint"
    [ "$TREE_SHA" = "$TESTED_TREE" ] \
      || execute_task_die "candidate tree $TREE_SHA differs from tested tree $TESTED_TREE; return through phase fix"
    update_state '
      if .candidate.sha != null and .candidate.sha != $sha then
        .invalidations += [{at: $updated_at, reason: "new candidate recorded", candidate_sha: .candidate.sha}]
      else . end |
      .candidate = {sha: $sha, tree_sha: $tree, recorded_at: $updated_at} |
      .reviews = [.required_reviewers[] as $reviewer |
        {reviewer: $reviewer, verdict: "PENDING", sha: null, evidence: null, recorded_at: null}] |
      .ci = {status: "pending", sha: null, pr_number: null, evidence: null, recorded_at: null} |
      .gates = [.gates[] | select(.id != "dod")]
    ' --arg sha "$SHA" --arg tree "$TREE_SHA"
    ;;

  review)
    [ "$#" -eq 6 ] || usage
    [ "$3" = "record" ] || execute_task_die "unknown review action '$3'"
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "review" ] \
      || execute_task_die "reviews may be recorded only in review phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "review evidence is immutable after review phase completes"
    REVIEWER="$4"; execute_task_validate_item_id "reviewer" "$REVIEWER"
    jq -e --arg reviewer "$REVIEWER" 'any(.required_reviewers[]; . == $reviewer)' "$STATE" >/dev/null 2>&1 \
      || execute_task_die "reviewer '$REVIEWER' is not required by this run"
    VERDICT="$5"; case "$VERDICT" in APPROVE|REQUEST_CHANGES) ;; *) execute_task_die "verdict must be APPROVE or REQUEST_CHANGES" ;; esac
    SHA="$(resolve_commit "$6")"
    CANDIDATE="$(jq -r '.candidate.sha // empty' "$STATE")"
    [ "$SHA" = "$CANDIDATE" ] || execute_task_die "review verdict is stale: candidate is $CANDIDATE, verdict names $SHA"
    if [ "$VERDICT" = "APPROVE" ]; then
      jq -e --arg reviewer "$REVIEWER" --arg sha "$SHA" '
        any(.reviews[]; .reviewer == $reviewer and .verdict == "REQUEST_CHANGES" and .sha == $sha)
      ' "$STATE" >/dev/null 2>&1 \
        && execute_task_die "reviewer '$REVIEWER' already requested changes on candidate $SHA; use phase fix"
    fi
    assert_current_candidate
    read_evidence "review evidence"
    if [ "$REVIEWER" = "codex" ] && [ "$VERDICT" = "APPROVE" ]; then
      validate_codex_approval_evidence
    fi
    update_state '
      .review_history += [{reviewer: $reviewer, verdict: $verdict, sha: $sha,
        evidence: $evidence, recorded_at: $updated_at}] |
      (.reviews[] | select(.reviewer == $reviewer)) =
        {reviewer: $reviewer, verdict: $verdict, sha: $sha,
          evidence: $evidence, recorded_at: $updated_at}
    ' --arg reviewer "$REVIEWER" --arg verdict "$VERDICT" --arg sha "$SHA" --arg evidence "$EVIDENCE"
    ;;

  ci)
    [ "$#" -ge 5 ] || usage
    [ "$3" = "record" ] || execute_task_die "unknown CI action '$3'"
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "delivery" ] \
      || execute_task_die "CI may be recorded only in delivery phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "in_progress" ] \
      || execute_task_die "CI evidence is immutable after delivery phase completes"
    CI_STATUS="$4"; case "$CI_STATUS" in success|failure) ;; *) execute_task_die "CI status must be success or failure" ;; esac
    SHA="$(resolve_commit "$5")"
    shift 5
    PR_NUMBER=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pr)
          [ "$#" -ge 2 ] || execute_task_die "--pr requires a value"
          PR_NUMBER="$2"; shift
          ;;
        *) execute_task_die "unknown CI option '$1'" ;;
      esac
      shift
    done
    CANDIDATE="$(jq -r '.candidate.sha // empty' "$STATE")"
    [ "$SHA" = "$CANDIDATE" ] || execute_task_die "CI result is for $SHA, not candidate $CANDIDATE"
    if [ "$CI_STATUS" = "success" ]; then
      case "$PR_NUMBER" in ''|*[!0-9]*) execute_task_die "successful CI requires --pr <positive-number>" ;; esac
      [ "$PR_NUMBER" -gt 0 ] || execute_task_die "successful CI requires --pr <positive-number>"
      command -v gh >/dev/null 2>&1 || execute_task_die "gh is required to verify hosted CI"
      jq -e '.ci.status == "failure"' "$STATE" >/dev/null 2>&1 \
        && execute_task_die "CI already failed for this candidate; use phase fix before recording success"
      verify_hosted_ci "$SHA" "$PR_NUMBER"
    elif [ -n "$PR_NUMBER" ]; then
      execute_task_die "--pr is accepted only when recording successful CI"
    fi
    read_evidence "CI evidence"
    if [ "$CI_STATUS" = "success" ]; then
      EVIDENCE="PR #$PR_NUMBER required checks verified at $SHA
$EVIDENCE"
    fi
    update_state '.ci = {status: $status, sha: $sha, pr_number: $pr_number,
      evidence: $evidence, recorded_at: $updated_at}' \
      --arg status "$CI_STATUS" --arg sha "$SHA" --arg evidence "$EVIDENCE" \
      --argjson pr_number "${PR_NUMBER:-null}"
    ;;

  can-advance)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; load_state; assert_active
    CURRENT="$(jq -r '.phase.name' "$STATE")"
    validate_phase_completion "$CURRENT"
    printf 'ADVANCE OK: %s\n' "$CURRENT"
    ;;

  can-merge)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "delivery" ] \
      || execute_task_die "merge requires delivery phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "completed" ] \
      || execute_task_die "merge requires completed delivery phase"
    validate_phase_completion delivery
    printf 'MERGE OK: %s\n' "$(jq -r '.candidate.sha' "$STATE")"
    ;;

  block)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; lock_state; load_state; assert_active; read_evidence "block reason"
    update_state '.status = "blocked" | .blocked_reason = $reason' --arg reason "$EVIDENCE"
    ;;

  resume)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; lock_state; lock_initialization; load_state
    case "$(jq -r '.status' "$STATE")" in
      blocked|active) assert_no_other_active_run ;;
      completed) execute_task_die "completed run '$EXECUTE_TASK_RUN_ID' cannot be resumed" ;;
    esac
    [ "$(jq -r '.status' "$STATE")" = "active" ] \
      || update_state '.status = "active" | .blocked_reason = null'
    jq '{run_id,status,phase,spec,candidate,ci}' "$STATE"
    ;;

  finish)
    [ "$#" -eq 2 ] || usage
    state_paths "$2"; lock_state; load_state; assert_active
    [ "$(jq -r '.phase.name' "$STATE")" = "delivery" ] \
      || execute_task_die "finish requires delivery phase"
    [ "$(jq -r '.phase.status' "$STATE")" = "completed" ] \
      || execute_task_die "finish requires completed delivery phase"
    validate_delivery_state
    verify_merged_pr
    read_evidence "post-merge reconciliation evidence"
    update_state '.status = "completed" | .phase = {name: "done", status: "completed"} |
      .completed_phases += ["done"] | .completion_evidence = $evidence | .completed_at = $updated_at' \
      --arg evidence "$EVIDENCE"
    ;;

  *) usage ;;
esac
