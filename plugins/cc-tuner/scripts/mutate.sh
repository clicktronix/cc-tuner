#!/usr/bin/env bash
# One mutation, graded by a program instead of by the agent's account of it.
#
#   mutate.sh <file> <test-command> <mutation-command>
#
# The mutation command edits <file> however it likes ($MUTATE_FILE holds the path); this script owns
# the parts that went wrong when runs did it by hand:
#
#   * it proves the file actually changed, because a patch that silently no-ops and then "survives"
#     is the false SURVIVED that two live runs recorded and one of them believed;
#   * it syntax-checks the mutant, because a file that no longer parses fails every test and proves
#     only that broken files fail;
#   * it restores from a byte copy and verifies the restore, because state leaking between mutants is
#     how a run "corrected" a right number into a wrong one;
#   * it prints one ledger line, so the record is generated rather than transcribed.
#
# Exit: 0 KILLED (the test failed, as a guarded behaviour should), 1 SURVIVED (the test passed and the
# guard does not bite), 2 the run proved nothing — no change, broken syntax, or a failed restore.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

die() { printf 'mutate: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 3 ] || die 'usage: mutate.sh <file> <test-command> <mutation-command>'
FILE="$1"; TEST_CMD="$2"; MUT_CMD="$3"
[ -f "$FILE" ] || die "no such file: $FILE"

# Refuse to mutate the script that is running. bash reads a script incrementally, from a byte offset,
# so editing this file mid-run makes the interpreter continue inside the mutant -- measured twice: a
# syntax error at a line that is fine on disk, and a restore that ran with the wrong variables. The
# file survived both, which is luck rather than design.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TARGET_ABS="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd)/$(basename "$FILE")"
[ "$TARGET_ABS" != "$SELF" ] || die "refusing to mutate the running script — bash re-reads it mid-run; copy it elsewhere and mutate the copy"

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# The backup sits beside the file, not in $TMPDIR. The test command is arbitrary and often a whole
# suite; one that sweeps temp space -- or that runs this script recursively -- can delete a backup
# parked there, and the failure mode is the worst one available: a mutated file left in the tree with
# nothing to restore from. Measured, on the first attempt to mutate this script using its own suite as
# the test command.
BACKUP="$FILE.premutation"
[ -e "$BACKUP" ] && die "$BACKUP already exists — an earlier mutation did not restore; deal with that first"
cp "$FILE" "$BACKUP" || die "cannot copy $FILE"
BEFORE="$(sha_of "$FILE")"

restore() {
  cp "$BACKUP" "$FILE" || { printf 'mutate: RESTORE FAILED for %s — the tree is now dirty\n' "$FILE" >&2; rm -f "$BACKUP"; exit 2; }
  [ "$(sha_of "$FILE")" = "$BEFORE" ] || { printf 'mutate: RESTORE MISMATCH for %s\n' "$FILE" >&2; rm -f "$BACKUP"; exit 2; }
  rm -f "$BACKUP"
}
# Restore on interrupt too: a half-finished mutation left in the tree is worse than no mutation.
trap 'cp "$BACKUP" "$FILE" 2>/dev/null; rm -f "$BACKUP"; exit 2' INT TERM

MUTATE_FILE="$FILE" sh -c "$MUT_CMD" >/dev/null 2>&1
if [ "$(sha_of "$FILE")" = "$BEFORE" ]; then
  restore
  printf 'NO-CHANGE  %s  the mutation command left the file byte-identical — nothing was tested\n' "$FILE"
  exit 2
fi

# Syntax, by extension. An unknown extension is not checked and says so, rather than claiming it was.
syntax_note="not syntax-checked"
case "$FILE" in
  *.sh)  if command -v bash >/dev/null 2>&1; then bash -n "$FILE" 2>/dev/null || { restore; printf 'SYNTAX     %s  the mutant does not parse — a broken file failing proves only that broken files fail\n' "$FILE"; exit 2; }; syntax_note="bash -n clean"; fi ;;
  *.py)  if command -v python3 >/dev/null 2>&1; then python3 -m py_compile "$FILE" 2>/dev/null || { restore; printf 'SYNTAX     %s  the mutant does not parse — a broken file failing proves only that broken files fail\n' "$FILE"; exit 2; }; syntax_note="py_compile clean"; fi ;;
  *.json) if command -v jq >/dev/null 2>&1; then jq -e . "$FILE" >/dev/null 2>&1 || { restore; printf 'SYNTAX     %s  the mutant is not valid JSON\n' "$FILE"; exit 2; }; syntax_note="jq clean"; fi ;;
esac

sh -c "$TEST_CMD" >/dev/null 2>&1
rc=$?
restore

if [ "$rc" -ne 0 ]; then
  printf 'KILLED     %s  rc=%s  (%s)  %s\n' "$FILE" "$rc" "$syntax_note" "$MUT_CMD"
  exit 0
fi
printf 'SURVIVED   %s  rc=0  (%s)  %s\n' "$FILE" "$syntax_note" "$MUT_CMD"
exit 1
