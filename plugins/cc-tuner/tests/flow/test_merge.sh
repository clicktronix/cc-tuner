#!/usr/bin/env bash
# merge.sh: the only sanctioned way to merge a cc-tuner run, and the thing that actually checks one.
#
# These assertions used to live against a PreToolUse hook that tried to judge arbitrary Bash text.
# Here the PR, strategy and SHA are arguments, so there is nothing to parse and nothing to guess.
#
# The positive path is asserted FIRST and on purpose: every case here could assert refusal, and a
# script that refused unconditionally would pass the lot.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MERGE="$FLOW_PLUGIN/scripts/merge.sh"
OTHER_SHA="0000111122223333"

# A real repository, because merge.sh asks git whether the target is inside the candidate and a
# fake SHA cannot answer that. base -> candidate on main; `advanced` is one commit past base that
# the candidate does NOT contain — the target moving on while the candidate was under review.
FIX_REPO="$(flow_workdir)/repo"
mkdir -p "$FIX_REPO"
(
  cd "$FIX_REPO"
  git init -q -b main
  git config user.email test@example.com
  git config user.name test
  printf 'base\n' > base.txt;      git add base.txt;      git commit -qm base
  printf 'candidate\n' > cand.txt; git add cand.txt;      git commit -qm candidate
  git checkout -q -b advanced HEAD^
  printf 'advanced\n' > adv.txt;   git add adv.txt;       git commit -qm 'target advanced'
  git checkout -q main
)
SHA="$(git -C "$FIX_REPO" rev-parse main)"
BASE_SHA="$(git -C "$FIX_REPO" rev-parse main^)"
ADVANCED="$(git -C "$FIX_REPO" rev-parse advanced)"

gh_stub() {
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$D/calls"
serve() { [ -f "$D/$1" ] || exit 1; cat "$D/$1"; }
case "$1 $2" in
  "api user")  serve user ;;
  "api repos/"*)
    case "$*" in *--paginate*) ;; *) exit 1 ;; esac
    [ ! -f "$D/api-fail" ] || exit 1
    serve api-files ;;
  "pr view")   serve pr.json ;;
  "pr checks")
    # Real `gh pr checks` exits 1 and reports on stderr when there is nothing to report; it never
    # returns an empty array. A stub that returns [] tests a CLI that does not exist -- the behaviour
    # the deleted runctl.sh had already learned and documented.
    #
    # --required and the bare form are separate worlds here, because that is the whole point of the
    # --ci modes: a branch can require nothing while checks still run on the head.
    case "$*" in
      *--required*)
        if [ -f "$D/checks-none" ]; then echo "no checks reported on the 'task' branch" >&2; exit 1; fi
        if [ -f "$D/checks-none-required" ]; then echo "no required checks reported on the 'task' branch" >&2; exit 1; fi
        serve checks.json ;;
      *)
        if [ -f "$D/checks-none-any" ]; then echo "no checks reported on the 'task' branch" >&2; exit 1; fi
        if [ -f "$D/checks-any.json" ]; then serve checks-any.json; else serve checks.json; fi ;;
    esac ;;
  "pr merge")  printf 'MERGED %s\n' "$*" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/gh"
}

world() {  # world <files-json> <reviews-json> <checks-json> [head-sha] [local-ci comment body] [base-sha]
  local d; d="$(flow_workdir)"; gh_stub "$d"
  local comments='[]'
  [ -n "${5:-}" ] && comments="$(jq -nc --arg b "$5" '[{author:{login:"agent-bot"}, body:$b}]')"
  jq -nc --arg head "${4:-$SHA}" --arg base "${6:-$BASE_SHA}" --argjson reviews "$2" --argjson comments "$comments" \
    '{headRefOid: $head, baseRefName: "main", baseRefOid: $base, reviews: $reviews, comments: $comments}' > "$d/pr.json"
  printf '%s' "$1" | jq -r '.[]? | (.path // .filename // empty)' > "$d/api-files"
  printf '%s\n' "$3" > "$d/checks.json"
  printf 'agent-bot\n' > "$d/user"
  mkdir -p "$d/codex/scripts"
  printf '%s\n' "${4:-$SHA}" > "$d/codex-head"
  cat > "$d/codex/scripts/review-state.sh" <<'EOF'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")/../.." && pwd)"
