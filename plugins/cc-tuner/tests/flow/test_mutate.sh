#!/usr/bin/env bash
# mutate.sh: one mutation, graded by the program rather than by an account of it.
#
# Every case here is a way a hand-rolled mutation pass lied to a live run: a patch that no-opped and
# was read as SURVIVED, a mutant that no longer parsed, and state left behind between mutants.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MUTATE="$FLOW_PLUGIN/scripts/mutate.sh"

# A tiny subject with a real guard and a test that bites on it.
subject() {  # subject <dir>
  mkdir -p "$1"
  cat > "$1/calc.py" <<'PY'
def half(n):
    if n < 0:
        raise ValueError("negative")
    return n // 2
PY
  cat > "$1/check.sh" <<'SH'
cd "$(dirname "$0")"
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from calc import half
assert half(8) == 4
try:
    half(-1)
except ValueError:
    sys.exit(0)
sys.exit(1)
PY
SH
  chmod +x "$1/check.sh"
}

run() { ( bash "$MUTATE" "$@" 2>&1; printf 'rc=%s\n' "$?" ); }

W="$(flow_workdir)"; subject "$W"
BEFORE="$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- the guard bites: weakening it must turn the test red ----------------------------------------
# The mutation moves the boundary rather than deleting the raise: deleting it leaves an `if` with an
# empty body, which the syntax check rightly refuses -- as it did when this test was first written.
MUTATE_GUARD="sed 's/n < 0/n < -1/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE"
OUT="$(run "$W/calc.py" "bash $W/check.sh" "$MUTATE_GUARD")"
check "killed-when-the-guard-is-removed" "KILLED" "$OUT"
check "killed-exits-0"                   "rc=0"   "$OUT"
check "killed-restores-the-file"         "$BEFORE" "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- a mutation nothing asserts on: SURVIVED is a finding, not a failure of the tool --------------
OUT="$(run "$W/calc.py" "bash $W/check.sh" "printf '\n# a comment\n' >> \$MUTATE_FILE")"
check "survived-when-nothing-asserts" "SURVIVED" "$OUT"
check "survived-exits-1"              "rc=1"     "$OUT"
check "survived-restores-the-file"    "$BEFORE"  "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- the defect this script exists for: a patch that changes nothing ------------------------------
# A live run recorded SURVIVED for a mutant that a quoting bug never applied. Reporting a result for
# code that was never mutated is worse than reporting nothing, so this is neither KILLED nor SURVIVED.
OUT="$(run "$W/calc.py" "bash $W/check.sh" "cat \$MUTATE_FILE > /dev/null")"
check "no-change-is-not-a-result" "byte-identical" "$OUT"
check "no-change-exits-2"         "rc=2"           "$OUT"
check "no-change-restores"        "$BEFORE"   "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- a mutant that does not parse proves only that broken files fail ------------------------------
OUT="$(run "$W/calc.py" "bash $W/check.sh" "printf 'def (' >> \$MUTATE_FILE")"
check "syntax-break-is-not-a-kill" "SYNTAX"  "$OUT"
check "syntax-break-exits-2"       "rc=2"    "$OUT"
check "syntax-break-restores"      "$BEFORE" "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- the ledger line is generated, and names the mutation it ran ----------------------------------
OUT="$(run "$W/calc.py" "bash $W/check.sh" "$MUTATE_GUARD")"
check "ledger-names-the-file"      "calc.py"  "$OUT"
check "ledger-names-the-mutation"  "n < -1"   "$OUT"
check "ledger-records-the-baseline"     "green before, red after" "$OUT"

# --- the backup survives a test command that sweeps temp space ------------------------------------
# The first attempt to mutate this script with its own suite as the test command ended in RESTORE
# FAILED and a dirty tree, because the backup was parked in $TMPDIR. It now lives beside the file.
# Files only, at depth 1: that is what a mktemp backup is, and deleting the suite's own root
# directory would destroy the subject rather than test anything.
OUT="$(run "$W/calc.py" "find \"\${TMPDIR:-/tmp}\" -maxdepth 1 -type f -name 'tmp.*' -delete 2>/dev/null; bash $W/check.sh" "$MUTATE_GUARD")"
check "sweeping-tmp-does-not-break-restore" "KILLED"  "$OUT"
check "sweeping-tmp-restores-the-file"      "$BEFORE" "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"
absent "no-backup-left-behind" "premutation" "$(ls "$W")"

