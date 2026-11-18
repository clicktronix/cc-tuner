#!/usr/bin/env bash
# One mutation, graded by a program instead of by the agent's account of it.
#
#   mutate.sh [--expect <ere>] <file> <test-command> <mutation-command> [syntax-command]
#
# The mutation command edits <file> however it likes ($MUTATE_FILE holds the path). This script owns
# the parts a hand-rolled mutation pass gets wrong, and each rule below removes a false KILLED or a
# false SURVIVED:
#
#   * the test must be GREEN before the mutation, or a red suite grades every mutant as killed;
#   * the mutation command must exit 0 and change the file: a half-applied patch is not a mutant, and a
#     patch that no-ops and then "survives" was never tested;
#   * the mutant must parse, and if this cannot tell whether it parses it refuses: a file that no
#     longer parses fails every test and proves only that broken files fail;
#   * every kill is confirmed by re-running the test on the RESTORED file: red there too means
#     something other than the mutant is breaking it;
#   * all three runs see the same working tree: the original is kept outside it while the mutant is in
#     place, so a test that inspects the tree (a linter over untracked files) is not failed by a backup;
#   * Python runs use separate bytecode-cache directories, so a same-size, same-mtime edit cannot be
#     hidden by an existing .pyc;
#   * the file comes back byte-identical AND mode-identical, also on INT, TERM and HUP, and if it
#     cannot, the original is kept and its path printed.
#
# Exit: 0 KILLED, 1 SURVIVED, 2 nothing was proved (the line says which rule). `--help` has the list.
#
# The mutation command is written by whoever runs this, in the same session as the test command: it
# is careless, not hostile. Where a careless command could change something outside its subject (a
# symlink, a second hard link) this refuses. It is not a sandbox.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

usage() {
  cat <<'USAGE'
usage: mutate.sh [--expect <ere>] <file> <test-command> <mutation-command> [syntax-command]

  <file>              the file to mutate; restored byte- and mode-identical before this exits
  <test-command>      must pass BEFORE the mutation, and is what the mutant has to break. Runs under
                      `sh -c` with stdin closed, three times at most: baseline, mutant, control.
  <mutation-command>  shell, also under `sh -c`; $MUTATE_FILE is the file; must exit 0 and change it
  [syntax-command]    how to check the mutant parses ($MUTATE_FILE again). Inferred for .sh, .bash,
                      .py and .json; required otherwise.
  --expect <ere>      an optional extra filter on the killed test's output. It is not the proof: a
                      traceback echoes the failing source line, so the text can match on a run where
                      the assertion never executed. The control run is the proof.

Prints one ledger line (paste it, do not retype it) and the tail of each log it names.
  KILLED     exit 0   green, red with the mutant, green again on the restored file
  SURVIVED   exit 1   green before and after: nothing in the suite covers this behaviour
  BASELINE   exit 2   the test already fails before any mutation
  MUTATION   exit 2   the mutation command failed or left the file byte-identical
  SYNTAX     exit 2   the mutant does not parse, or no syntax check is known for this file
  NOTRUN     exit 2   the mutant run was killed from outside (HUP, INT, KILL or TERM)
  NOTPROVED  exit 2   the test is red on the restored file too, so something else is breaking it
  UNEXPECTED exit 2   the mutant broke the test, but not with the text --expect named

KILLED claims exactly: green, red with the mutant, green again. Any other failing status of the mutant
run counts, a missing command (127), an abort (134) and a timeout (124) included, because the same
command had just passed on the original. It cannot claim that a failure seen only in the mutant run
was caused by the mutant: a flaky test or a service that blipped has the same shape. Read the mutant
log, which is where a ConnectionError is visible and an assertion message is not.

Refuses before touching anything:
  * a symlink, a hard-linked file, a directory: restoring puts a fresh inode at the path, so the
    target must be a plain file with one name;
  * this script itself;
  * a file whose earlier mutation did not restore. The original of an interrupted run is kept
    outside the working tree, in <git-dir>/cc-tuner-mutate/ (or $TMPDIR/cc-tuner-mutate-<uid>/
    outside a repository), and the refusal prints the `mv` that puts it back.

This is not a sandbox: the commands are yours, and it only stops carelessness reaching past the subject.
USAGE
}