printf '%s\n' "$*" >> "$D/codex-calls"
[ "$1" = check ] && [ -n "${2:-}" ] || exit 1
[ ! -f "$D/codex-fail" ] || { echo NO_APPROVAL >&2; exit 10; }
HEAD="$(cat "$D/codex-head")"
printf 'CC_CODEX_REQUIRED_REVIEW APPROVE thread=%s head=%s tree=tree123 base_sha=base123 spec_path=docs/spec.md\n' "$2" "$HEAD"
EOF
  chmod +x "$d/codex/scripts/review-state.sh"
  jq -nc --arg root "$d/codex" '[{id:"cc-codex-triage@cc-codex-triage",version:"0.11.0",scope:"user",enabled:true,installPath:$root}]' > "$d/plugins.json"
  printf '%s' "$d"
}

PLAN_FILES='[{"path":"docs/task-plans/2026-01-01-retry.md"},{"path":"src/retry.ts"}]'
WIKI_FILES='[{"path":"wiki/task-plans/2026-01-01-retry.md"}]'
NO_PLAN_FILES='[{"path":"src/retry.ts"}]'
GREEN_CI='[{"name":"build","bucket":"pass"},{"name":"test","bucket":"pass"}]'
review() { printf '[{"author":{"login":"%s"},"commit":{"oid":"%s"},"submittedAt":"%s","body":"%s"}]' "$1" "$2" "$3" "$4"; }
APPROVED="$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $SHA")"

# run <stub> <args...> -> stdout+stderr then rc=<code>
run() {
  local d="$1"; shift
  # Normal /run calls carry the exact thread. Keep individual cases focused by supplying the standard
  # fixture thread when they pass a complete merge triplet; partial-argument tests stay partial.
  if [ "$#" -eq 3 ]; then set -- "$@" review-default
  elif [ "$#" -eq 4 ] && [ "$1" = --check-only ]; then set -- "$@" review-default
  fi
  # From inside the fixture repository: the target-inclusion check asks git about real commits.
  out="$(cd "$FIX_REPO" && CC_TUNER_GH="$d/gh" CC_TUNER_PLUGIN_LIST_CMD="cat $d/plugins.json" bash "$MERGE" "$@" 2>&1)"
  printf '%s\nrc=%s\n' "$out" "$?"
}
run_without_thread() {
  local d="$1"; shift
  out="$(cd "$FIX_REPO" && CC_TUNER_GH="$d/gh" CC_TUNER_PLUGIN_LIST_CMD="cat $d/plugins.json" bash "$MERGE" "$@" 2>&1)"
  printf '%s\nrc=%s\n' "$out" "$?"
}

# --- the one state that merges ------------------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check "attested-candidate-merges" "MERGED pr merge 42 --squash --match-head-commit $SHA" "$OUT"
check "attested-candidate-rc0"    "rc=0"                                                 "$OUT"
# The pin is not the caller's to omit: merge.sh always adds it, so the head cannot move underneath.
check "always-pins-the-head" "--match-head-commit" "$OUT"
check "required-review-check-runs" "check review-default" "$(cat "$D/codex-calls")"

# --- the target moved on while the candidate was under review -------------------------------------
# --match-head-commit protects the head, not the base. A candidate that does not contain the
# advanced target would have GitHub merge a tree nobody reviewed, so it is refused by name; a base
# git cannot resolve locally is a fetch problem, named as such; and once the workflow integrates the
# target and the new head is approved, the merge proceeds — the path a base-equality check would
# have made impossible.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "" "" "$ADVANCED")"
OUT="$(run "$D" 42 squash "$SHA")"
check "unintegrated-target-refused"        "does not include it"                       "$OUT"
check "unintegrated-target-names-the-fix"  "integrate the target, re-verify"           "$OUT"
check "unintegrated-target-rc1"            "rc=1"                                      "$OUT"
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "" "" "$OTHER_SHA")"
OUT="$(run "$D" 42 squash "$SHA")"
check "unresolvable-target-tip-named"      "cannot resolve the current target tip"     "$OUT"
check "unresolvable-target-tip-rc1"        "rc=1"                                      "$OUT"
( cd "$FIX_REPO" && git merge -q --no-edit advanced )
INTEGRATED="$(git -C "$FIX_REPO" rev-parse main)"
APPROVED_INT="$(review agent-bot "$INTEGRATED" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $INTEGRATED")"
D="$(world "$PLAN_FILES" "$APPROVED_INT" "$GREEN_CI" "$INTEGRATED" "" "$ADVANCED")"
OUT="$(run "$D" 42 squash "$INTEGRATED")"
check "integrated-candidate-merges"        "MERGED pr merge 42 --squash --match-head-commit $INTEGRATED" "$OUT"
check "integrated-candidate-rc0"           "rc=0"                                      "$OUT"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(run_without_thread "$D" 42 squash "$SHA")"
check "in-scope-merge-requires-review-thread" "requires the same review-thread" "$OUT"
absent "missing-review-thread-no-merge" "MERGED" "$OUT"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/codex-fail"
OUT="$(run "$D" 42 squash "$SHA")"
check "missing-required-review-refused" "did not approve this worktree candidate" "$OUT"
absent "missing-required-review-no-merge" "MERGED" "$OUT"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
printf '%s\n' "$OTHER_SHA" > "$D/codex-head"
OUT="$(run "$D" 42 squash "$SHA")"
check "wrong-required-review-head-refused" "does not cover thread" "$OUT"
absent "wrong-required-review-head-no-merge" "MERGED" "$OUT"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA" review-explicit)"
check "explicit-required-review-thread-passes" "rc=0" "$OUT"
check "explicit-required-review-thread-reaches-checker" "check review-explicit" "$(cat "$D/codex-calls")"

