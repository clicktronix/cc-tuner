#!/usr/bin/env bash
# merge.sh: the only sanctioned way to merge a cc-tuner run, and the thing that actually checks one.
#
# These assertions used to live against the PreToolUse hook, which read the agent's Bash string and
# tried to judge the merge inside it. That failed three rounds running -- see the hook's header for
# the list of forms it guessed wrong about. Here the PR, the strategy and the SHA are arguments, so
# there is nothing to parse and nothing to guess.
#
# The positive path is asserted FIRST and on purpose: every case here could assert refusal, and a
# script that refused unconditionally would pass the lot.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MERGE="$FLOW_PLUGIN/scripts/merge.sh"
SHA="abc1234def5678"
OTHER_SHA="0000111122223333"

gh_stub() {
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$D/calls"
serve() { [ -f "$D/$1" ] || exit 1; cat "$D/$1"; }
case "$1 $2" in
  "pr view")   case "$*" in *reviews*) serve reviews.json ;; *) serve pr.json ;; esac ;;
  "pr checks") case "$*" in *--required*) serve checks.json ;; *) exit 1 ;; esac ;;
  "api user")  serve user ;;
  "pr merge")  printf 'MERGED %s\n' "$*" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/gh"
}

world() {  # world <files-json> <reviews-json> <checks-json> [head-sha]
  local d; d="$(flow_workdir)"; gh_stub "$d"
  printf '{"number":42,"headRefOid":"%s","files":%s}\n' "${4:-$SHA}" "$1" > "$d/pr.json"
  printf '{"reviews":%s}\n' "$2" > "$d/reviews.json"
  printf '%s\n' "$3" > "$d/checks.json"
  printf 'agent-bot\n' > "$d/user"
  printf '%s' "$d"
}

PLAN_FILES='[{"path":"docs/task-plans/2026-01-01-retry.md"},{"path":"src/retry.ts"}]'
WIKI_FILES='[{"path":"wiki/task-plans/2026-01-01-retry.md"}]'
NO_PLAN_FILES='[{"path":"src/retry.ts"}]'
GREEN_CI='[{"name":"build","bucket":"pass"},{"name":"test","bucket":"pass"}]'
review() { printf '[{"author":{"login":"%s"},"commit":{"oid":"%s"},"submittedAt":"%s","body":"%s"}]' "$1" "$2" "$3" "$4"; }
APPROVED="$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $SHA")"

# run <stub> <args...> -> stdout+stderr then rc=<code>
run() { local d="$1"; shift; out="$(CC_TUNER_GH="$d/gh" bash "$MERGE" "$@" 2>&1)"; printf '%s\nrc=%s\n' "$out" "$?"; }

# --- the one state that merges ------------------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check "attested-candidate-merges" "MERGED pr merge 42 --squash --match-head-commit $SHA" "$OUT"
check "attested-candidate-rc0"    "rc=0"                                                 "$OUT"
# The pin is not the caller's to omit: merge.sh always adds it, so the head cannot move underneath.
check "always-pins-the-head" "--match-head-commit" "$OUT"

D="$(world "$WIKI_FILES" "$APPROVED" "$GREEN_CI")"
check "wiki-task-plans-is-in-scope" "rc=0" "$(run "$D" 42 squash "$SHA")"

# --- one missing fact at a time -----------------------------------------------------------------
D="$(world "$PLAN_FILES" "$(review agent-bot "$OTHER_SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $OTHER_SHA")" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check "unreviewed-head-refused" "has not been reviewed at this commit" "$OUT"
check "unreviewed-head-rc1"     "rc=1"                                 "$OUT"

D="$(world "$PLAN_FILES" '[]' "$GREEN_CI")"
check "no-verdict-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$APPROVED" '[{"name":"build","bucket":"fail"},{"name":"test","bucket":"pass"}]')"
check "red-ci-refused" "not passing" "$(run "$D" 42 squash "$SHA")"

# Zero required checks is not green: an empty list satisfies "nothing failed" under any naive reading.
D="$(world "$PLAN_FILES" "$APPROVED" '[]')"
check "zero-required-checks-refused" "absent CI is unproven CI" "$(run "$D" 42 squash "$SHA")"

# The reproduction of the original defect: a run with nothing recorded merged freely in 0.10.0.
D="$(world "$PLAN_FILES" '[]' '[]')"
check "nothing-recorded-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

# --- the caller's belief is checked against GitHub's -----------------------------------------------
# The SHA is an argument, so it can be wrong. If the branch moved since the caller read it, that is
# exactly the race --match-head-commit exists for, caught before the merge rather than by it.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "$OTHER_SHA")"
OUT="$(run "$D" 42 squash "$SHA")"
check "stale-sha-refused"  "the branch moved" "$OUT"
absent "stale-sha-no-merge" "MERGED"          "$OUT"

# --- outside a run, this is not our business ------------------------------------------------------
D="$(world "$NO_PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "non-cc-tuner-pr-refused" "not a cc-tuner run" "$OUT"
absent "non-cc-tuner-no-merge"   "MERGED"             "$OUT"

# --- latest verdict per author, and forgery -------------------------------------------------------
SUPERSEDED="[$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $SHA" | tr -d '[]'),
$(review agent-bot "$SHA" 2026-02-02T00:00:00Z "cc-tuner-verdict: REQUEST_CHANGES $SHA" | tr -d '[]')]"
D="$(world "$PLAN_FILES" "$SUPERSEDED" "$GREEN_CI")"
check "superseded-approval-refused" "is not an approval" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$(review someone-else "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $SHA")" "$GREEN_CI")"
check "wrong-author-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "I think cc-tuner-verdict: APPROVE $SHA is fine")" "$GREEN_CI")"
check "marker-inside-prose-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

# --- arguments ------------------------------------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
check "missing-arguments-refused" "usage:"        "$(run "$D" 42 squash)"
check "bad-strategy-refused"      "strategy must" "$(run "$D" 42 fast-forward "$SHA")"
check "merge-strategy-accepted"   "rc=0"          "$(run "$D" 42 merge "$SHA")"

# --- facts it cannot establish are not facts ------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/pr.json"
check "unresolvable-pr-refused" "cannot resolve" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/user"
check "unknown-identity-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

exit $fails
