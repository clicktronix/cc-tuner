#!/usr/bin/env bash
# The checked merge for a cc-tuner run.
#
#   merge.sh [--check-only] [--ci required|any|none:<reason>] [--review codex|none:<reason>]
#            [--unmanaged] <pr> <squash|merge> <sha> [review-thread]
#
# Every input is an argument and every fact is re-read from GitHub, git and cc-codex-triage here;
# nothing is accepted because the caller repeats it. Raw `gh pr merge`, the web button and the API
# are outside this boundary by design: this script checks one merge, it does not police Bash.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

GH="${CC_TUNER_GH:-gh}"

die() { printf 'cc-tuner merge: %s\n' "$1" >&2; exit 1; }

CHECK_ONLY=""
UNMANAGED=""
CI_MODE=required
CI_REASON=""
REVIEW_MODE=codex
REVIEW_REASON=""
REVIEW_GIVEN=""
while :; do
  case "${1:-}" in
    --check-only) CHECK_ONLY=1; shift ;;
    --unmanaged)  UNMANAGED=1; shift ;;
    --ci)
      [ -n "${2:-}" ] || die "--ci needs a mode: required, any, or none:<reason>"
      case "$2" in
        required|any) CI_MODE="$2" ;;
        none:?*)      CI_MODE=none; CI_REASON="${2#none:}" ;;
        none|none:)   die "--ci none needs a reason: --ci 'none:<why this repository runs no CI>'" ;;
        *)            die "unknown --ci mode '$2' (expected required, any, or none:<reason>)" ;;
      esac
      shift 2 ;;
    --review)
      [ -n "${2:-}" ] || die "--review needs a mode: codex or none:<reason>"
      case "$2" in
        codex)      REVIEW_MODE=codex ;;
        none:?*)    REVIEW_MODE=none; REVIEW_REASON="${2#none:}" ;;
        none|none:) die "--review none needs a reason: --review 'none:<who decided, and why>'" ;;
        *)          die "unknown --review mode '$2' (expected codex or none:<reason>)" ;;
      esac
      REVIEW_GIVEN=1
      shift 2 ;;
    *) break ;;
  esac
done

PR="${1:-}"; STRATEGY="${2:-}"; SHA="${3:-}"; REVIEW_THREAD="${4:-}"
[ -n "$PR" ] && [ -n "$STRATEGY" ] && [ -n "$SHA" ] \
  || die "usage: merge.sh [--check-only] [--ci <mode>] [--review <mode>] [--unmanaged] <pr> <squash|merge> <candidate-sha> [review-thread]"
[ "$#" -le 4 ] || die "too many arguments: '$5' came after the positional ones. Flags go first: merge.sh [flags] <pr> <strategy> <sha> [thread]"
case "$REVIEW_THREAD" in --*) die "'$REVIEW_THREAD' looks like a flag, but it is in the review-thread position — flags go before <pr>" ;; esac
case "$STRATEGY" in squash|merge) ;; *) die "strategy must be squash or merge" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required to check the candidate"

# State from the runtime removed in 0.10 means a run nothing can advance; refuse rather than let it
# look finished.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ]; then
  for legacy in "$REPO_ROOT"/.claude/execute-task-runs/*.state.json; do
    [ -e "$legacy" ] || continue
    die "$REPO_ROOT/.claude/execute-task-runs/ still holds run state from the removed runtime (${legacy##*/}).
  Finish that run under the plugin version that created it, or delete the directory and re-plan."
  done
fi

PRJSON="$("$GH" pr view "$PR" --json headRefOid,baseRefName,baseRefOid,isDraft,reviews,comments 2>/dev/null)" \
  || die "cannot resolve pull request '$PR'"

HEAD_SHA="$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty')"
[ -n "$HEAD_SHA" ] || die "pull request $PR reports no head commit"
[ "$HEAD_SHA" = "$SHA" ] \
  || die "the head of $PR is $HEAD_SHA, not the $SHA you asked to merge — the branch moved"

# GitHub refuses to merge a draft, so neither a merge nor a preflight may report one as ready.
[ "$(printf '%s' "$PRJSON" | jq -r '.isDraft // false')" != true ] \
  || die "$PR is a draft, which GitHub will not merge. When the candidate is ready: $GH pr ready $PR, let CI run on the ready PR, then re-run this command"