D="$(world "$WIKI_FILES" "$APPROVED" "$GREEN_CI")"
check "wiki-task-plans-is-in-scope" "rc=0" "$(run "$D" 42 squash "$SHA")"

# --- one missing fact at a time -----------------------------------------------------------------
D="$(world "$PLAN_FILES" "$(review agent-bot "$OTHER_SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $OTHER_SHA")" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check "unreviewed-head-refused" "has not been reviewed at this commit" "$OUT"
check "unreviewed-head-rc1"     "rc=1"                                 "$OUT"

D="$(world "$PLAN_FILES" '[]' "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "no-verdict-refused" "rc=1" "$OUT"
# The refusal must be the only thing on stderr. The first-line fix indexed `split("\n")[0]` on an
# empty body, and jq's `"" | split("\n")` is `[]` rather than `[""]`, so the index was null and `sub`
# raised. It refused for the right reason while printing a jq error underneath it -- on the commonest
# path there is, a PR whose head carries no review at all.
absent "no-verdict-no-jq-error" "jq: error" "$OUT"

D="$(world "$PLAN_FILES" "$APPROVED" '[{"name":"build","bucket":"fail"},{"name":"test","bucket":"pass"}]')"
check "red-ci-refused" "not passing" "$(run "$D" 42 squash "$SHA")"

# A branch that requires nothing does not report an empty list -- gh exits 1 and says so on stderr.
# Reading only the exit status called that "cannot read CI", sending the operator to hunt a failing
# check that does not exist.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none"
OUT="$(run "$D" 42 squash "$SHA")"
check  "no-required-checks-refused"  "absent CI is unproven CI" "$OUT"
absent "no-required-checks-no-merge" "MERGED"                        "$OUT"

# Current gh versions include "required" in the same diagnostic when --required is supplied.
# Keep both forms because the CLI has emitted both and the operator-facing distinction matters.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
OUT="$(run "$D" 42 squash "$SHA")"
check  "new-gh-no-required-checks-refused"  "absent CI is unproven CI" "$OUT"
absent "new-gh-no-required-checks-no-merge" "MERGED"                        "$OUT"

# And the empty-array shape too, in case a future gh ever produces it.
D="$(world "$PLAN_FILES" "$APPROVED" '[]')"
check "zero-required-checks-refused" "absent CI is unproven CI" "$(run "$D" 42 squash "$SHA")"

# --- the CI modes ---------------------------------------------------------------------------------
# `required` is not universal. A repository with no branch protection requires nothing, and one whose
# CI runs by hand has nothing on a given head. Refusing both outright is what sent operators to a raw
# `gh pr merge`, which is outside every check in this file -- so the modes exist. What none of them
# may do is turn a red or a pending check green, and that is what these cases pin.

# --ci any: the branch requires nothing, but checks ran on the head and passed.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
OUT="$(run_without_thread "$D" --ci any 42 squash "$SHA" review-default)"
check "ci-any-merges-on-reported-green" "MERGED" "$OUT"

