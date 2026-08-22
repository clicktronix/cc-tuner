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
[ -f "$FILE" ] || die "no such file: $FILE"

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
[ -e "$BACKUP" ] && die "$BACKUP already exists — an earlier mutation did not restore; deal with that first"
cp "$FILE" "$BACKUP" || die "cannot copy $FILE"
BEFORE="$(sha_of "$FILE")"; BEFORE_MODE="$(mode_of "$FILE")"

# The backup is never deleted on a failed restore: it is the last copy of the original.
restore() {
  cp "$BACKUP" "$FILE" 2>/dev/null || { printf 'mutate: RESTORE FAILED for %s — the mutant is still in the tree; the original is %s\n' "$FILE" "$BACKUP" >&2; exit 2; }
  chmod "$BEFORE_MODE" "$FILE" 2>/dev/null || true
  [ "$(sha_of "$FILE")" = "$BEFORE" ] && [ "$(mode_of "$FILE")" = "$BEFORE_MODE" ] \
    || { printf 'mutate: RESTORE MISMATCH for %s — the original is kept at %s\n' "$FILE" "$BACKUP" >&2; exit 2; }
  rm -f "$BACKUP"
}
trap 'cp "$BACKUP" "$FILE" 2>/dev/null; chmod "$BEFORE_MODE" "$FILE" 2>/dev/null; rm -f "$BACKUP"; exit 2' INT TERM

# 1. Baseline. A suite that is already red grades every mutant as killed.
if ! sh -c "$TEST_CMD" >/dev/null 2>&1; then
  restore
  printf 'BASELINE   %s  the test command already fails before any mutation — nothing could be graded\n' "$FILE"
  exit 2
fi

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
