#!/usr/bin/env bash
# One mutation, graded by a program instead of by the agent's account of it.
#
#   mutate.sh <file> <test-command> <mutation-command> [syntax-command]
#
# The mutation command edits <file> however it likes ($MUTATE_FILE holds the path). This script owns
# the parts that went wrong when live runs did it by hand, and every refusal below was a false
# KILLED or a false SURVIVED that something actually produced:
#
#   * the test must be GREEN before the mutation, or a red suite grades every mutant as killed;
#   * a test that was killed or never ran (signal, timeout, missing command) is not a test the
#     mutant failed, and the reserved exit codes for that are refused rather than graded;
#   * every kill is confirmed by re-running the test on the RESTORED file: red there too means
#     something other than the mutant is breaking it, and no text match can establish that;
#   * the mutation command must exit 0 and change the file — a half-applied patch that errors out is
#     not a mutant, and a patch that no-ops and then "survives" is the defect that started this;
#   * the mutant must parse, and if this cannot tell whether it parses it refuses rather than
#     guessing: a file that no longer parses fails every test and proves only that broken files fail;
#   * Python baseline and mutant tests use separate bytecode-cache directories, so a same-size,
#     same-mtime edit cannot be hidden by an existing .pyc;
#   * the file comes back byte-identical AND mode-identical, and if it cannot, the backup is kept.
#
# Exit: 0 KILLED (the test was green and the mutant turned it red), 1 SURVIVED (green either way, so
# the guard does not bite), 2 nothing was proved — and the line says which of the above it was.
#
# WHAT THIS DEFENDS AGAINST, and what it does not. It exists to stop a mutation run reporting a result
# it did not earn: no baseline, an ignored exit code, a patch that no-opped, an unchecked mutant, a
# lost original. The mutation command is written by whoever runs it, in the same session as the test
# command -- it is careless, not hostile. Where a careless command could quietly change something
# outside its own subject (a symlink, a second hard link, a planted staging path) this refuses rather
# than proceeds, because refusing is a line of code. It is not a sandbox and does not try to be one:
# a command that means harm has a hundred routes this cannot see, and chasing them would grow the
# script past the defect it was written to remove.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

# Once a backup exists, every exit path has to go through restore. `die` did not, so an unrelated
# failure after the mutation -- a mktemp for the Python cache, a log file -- left the mutant in the
# working file and the original only in the backup, and the next run then refused to start because that
# backup was in the way. `restore` is a no-op when there is nothing to put back.
BACKUP_LIVE=""
die() {
  printf 'mutate: %s\n' "$1" >&2
  [ -z "$BACKUP_LIVE" ] || restore
  exit 2
}