# ...and a red reported check still refuses. `any` widens WHICH checks answer, not whether they may fail.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
printf '%s\n' '[{"name":"build","bucket":"fail"}]' > "$D/checks-any.json"
OUT="$(run_without_thread "$D" --ci any 42 squash "$SHA" review-default)"
check  "ci-any-red-refused"  "not passing" "$OUT"
absent "ci-any-red-no-merge" "MERGED"      "$OUT"

# ...and `any` with nothing reported at all is still absent CI, not a pass.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci any 42 squash "$SHA" review-default)"
check  "ci-any-nothing-reported-refused" "absent CI is unproven CI" "$OUT"
absent "ci-any-nothing-reported-no-merge" "MERGED"                  "$OUT"

# --ci none:<reason>: the recorded waiver. Two conditions, not one -- nothing reported AND a written
# local result naming this exact commit in the pull-request body. Without the second, the waiver's
# precondition ("no checks reported") would be satisfied by the very policy it waives.
LOCAL_LINE="cc-tuner-local-ci: $SHA bun run check — 6299 pass 0 fail"
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "$SHA" "$LOCAL_LINE")"; : > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci 'none:paid CI minutes, run by hand before release' 42 squash "$SHA" review-default)"
check "ci-none-merges-when-absent"   "MERGED"                     "$OUT"
check "ci-none-prints-the-waiver"    "paid CI minutes"            "$OUT"
check "ci-none-prints-the-local-run" "bun run check"              "$OUT"
check "ci-none-names-who-claimed-it" "agent-bot"                 "$OUT"

# ...and without that record the waiver is refused, however good the reason reads.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci 'none:paid CI minutes' 42 squash "$SHA" review-default)"
check  "ci-none-needs-a-local-record" "has to be on the record" "$OUT"
absent "ci-none-no-record-no-merge"   "MERGED"                  "$OUT"

# A record for a different commit does not carry over to this one.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "$SHA" "cc-tuner-local-ci: $OTHER_SHA bun run check — green")"
: > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci 'none:paid CI minutes' 42 squash "$SHA" review-default)"
check  "ci-none-stale-record-refused"  "has to be on the record" "$OUT"
absent "ci-none-stale-record-no-merge" "MERGED"                  "$OUT"

# An empty result is not a record: the marker with nothing after the SHA says nothing.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "$SHA" "cc-tuner-local-ci: $SHA")"
: > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci 'none:paid CI minutes' 42 squash "$SHA" review-default)"
check "ci-none-empty-record-refused" "has to be on the record" "$OUT"

# The waiver's whole safety: it may not outrank CI that exists. A red check reported on the head
# refuses even under `none`, because absence is what a human can take responsibility for.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
printf '%s\n' '[{"name":"build","bucket":"fail"}]' > "$D/checks-any.json"
OUT="$(run_without_thread "$D" --ci 'none:we do not run CI' 42 squash "$SHA" review-default)"
check  "ci-none-refused-over-reported-checks" "never CI that ran" "$OUT"
absent "ci-none-reported-checks-no-merge"     "MERGED"            "$OUT"

# A pending check is CI that exists and has not answered yet, so the waiver is refused there too.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
printf '%s\n' '[{"name":"build","bucket":"pending"}]' > "$D/checks-any.json"
OUT="$(run_without_thread "$D" --ci 'none:we do not run CI' 42 squash "$SHA" review-default)"
check  "ci-none-refused-over-pending" "never CI that ran" "$OUT"
absent "ci-none-pending-no-merge"     "MERGED"            "$OUT"

# A waiver with no reason is not a waiver: the run log would record that CI was skipped and nothing
# about who accepted it.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
check "ci-none-needs-a-reason" "needs a reason" "$(run_without_thread "$D" --ci none 42 squash "$SHA" review-default)"
check "ci-unknown-mode-refused" "unknown --ci mode" "$(run_without_thread "$D" --ci sometimes 42 squash "$SHA" review-default)"

# The default is unchanged when no mode is passed: required checks, nothing else.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/checks-none-required"
printf '%s\n' '[{"name":"build","bucket":"pass"}]' > "$D/checks-any.json"
OUT="$(run "$D" 42 squash "$SHA")"
check  "default-ignores-non-required-green" "absent CI is unproven CI" "$OUT"
absent "default-non-required-no-merge"      "MERGED"                   "$OUT"

