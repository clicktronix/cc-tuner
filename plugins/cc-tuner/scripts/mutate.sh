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
#   * the mutation command must exit 0 and change the file — a half-applied patch that errors out is
#     not a mutant, and a patch that no-ops and then "survives" is the defect that started this;
#   * the mutant must parse, and if this cannot tell whether it parses it refuses rather than
#     guessing: a file that no longer parses fails every test and proves only that broken files fail;
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

die() { printf 'mutate: %s\n' "$1" >&2; exit 2; }

usage() {
  cat <<'USAGE'
usage: mutate.sh <file> <test-command> <mutation-command> [syntax-command]

  <file>              the file to mutate; restored byte- and mode-identical before this exits
  <test-command>      must pass BEFORE the mutation, and is what the mutant has to break
  <mutation-command>  arbitrary shell; $MUTATE_FILE is the file; must exit 0 and change it
  [syntax-command]    how to check the mutant parses. Inferred for .sh/.py/.json when the checker
                      is installed; required otherwise, because an unchecked mutant that fails the
                      test is indistinguishable from a broken file that fails everything.

If a restore cannot finish, the original is left at <file>.premutation and this says so — the backup
is deleted only after the file is verified back to a regular file with the original bytes and mode.

Prints one ledger line — paste it, do not retype it.
  KILLED     exit 0   the test was green, the mutant turned it red: the guard bites
  SURVIVED   exit 1   green before and after: nothing in the suite covers this behaviour
  BASELINE   exit 2   the test was already failing, so no mutant could have been graded
  MUTATION   exit 2   the mutation command failed or left the file byte-identical
  SYNTAX     exit 2   the mutant does not parse, or nothing here can tell whether it does
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
FILE="$1"; TEST_CMD="$2"; MUT_CMD="$3"; SYNTAX_CMD="${4:-}"
# `-e || -L` rather than `-f`: a dangling symlink is not "no such file", and saying so sends the caller
# looking for the wrong thing.
[ -e "$FILE" ] || [ -L "$FILE" ] || die "no such file: $FILE"
# A symlink target makes "restore the file" ambiguous -- write through it, or replace it? -- and the
# ambiguity is not worth resolving for a mutation harness. Refusing means the restore below can always
# produce a regular file, which is a property it can then check.
[ ! -L "$FILE" ] || die "refusing a symlink target: $FILE — mutate the file it points at"
[ -f "$FILE" ] || die "not a regular file: $FILE"

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
links_of() {
  if stat -f '%l' "$1" >/dev/null 2>&1; then stat -f '%l' "$1"     # BSD
  else stat -c '%h' "$1"; fi                                        # GNU
}
# Restoring moves a fresh inode into place, so any other name for the old inode keeps the mutant and
# the two names come apart. Measured: with a second hardlink, the subject came back and the alias did
# not. Restoring in place instead would trade this for the symlink hole, so the harness refuses.
[ "$(links_of "$FILE")" -le 1 ] 2>/dev/null || die "refusing a target with $(links_of "$FILE") hard links: $FILE — restoring replaces the inode, so every other name would keep the mutant"

# Resolve the syntax check before anything is touched, so an unsupported file is refused while the
# tree is still clean rather than after a mutant is sitting in it.
if [ -z "$SYNTAX_CMD" ]; then
  case "$FILE" in
    *.sh)   command -v bash    >/dev/null 2>&1 && SYNTAX_CMD='bash -n "$MUTATE_FILE"' ;;
    *.bash) command -v bash    >/dev/null 2>&1 && SYNTAX_CMD='bash -n "$MUTATE_FILE"' ;;
    *.py)   command -v python3 >/dev/null 2>&1 && SYNTAX_CMD='python3 -m py_compile "$MUTATE_FILE"' ;;
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
if ! sh -c "$TEST_CMD" >/dev/null 2>&1; then
  printf 'BASELINE   %s  the test command already fails before any mutation — nothing could be graded\n' "$FILE"
  exit 2
fi

cp "$FILE" "$BACKUP" || die "cannot copy $FILE"
BEFORE="$(sha_of "$FILE")"; BEFORE_MODE="$(mode_of "$FILE")"

# Restore through a temp regular file in the same directory, verified, then moved into place. `cp`
# straight onto the path writes *through* a symlink, so a mutation that swapped the file for a link
# left the tree changed while the bytes compared equal -- and the backup was deleted on the way out.
# The backup is removed only after the final state is checked: regular file, exact bytes, exact mode.
restore_failed() {
  printf 'mutate: %s for %s — the mutant is still in the tree; the original is kept at %s\n' "$1" "$FILE" "$BACKUP" >&2
  exit 2
}
restore() {
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
}
# The signal path goes through the same restore, with the trap cleared first so a second signal cannot
# re-enter it. An earlier version inlined a cp, ignored whether it worked, and deleted the backup
# anyway -- on a mutant that could not be overwritten that lost the original outright.
trap 'trap - INT TERM; restore; exit 2' INT TERM

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
sh -c "$TEST_CMD" >/dev/null 2>&1
rc=$?
restore

if [ "$rc" -ne 0 ]; then
  printf 'KILLED     %s  rc=%s  green before, red after  %s\n' "$FILE" "$rc" "$MUT_CMD"
  exit 0
fi
printf 'SURVIVED   %s  rc=0  green before and after  %s\n' "$FILE" "$MUT_CMD"
exit 1