usage() {
  cat <<'USAGE'
usage: mutate.sh [--expect <ere>] <file> <test-command> <mutation-command> [syntax-command]

  <file>              the file to mutate; restored byte- and mode-identical before this exits
  <test-command>      must pass BEFORE the mutation, and is what the mutant has to break
  <mutation-command>  arbitrary shell; $MUTATE_FILE is the file; must exit 0 and change it
  [syntax-command]    how to check the mutant parses. Inferred for .sh/.py/.json when the checker
                      is installed; required otherwise, because an unchecked mutant that fails the
                      test is indistinguishable from a broken file that fails everything.
  --expect <ere>      an OPTIONAL extra filter on what the killed test says. It is not the proof and
                      cannot be: a traceback echoes the failing source line, so the text you are
                      matching appears even on a run where the assertion never executed. A KILLED
                      verdict is earned by the control run below, not by this.

Every KILLED is confirmed by a CONTROL RUN: the file is restored and the same test runs again. It costs
a third run of the test command, on the KILLED path only, and both runs' full logs are kept with their
paths printed.

WHAT KILLED CLAIMS, EXACTLY: green on the original, red with the mutant, green again on the original.
Nothing more. Exit 1 is what a suite returns for a failed assertion and for a fixture that could not
reach its database alike, and the control separates them **when the breakage persists** — which is the
case that used to grade every mutant as killed.

WHAT IT CANNOT CLAIM: that a failure occurring only during the mutant run, and clearing before the
control, was caused by the mutant. A flaky test, a service that blipped, a port that was briefly taken
produce exactly this shape, and no generic helper can tell them apart from a kill — the runs are
sequential, so the environment is a variable alongside the mutant. This is the known limit of mutation
testing over flaky tests, not a gap this script can close. Read the mutant log: it is printed for
precisely this reason, and it is where a ConnectionError is visible and an assertion message is not.

Refuses before touching anything, because restoring puts a fresh inode at the path:
  * a symlink, dangling or not, a hard-linked file, a directory — the path must be a plain file with
    one name, or "put it back" cannot be checked afterwards;
  * a <file>.premutation that already exists, including a symlink parked there;
  * this script itself, since bash re-reads a running script as it goes.
If a restore cannot finish, the original is left at <file>.premutation and this says so — the backup
is deleted only after the file is verified back to a regular file with the original bytes and mode,
and the staging copy is made with mktemp so nothing can pre-empt its path.

Scope: the mutation command is careless, not hostile — written by whoever runs this, in the same
session as the test command. The refusals above stop carelessness reaching past the subject. This is
not a sandbox and does not try to be one.

Python subprocesses in the baseline and mutant test commands get separate fresh bytecode-cache
directories. Existing or same-mtime .pyc files therefore cannot hide the source being graded.

Prints one ledger line — paste it, do not retype it.
  KILLED     exit 0   green, then red with the mutant, then green again: the guard bites, unless the
                      environment failed only during the mutant run — read the log to rule that out
  SURVIVED   exit 1   green before and after: nothing in the suite covers this behaviour
  BASELINE   exit 2   the test was already failing, so no mutant could have been graded
  MUTATION   exit 2   the mutation command failed or left the file byte-identical
  SYNTAX     exit 2   the mutant does not parse, or nothing here can tell whether it does
  NOTRUN     exit 2   the test was killed or never ran (signal, timeout, missing or non-executable
                      command) rather than failed: grading that KILLED credits the mutant with a red
                      suite something else produced
  NOTPROVED  exit 2   the test is red on the RESTORED file too, so something other than the mutant is
                      breaking it and the kill was not earned
  UNEXPECTED exit 2   the mutant did break the test, but not with the text --expect named
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
# `--expect <ere>` is how the caller says WHY the test should go red. Without it, an exit status of 1
# is all this can read, and 1 is what a suite returns whether an assertion fired or a fixture could
# not reach the database -- an environment failure in setUp reads exactly like a killed mutant. The
# reserved codes above catch a test that never ran; only the caller knows what a correctly killed test
# says. So the mutant's output is always shown, and matched when a pattern is given.
EXPECT=""
if [ "${1:-}" = "--expect" ]; then
  [ -n "${2:-}" ] || { printf 'mutate: --expect needs a pattern\n' >&2; exit 2; }
  EXPECT="$2"; shift 2
fi
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
FILE="$1"; TEST_CMD="$2"; MUT_CMD="$3"; SYNTAX_CMD="${4:-}"
# One precondition where there were five. Restoring puts a *fresh inode* at this path, so the path has
# to be a plain file with a single name: a symlink (live or dangling) would be written through, a second
# hard link would keep the mutant after the subject came back, and anything else is not a file this can
# put back at all. Reviewers found each of those separately; they are one rule.
kind_of() {
  [ -L "$1" ] && { printf 'a symlink'; return; }
  [ -e "$1" ] || { printf 'a missing'; return; }
  [ -f "$1" ] || { printf 'a non-regular'; return; }
  if stat -f '%l' "$1" >/dev/null 2>&1; then n="$(stat -f '%l' "$1")"; else n="$(stat -c '%h' "$1")"; fi
  [ "$n" -le 1 ] 2>/dev/null || { printf 'a hard-linked'; return; }
  printf 'regular'
}
KIND="$(kind_of "$FILE")"
[ "$KIND" = "a missing" ] && die "no such file: $FILE"
[ "$KIND" = regular ] || die "refusing $KIND target: $FILE — restoring replaces the inode, so this takes a plain file with one name and nothing else"

# Refuse to mutate the script that is running: bash reads a script incrementally, from a byte offset,
# so editing this file mid-run makes the interpreter continue inside the mutant. Measured twice.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TARGET_ABS="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd)/$(basename "$FILE")"
[ "$TARGET_ABS" != "$SELF" ] || die "refusing to mutate the running script — bash re-reads it mid-run; copy it elsewhere and mutate the copy"

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}
mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"   # BSD
  else stat -c '%a' "$1"; fi                                        # GNU
}