# A flag written after the positionals is not a flag. Swallowing it as the review-thread name refuses
# for a reason that names the wrong problem.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
check "flag-after-positionals-refused" "Flags go first" "$(run_without_thread "$D" 42 squash "$SHA" --ci any)"
check "flag-in-thread-position-refused" "flags go before" "$(run_without_thread "$D" 42 squash "$SHA" --ci)"
check "extra-argument-refused" "too many arguments" "$(run_without_thread "$D" 42 squash "$SHA" thread extra)"

# The last word on a commit belongs to the latest review, and only then is its grammar read. A
# revision that filtered by grammar first -- so a second marker kind could share this stream -- let an
# approval from five hours earlier merge over a later review saying "do not merge this".
DISSENT="$(review agent-bot "$SHA" 2026-01-01T05:00:00Z "Hold on — I found a regression in the retry path, do not merge this.")"
BOTH="$(printf '%s' "$APPROVED" | jq -c --argjson extra "$DISSENT" '. + $extra')"
D="$(world "$PLAN_FILES" "$BOTH" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "later-dissent-blocks"  "has not been reviewed at this commit" "$OUT"
absent "later-dissent-no-merge" "MERGED"                              "$OUT"

# A marker quoted inside prose does not open a record, for the same reason it does not open a review.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI" "$SHA" "I think cc-tuner-local-ci: $SHA bun test would be enough here")"
: > "$D/checks-none-any"
OUT="$(run_without_thread "$D" --ci 'none:no CI here' 42 squash "$SHA" review-default)"
check  "ci-none-quoted-marker-refused" "has to be on the record" "$OUT"
absent "ci-none-quoted-marker-no-merge" "MERGED"                 "$OUT"

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

# The marker grammar has one SHA definition. An abbreviated SHA is not attributed to this head and
# must not be misdiagnosed as a valid marker carrying a non-approval.
D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE abc1234")" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "abbreviated-sha-refused"          "has not been reviewed at this commit" "$OUT"
absent "abbreviated-sha-not-misdiagnosed" "is not an approval"                  "$OUT"

# `gh pr view --json files` is capped at 100. The checked path instead requires `--paginate` on the
# REST endpoint, so a plan at item 101 remains in scope.
D="$(world "$NO_PLAN_FILES" "$APPROVED" "$GREEN_CI")"
: > "$D/api-files"
i=0
while [ "$i" -lt 100 ]; do
  printf 'src/f%s.ts\n' "$i" >> "$D/api-files"
  i=$((i + 1))
done
printf 'docs/task-plans/2026-01-01-retry.md\n' >> "$D/api-files"
check "paginated-files-find-plan" "MERGED" "$(run "$D" 42 squash "$SHA")"

printf 'src/f0.ts\nsrc/f1.ts\n' > "$D/api-files"
check "paginated-files-find-no-plan" "not a cc-tuner run" "$(run "$D" 42 squash "$SHA")"

# --- a scope it cannot establish is not a scope out of ------------------------------------------
# An API failure is not evidence that the PR is out of scope. Earlier code folded unknown into no
# and merged with no review or CI.
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; : > "$D/api-fail"
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

# --- a verdict that also explains itself ----------------------------------------------------------
# The grammar was applied to the whole body until a live PR ran into it: `/run` posts the marker and
# then says why, and 1400 characters of reasoning made the verdict unreadable. Safe -- unreadable
# reads as absent, which refuses -- and total, because the positive path could never complete. Both
# halves were correct alone, which is why only a real reviewer surfaced it.
EXPLAINED="cc-tuner-verdict: APPROVE $SHA\n\nRequired review returned APPROVE on this exact SHA. Gate state: APPROVED."
D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "$EXPLAINED")" "$GREEN_CI")"
check "explained-approval-merges" "MERGED" "$(run "$D" 42 squash "$SHA")"

EXPLAINED_RC="cc-tuner-verdict: REQUEST_CHANGES $SHA\n\nTwo findings, both on the exact SHA."
D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "$EXPLAINED_RC")" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "explained-rejection-is-read" "is not an approval" "$OUT"
absent "explained-rejection-no-merge" "MERGED"            "$OUT"

# First line, not anywhere in the body. A marker buried under prose is the forgery the grammar
# refuses, and "read the first line" must not quietly become "search the whole thing".
BURIED="Looks good to me.\n\ncc-tuner-verdict: APPROVE $SHA"
D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "$BURIED")" "$GREEN_CI")"
OUT="$(run "$D" 42 squash "$SHA")"
check  "buried-marker-refused"  "rc=1"   "$OUT"
absent "buried-marker-no-merge" "MERGED" "$OUT"

