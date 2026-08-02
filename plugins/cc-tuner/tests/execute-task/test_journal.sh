#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
J="$DIR/journal.sh"; P="$DIR/preflight.sh"
fails=0

T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
( cd "$T" && git init -q -b main && git config user.email a@b.c \
  && git config user.name t && echo x > f && git add f && git commit -qm init \
  && git switch -qc task ) \
  || { echo "FATAL: fixture setup failed"; exit 1; }
CLAUDE_PROJECT_DIR="$T" bash "$P" run1 main --expected-branch task >/dev/null 2>&1

# path
[ "$(CLAUDE_PROJECT_DIR="$T" bash "$J" path run1)" = ".claude/execute-task-runs/run1.md" ] \
  && echo "PASS path" || { echo "FAIL path"; fails=1; }
# append adds a line
CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 "step 2 APPROVE r3" >/dev/null 2>&1
grep -q "step 2 APPROVE r3" "$T/.claude/execute-task-runs/run1.md" \
  && echo "PASS append" || { echo "FAIL append"; fails=1; }
# append with NO message -> rejected (exit exactly 1), no blank bullet written
before="$(wc -l < "$T/.claude/execute-task-runs/run1.md")"
CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 >/dev/null 2>&1; rc=$?
after="$(wc -l < "$T/.claude/execute-task-runs/run1.md")"
{ [ "$rc" -eq 1 ] && [ "$before" = "$after" ]; } \
  && echo "PASS append-empty-rejected" || { echo "FAIL append-empty-rejected (rc=$rc, lines $before->$after)"; fails=1; }
# append to missing journal -> exit exactly 1
CLAUDE_PROJECT_DIR="$T" bash "$J" append nope "x" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS append-missing" || { echo "FAIL append-missing (rc=$rc, want 1)"; fails=1; }

# --- read / resume: the whole point is getting progress BACK after a compaction ---
# read returns the header AND the log entries
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" read run1 2>&1)"
{ printf '%s' "$OUT" | grep -q 'base SHA' && printf '%s' "$OUT" | grep -q 'step 2 APPROVE r3'; } \
  && echo "PASS read" || { echo "FAIL read (out=$OUT)"; fails=1; }

# read on a missing journal is an ERROR, not empty output -- "nothing recorded" and
# "could not find the record" must not be indistinguishable to the caller.
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" read nope 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$OUT" ]; } \
  && echo "PASS read-missing-errors" || { echo "FAIL read-missing-errors (rc=$rc out=$OUT)"; fails=1; }

# resume keeps the header (base SHA / target -- what stops a resumed run rebasing
# onto the wrong thing) and bounds the log tail
for i in 1 2 3 4 5 6 7 8; do CLAUDE_PROJECT_DIR="$T" bash "$J" append run1 "entry $i" >/dev/null 2>&1; done
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 3 2>&1)"
{ printf '%s' "$OUT" | grep -q 'base SHA' \
  && printf '%s' "$OUT" | grep -q 'entry 8' \
  && printf '%s' "$OUT" | grep -q 'entry 6' \
  && ! printf '%s' "$OUT" | grep -q 'entry 5'; } \
  && echo "PASS resume-bounded" || { echo "FAIL resume-bounded (out=$OUT)"; fails=1; }

# truncation must be announced -- a silently clipped journal reads as a complete one.
# "lines", not "entries": the count is grep -c '' over the log region, so blanks and
# '## restarted:' markers are included. It is an upper bound, and says so.
printf '%s' "$OUT" | grep -q 'lines omitted' \
  && echo "PASS resume-announces-truncation" || { echo "FAIL resume-announces-truncation (out=$OUT)"; fails=1; }

# a full-length resume omits nothing and says nothing about omitting
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 500 2>&1)"
{ printf '%s' "$OUT" | grep -q 'entry 1' && ! printf '%s' "$OUT" | grep -q 'omitted'; } \
  && echo "PASS resume-full" || { echo "FAIL resume-full (out=$OUT)"; fails=1; }

# a non-numeric line count is rejected rather than silently treated as a default
CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 banana >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS resume-bad-count" || { echo "FAIL resume-bad-count (rc=$rc, want 1)"; fails=1; }