# --- a leftover backup is a refusal, not something to overwrite -----------------------------------
cp "$W/calc.py" "$W/calc.py.premutation"
OUT="$(run "$W/calc.py" "bash $W/check.sh" "$MUTATE_GUARD")"
check "leftover-backup-refused" "already exists" "$OUT"
check "leftover-backup-rc2"     "rc=2"           "$OUT"
rm -f "$W/calc.py.premutation"

# --- a suite that is already red grades every mutant as killed ------------------------------------
# Reproduced against the first version of this script: test-command `false`, and it reported KILLED.
OUT="$(run "$W/calc.py" "false" "$MUTATE_GUARD")"
check "already-red-is-not-a-kill" "BASELINE" "$OUT"
check "already-red-rc2"           "rc=2"     "$OUT"
check "already-red-restores"      "$BEFORE"  "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- a mutation command that fails is not a mutant ------------------------------------------------
# Also reproduced: a command that edits the file and then exits non-zero was graded KILLED.
OUT="$(run "$W/calc.py" "bash $W/check.sh" "printf 'x = 1\n' >> \$MUTATE_FILE; exit 7")"
check "failed-mutation-is-not-a-kill" "MUTATION" "$OUT"
check "failed-mutation-names-the-code" "exited 7" "$OUT"
check "failed-mutation-restores"      "$BEFORE"  "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- no syntax check available: refuse, do not grade ----------------------------------------------
cp "$W/calc.py" "$W/thing.unknownext"
OUT="$(run "$W/thing.unknownext" "true" "printf 'x\n' >> \$MUTATE_FILE")"
check "unknown-extension-refused" "no syntax check for this file" "$OUT"
check "unknown-extension-rc2"     "rc=2"                          "$OUT"
absent "unknown-extension-leaves-no-backup" "premutation" "$(ls "$W")"

# --- ...unless one is supplied -------------------------------------------------------------------
OUT="$(run "$W/thing.unknownext" "bash $W/check.sh" "sed 's/n < 0/n < -1/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE" "python3 -m py_compile \$MUTATE_FILE")"
check "supplied-syntax-command-is-used" "SURVIVED" "$OUT"
rm -f "$W/thing.unknownext"

# --- the file comes back with its mode, not just its bytes ----------------------------------------
chmod 755 "$W/calc.py"
OUT="$(run "$W/calc.py" "bash $W/check.sh" "chmod 600 \$MUTATE_FILE && sed 's/n < 0/n < -1/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE && chmod 600 \$MUTATE_FILE")"
check "mode-restored" "755" "$(stat -f '%Lp' "$W/calc.py" 2>/dev/null || stat -c '%a' "$W/calc.py")"
chmod 644 "$W/calc.py"
BEFORE="$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- the running script is not a legal target ------------------------------------------------------
OUT="$(run "$MUTATE" "true" "true")"
check "self-mutation-refused" "refusing to mutate the running script" "$OUT"
check "self-mutation-rc2"     "rc=2"                                  "$OUT"

# --- the published contract is reachable ----------------------------------------------------------
# `/cc-tuner:run` now points at `--help` instead of restating the contract, so the help text is public
# surface. Nothing asserted it existed until a reviewer pointed that out.
OUT="$( bash "$MUTATE" --help 2>&1; printf 'rc=%s\n' "$?" )"
check "help-exits-0"          "rc=0"      "$OUT"
check "help-names-KILLED"     "KILLED"    "$OUT"
check "help-names-SURVIVED"   "SURVIVED"  "$OUT"
check "help-names-BASELINE"   "BASELINE"  "$OUT"
check "help-names-the-syntax-argument" "syntax-command" "$OUT"

# --- a symlink swap must not write through the link, and must not eat the original ----------------
# `cp` onto the path follows a symlink: a mutation that replaced the file with a link left the tree
# changed while the bytes compared equal, and the backup was deleted on the way out.
S="$(flow_workdir)"; subject "$S"
printf 'def half(n):\n    return n // 2\n' > "$S/elsewhere.py"
SBEFORE="$(shasum -a 256 "$S/calc.py" | cut -d' ' -f1)"
OUT="$(run "$S/calc.py" "bash $S/check.sh" "rm \$MUTATE_FILE && ln -s $S/elsewhere.py \$MUTATE_FILE")"
if [ -L "$S/calc.py" ]; then fail "symlink-swap-restores-a-regular-file (the path is still a symlink)"; else pass "symlink-swap-restores-a-regular-file"; fi
check "symlink-swap-restores-the-bytes" "$SBEFORE" "$(shasum -a 256 "$S/calc.py" | cut -d' ' -f1)"
absent "symlink-swap-leaves-no-backup" "premutation" "$(ls "$S")"

