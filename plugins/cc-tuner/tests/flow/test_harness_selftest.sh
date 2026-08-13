#!/usr/bin/env bash
# Proves the flow harness can report a failure.
#
# This is the one test that has to exist before any other test in this tier is worth writing. The
# defect this branch was opened against was not a wrong assertion -- it was 82 assertions that could
# not fail while the product did not work. "All tests passed" and "nothing was actually checked" print
# the same thing. So: build a deliberately failing test, run it, and require the harness to notice.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# hard_require exists because everything else here would be circular without it.
#
# The first mutation run proved the point: deleting `fails=1` from `fail()` left this suite exiting 0.
# The tier had lost the ability to report anything, and the test for that ability could not say so --
# because it reported through the function that was broken. So the assertions that establish the
# harness can fail do NOT route through `fail`; they print and exit here, on their own.
hard_require() { # hard_require <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'PASS %s\n' "$1"
  else
    printf 'FAIL %s (want %s, got %s) -- the harness cannot report failures; every other\n' "$1" "$2" "$3"
    printf '     PASS in this tier is meaningless until this is fixed\n'
    exit 1
  fi
}

# --- 1. a failing assertion is reported, and it sets a non-zero exit ------------------------------
# Written to a temp file and run in its own bash, because the point is to observe the harness's
# externally visible behaviour -- output and exit code -- not to call `fail` in this shell.
W="$(flow_workdir)"
cat > "$W/test_deliberate_failure.sh" <<EOF
set -u
. "$FLOW_LIB_DIR/lib.sh"
equals "must-fail" "expected" "actual"
exit \$fails
EOF
OUT="$(bash "$W/test_deliberate_failure.sh" 2>&1)"; RC=$?
case "$OUT" in
  *"FAIL must-fail"*) hard_require "failing-test-prints-FAIL" "found" "found" ;;
  *) hard_require "failing-test-prints-FAIL" "found" "absent: $OUT" ;;
esac
hard_require "failing-test-exits-nonzero" "1" "$RC"

# The mirror. Without it, a harness hard-wired to fail would pass the check above.
cat > "$W/test_deliberate_pass.sh" <<EOF
set -u
. "$FLOW_LIB_DIR/lib.sh"
equals "must-pass" "same" "same"
exit \$fails
EOF
OUT="$(bash "$W/test_deliberate_pass.sh" 2>&1)"; RC=$?
check  "passing-test-prints-PASS" "PASS must-pass" "$OUT"
absent "passing-test-prints-no-FAIL" "FAIL" "$OUT"
equals "passing-test-exits-zero" "0" "$RC"

# --- 2. two work directories are two directories --------------------------------------------------
# The first version numbered them with a counter incremented inside the function. Callers invoke it
# through `$(...)`, so the increment died in the subshell and every call handed back the same path --
# which surfaced as the second flow_repo trying to git init over the first, several tests later.
A="$(flow_workdir)"; B="$(flow_workdir)"
if [ "$A" != "$B" ]; then pass "workdirs-are-distinct"; else fail "workdirs-are-distinct (both $A)"; fi

# Two repositories in a row, because that is the shape that broke: the failure was not in flow_repo.
R1="$(flow_repo)"; R2="$(flow_repo)"
if [ "$R1" != "$R2" ] && [ -d "$R1/.git" ] && [ -d "$R2/.git" ]; then
  pass "two-repos-are-independent"
else
  fail "two-repos-are-independent (r1=$R1 r2=$R2)"
fi

# --- 3. the repository builder produces something git will answer questions about -----------------
R="$(flow_repo)"
equals "repo-is-a-worktree" "true" "$(cd "$R" && git rev-parse --is-inside-work-tree 2>&1)"
# A repo with no commit has no HEAD, and the merge guard resolves ranges against one.
if (cd "$R" && git rev-parse --verify -q HEAD >/dev/null); then
  pass "repo-has-a-commit"
else
  fail "repo-has-a-commit (HEAD does not resolve)"
fi

# --- 3. fixtures are real payloads and still carry the fields later tasks read --------------------
# These were captured from a live session during the spike, then scrubbed of local paths. A fixture
# invented from the documentation would only ever prove that the documentation was read.
P="$(flow_payload pretooluse-bash)"
equals "bash-fixture-event"   "PreToolUse" "$(printf '%s' "$P" | jq -r '.hook_event_name')"
equals "bash-fixture-tool"    "Bash"       "$(printf '%s' "$P" | jq -r '.tool_name')"
equals "bash-fixture-command" "string"     "$(printf '%s' "$P" | jq -r '.tool_input.command | type')"

S="$(flow_payload sessionstart)"
equals "session-fixture-event"  "SessionStart" "$(printf '%s' "$S" | jq -r '.hook_event_name')"
equals "session-fixture-source" "string"       "$(printf '%s' "$S" | jq -r '.source | type')"

# The payload transform is what every later test uses to build its case from one captured fixture.
M="$(flow_payload pretooluse-bash '.tool_input.command = "gh pr merge 42 --squash"')"
equals "payload-override" "gh pr merge 42 --squash" "$(printf '%s' "$M" | jq -r '.tool_input.command')"

# --- 4. a hook runner reports stdout and exit code, without losing either -------------------------
cat > "$W/hook.sh" <<'EOF'
IN="$(cat)"
printf 'saw:%s\n' "$(printf '%s' "$IN" | jq -r '.tool_name')"
exit 2
EOF
OUT="$(flow_hook "$W/hook.sh" "$P")"
check "hook-stdout-survives" "saw:Bash" "$OUT"
check "hook-rc-survives"     "rc=2"     "$OUT"

exit $fails
