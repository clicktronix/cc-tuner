#!/usr/bin/env bash
# The only sanctioned way to merge a cc-tuner run.
#
#   merge.sh [--check-only] <pr> <squash|merge> <candidate-sha>
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
# `/run` calls this script directly. Raw CLI commands, the web button, the API and direct pushes are
# outside its boundary; trying to recognise every equivalent Bash program created bypasses and also
# blocked unrelated merges, so the global command-string hook was removed.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

GH="${CC_TUNER_GH:-gh}"

die() { printf 'cc-tuner merge: %s\n' "$1" >&2; exit 1; }

CHECK_ONLY=""
case "${1:-}" in --check-only) CHECK_ONLY=1; shift ;; esac

PR="${1:-}"; STRATEGY="${2:-}"; SHA="${3:-}"
[ -n "$PR" ] && [ -n "$STRATEGY" ] && [ -n "$SHA" ] \
  || die "usage: merge.sh [--check-only] <pr> <squash|merge> <candidate-sha>"
# squash and merge only, matching what a spec is allowed to declare. rebase was accepted here and by
# /run for one revision, offering a strategy no spec can ask for.
case "$STRATEGY" in squash|merge) ;; *) die "strategy must be squash or merge" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required to check the candidate"

# Every fact is re-read here, from GitHub, at merge time. Nothing is carried in from the caller except
# which PR and which SHA they believe they are merging — and both are checked against what GitHub says.
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

ME="$("$GH" api user --jq .login 2>/dev/null)" || die "cannot identify the authenticated GitHub account"

# One definition of the marker. The embedded SHA is the exact GitHub head, not a second broad
# 7-to-40-hex grammar that can disagree with the comparison below.
VERDICT="$(printf '%s' "$PRJSON" | jq -r --arg sha "$HEAD_SHA" --arg me "$ME" '
  [ .reviews[]? | select((.commit.oid // "") == $sha and (.author.login // "") == $me) ]
  | sort_by(.submittedAt) | last | .body // ""
  | if test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) " + $sha + "$") then . else "" end')"
case "$VERDICT" in
  "cc-tuner-verdict: APPROVE $HEAD_SHA") ;;
  "") die "no cc-tuner verdict from $ME on $HEAD_SHA — the candidate has not been reviewed at this commit" ;;
  *)  die "the latest cc-tuner verdict on $HEAD_SHA is not an approval: $VERDICT" ;;
esac

# --required, and zero checks is not green: an empty list satisfies "nothing failed" under any naive
# reading, and absent CI is unproven CI.
# `gh pr checks --required` does NOT return an empty list when the branch requires nothing: it exits
# non-zero and says "no checks reported" on stderr. runctl.sh has carried that knowledge, and a
# comment explaining it, since before this rewrite; reading only the exit status reports "cannot read
# CI" for a repository that simply has no branch protection, sending the operator to look for a
# failing check that does not exist.
CHECKS_ERR="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-checks.XXXXXX")" || die "cannot create a temporary file"
if ! CHECKS="$("$GH" pr checks "$PR" --required --json name,bucket 2>"$CHECKS_ERR")"; then
  if grep -q 'no checks reported' "$CHECKS_ERR"; then
    rm -f "$CHECKS_ERR"
    die "$PR has no required checks configured on GitHub — absent CI is unproven CI, so configure at least one required check"
  fi
  rm -f "$CHECKS_ERR"
  die "cannot read required CI checks for $HEAD_SHA"
fi
rm -f "$CHECKS_ERR"
TOTAL="$(printf '%s' "$CHECKS" | jq -r 'length // 0')"
[ "${TOTAL:-0}" -gt 0 ] 2>/dev/null || die "no required CI checks ran on $HEAD_SHA — absent CI is unproven CI"
BAD="$(printf '%s' "$CHECKS" | jq -r '[.[] | select(.bucket != "pass")] | length')"
[ "${BAD:-1}" -eq 0 ] 2>/dev/null || die "$BAD of $TOTAL required CI checks on $HEAD_SHA are not passing"

# --match-head-commit closes the window between the checks above and the merge itself, on GitHub's
# side, which nothing local can do.
# --check-only stops here, having proved the candidate would be accepted. The eval needs to observe
# the positive path without actually merging, and a check that can only be run by merging is one
# nobody will run twice.
[ -z "$CHECK_ONLY" ] || { printf 'would merge %s (--%s) at %s: verdict, required CI and head all check out\n' "$PR" "$STRATEGY" "$HEAD_SHA"; exit 0; }

exec "$GH" pr merge "$PR" --"$STRATEGY" --match-head-commit "$HEAD_SHA"