BASE_REF="$(printf '%s' "$PRJSON" | jq -r '.baseRefName // empty')"
BASE_OID="$(printf '%s' "$PRJSON" | jq -r '.baseRefOid // empty')"
[ -n "$BASE_OID" ] || die "pull request $PR reports no base commit"

# `gh pr view --json files` stops at 100 files; the paginated REST list does not.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || die "cannot resolve the plugin scripts directory"
PLAN_PATTERN="$(bash "$SCRIPT_DIR/plan-path.sh" pattern)" || die "cannot read the plan-path contract"
FILES="$("$GH" api "repos/{owner}/{repo}/pulls/$PR/files" --paginate --jq '.[].filename' 2>/dev/null)" \
  || die "cannot read the file list of $PR — refusing rather than guessing whether it is a cc-tuner run"
HAS_PLAN=no
if printf '%s\n' "$FILES" | grep -Eq "$PLAN_PATTERN"; then
  HAS_PLAN=yes
else
  [ "$?" -eq 1 ] || die "cannot match the file list of $PR against the plan pattern"
fi

# Scope is the caller's statement, never an inference from file names alone. A plan in the diff, a
# review thread or an explicit --review all say "this is a cc-tuner run" and get every check below.
# Only --unmanaged merges without them, and it is refused where the PR says otherwise.
if [ -n "$UNMANAGED" ]; then
  [ "$HAS_PLAN" = no ] && [ -z "$REVIEW_THREAD" ] && [ -z "$REVIEW_GIVEN" ] \
    || die "--unmanaged contradicts this call: $PR carries a plan file or a review was named, so it is a cc-tuner run — drop --unmanaged"
  [ -z "$CHECK_ONLY" ] || die "--check-only has nothing to check on an --unmanaged merge"
  printf 'cc-tuner merge: %s merged as --unmanaged, without cc-tuner checks.\n' "$PR" >&2
  exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
fi
if [ "$HAS_PLAN" = no ] && [ -z "$REVIEW_THREAD" ] && [ -z "$REVIEW_GIVEN" ]; then
  die "$PR carries no plan file and no review was named. For a cc-tuner run pass its review thread (or --review none:<reason>); for an ordinary pull request pass --unmanaged."
fi

# --match-head-commit pins the head, not the base: with the target advanced past the candidate,
# GitHub would merge a tree nobody reviewed.
MERGE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a Git repository"
git -C "$MERGE_ROOT" cat-file -e "$BASE_OID^{commit}" 2>/dev/null \
  || git -C "$MERGE_ROOT" fetch -q origin "$BASE_REF" 2>/dev/null \
  || die "cannot resolve the current target tip $BASE_OID locally; fetch $BASE_REF and retry"
git -C "$MERGE_ROOT" merge-base --is-ancestor "$BASE_OID" "$SHA" 2>/dev/null \
  || die "the target advanced to $BASE_OID and candidate $SHA does not include it — integrate the target, re-verify affected evidence, obtain approval for the new candidate, then merge"

# Required review. codex: cc-codex-triage's own exact-candidate state, checked in this worktree.
# none: a recorded decision, printed so the log says who waived what.
if [ "$REVIEW_MODE" = codex ]; then
  CODEX_ROW="$(bash "$SCRIPT_DIR/setup/plugin-here.sh" 'cc-codex-triage@cc-codex-triage' "$REPO_ROOT" 2>/dev/null)" \
    || die "cannot resolve the enabled cc-codex-triage installation for this worktree (a spec without Codex review declares review: none:<reason>)"
  CODEX_CHECK="${CODEX_ROW%%$(printf '\t')*}/scripts/review-state.sh"
  [ -f "$CODEX_CHECK" ] || die "the enabled cc-codex-triage has no review-state.sh checker"
  [ -n "$REVIEW_THREAD" ] \
    || die "a Codex-reviewed merge requires the same review-thread passed to cc-codex-triage"
  CODEX_MARKER="$(bash "$CODEX_CHECK" check "$REVIEW_THREAD" 2>&1)" \
    || die "cc-codex-triage did not approve this worktree candidate: $CODEX_MARKER"
  set -f
  set -- $CODEX_MARKER
  set +f
  [ "$#" -eq 7 ] && [ "$1" = CC_CODEX_REQUIRED_REVIEW ] && [ "$2" = APPROVE ] \
    && [ "$3" = "thread=$REVIEW_THREAD" ] && [ "$4" = "head=$HEAD_SHA" ] \
    && case "$5:$6:$7" in tree=?*:base_sha=?*:spec_path=?*) true ;; *) false ;; esac \
    || die "cc-codex-triage returned a marker that does not cover thread $REVIEW_THREAD at $HEAD_SHA"