RUN_DIR=""       # this run's logs and bytecode caches
BACKUP=""        # the original, outside the working tree
BACKUP_LIVE=""   # set while the working file may differ from the original
TEST_PID=""

# Every exit after the backup exists goes through restore.
die() {
  printf 'mutate: %s\n' "$1" >&2
  [ -z "$BACKUP_LIVE" ] || restore
  exit 2
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
EXPECT=""
if [ "${1:-}" = "--expect" ]; then
  [ -n "${2:-}" ] || { printf 'mutate: --expect needs a pattern\n' >&2; exit 2; }
  EXPECT="$2"; shift 2
fi
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
FILE="$1"; TEST_CMD="$2"; MUT_CMD="$3"; SYNTAX_CMD="${4:-}"

# Restoring puts a fresh inode at this path, so it has to be a plain file with a single name: a
# symlink would be written through, and a second hard link would keep the mutant.
kind_of() {
  local n
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

# bash reads a script incrementally, so editing this file mid-run continues inside the mutant.
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
TARGET_DIR="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P)" || die "cannot enter the directory of $FILE"
TARGET_ABS="$TARGET_DIR/$(basename "$FILE")"
[ "$TARGET_ABS" != "$SELF" ] || die "refusing to mutate the running script — bash re-reads it mid-run; copy it elsewhere and mutate the copy"

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}
mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"   # BSD
  else stat -c '%a' "$1"; fi                                        # GNU
}

# Resolved before anything is touched, so an unsupported file is refused while the tree is clean.
if [ -z "$SYNTAX_CMD" ]; then
  case "$FILE" in
    *.sh|*.bash) command -v bash >/dev/null 2>&1 && SYNTAX_CMD='bash -n "$MUTATE_FILE"' ;;
    # Compiled in memory: py_compile would write the mutant's bytecode into __pycache__, where the
    # next baseline can pick it up.
    *.py)   command -v python3 >/dev/null 2>&1 \
              && SYNTAX_CMD="python3 -c 'import sys; compile(open(sys.argv[1], \"rb\").read(), sys.argv[1], \"exec\")' \"\$MUTATE_FILE\"" ;;
    *.json) command -v jq      >/dev/null 2>&1 && SYNTAX_CMD='jq -se "length == 1" "$MUTATE_FILE" >/dev/null' ;;
  esac
fi
[ -n "$SYNTAX_CMD" ] || die "SYNTAX     $FILE  no syntax check for this file and none given — pass one as the 4th argument; an unchecked mutant that fails the test cannot be told from a broken file"

# The original is kept outside the working tree while the mutant is in place. Beside the file it was
# an untracked file only the mutant run saw (a false KILLED for a test that inspects the tree), one
# `git clean` in a test command could delete, and one an interrupted run left to be committed. The
# git directory is none of those, and unlike $TMPDIR it is the same place in the next session;
# $TMPDIR is the fallback outside a repository or when the git directory cannot be written.
KEY="$(printf '%s' "$TARGET_ABS" | cksum | cut -d' ' -f1)-$(basename "$FILE").premutation"
TMP_STATE="${TMPDIR:-/tmp}/cc-tuner-mutate-$(id -u)"
GIT_STATE="$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null)" && GIT_STATE="$GIT_STATE/cc-tuner-mutate" || GIT_STATE=""
# Every place an interrupted run may have left the original, the name versions before 0.24 used
# beside the file included.
for left in ${GIT_STATE:+"$GIT_STATE/$KEY"} "$TMP_STATE/$KEY" "$FILE.premutation"; do
  if [ -e "$left" ] || [ -L "$left" ]; then
    die "an earlier mutation of $FILE did not restore: $left holds the original, and the file may still hold the mutant. Check it, then put it back: mv '$left' '$FILE'"
  fi
