#!/usr/bin/env bash
# The only sanctioned way to merge a cc-tuner run.
#
#   merge.sh [--check-only] [--ci required|any|none:<reason>] <pr> <squash|merge> <sha> [thread]
#
# Why this exists, after three attempts at the other design: the guard used to read the agent's Bash
# command string and decide whether the merge inside it was attested. That cannot work. A shell
# command is a program, and every round of "better parsing" produced another form that ran a merge the
# guard had not seen — `bash -c`, `eval`, `/usr/local/bin/gh`, a line continuation, `G=gh; "$G" …`,
# `$(printf gh)`. There is no regex that ends that list.
#
# So the checking moved to where the inputs are arguments rather than text. This script takes the PR,
# strategy, SHA and required-review thread as values, verifies them itself, and only then calls `gh`.
# Nothing has to guess what a string would have done.
#
# `/run` calls this script directly. Raw CLI commands, the web button, the API and direct pushes are
# outside its boundary; trying to recognise every equivalent Bash program created bypasses and also
# blocked unrelated merges, so the global command-string hook was removed.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

GH="${CC_TUNER_GH:-gh}"

die() { printf 'cc-tuner merge: %s\n' "$1" >&2; exit 1; }

CHECK_ONLY=""
# CI policy, defaulting to the strictest. It is an argument rather than a constant because "required"
# is not universal: a repository with no branch protection has no required checks at all, and one
# whose CI is triggered by hand for cost reasons has none on a given head. Refusing both outright did
# not make them safer — it sent the operator to `gh pr merge` by hand, which is outside every check in
# this file. What each mode means is at the CI section below, where it is applied.
CI_MODE=required
CI_REASON=""
while :; do
  case "${1:-}" in
    --check-only) CHECK_ONLY=1; shift ;;
    --ci)
      [ -n "${2:-}" ] || die "--ci needs a mode: required, any, or none:<reason>"
      case "$2" in
        required|any) CI_MODE="$2" ;;
        none:?*)      CI_MODE=none; CI_REASON="${2#none:}" ;;
        none|none:)   die "--ci none needs a reason: --ci 'none:<why this repository runs no CI>'" ;;
        *)            die "unknown --ci mode '$2' (expected required, any, or none:<reason>)" ;;
      esac
      shift 2 ;;
    *) break ;;
  esac
done

PR="${1:-}"; STRATEGY="${2:-}"; SHA="${3:-}"; REVIEW_THREAD="${4:-}"
[ -n "$PR" ] && [ -n "$STRATEGY" ] && [ -n "$SHA" ] \
  || die "usage: merge.sh [--check-only] [--ci required|any|none:<reason>] <pr> <squash|merge> <candidate-sha> [review-thread]"
# squash and merge only, matching what a spec is allowed to declare. rebase was accepted here and by
# /run for one revision, offering a strategy no spec can ask for.
case "$STRATEGY" in squash|merge) ;; *) die "strategy must be squash or merge" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required to check the candidate"

# A repository still holding a run-state file is mid-flight on a runtime that no longer exists. Left
# undetected the old machinery does not merely vanish, it fails open: every gate that file used to
# arm is gone, and the run looks finished because nothing is left to say otherwise -- the defect being
# deleted, reintroduced by the deletion.
#
# This is the one real refusal. `SessionStart` can only advise: the reference is explicit that it
# cannot block. And it is checked here rather than in a new global hook, because a fence over every
# Bash command is what this design removed.
#
# Detection only. Migrating the old state is deliberately not offered -- the runtime that understood
# it is gone, so anything this script wrote back would be a guess about a format nothing reads.
# Read-only: this is the only code left that mentions a state file, and it never creates or edits one.
LEGACY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$LEGACY_ROOT" ]; then
  for legacy in "$LEGACY_ROOT"/.claude/execute-task-runs/*.state.json; do
    [ -e "$legacy" ] || continue
    die "$LEGACY_ROOT/.claude/execute-task-runs/ still holds run state from the removed runtime (${legacy##*/}).
  Finish that run under the plugin version that created it, or delete the directory and re-plan.
  Refusing to merge while the repository is mid-flight on a runtime this version no longer implements."
  done
fi

# Every GitHub fact is re-read here at merge time. The required-review fact is re-read from the
# companion's exact-candidate state below. Nothing is accepted merely because the caller repeats it.
# One round trip. reviews is a field on the same query, and an earlier revision fetched it in a
# second call to the same endpoint -- a whole network round trip per merge for nothing.
PRJSON="$("$GH" pr view "$PR" --json headRefOid,reviews 2>/dev/null)" \
  || die "cannot resolve pull request '$PR'"

HEAD_SHA="$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty')"
[ -n "$HEAD_SHA" ] || die "pull request $PR reports no head commit"
[ "$HEAD_SHA" = "$SHA" ] \
  || die "the head of $PR is $HEAD_SHA, not the $SHA you asked to merge — the branch moved"