# A Python import may trust an existing .pyc when the mutant preserves source size and timestamp.
# Give every test invocation a new cache namespace instead of deleting repository caches or asking
# callers to remember an interpreter flag. Non-Python test commands simply ignore this environment.
TEST_CACHE_DIR=""
run_test() {
  local rc
  TEST_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner.pycache.XXXXXX" 2>/dev/null)" \
    || die "cannot create an isolated Python bytecode cache"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$TEST_CACHE_DIR" sh -c "$TEST_CMD" >/dev/null 2>&1
  rc=$?
  rmdir "$TEST_CACHE_DIR" 2>/dev/null || true
  TEST_CACHE_DIR=""
  return "$rc"
}

# The mutant run keeps its output: it is the only evidence of WHY the test went red, and the exit
# status cannot carry that.
run_test_capturing() { # $1=output file
  local rc
  TEST_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner.pycache.XXXXXX" 2>/dev/null)" \
    || die "cannot create an isolated Python bytecode cache"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$TEST_CACHE_DIR" sh -c "$TEST_CMD" >"$1" 2>&1
  rc=$?
  rmdir "$TEST_CACHE_DIR" 2>/dev/null || true
  TEST_CACHE_DIR=""
  return "$rc"
}

# Resolve the syntax check before anything is touched, so an unsupported file is refused while the
# tree is still clean rather than after a mutant is sitting in it.
if [ -z "$SYNTAX_CMD" ]; then
  case "$FILE" in
    *.sh)   command -v bash    >/dev/null 2>&1 && SYNTAX_CMD='bash -n "$MUTATE_FILE"' ;;
    *.bash) command -v bash    >/dev/null 2>&1 && SYNTAX_CMD='bash -n "$MUTATE_FILE"' ;;
    # `py_compile` writes the mutant to __pycache__. When restore puts back an original with the
    # same size and timestamp second, the next baseline can execute that stale mutant bytecode and
    # report BASELINE. Compile in memory: syntax is the only fact this step needs.
    *.py)   command -v python3 >/dev/null 2>&1 \
              && SYNTAX_CMD="python3 -c 'import sys; compile(open(sys.argv[1], \"rb\").read(), sys.argv[1], \"exec\")' \"\$MUTATE_FILE\"" ;;
    *.json) command -v jq      >/dev/null 2>&1 && SYNTAX_CMD='jq -e . "$MUTATE_FILE" >/dev/null' ;;
  esac
fi
[ -n "$SYNTAX_CMD" ] || die "SYNTAX     $FILE  no syntax check for this file and none given — pass one as the 4th argument; an unchecked mutant that fails the test cannot be told from a broken file"

BACKUP="$FILE.premutation"
# `-e || -L`, for the same reason as the target above and in the place it actually mattered: a dangling
# symlink parked at the backup path is invisible to `-e`, and `cp` then follows it and writes the
# original wherever it pointed — outside this directory, consuming the link. Measured.
if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
  die "$BACKUP already exists — an earlier mutation did not restore, or something else owns that path; deal with that first"
fi

# 1. Baseline, before anything is written. A suite that is already red grades every mutant as killed --
# and the backup is created only after this passes, because a test command that inspects the working
# tree (a linter over untracked files, a "no stray files" check) would otherwise fail on the backup
# this script had just dropped next to the subject. Measured in a clean git repository.
if ! run_test; then
  printf 'BASELINE   %s  the test command already fails before any mutation — nothing could be graded\n' "$FILE"
  exit 2
fi

cp "$FILE" "$BACKUP" || die "cannot copy $FILE"
BEFORE="$(sha_of "$FILE")"; BEFORE_MODE="$(mode_of "$FILE")"
BACKUP_LIVE=1