done
usable() { { mkdir -p "$1" && chmod 700 "$1"; } 2>/dev/null; [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -w "$1" ]; }
if [ -n "$GIT_STATE" ] && usable "$GIT_STATE"; then STATE="$GIT_STATE"
elif usable "$TMP_STATE"; then STATE="$TMP_STATE"
else die "cannot keep the original in ${GIT_STATE:-$TMP_STATE} or $TMP_STATE (not writable directories of yours)"; fi
BACKUP="$STATE/$KEY"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-tuner-mutate.XXXXXX")" || die "cannot create a temporary directory"

# The tail of a log, and where the whole of it is: the exit status cannot say WHY a command failed.
show_log() { # show_log <label> <name>
  local f="$RUN_DIR/$2.log"
  if [ -s "$f" ]; then
    printf '           %s (full log: %s)\n' "$1" "$f"
    sed -e 's/^/           | /' "$f" | tail -12
  else
    printf '           %s: the command printed nothing\n' "$1"
  fi
}

# run_test <name>: the test command, its output in $RUN_DIR/<name>.log and a bytecode cache of its
# own. It runs in the background under `wait` so that a signal reaches the trap at once: bash defers a
# trap until a foreground command returns, which left the mutant in place for the rest of a long test.
# `set -m` around the start gives the test its own process group, which the trap can stop whole, and
# keeps SIGINT at its default in it (a plain background job would inherit it ignored).
# A test command that sweeps temp space can take $RUN_DIR with it, and a redirect into a missing
# directory would read as the command failing.
logs() { mkdir -p "$RUN_DIR/pycache-$1" 2>/dev/null || die "cannot write logs under $RUN_DIR"; }
run_test() {
  local rc
  logs "$1"
  set -m
  PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$RUN_DIR/pycache-$1" sh -c "$TEST_CMD" </dev/null >"$RUN_DIR/$1.log" 2>&1 &
  TEST_PID=$!
  set +m
  wait "$TEST_PID"; rc=$?
  TEST_PID=""
  return "$rc"
}

