#!/usr/bin/env bash
# PreToolUse: send merges through scripts/merge.sh, which is the thing that actually checks them.
#
# This hook does NOT decide whether a merge is attested. It used to, by reading the agent's Bash
# command and judging the merge it thought it saw, and that design failed three times running: every
# round of better parsing produced another form that ran a merge the guard never inspected —
# `bash -c '…'`, `eval '…'`, `/usr/local/bin/gh`, a line continuation between `pr` and `merge`,
# `G=gh; "$G" pr merge`, `$(printf gh) pr merge`. A shell command is a program; a hook that reads it
# as a string is guessing, and the list of forms it guesses wrong about has no end.
#
# So verification moved to `scripts/merge.sh`, where the PR, the strategy and the SHA arrive as
# arguments rather than as text. What is left here is one narrow rule: if this command looks like a
# raw `gh pr merge`, refuse it and name the script that does the checking.
#
# WHAT THIS DOES NOT COVER, stated plainly because a guardrail described as more than it is, is worse
# than none:
#   - A raw merge written in a form this cannot recognise. That is a bypass of the same class as the
#     merge button on github.com, `git push` to the target, and the REST API — none of which any local
#     hook sees either. The difference from before is that it is no longer pretending the checking
#     happens here.
#   - A pull request whose plan file was committed and then deleted before merging falls outside
#     `merge.sh`'s scope check. Recorded there.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

deny() {  # deny <reason> -- built by hand so this works with or without jq
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cc-tuner: %s"}}' "$1"
  exit 0
}

INPUT="$(cat)"

# Registered for Bash only, so without jq refusing is honest rather than guessing at the payload.
command -v jq >/dev/null 2>&1 || deny "jq is not installed, so no Bash command can be checked"

[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')" = "Bash" ] || exit 0
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"

# No exception for merge.sh, deliberately. A `bash .../merge.sh 42 squash <sha>` call contains no
# "pr merge" and never reaches the rule below, so the exception bought nothing — and it let anything
# through that merely mentioned the path:
#     echo scripts/merge.sh; gh pr merge 42 --squash
#     gh pr merge 42 --squash # scripts/merge.sh
# A special case that is unnecessary and exploitable is only exploitable.

# Otherwise: does this look like a raw merge? Newlines and backslash continuations are flattened
# first, because `gh pr \<newline> merge` is one command to bash and was two lines to an earlier
# version of this file. Quotes are stripped so `"$G"` and `'gh'` read the same. This is deliberately
# broad and one-directional: it can only over-refuse, and over-refusing costs a redirection to
# merge.sh rather than an unchecked merge.
NORM="$(printf '%s' "$CMD" | tr '\n\t' '  ' | sed 's/\\ */ /g' | tr -d '"'\''`' | sed 's/  */ /g')"
case "$NORM" in
  *"pr merge"*)
    deny "merges go through scripts/merge.sh <pr> <squash|merge> <candidate-sha>. On a cc-tuner run it checks the verdict, required CI and the head SHA first; on any other pull request it merges straight through, so this is also how you merge something unrelated"
    ;;
esac

exit 0
