#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)"
J="$DIR/journal.sh"; P="$DIR/preflight.sh"
fails=0

T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
( cd "$T" && git init -q && git config user.email a@b.c \
  && git config user.name t && echo x > f && git add f && git commit -qm init ) \
  || { echo "FATAL: fixture setup failed"; exit 1; }
CLAUDE_PROJECT_DIR="$T" bash "$P" run1 main >/dev/null 2>&1

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

# truncation must be announced -- a silently clipped journal reads as a complete one
printf '%s' "$OUT" | grep -q 'entries omitted' \
  && echo "PASS resume-announces-truncation" || { echo "FAIL resume-announces-truncation (out=$OUT)"; fails=1; }

# a full-length resume omits nothing and says nothing about omitting
OUT="$(CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 500 2>&1)"
{ printf '%s' "$OUT" | grep -q 'entry 1' && ! printf '%s' "$OUT" | grep -q 'entries omitted'; } \
  && echo "PASS resume-full" || { echo "FAIL resume-full (out=$OUT)"; fails=1; }

# a non-numeric line count is rejected rather than silently treated as a default
CLAUDE_PROJECT_DIR="$T" bash "$J" resume run1 banana >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS resume-bad-count" || { echo "FAIL resume-bad-count (rc=$rc, want 1)"; fails=1; }

# unknown subcommand still rejected
CLAUDE_PROJECT_DIR="$T" bash "$J" frobnicate run1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS unknown-subcommand" || { echo "FAIL unknown-subcommand (rc=$rc)"; fails=1; }
rm -rf "$T"
exit $fails