# --- a restore that cannot happen keeps the original ----------------------------------------------
R="$(flow_workdir)"; subject "$R"
RBEFORE="$(shasum -a 256 "$R/calc.py" | cut -d' ' -f1)"
OUT="$(run "$R/calc.py" "bash $R/check.sh" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 500 \$(dirname \$MUTATE_FILE)")"
chmod 755 "$R" 2>/dev/null
check "unrestorable-says-so"        "RESTORE"     "$OUT"
check "unrestorable-rc2"            "rc=2"        "$OUT"
check "unrestorable-keeps-original" "premutation" "$(ls "$R")"
check "the-kept-original-is-the-original" "$RBEFORE" "$(shasum -a 256 "$R/calc.py.premutation" | cut -d' ' -f1)"
rm -f "$R/calc.py.premutation"

# --- a signal restores through the same path ------------------------------------------------------
# The harness runs in the FOREGROUND and its own test command signals it. Two earlier versions put it
# in a background job and killed that: a background job inherits an ignored SIGINT, so removing INT
# from the trap left the suite at 64 PASS while proving nothing. `sh -c` execs the test command, so
# $PPID inside it is this harness.
for sig in TERM INT; do
  X="$(flow_workdir)"; subject "$X"
  XBEFORE="$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  cat > "$X/slow.sh" <<SLOW
if [ -e "$X/seen" ]; then kill -$sig \$PPID; sleep 5; else : > "$X/seen"; fi
SLOW
  OUT="$(run "$X/calc.py" "sh $X/slow.sh" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 400 \$MUTATE_FILE")"
  chmod 644 "$X/calc.py" 2>/dev/null
  check  "signal-$sig-rc2"                       "rc=2"     "$OUT"
  equals "signal-$sig-restores-an-unwritable-mutant" "$XBEFORE" "$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  absent "signal-$sig-leaves-no-backup"          "premutation" "$(ls "$X")"
done

# --- a signal arriving when the restore cannot finish keeps the original --------------------------
# The two halves were tested apart: an ordinary failed restore, and an ordinary signal. Their
# combination is what loses data — the earlier handler deleted the backup whether or not its copy had
# worked. Read-only directory, so the staging copy cannot even be created.
for sig in TERM INT; do
  Y="$(flow_workdir)"; subject "$Y"
  YBEFORE="$(shasum -a 256 "$Y/calc.py" | cut -d' ' -f1)"
  cat > "$Y/slow.sh" <<SLOW
if [ -e "$Y/seen" ]; then kill -$sig \$PPID; sleep 5; else : > "$Y/seen"; fi
SLOW
  OUT="$(run "$Y/calc.py" "sh $Y/slow.sh" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 500 $Y")"
  chmod 755 "$Y" 2>/dev/null
  check  "signal-$sig-unrestorable-rc2"            "rc=2"        "$OUT"
  check  "signal-$sig-unrestorable-keeps-original" "premutation" "$(ls "$Y")"
  equals "signal-$sig-kept-copy-is-the-original"   "$YBEFORE"    "$(shasum -a 256 "$Y/calc.py.premutation" 2>/dev/null | cut -d' ' -f1)"
  rm -f "$Y/calc.py.premutation"
done

# --- a dangling symlink at the backup path is not an empty slot -----------------------------------
# `-e` does not see it, so `cp` followed it and wrote the original outside this directory, consuming
# the link — and then graded the run. Measured on 3737e9a.
E="$(flow_workdir)"; subject "$E"; mkdir "$E/out"; ln -s "$E/out/escaped" "$E/calc.py.premutation"
OUT="$(run "$E/calc.py" "bash $E/check.sh" "$MUTATE_GUARD")"
check  "dangling-backup-path-refused" "already exists" "$OUT"
absent "dangling-backup-path-writes-nothing-outside" "escaped" "$(ls "$E/out")"
if [ -L "$E/calc.py.premutation" ]; then pass "dangling-backup-link-left-alone"; else fail "dangling-backup-link-left-alone (the link was consumed)"; fi
rm -f "$E/calc.py.premutation"

# --- the baseline runs against the tree the run will see ------------------------------------------
# The backup used to be created first, so a test command that refuses stray files failed the baseline
# on the file this script had just written next to the subject.
B="$(flow_workdir)"; subject "$B"
OUT="$(run "$B/calc.py" "test ! -e $B/calc.py.premutation && bash $B/check.sh" "$MUTATE_GUARD")"
check "baseline-sees-no-backup" "KILLED" "$OUT"