# Restore through a temp regular file in the same directory, verified, then moved into place. `cp`
# straight onto the path writes *through* a symlink, so a mutation that swapped the file for a link
# left the tree changed while the bytes compared equal -- and the backup was deleted on the way out.
# The backup is removed only after the final state is checked: regular file, exact bytes, exact mode.
restore_failed() {
  printf 'mutate: %s for %s — the mutant is still in the tree; the original is kept at %s\n' "$1" "$FILE" "$BACKUP" >&2
  exit 2
}
restore() {
  # Idempotent on purpose: the trap can fire during the control run, when the file is already back, and
  # re-entering the copy below printed RESTORE FAILED for a tree in perfect shape. But the no-op is
  # keyed on BACKUP_LIVE -- the flag this sets when it finishes -- and NOT on whether the backup file is
  # still there. Those are different questions, and answering the second was a silent data defect: a
  # test command that runs `git clean` deletes the untracked backup, and "the backup is gone" then read
  # as "already restored". The mutant stayed in the working file, the control ran against it, and the
  # verdict said "the RESTORED file". A vanished backup is a restore that cannot happen, and it has to
  # say so.
  [ -n "$BACKUP_LIVE" ] || return 0
  if [ ! -f "$BACKUP" ]; then
    printf 'mutate: RESTORE IMPOSSIBLE for %s — the backup at %s is gone (a test or mutation command deleted it; `git clean` over untracked files does this). The mutant is still in the tree; recover the file from git or your editor.\n' \
      "$FILE" "$BACKUP" >&2
    exit 2
  fi
  # mktemp, not a name built from $$: the mutation command is arbitrary shell, it can read $PPID, and a
  # symlink planted at a predictable staging path would have this `cp` write through it into whatever
  # the link pointed at. mktemp creates the file itself, exclusively.
  tmp="$(mktemp "$(dirname "$FILE")/.mutate.restore.XXXXXX" 2>/dev/null)" \
    || restore_failed "RESTORE FAILED (cannot stage a copy)"
  cp "$BACKUP" "$tmp" 2>/dev/null || { rm -f "$tmp"; restore_failed "RESTORE FAILED (cannot stage a copy)"; }
  chmod "$BEFORE_MODE" "$tmp" 2>/dev/null || { rm -f "$tmp"; restore_failed "RESTORE FAILED (cannot set mode)"; }
  [ "$(sha_of "$tmp")" = "$BEFORE" ] || { rm -f "$tmp"; restore_failed "RESTORE MISMATCH (staged copy differs)"; }
  mv -f "$tmp" "$FILE" 2>/dev/null || { rm -f "$tmp"; restore_failed "RESTORE FAILED (cannot replace the file)"; }
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || restore_failed "RESTORE MISMATCH (not a regular file)"
  [ "$(sha_of "$FILE")" = "$BEFORE" ] || restore_failed "RESTORE MISMATCH (bytes)"
  [ "$(mode_of "$FILE")" = "$BEFORE_MODE" ] || restore_failed "RESTORE MISMATCH (mode)"
  rm -f "$BACKUP"
  BACKUP_LIVE=""
}
# The signal path goes through the same restore, with the trap cleared first so a second signal cannot
# re-enter it. An earlier version inlined a cp, ignored whether it worked, and deleted the backup
# anyway -- on a mutant that could not be overwritten that lost the original outright.
trap 'trap - INT TERM; [ -z "$TEST_CACHE_DIR" ] || rmdir "$TEST_CACHE_DIR" 2>/dev/null || true; restore; exit 2' INT TERM

# Log files are allocated here, while the tree is still clean. They were created after the mutation for
# one revision, and a failure there exits through `die`, which does not restore -- leaving the mutant in
# the working file with the original only in the backup. Nothing that runs after the mutation may fail
# on a resource it could have reserved first.
MUT_OUT="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-mutant.XXXXXX")" || die "cannot create a temporary file"
CONTROL_OUT="$(mktemp "${TMPDIR:-/tmp}/cc-tuner-control.XXXXXX")" || { rm -f "$MUT_OUT"; die "cannot create a temporary file"; }

# 2. The mutation itself has to succeed and to change something.
MUTATE_FILE="$FILE" sh -c "$MUT_CMD" >/dev/null 2>&1
mrc=$?
if [ "$mrc" -ne 0 ]; then
  restore
  printf 'MUTATION   %s  the mutation command exited %s — a half-applied patch is not a mutant\n' "$FILE" "$mrc"
  exit 2
fi
if [ "$(sha_of "$FILE")" = "$BEFORE" ]; then
  restore
  printf 'MUTATION   %s  the command left the file byte-identical — nothing was tested\n' "$FILE"
  exit 2
fi

# 3. The mutant must parse.
if ! MUTATE_FILE="$FILE" sh -c "$SYNTAX_CMD" >/dev/null 2>&1; then
  restore
  printf 'SYNTAX     %s  the mutant does not parse — a broken file failing proves only that broken files fail\n' "$FILE"
  exit 2