# Trailing whitespace and a CR are the reviewer's client, not the reviewer's intent.
D="$(world "$PLAN_FILES" "$(review agent-bot "$SHA" 2026-01-01T00:00:00Z "cc-tuner-verdict: APPROVE $SHA  \r\nwhy: it is correct")" "$GREEN_CI")"
check "trailing-whitespace-tolerated" "MERGED" "$(run "$D" 42 squash "$SHA")"

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
check  "check-only-reports-pass" "CI (--ci required) and head all check out" "$OUT"
check  "check-only-rc0"          "rc=0"                                        "$OUT"
absent "check-only-does-not-merge" "MERGED"                                    "$OUT"

D="$(world "$PLAN_FILES" '[]' "$GREEN_CI")"
OUT="$(run "$D" --check-only 42 squash "$SHA")"
check  "check-only-still-refuses" "rc=1"   "$OUT"
absent "check-only-refusal-no-merge" "MERGED" "$OUT"

# --- facts it cannot establish are not facts ------------------------------------------------------
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/pr.json"
check "unresolvable-pr-refused" "cannot resolve" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/api-files"
check "unreadable-file-list-refused" "refusing rather than guessing" "$(run "$D" 42 squash "$SHA")"

D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"; rm -f "$D/user"
check "unknown-identity-refused" "rc=1" "$(run "$D" 42 squash "$SHA")"

# --- a repository mid-flight on the deleted runtime ----------------------------------------------
# Removing the old state machine without detecting its leftovers would fail OPEN: every gate that
# file used to arm is gone, so a half-finished run looks finished. This is the one real refusal --
# SessionStart can only advise -- so it is asserted against the fully-approved world, where every
# other check passes and only the leftover state can be what refuses.
#
# The check reads the repository the script runs IN, so these cases run from a real repo on disk;
# invoking from the cc-tuner checkout would only ever assert the absence of a file here.
LEGACY_REPO="$(flow_repo)"
# The target-inclusion check runs after the legacy check and asks THIS repository about the fixture's
# commits, so give it the objects: the refusal cases never reach it, the cleared case does.
git -C "$LEGACY_REPO" fetch -q "$FIX_REPO" main advanced
mkdir -p "$LEGACY_REPO/.claude/execute-task-runs"
printf '{"schema_version":1,"status":"active"}\n' > "$LEGACY_REPO/.claude/execute-task-runs/old.state.json"
D="$(world "$PLAN_FILES" "$APPROVED" "$GREEN_CI")"
OUT="$(cd "$LEGACY_REPO" && CC_TUNER_GH="$D/gh" CC_TUNER_PLUGIN_LIST_CMD="cat $D/plugins.json" bash "$MERGE" 42 squash "$SHA" review-default 2>&1; printf 'rc=%s\n' "$?")"
check  "legacy-state-refuses-merge"     "removed runtime"  "$OUT"
check  "legacy-state-names-the-file"    "old.state.json"   "$OUT"
check  "legacy-state-refuses-rc1"       "rc=1"             "$OUT"
absent "legacy-state-never-merges"      "MERGED"           "$OUT"

# --check-only must refuse too: it is the eval's evidence, and "would merge" from a repository whose
# state cannot be reasoned about is not evidence of anything.
OUT="$(cd "$LEGACY_REPO" && CC_TUNER_GH="$D/gh" CC_TUNER_PLUGIN_LIST_CMD="cat $D/plugins.json" bash "$MERGE" --check-only 42 squash "$SHA" review-default 2>&1; printf 'rc=%s\n' "$?")"
check "legacy-state-refuses-check-only" "removed runtime" "$OUT"

# And the same world with the leftover removed merges, so the refusal above is attributable to the
# state file and to nothing else in the setup.
rm -rf "$LEGACY_REPO/.claude/execute-task-runs"
OUT="$(cd "$LEGACY_REPO" && CC_TUNER_GH="$D/gh" CC_TUNER_PLUGIN_LIST_CMD="cat $D/plugins.json" bash "$MERGE" 42 squash "$SHA" review-default 2>&1; printf 'rc=%s\n' "$?")"
check "cleared-legacy-state-merges" "MERGED" "$OUT"

exit $fails