# `gh pr view --json files` asks GraphQL for only the first 100 nodes. Scope is therefore read from
# the paginated REST endpoint instead: a large PR must not become unchecked precisely when its plan
# falls after item 100. The path grammar comes from the same resolver that creates the plan.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || die "cannot resolve the plugin scripts directory"
PLAN_PATTERN="$(bash "$SCRIPT_DIR/plan-path.sh" pattern)" \
  || die "cannot read the plan-path contract"
FILES="$("$GH" api "repos/{owner}/{repo}/pulls/$PR/files" --paginate --jq '.[].filename' 2>/dev/null)" \
  || die "cannot tell whether $PR is a cc-tuner run (its file list could not be read) — refusing rather than guessing"
IN_SCOPE=no
if printf '%s\n' "$FILES" | grep -Eq "$PLAN_PATTERN"; then
  IN_SCOPE=yes
else
  MATCH_RC=$?
  [ "$MATCH_RC" -eq 1 ] \
    || die "cannot tell whether $PR is a cc-tuner run (its file list could not be matched) — refusing rather than guessing"
fi

# Out of scope: merge it, and say so. The plugin must not seize work that is not its own.
if [ "$IN_SCOPE" = "no" ]; then
  # --check-only must not report success for a pull request it checked nothing about. Task 8 reads
  # that output as evidence, and "would merge, unchecked" is not evidence of a working gate.
  [ -z "$CHECK_ONLY" ] \
    || die "$PR carries no plan file, so there is nothing to check — --check-only has no answer here"
  printf 'cc-tuner merge: %s carries no plan file, so this is not a cc-tuner run — merging it unchecked.\n' "$PR" >&2
  # Still pinned. The head can move between the read above and the merge whether or not cc-tuner has
  # an opinion about the contents, and passing the SHA the caller asked for is free.
  exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
fi

# Re-read the required approval from the companion's own exact-candidate state. The GitHub verdict
# below is the public record, but it is written by the same agent being reviewed and cannot prove the
# required review happened. plugin-here.sh resolves the one enabled install that applies to this
# worktree; using the same worktree is part of the cc-codex-triage state contract.
CODEX_ROW="$(bash "$SCRIPT_DIR/setup/plugin-here.sh" 'cc-codex-triage@cc-codex-triage' "$LEGACY_ROOT" 2>/dev/null)" \
  || die "cannot resolve the enabled cc-codex-triage installation for this worktree"
CODEX_ROOT="${CODEX_ROW%%$(printf '\t')*}"
CODEX_CHECK="$CODEX_ROOT/scripts/review-state.sh"
[ -f "$CODEX_CHECK" ] || die "the enabled cc-codex-triage has no review-state.sh checker"
[ -n "$REVIEW_THREAD" ] \
  || die "an in-scope cc-tuner merge requires the same review-thread passed to cc-codex-triage"
CODEX_MARKER="$(bash "$CODEX_CHECK" check "$REVIEW_THREAD" 2>&1)" \
  || die "cc-codex-triage did not approve this worktree candidate: $CODEX_MARKER"
set -f
set -- $CODEX_MARKER
set +f
[ "$#" -eq 7 ] && [ "$1" = CC_CODEX_REQUIRED_REVIEW ] && [ "$2" = APPROVE ] \
  && [ "$3" = "thread=$REVIEW_THREAD" ] && [ "$4" = "head=$HEAD_SHA" ] \
  && case "$5:$6:$7" in tree=?*:base_sha=?*:spec_path=?*) true ;; *) false ;; esac \
  || die "cc-codex-triage returned a marker that does not cover thread $REVIEW_THREAD at $HEAD_SHA"

ME="$("$GH" api user --jq .login 2>/dev/null)" || die "cannot identify the authenticated GitHub account"

# One definition of the marker, applied to the review body's FIRST LINE.
#
# It was applied to the whole body until the eval put a real reviewer in front of it. `/run` posts the
# marker and then explains itself -- which reviewer output should do -- and the anchored test rejected
# all 1400 characters of it, so a verdict the producer had just published was invisible to the gate.
# The failure was safe (unreadable reads as absent, which refuses) and total: the positive path could
# never have completed. That is the producer-versus-checker gap step 2b exists to find, and it took a
# live PR to find it, because both halves are correct on their own.
#
# First line, not "anywhere in the body": the forgery this grammar refuses is a marker quoted inside
# prose -- `I think cc-tuner-verdict: APPROVE <sha> is fine` -- and a quotation does not open a review.
#
# `// ""` after the index, because jq's `"" | split("\n")` is `[]` rather than `[""]`, so the index is
# null and `sub` on null is a hard error. The first version of this fix printed a jq error to stderr
# on every PR with no review at the head -- the commonest path there is -- while still refusing for
# the right reason, so the refusal looked correct and the diagnostics were noise.
# The embedded SHA is the exact GitHub head, not a second 7-to-40-hex grammar that could disagree with
# the comparison above.
VERDICT="$(printf '%s' "$PRJSON" | jq -r --arg sha "$HEAD_SHA" --arg me "$ME" '
  [ .reviews[]? | select((.commit.oid // "") == $sha and (.author.login // "") == $me) ]
  | sort_by(.submittedAt) | last | .body // ""
  | (split("\n")[0] // "") | sub("[ \t\r]+$"; "")
  | if test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) " + $sha + "$") then . else "" end')"
case "$VERDICT" in
  "cc-tuner-verdict: APPROVE $HEAD_SHA") ;;
  "") die "no cc-tuner verdict from $ME on $HEAD_SHA — the candidate has not been reviewed at this commit" ;;
  *)  die "the latest cc-tuner verdict on $HEAD_SHA is not an approval: $VERDICT" ;;
