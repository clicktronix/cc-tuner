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
  "pr view")   serve pr.json ;;
  "pr checks")
    # Real `gh pr checks --required` exits 1 and reports on stderr when the branch requires nothing;
    # it never returns an empty array. A stub that returns [] tests a CLI that does not exist -- the
    # comment runctl.sh has carried since before this rewrite.
    case "$*" in *--required*) ;; *) exit 1 ;; esac
    if [ -f "$D/checks-none" ]; then echo "no checks reported on the 'task' branch" >&2; exit 1; fi
    serve checks.json ;;
  "api user")  serve user ;;
  "pr merge")  printf 'MERGED %s\n' "$*" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/gh"
}

world() {  # world <files-json> <reviews-json> <checks-json> [head-sha]
  local d; d="$(flow_workdir)"; gh_stub "$d"
  # One document, because merge.sh makes one `gh pr view` call for all three fields.
  printf '{"headRefOid":"%s","files":%s,"reviews":%s}\n' "${4:-$SHA}" "$1" "$2" > "$d/pr.json"
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

# A branch that requires nothing does not report an empty list -- gh exits 1 and says so on stderr.
# Reading only the exit status called that "cannot read CI", sending the operator to hunt a failing
# check that does not exist.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none"
OUT="$(run "$D" 42 squash "$SHA")"
check  "no-required-checks-refused"  "no required checks configured" "$OUT"
absent "no-required-checks-no-merge" "MERGED"                        "$OUT"

# And the empty-array shape too, in case a future gh ever produces it.
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

# --- outside a run, this is not our business, so it merges --------------------------------------
# Refusing here was a deadlock: the hook refuses a raw `gh pr merge` and this refused everything with
# no plan file, so a repository with cc-tuner installed could not merge an ordinary pull request at
# all. There must always be a path, and for work that is not a cc-tuner run the path is "just merge".
D="$(world "$NO_PLAN_FILES" '[]' '[]')"
OUT="$(run "$D" 42 squash "$SHA")"
check "non-cc-tuner-pr-merges"   "MERGED pr merge 42 --squash" "$OUT"
check "non-cc-tuner-says-so"     "not a cc-tuner run"          "$OUT"
check "non-cc-tuner-rc0"         "rc=0"                        "$OUT"
# Still pinned. The head can move between reading the PR and merging it whether or not cc-tuner has
# an opinion about the contents, and an earlier revision dropped the pin here -- with a test that
# asserted its absence, pinning the flaw instead of the head.
check "non-cc-tuner-still-pinned" "--match-head-commit $SHA" "$OUT"

# --check-only has no answer for a pull request it checks nothing about, and must not look like a
# pass: Task 8 reads that output as evidence.
OUT="$(run "$D" --check-only 42 squash "$SHA")"
check  "check-only-refuses-out-of-scope" "nothing to check" "$OUT"
check  "check-only-out-of-scope-rc1"     "rc=1"             "$OUT"
absent "check-only-out-of-scope-no-merge" "MERGED"          "$OUT"

# --- a scope it cannot establish is not a scope out of ------------------------------------------
# `unknown` was folded in with `no`, so a PR whose file list did not parse merged with no review, no
# CI and no pin. Not knowing whether this is a run is not the same as knowing it is not.
D="$(world 'null' "$APPROVED" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "unknown-scope-refused"  "refusing rather than guessing" "$OUT"
check  "unknown-scope-rc1"      "rc=1"                          "$OUT"
absent "unknown-scope-no-merge" "MERGED"                        "$OUT"

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
# rebase was accepted for one revision, offering a strategy no spec is allowed to declare.
check "rebase-refused"            "strategy must" "$(run "$D" 42 rebase "$SHA")"

# --check-only proves the candidate would be accepted without merging it. The eval has to observe the
# positive path, and a check that can only be run by merging is one nobody will run twice.
OUT="$(run "$D" --check-only 42 squash "$SHA")"
check  "check-only-reports-pass" "verdict, required CI and head all check out" "$OUT"
check  "check-only-rc0"          "rc=0"                                        "$OUT"
absent "check-only-does-not-merge" "MERGED"                                    "$OUT"

D="$(world "$PLAN_FILES" '[]' "$GREEN_CI")"
OUT="$(run "$D" --check-only 42 squash "$SHA")"
check  "check-only-still-refuses" "rc=1"   "$OUT"
absent "check-only-refusal-no-merge" "MERGED" "$OUT"

# --- facts it cannot establish are not facts ------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/pr.json"
check "unresolvable-pr-refused" "cannot resolve" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/user"
check "unknown-identity-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

exit $fails