# Restore through a temp regular file in the same directory, verified, then moved into place: `cp`
# straight onto the path writes through a symlink the mutation may have left there. The staging name
# comes from mktemp, so nothing can be planted at it. The backup is removed only after the final
# state is checked: regular file, exact bytes, exact mode.
restore_failed() {
  printf 'mutate: %s for %s — the mutant may still be in the file. The original is at %s; when the cause is fixed, put it back: mv '"'%s' '%s'"'\n' \
    "$1" "$FILE" "$BACKUP" "$BACKUP" "$FILE" >&2
  exit 2
}
restore() {
  local tmp
  [ -n "$BACKUP_LIVE" ] || return 0
  if [ ! -f "$BACKUP" ]; then
    printf 'mutate: RESTORE IMPOSSIBLE for %s — the original at %s is gone (a test or mutation command deleted it). The mutant is still in the file; recover it from git or your editor.\n' \
      "$FILE" "$BACKUP" >&2
    exit 2
  fi
  tmp="$(mktemp "$TARGET_DIR/.mutate.restore.XXXXXX" 2>/dev/null)" \
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
# HUP too: a closed terminal or an ended session is how most interrupted runs end. The trap is
# cleared first so a second signal cannot re-enter the restore.
trap 'trap - INT TERM HUP; [ -z "$TEST_PID" ] || kill -- "-$TEST_PID" 2>/dev/null; restore; exit 2' INT TERM HUP

# 1. Baseline, before anything is written.
run_test baseline
brc=$?
if [ "$brc" -ne 0 ]; then
  printf 'BASELINE   %s  rc=%s  the test command already fails before any mutation — nothing could be graded  %s\n' "$FILE" "$brc" "$TEST_CMD"
  show_log "baseline run" baseline
  exit 2
fi

BEFORE="$(sha_of "$FILE")"; BEFORE_MODE="$(mode_of "$FILE")"
cp "$FILE" "$BACKUP" 2>/dev/null && [ "$(sha_of "$BACKUP")" = "$BEFORE" ] || { rm -f "$BACKUP"; die "cannot copy $FILE to $BACKUP"; }
BACKUP_LIVE=1

# 2. The mutation itself has to succeed and to change something.
logs mutant
MUTATE_FILE="$FILE" sh -c "$MUT_CMD" >"$RUN_DIR/mutation.log" 2>&1
mrc=$?
if [ "$mrc" -ne 0 ]; then
  restore
  printf 'MUTATION   %s  the mutation command exited %s — a half-applied patch is not a mutant  %s\n' "$FILE" "$mrc" "$MUT_CMD"
  show_log "mutation command" mutation
  exit 2
fi
if [ "$(sha_of "$FILE")" = "$BEFORE" ]; then
  restore
  printf 'MUTATION   %s  the mutation command exited 0 and left the file byte-identical — nothing was tested  %s\n' "$FILE" "$MUT_CMD"
  show_log "mutation command" mutation
  exit 2
fi

# 3. The mutant must parse.
logs mutant
if ! MUTATE_FILE="$FILE" sh -c "$SYNTAX_CMD" >"$RUN_DIR/syntax.log" 2>&1; then
  restore
  printf 'SYNTAX     %s  the mutant does not parse — a broken file failing proves only that broken files fail  %s\n' "$FILE" "$MUT_CMD"
  show_log "syntax check" syntax
  exit 2
fi

# 4. Now the grade means something.
run_test mutant
rc=$?
restore

if [ "$rc" -eq 0 ]; then
  rm -rf "$RUN_DIR" 2>/dev/null
  printf 'SURVIVED   %s  rc=0  green before and after  %s\n' "$FILE" "$MUT_CMD"
  exit 1
fi

# A process does not send itself HUP, INT, KILL or TERM: those four come from outside (a closed
# session, Ctrl-C, the OOM killer, a harness timeout), so the run says nothing about the mutant. Any
# other status is a failing test, because this command had just passed on the original.
case "$rc" in
  129|130|137|143)
    printf 'NOTRUN     %s  rc=%s  the mutant run was killed from outside by signal %s, so it did not fail because of the mutant — nothing was graded  %s\n' \
      "$FILE" "$rc" "$((rc - 128))" "$MUT_CMD"
    show_log "mutant run" mutant
    exit 2 ;;
esac

# The control run. A failing status says the suite went red, not that the mutant is why: a fixture
# that stops reaching its database between the baseline and the mutant produces the same red. Matching
# text cannot settle it either (a traceback echoes the failing source line), so the test runs once
# more on the restored file, and only a green control makes the mutant the difference.
run_test control
crc=$?
if [ "$crc" -ne 0 ]; then
  printf 'NOTPROVED  %s  rc=%s  the test is red on the RESTORED file too (rc=%s), so something other than the mutant broke it  %s\n' \
    "$FILE" "$rc" "$crc" "$MUT_CMD"
  show_log "mutant run" mutant
  show_log "control run, original file restored" control
  exit 2
fi

if [ -n "$EXPECT" ] && ! grep -Eq -- "$EXPECT" "$RUN_DIR/mutant.log" 2>/dev/null; then
  printf 'UNEXPECTED %s  rc=%s  the control run is green, so the mutant did break the test — but not with the text --expect named  %s\n' \
    "$FILE" "$rc" "$MUT_CMD"
  show_log "mutant run" mutant
  exit 2
fi

printf 'KILLED     %s  rc=%s  green before, red on the mutant, green again once restored  %s\n' "$FILE" "$rc" "$MUT_CMD"
show_log "mutant run" mutant
exit 0