fi

# 4. Now the grade means something.
run_test_capturing "$MUT_OUT"
rc=$?
restore

# A test that DIED is not a test that failed, and neither is a test that never ran. Both arrive here as
# a non-zero status and were graded KILLED -- the mutant credited with a red suite it never caused,
# which is the whole class of lie this script exists to refuse.
#
# The reserved range, and why each part of it: 128+n is a signal (OOM kill, Ctrl-C); 124 is what
# `timeout` returns, and a run that ran out of wall clock proved nothing about the mutant; 125 is
# `timeout` itself failing, 126 is "found but not executable" and 127 is "command not found" -- all
# three mean the test command never executed. An earlier revision excluded only 128+, so the commonest
# way a heavy mutation run ends, a timeout, still read as a kill.
case "$rc" in
  124) why="the test timed out" ;;
  125) why="the timeout wrapper itself failed" ;;
  126) why="the test command was found but is not executable" ;;
  127) why="the test command was not found" ;;
  *) if [ "$rc" -ge 128 ] 2>/dev/null; then why="the test was killed by signal $((rc - 128))"; else why=""; fi ;;
esac
# The mutant's own words, and the whole of them. An earlier revision printed three lines and deleted
# the file, which is exactly enough to show `FAILED (errors=1)` and hide the ConnectionError above it.
show_log() { # $1=label $2=file
  if [ -s "$2" ]; then
    printf '           %s (full log: %s)\n' "$1" "$2"
    sed -e 's/^/           | /' "$2" | tail -12
  else
    printf '           %s: the command printed nothing (log: %s)\n' "$1" "$2"
  fi
}

if [ -n "$why" ]; then
  printf 'NOTRUN     %s  rc=%s  %s, so it did not fail because of the mutant — nothing was graded  %s\n' \
    "$FILE" "$rc" "$why" "$MUT_CMD"
  show_log "mutant run" "$MUT_OUT"
  rm -f "$CONTROL_OUT"
  exit 2
fi

if [ "$rc" -ne 0 ]; then
  # THE CONTROL RUN, and it is what makes the verdict mean anything. A failing exit status says the
  # suite went red; it does not say the MUTANT is why. A fixture that stops reaching its database
  # between the baseline and the mutant produces the same red, and every mutant then grades as killed
  # while nothing about the guard was exercised.
  #
  # Matching text cannot settle this and was tried: `--expect 'guard must allow small value'` matched a
  # Python traceback that merely ECHOED the failing source line, on a run where the assertion never
  # executed at all. The pattern was present, the assertion was not.
  #
  # So the file is restored, the same test runs again, and only a green control proves the mutant was
  # the difference. It costs a third run of the test command, on the KILLED path only -- a SURVIVED
  # verdict is green twice over and needs no control.
  run_test_capturing "$CONTROL_OUT"
  crc=$?
  if [ "$crc" -ne 0 ]; then
    printf 'NOTPROVED  %s  rc=%s  the test is red on the RESTORED file too (rc=%s), so something other than the mutant broke it  %s\n' \
      "$FILE" "$rc" "$crc" "$MUT_CMD"
    show_log "mutant run" "$MUT_OUT"
    show_log "control run, original file restored" "$CONTROL_OUT"
    exit 2
  fi

  # An optional extra filter, never the proof: a traceback can echo the text you are matching, which is
  # why the control run above decides and this only narrows.
  if [ -n "$EXPECT" ] && ! grep -Eq -- "$EXPECT" "$MUT_OUT" 2>/dev/null; then
    printf 'UNEXPECTED %s  rc=%s  the control run is green, so the mutant did break the test — but not with the text --expect named  %s\n' \
      "$FILE" "$rc" "$MUT_CMD"
    show_log "mutant run" "$MUT_OUT"
    exit 2
  fi

  printf 'KILLED     %s  rc=%s  green before, red on the mutant, green again once restored  %s\n' "$FILE" "$rc" "$MUT_CMD"
  show_log "mutant run" "$MUT_OUT"
  printf '           control run was green (full log: %s)\n' "$CONTROL_OUT"
  exit 0
fi
rm -f "$MUT_OUT" "$CONTROL_OUT"
printf 'SURVIVED   %s  rc=0  green before and after  %s\n' "$FILE" "$MUT_CMD"
exit 1