# unknown subcommand still rejected
CLAUDE_PROJECT_DIR="$T" bash "$J" frobnicate run1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS unknown-subcommand" || { echo "FAIL unknown-subcommand (rc=$rc)"; fails=1; }

# a successful resume must EXIT 0. Exit codes are a contract here (preflight 2 = dirty tree,
# guard 3 = artifacts), so a success path reporting failure corrupts a real signal.
CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && echo "PASS resume-exit-zero" || { echo "FAIL resume-exit-zero (rc=$rc)"; fails=1; }

# n=0 is accepted by the validator, so it must also succeed: header only, no log, exit 0
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 0 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'base SHA' && ! printf '%s' "$OUT" | grep -q 'entry 8'; } \
  && echo "PASS resume-zero-succeeds" || { echo "FAIL resume-zero-succeeds (rc=$rc out=$OUT)"; fails=1; }

# an n too large for `[` to compare must still print the log, not drop it
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 999999999999999999999 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'entry 8'; } \
  && echo "PASS resume-huge-n-clamped" || { echo "FAIL resume-huge-n-clamped (rc=$rc out=$OUT)"; fails=1; }

# a journal with no '## log' marker must stay BOUNDED — the sed range would otherwise run to
# EOF and print the whole file, breaking the promise that resume is safe to call every phase
CLAUDE_PROJECT_DIR="$T" bash "$P" nomarker main --expected-branch task >/dev/null 2>&1
printf 'a\nb\nc\nd\ne\nf\n' > "$T/.claude/execute-task-runs/nomarker.md"
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume nomarker 2 2>&1)"
{ printf '%s' "$OUT" | grep -q '^f$' && ! printf '%s' "$OUT" | grep -q '^a$'; } \
  && echo "PASS resume-no-marker-bounded" || { echo "FAIL resume-no-marker-bounded (out=$OUT)"; fails=1; }

# a symlinked journal must not be followed outside the project
CLAUDE_PROJECT_DIR="$T" bash "$P" linked main --expected-branch task >/dev/null 2>&1
OUTSIDE="$(mktemp)" || exit 1
rm "$T/.claude/execute-task-runs/linked.md"
ln -s "$OUTSIDE" "$T/.claude/execute-task-runs/linked.md"
CLAUDE_PROJECT_DIR="$T" bash "$J" append linked "escape" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$OUTSIDE" ] \
  && echo "PASS symlinked-journal-rejected" || { echo "FAIL symlinked-journal-rejected (rc=$rc)"; fails=1; }
rm -f "$OUTSIDE"

# THE resume case: a restarted run. preflight appends '## restarted: ... base <NEW SHA>' into the
# log region, so the header still shows the ORIGINAL base SHA. resume must surface the current one
# or a resumed run rebases onto the base of the first run -- the exact mistake the header prevents.
( cd "$T" && echo second > f2 && git add f2 && git commit -qm second ) >/dev/null 2>&1
NEWSHA="$( cd "$T" && git rev-parse HEAD )"
CLAUDE_PROJECT_DIR="$T" bash "$P" run1 main --expected-branch task >/dev/null 2>&1
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 1 2>&1)"
{ printf '%s' "$OUT" | grep -q "$NEWSHA" && printf '%s' "$OUT" | grep -q 'supersedes'; } \
  && echo "PASS resume-surfaces-restart-base" || { echo "FAIL resume-surfaces-restart-base (want $NEWSHA in: $OUT)"; fails=1; }

# Every state-consuming operation revalidates branch ownership, not only preflight.
(cd "$T" && git switch -qc other)
cross_branch_ok=1
for operation in "append run1 cross-branch" "read run1" "resume run1"; do
  # shellcheck disable=SC2086
  CLAUDE_PROJECT_DIR="$T" bash "$J" $operation >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || cross_branch_ok=0
done
if [ "$cross_branch_ok" -eq 1 ]; then
  echo "PASS cross-branch-journal-operations-rejected"
else
  echo "FAIL cross-branch-journal-operations-rejected"
  fails=1
fi
rm -rf "$T"
exit $fails
