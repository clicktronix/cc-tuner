#!/usr/bin/env bash
# merge-guard.sh: refuse a raw `gh pr merge` and point at scripts/merge.sh.
#
# The guard no longer decides whether a merge is attested -- merge.sh does, and test_merge.sh asserts
# that. What is tested here is narrower and one-directional: the raw forms are refused, the sanctioned
# path is not, and unrelated commands are untouched.
#
# The forms below are not hypothetical. Each one ran a merge past an earlier revision of this hook
# while it believed it had checked one.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GUARD="$FLOW_PLUGIN/hooks/merge-guard.sh"

fire() {
  jq -c --arg c "$1" '.tool_input.command = $c' "$FLOW_FIXTURES/pretooluse-bash.json" \
    | bash "$GUARD" 2>/dev/null
}
verdict_of() { [ -n "$1" ] || { printf 'allow'; return; }
               printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; }
decision() { verdict_of "$(fire "$1")"; }

# --- the sanctioned path is not obstructed --------------------------------------------------------
# Asserted first: a guard that refused everything would pass every other case in this file.
equals "sanctioned-merge-allowed" "allow" \
  "$(decision 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" 42 squash abc1234def')"
equals "sanctioned-merge-silent" "" \
  "$(fire 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" 42 squash abc1234def')"

# Not because the path is whitelisted -- there is no exception for it. An earlier revision had one,
# and it let anything through that merely mentioned the path.
equals "mentioning-the-script-does-not-excuse-a-raw-merge" "deny" \
  "$(decision 'echo scripts/merge.sh; gh pr merge 42 --squash')"
equals "the-path-in-a-comment-does-not-either" "deny" \
  "$(decision 'gh pr merge 42 --squash # scripts/merge.sh')"

# --- everything else that runs a merge ------------------------------------------------------------
for form in \
  'gh pr merge 42 --squash' \
  '/usr/local/bin/gh pr merge 42 --squash' \
  'bash -c "gh pr merge 42 --squash"' \
  'eval "gh pr merge 42 --squash"' \
  'G=gh; "$G" pr merge 42 --squash' \
  '$(printf gh) pr merge 42 --squash' \
  'gh  pr   merge 42 --squash' \
  'gh pr merge 42 --squash && gh pr merge 99 --squash' \
  'gh pr merge 42 --squash $(gh pr merge 99 --squash)' \
  'gh pr merge 42 --squash --match-head-commit abc1234def'
do
  equals "refused: $form" "deny" "$(decision "$form")"
done

# A line continuation is one command to bash and was two lines to an earlier version of this hook.
equals "refused: line continuation" "deny" "$(decision 'gh pr \
merge 42 --squash')"

check "refusal-names-the-script" "scripts/merge.sh" \
  "$(fire 'gh pr merge 42' | jq -r '.hookSpecificOutput.permissionDecisionReason')"

# --- and nothing else -----------------------------------------------------------------------------
equals "git-status-allowed"    "allow" "$(decision 'git status')"
equals "git-merge-allowed"     "allow" "$(decision 'git merge main')"
equals "gh-pr-view-allowed"    "allow" "$(decision 'gh pr view 42')"
equals "non-bash-tool-allowed" "allow" \
  "$(verdict_of "$(jq -c '.tool_name = "Read"' "$FLOW_FIXTURES/pretooluse-bash.json" | bash "$GUARD" 2>/dev/null)")"

# --- without jq there is no check, so there is no merge -------------------------------------------
NOJQ="$(flow_workdir)"; mkdir -p "$NOJQ/bin"
for u in bash cat sed tr; do ln -sf "$(command -v $u)" "$NOJQ/bin/$u" 2>/dev/null; done
jq -c '.tool_input.command = "gh pr merge 42 --squash"' "$FLOW_FIXTURES/pretooluse-bash.json" > "$NOJQ/p.json"
NOJQ_OUT="$(PATH="$NOJQ/bin" bash "$GUARD" < "$NOJQ/p.json" 2>/dev/null)"
check "no-jq-denies"   '"permissionDecision":"deny"' "$NOJQ_OUT"
check "no-jq-says-why" 'jq is not installed'         "$NOJQ_OUT"

# The fallback cannot parse JSON, so it must not depend on how the JSON is spaced or escaped.
printf '%s' '{"tool_name" : "Bash", "tool_input" : {"command" : "gh pr merge 42"}}' > "$NOJQ/spaced.json"
check "no-jq-ignores-json-shape" '"permissionDecision":"deny"' \
  "$(PATH="$NOJQ/bin" bash "$GUARD" < "$NOJQ/spaced.json" 2>/dev/null)"

exit $fails