else
  printf 'cc-tuner merge: no Codex review for this candidate: %s\n' "$REVIEW_REASON" >&2
fi

ME="$("$GH" api user --jq .login 2>/dev/null)" || die "cannot identify the authenticated GitHub account"

# Every cc-tuner record on the pull request counts only when the authenticated account wrote it: on
# a public repository anyone can comment, and a marker from someone else is not this run's evidence.
TRUSTED="$(printf '%s' "$PRJSON" | jq -c --arg me "$ME" '
  { reviews:  [ .reviews[]?  | select((.author.login // "") == $me) ],
    comments: [ .comments[]? | select((.author.login // "") == $me) ] }')" \
  || die "cannot read the records on $PR"

# The decision is the latest record about the head, from the review stream or a comment: a verdict,
# or under --review none a user's decision to merge without an approval (the review cap reached, the
# remaining findings accepted), recorded as its own line and never as a rewritten verdict:
#   cc-tuner-accepted: <head sha> <who decided, and what they accepted>
# Latest wins in both directions: a later REQUEST_CHANGES or dissenting review at the head overrides
# an earlier approval or decision, and a later decision overrides an earlier REQUEST_CHANGES.
DECISION="$(printf '%s' "$TRUSTED" | jq -r --arg sha "$HEAD_SHA" --arg mode "$REVIEW_MODE" '
  def first: (. // "") | (split("\n")[0] // "") | sub("[ \t\r]+$"; "");
  def verdict: test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) " + $sha + "$");
  def accepted: $mode == "none" and test("^cc-tuner-accepted: " + $sha + " \\S");
  ( [ .reviews[]  | select((.commit.oid // "") == $sha) | {at: (.submittedAt // ""), line: (.body | first)} ]
  + [ .comments[] | {at: (.createdAt // ""), line: (.body | first)} | select((.line | verdict) or (.line | accepted)) ] )
  | sort_by(.at) | last | (.line // "")
  | if verdict or accepted then . else "" end')"
case "$DECISION" in
  "cc-tuner-verdict: APPROVE $HEAD_SHA") ;;
  "cc-tuner-accepted: $HEAD_SHA "*)
    printf 'cc-tuner merge: no approval at %s; merging on a decision recorded by %s: %s\n' "$HEAD_SHA" "$ME" "${DECISION#cc-tuner-accepted: $HEAD_SHA }" >&2 ;;
  "") die "no cc-tuner verdict from $ME on $HEAD_SHA — the candidate has not been reviewed at this commit. Publish the verdict: $GH pr review $PR --comment --body \"cc-tuner-verdict: APPROVE $HEAD_SHA\"" ;;
  *)  die "the latest cc-tuner verdict on $HEAD_SHA is not an approval: $DECISION (a user's decision to merge anyway is --review none:<reason> plus a later PR comment: cc-tuner-accepted: $HEAD_SHA <who, and what they accepted>)" ;;
esac

# The feature was exercised: verify-feature's record, for a commit the head contains. Fix commits
# after verification do not force a new record; the evidence-reuse rule in /run decides that.
VERIFIED_SHA="$(printf '%s' "$TRUSTED" | jq -r '
  [ .comments[]? | ((.body // "") | (split("\n")[0] // "") | sub("[ \t\r]+$"; ""))
    | select(test("^cc-tuner-verified: [0-9a-f]{40}( |$)")) | split(" ")[1] ] | last // ""')"
[ -n "$VERIFIED_SHA" ] \
  || die "no verify-feature record on $PR — post its hand-back as a comment whose first line is: cc-tuner-verified: <full sha it verified>"
git -C "$MERGE_ROOT" merge-base --is-ancestor "$VERIFIED_SHA" "$HEAD_SHA" 2>/dev/null \
  || die "the verify-feature record names $VERIFIED_SHA, which the head $HEAD_SHA does not contain — verify the current candidate"

# CI: zero checks is not green. required = GitHub's required checks; any = every reported check;
# none:<reason> = honoured only when nothing is reported and a local result is on record.
# `gh pr checks` exits non-zero with "no (required) checks reported" instead of returning [].
case "$CI_MODE" in
  required) CI_SELECT="--required"; CI_LABEL="required" ;;
  *)        CI_SELECT="";           CI_LABEL="reported" ;;
esac
CHECKS_ERR="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-checks.XXXXXX")" || die "cannot create a temporary file"
NONE_REPORTED=""
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
  { [ -n "$NONE_REPORTED" ] || [ "${TOTAL:-0}" -eq 0 ]; } 2>/dev/null \
    || die "the spec declares 'ci: none' but $TOTAL check(s) are reported on $HEAD_SHA — a waiver covers CI that does not exist, never CI that ran: use --ci any (or required) and let those checks decide."
  LOCAL_CI="$(printf '%s' "$TRUSTED" | jq -r --arg sha "$HEAD_SHA" '
    [ .comments[]?
      | . + {first: ((.body // "") | (split("\n")[0] // "") | sub("[ \t\r]+$"; ""))}
      | select(.first | test("^cc-tuner-local-ci: " + $sha + " \\S.*$"))
      | "\(.first)   — " + (.author.login // "unknown") ]
    | last // ""')"
  [ -n "$LOCAL_CI" ] \
    || die "'ci: none' waives CI on $HEAD_SHA, so what stood in for it has to be on the record:
  $GH pr comment $PR --body \"cc-tuner-local-ci: $HEAD_SHA <the command that ran, and what it returned>\""
  printf 'cc-tuner merge: no CI reported on %s; merging under a recorded waiver: %s\n' "$HEAD_SHA" "$CI_REASON" >&2
  printf 'cc-tuner merge: local verification claimed on the pull request: %s\n' "$LOCAL_CI" >&2
else
  [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null || die "no $CI_LABEL CI checks ran on $HEAD_SHA — absent CI is unproven CI. Make CI run on this commit, or correct the spec's 'ci:' mode to match how this repository verifies a candidate."
  BAD="$(printf '%s' "$CHECKS" | jq -r '[.[] | select(.bucket != "pass")] | length')"
  [ "${BAD:-1}" -eq 0 ] 2>/dev/null || die "$BAD of $TOTAL $CI_LABEL CI checks on $HEAD_SHA are not passing (pending counts as not passing: re-run when they finish)"
fi

# Movement during the checks above. Only --match-head-commit is atomic, and only for the head.
CURRENT_PRJSON="$("$GH" pr view "$PR" --json headRefOid,baseRefOid 2>/dev/null)" \
  || die "cannot re-read pull request '$PR' after the checks"
CURRENT_HEAD="$(printf '%s' "$CURRENT_PRJSON" | jq -r '.headRefOid // empty')"
CURRENT_BASE="$(printf '%s' "$CURRENT_PRJSON" | jq -r '.baseRefOid // empty')"
[ "$CURRENT_HEAD" = "$HEAD_SHA" ] && [ "$CURRENT_BASE" = "$BASE_OID" ] \
  || die "PR head or base changed while merge readiness was checked (head ${HEAD_SHA} -> ${CURRENT_HEAD:-?}, base ${BASE_OID} -> ${CURRENT_BASE:-?}); re-run against the current state"

[ -z "$CHECK_ONLY" ] || { printf 'would merge %s (--%s) at %s: review (%s), verdict, verification, CI (--ci %s) and head all check out\n' "$PR" "$STRATEGY" "$HEAD_SHA" "$REVIEW_MODE" "$CI_MODE"; exit 0; }

exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