esac

# Zero checks is not green: an empty list satisfies "nothing failed" under any naive reading, and
# absent CI is unproven CI. The three modes differ only in WHICH checks answer that question, never in
# whether a failing one can be waived:
#
#   required (default) — GitHub's own required checks. The strongest claim available: the repository
#                        itself declared what must pass, so nothing here decides it.
#   any                — every check reported on the head. For a repository that runs CI without
#                        branch protection, which is most solo and fork repositories. Weaker, because
#                        a workflow that never started reports nothing; that is why at least one
#                        check is still demanded.
#   none:<reason>      — a recorded waiver, honoured ONLY when GitHub reports no checks whatsoever on
#                        the head. A waiver over a failing or still-running check is refused: absence
#                        is what a human can accept responsibility for, failure is not. The reason is
#                        mandatory and is printed, so the run log carries who accepted what.
#
# `gh pr checks` does NOT return an empty list when there is nothing to report: it exits non-zero and
# says "no checks reported" or "no required checks reported" on stderr. This was learned the hard way
# in the deleted runctl.sh; reading only the exit status reports "cannot read CI" for a repository
# that simply has no branch protection, sending the operator to look for a failing check that does not
# exist.
case "$CI_MODE" in
  required) CI_SELECT="--required"; CI_LABEL="required" ;;
  *)        CI_SELECT="";           CI_LABEL="reported" ;;
esac
CHECKS_ERR="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-checks.XXXXXX")" || die "cannot create a temporary file"
NONE_REPORTED=""
# Unquoted on purpose: an empty CI_SELECT must expand to no argument at all, not to an empty one.
# shellcheck disable=SC2086
if ! CHECKS="$("$GH" pr checks "$PR" $CI_SELECT --json name,bucket 2>"$CHECKS_ERR")"; then
  if grep -Eq 'no( required)? checks reported' "$CHECKS_ERR"; then
    NONE_REPORTED=1
    CHECKS='[]'
  else
    rm -f "$CHECKS_ERR"
    die "cannot read $CI_LABEL CI checks for $HEAD_SHA"
  fi
fi
rm -f "$CHECKS_ERR"
TOTAL="$(printf '%s' "$CHECKS" | jq -r 'length // 0')"

if [ "$CI_MODE" = none ]; then
  # The waiver's whole safety is this comparison. Anything reported — passing, failing or pending —
  # means CI exists here and gets to decide, so the waiver is refused rather than allowed to outrank it.
  { [ -n "$NONE_REPORTED" ] || [ "${TOTAL:-0}" -eq 0 ]; } 2>/dev/null \
    || die "--ci none was passed, but $TOTAL check(s) are reported on $HEAD_SHA — a waiver covers CI that does not exist, never CI that ran. Drop the waiver and let those checks decide."
  printf 'cc-tuner merge: no CI reported on %s; merging under a recorded waiver: %s\n' "$HEAD_SHA" "$CI_REASON" >&2
else
  [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null || die "no $CI_LABEL CI checks ran on $HEAD_SHA — absent CI is unproven CI. Configure a required check, or pass --ci any if this repository runs CI without branch protection, or --ci 'none:<reason>' to merge under a recorded waiver."
  BAD="$(printf '%s' "$CHECKS" | jq -r '[.[] | select(.bucket != "pass")] | length')"
  [ "${BAD:-1}" -eq 0 ] 2>/dev/null || die "$BAD of $TOTAL $CI_LABEL CI checks on $HEAD_SHA are not passing"
fi

# --match-head-commit closes the window between the checks above and the merge itself, on GitHub's
# side, which nothing local can do.
# --check-only stops here, having proved the candidate would be accepted. The eval needs to observe
# the positive path without actually merging, and a check that can only be run by merging is one
# nobody will run twice.
[ -z "$CHECK_ONLY" ] || { printf 'would merge %s (--%s) at %s: required review, verdict, CI (--ci %s) and head all check out\n' "$PR" "$STRATEGY" "$HEAD_SHA" "$CI_MODE"; exit 0; }

exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
