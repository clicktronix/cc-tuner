#!/usr/bin/env bash
# The only sanctioned way to merge a cc-tuner run.
#
#   merge.sh <pr> <squash|merge|rebase> <candidate-sha>
#
# Why this exists, after three attempts at the other design: the guard used to read the agent's Bash
# command string and decide whether the merge inside it was attested. That cannot work. A shell
# command is a program, and every round of "better parsing" produced another form that ran a merge the
# guard had not seen — `bash -c`, `eval`, `/usr/local/bin/gh`, a line continuation, `G=gh; "$G" …`,
# `$(printf gh)`. There is no regex that ends that list.
#
# So the checking moved to where the inputs are arguments rather than text. This script takes the PR,
# the strategy and the SHA as three values, verifies them itself, and only then calls `gh`. Nothing
# has to guess what a string would have done.
#
# The guard's remaining job is much smaller and honestly bounded: deny a raw `gh pr merge` when it can
# see one, and say to use this. A raw merge it cannot see is in the same class as the merge button on
# github.com — a bypass this plugin does not claim to prevent.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

GH="${CC_TUNER_GH:-gh}"

die() { printf 'cc-tuner merge: %s\n' "$1" >&2; exit 1; }

PR="${1:-}"; STRATEGY="${2:-}"; SHA="${3:-}"
[ -n "$PR" ] && [ -n "$STRATEGY" ] && [ -n "$SHA" ] \
  || die "usage: merge.sh <pr> <squash|merge|rebase> <candidate-sha>"
case "$STRATEGY" in squash|merge|rebase) ;; *) die "strategy must be squash, merge or rebase" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required to check the candidate"

# Every fact is re-read here, from GitHub, at merge time. Nothing is carried in from the caller except
# which PR and which SHA they believe they are merging — and both are checked against what GitHub says.
PRJSON="$($GH pr view "$PR" --json number,headRefOid,files 2>/dev/null)" \
  || die "cannot resolve pull request '$PR'"

HEAD_SHA="$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty')"
[ -n "$HEAD_SHA" ] || die "pull request $PR reports no head commit"
[ "$HEAD_SHA" = "$SHA" ] \
  || die "the head of $PR is $HEAD_SHA, not the $SHA you asked to merge — the branch moved"

IN_SCOPE="$(printf '%s' "$PRJSON" | jq -r '
  if (.files | type) != "array" then "unknown"
  elif any(.files[]; .path // .filename | test("^(docs|wiki)/task-plans/.*\\.md$")) then "yes"
  else "no" end')"
[ "$IN_SCOPE" = "yes" ] || die "$PR is not a cc-tuner run (no plan file in its diff); merge it yourself"

ME="$($GH api user --jq .login 2>/dev/null)" || die "cannot identify the authenticated GitHub account"
REVIEWS="$($GH pr view "$PR" --json reviews 2>/dev/null)" || die "cannot read reviews for $PR"

VERDICT="$(printf '%s' "$REVIEWS" | jq -r --arg sha "$HEAD_SHA" --arg me "$ME" '
  [ .reviews[]? | select((.commit.oid // "") == $sha and (.author.login // "") == $me) ]
  | sort_by(.submittedAt) | last | .body // ""
  | if test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) [0-9a-f]{7,40}$") then . else "" end')"
case "$VERDICT" in
  "cc-tuner-verdict: APPROVE $HEAD_SHA") ;;
  "") die "no cc-tuner verdict from $ME on $HEAD_SHA — the candidate has not been reviewed at this commit" ;;
  *)  die "the latest cc-tuner verdict on $HEAD_SHA is not an approval: $VERDICT" ;;
esac

# --required, and zero checks is not green: an empty list satisfies "nothing failed" under any naive
# reading, and absent CI is unproven CI.
CHECKS="$($GH pr checks "$PR" --required --json name,bucket 2>/dev/null)" \
  || die "cannot read required CI checks for $HEAD_SHA"
TOTAL="$(printf '%s' "$CHECKS" | jq -r 'length // 0')"
[ "${TOTAL:-0}" -gt 0 ] 2>/dev/null || die "no required CI checks ran on $HEAD_SHA — absent CI is unproven CI"
BAD="$(printf '%s' "$CHECKS" | jq -r '[.[] | select(.bucket != "pass")] | length')"
[ "${BAD:-1}" -eq 0 ] 2>/dev/null || die "$BAD of $TOTAL required CI checks on $HEAD_SHA are not passing"

# --match-head-commit closes the window between the checks above and the merge itself, on GitHub's
# side, which nothing local can do.
exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