# --- a second name for the same inode is refused --------------------------------------------------
# Restoring moves a fresh inode into place. Measured before this refusal existed: the subject came back
# and the alias kept the mutant, so the two names silently came apart.
H="$(flow_workdir)"; subject "$H"; ln "$H/calc.py" "$H/alias.py"
OUT="$(run "$H/calc.py" "bash $H/check.sh" "$MUTATE_GUARD")"
check "hardlinked-target-refused" "hard links" "$OUT"
check "hardlinked-target-rc2"     "rc=2"       "$OUT"
equals "hardlink-alias-untouched" "$(shasum -a 256 "$H/calc.py" | cut -d' ' -f1)" "$(shasum -a 256 "$H/alias.py" | cut -d' ' -f1)"

# --- a dangling symlink is refused as a symlink, not as a missing file ----------------------------
D="$(flow_workdir)"; ln -s "$D/never-existed.py" "$D/dangling.py"
OUT="$(run "$D/dangling.py" "true" "true")"
check "dangling-symlink-refused-as-symlink" "refusing a symlink target" "$OUT"
absent "dangling-symlink-target-not-created" "never-existed" "$(ls "$D")"

# --- the staging path cannot be guessed and pre-planted -------------------------------------------
# The mutation command is arbitrary shell and can read $PPID. A symlink parked at a staging path built
# from the pid would have the restore copy write through it, into a file that has nothing to do with
# this run.
P="$(flow_workdir)"; subject "$P"; printf 'do not touch me\n' > "$P/victim"
VICTIM="$(shasum -a 256 "$P/victim" | cut -d' ' -f1)"
OUT="$(run "$P/calc.py" "bash $P/check.sh" "ln -s $P/victim \$(dirname \$MUTATE_FILE)/.mutate.restore.\$PPID; $MUTATE_GUARD")"
check "planted-staging-path-does-not-divert-the-restore" "KILLED" "$OUT"
equals "planted-staging-path-leaves-the-victim-alone" "$VICTIM" "$(shasum -a 256 "$P/victim" | cut -d' ' -f1)"

# --- a signal arriving on a mutant that cannot be written over ------------------------------------
# The two halves were tested apart: an ordinary failed restore, and an ordinary signal. Their
# combination is what loses data, and the first attempt at this fixture did not discriminate: it made
# the *directory* read-only, where the old unsafe trap's `cp` still succeeded and its `rm` still
# failed, so both implementations passed. The case that separates them is a mutant with mode 000 in a
# writable directory: `cp` onto it is denied while `rm` of the backup succeeds, so the old handler
# deletes the last copy and leaves the mutant, and the current one replaces the file by rename.
# Read-only, not unreadable: mode 000 fails the syntax check instead, and the run ends before any
# signal can arrive — which is how a second version of this fixture passed against both handlers.
for sig in TERM INT; do
  X="$(flow_workdir)"; subject "$X"
  XBEFORE="$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  cat > "$X/slow.sh" <<SLOW
if [ -e "$X/seen" ]; then sleep 30; else : > "$X/seen"; fi
SLOW
  ( bash "$MUTATE" "$X/calc.py" "bash $X/slow.sh" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 400 \$MUTATE_FILE" >/dev/null 2>&1 ) &
  xp=$!
  sleep 3; kill -"$sig" "$xp" 2>/dev/null; wait "$xp" 2>/dev/null
  chmod 644 "$X/calc.py" 2>/dev/null
  equals "signal-$sig-restores-an-unwritable-mutant" "$XBEFORE" "$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  absent "signal-$sig-leaves-no-backup" "premutation" "$(ls "$X")"
done

# --- refusals that are not about mutants at all ---------------------------------------------------
OUT="$(run "$W/calc.py" "true" "true" "true" "extra")"
check "too-many-arguments-refused" "usage:" "$OUT"

L="$(flow_workdir)"; subject "$L"; ln -s "$L/calc.py" "$L/link.py"
OUT="$(run "$L/link.py" "true" "true")"
check "symlink-target-refused" "refusing a symlink target" "$OUT"

OUT="$(run "$W/does-not-exist.py" "true" "true")"
check "missing-file-refused" "no such file" "$OUT"
check "missing-file-rc2"     "rc=2"         "$OUT"

OUT="$(run "$W/calc.py" "true")"
check "wrong-arity-refused" "usage:" "$OUT"

exit $fails
