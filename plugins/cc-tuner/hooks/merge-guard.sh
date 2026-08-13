#!/usr/bin/env bash
# PreToolUse: refuse `gh pr merge` on a cc-tuner run whose candidate is not attested.
#
# The one fail-closed gate. Everything else in this plugin advises; this denies.
#
# Registered globally, and it scopes itself: it has an opinion only on `gh pr merge`, and only when
# the target pull request carries a cc-tuner plan file. Outside that it allows and says nothing —
# installing this plugin must not seize the user's ordinary merges. Inside it, every missing fact
# denies, and the reason names which one. 0.10.0's gates allowed whenever their state file was
# absent, which is how a plugin full of guards shipped with none of them working.
#
# WHAT IT DOES NOT COVER, stated here because a guardrail described as more than it is, is worse than
# none:
#   - The merge button on github.com, `git push` to the target, and the REST API all bypass any local
#     hook entirely.
#   - Scope is the pull request's net diff. A run that commits its plan and then deletes it in the
#     same PR leaves scope. Detecting that needs either one API call per commit on every merge
#     attempt, or fetch refs written into the user's repository from a hook — real cost to close an
#     adversarial hole in a tool whose threat model is an agent's mistake, while the three bypasses
#     above stay open.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

GH="${CC_TUNER_GH:-gh}"

allow() { exit 0; }   # silence is the common case: this fires on every Bash call in every repo

deny() {  # deny <reason>
  jq -n --arg r "cc-tuner: $1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

command -v jq >/dev/null 2>&1 || allow

INPUT="$(cat)"
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')" = "Bash" ] || allow
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
case "$CMD" in *"gh pr merge"*) ;; *) allow ;; esac

# The pull request named in the command, never the checked-out branch: `gh pr merge` takes a number,
# a URL or a branch, and any of them may name a PR that is not the one in the working tree. Deriving
# this from HEAD would let `gh pr merge 42` sail through while the guard inspected branch 7.
TARGET="$(printf '%s' "$CMD" | awk '
  { for (i = 1; i <= NF; i++) if ($i == "merge" && $(i-1) == "pr") { start = i + 1; break } }
  { for (i = start; i <= NF; i++) if (start && substr($i, 1, 1) != "-") { print $i; exit } }
')"

PR="$($GH pr view ${TARGET:+"$TARGET"} --json number,headRefOid,files 2>/dev/null)" \
  || deny "cannot resolve the pull request for '${TARGET:-the current branch}', so its candidate cannot be checked"

HEAD_SHA="$(printf '%s' "$PR" | jq -r '.headRefOid // empty')"
[ -n "$HEAD_SHA" ] || deny "the pull request reports no head commit"

# Scope. Failing to DETERMINE scope is not the same as being out of scope, and denies.
IN_SCOPE="$(printf '%s' "$PR" | jq -r '
  if (.files | type) != "array" then "unknown"
  elif any(.files[]; .path // .filename | test("^docs/plans/.*\\.md$")) then "yes"
  else "no" end')"
case "$IN_SCOPE" in
  no)      allow ;;
  unknown) deny "cannot tell whether this pull request is a cc-tuner run" ;;
esac

# One verdict review, on the exact head, from the account that would have posted it. Latest per
# author: reviews accumulate, and counting rows instead of authors passes a superseded approval.
ME="$($GH api user --jq .login 2>/dev/null)" || deny "cannot identify the authenticated GitHub account"
REVIEWS="$($GH pr view ${TARGET:+"$TARGET"} --json reviews 2>/dev/null)" \
  || deny "cannot read the pull request's reviews"

VERDICT="$(printf '%s' "$REVIEWS" | jq -r --arg sha "$HEAD_SHA" --arg me "$ME" '
  [ .reviews[]? | select((.commit.oid // "") == $sha and (.author.login // "") == $me) ]
  | sort_by(.submittedAt) | last | .body // ""
  | if test("^cc-tuner-verdict: (APPROVE|REQUEST_CHANGES) [0-9a-f]{7,40}$") then . else "" end')"

case "$VERDICT" in
  "cc-tuner-verdict: APPROVE $HEAD_SHA") ;;
  "") deny "no cc-tuner verdict from $ME on $HEAD_SHA — the candidate has not been reviewed at this commit" ;;
  *)  deny "the latest cc-tuner verdict on $HEAD_SHA is not an approval: $VERDICT" ;;
esac

# CI on that same commit. Zero checks is not green: an empty list satisfies "nothing failed" under
# any naive reading, and absent CI is unproven CI.
CHECKS="$($GH pr checks ${TARGET:+"$TARGET"} --json name,bucket 2>/dev/null)" \
  || deny "cannot read CI checks for $HEAD_SHA"
TOTAL="$(printf '%s' "$CHECKS" | jq -r 'length // 0')"
[ "${TOTAL:-0}" -gt 0 ] 2>/dev/null || deny "no CI checks ran on $HEAD_SHA — absent CI is unproven CI"
BAD="$(printf '%s' "$CHECKS" | jq -r '[.[] | select(.bucket != "pass")] | length')"
[ "${BAD:-1}" -eq 0 ] 2>/dev/null || deny "$BAD of $TOTAL CI checks on $HEAD_SHA are not passing"

# The head can move between this check and the merge. --match-head-commit closes that window on
# GitHub's side, which no local check can do.
case "$CMD" in
  *"--match-head-commit $HEAD_SHA"*) ;;
  *) deny "run it as: gh pr merge ... --match-head-commit $HEAD_SHA — without it the head can move between this check and the merge" ;;
esac

allow
