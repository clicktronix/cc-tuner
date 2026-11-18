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

# JSON syntax is independent of the truth value; empty input and streams are not one JSON document.
printf 'true\n' > "$W/value.json"
for value in false null; do
  OUT="$(run "$W/value.json"  "grep -qx true '$W/value.json'" "printf '%s' '$value' > \"\$MUTATE_FILE\"")"
  check "json-$value-reaches-behavioral-test" "KILLED" "$OUT"
  equals "json-$value-restored" true "$(cat "$W/value.json")"
done
for value in '' 'true false'; do
  OUT="$(run "$W/value.json"  "grep -qx true '$W/value.json'" "printf '%s' '$value' > \"\$MUTATE_FILE\"")"
  check "reject-invalid-single-document-$value" "SYNTAX" "$OUT"
done

# --- Python bytecode must not hide a same-size, same-mtime mutant --------------------------------
# A live run had already imported the original. The mutant kept its size and timestamp, so Python
# trusted the original .pyc and mutate.sh falsely printed SURVIVED even though a cache-free run failed.
C="$(flow_workdir)"
printf 'VALUE = 0\n' > "$C/cache_target.py"
touch -t 202601010101 "$C/cache_target.py"
(cd "$C" && unset PYTHONPYCACHEPREFIX PYTHONDONTWRITEBYTECODE && python3 -c 'import cache_target; assert cache_target.VALUE == 0')
CACHE_FILE="$(find "$C/__pycache__" -type f -name 'cache_target*.pyc' -print -quit)"
CACHE_BEFORE="$(shasum -a 256 "$CACHE_FILE" | cut -d' ' -f1)"
C_TEST="cd $C && python3 -c 'import cache_target; assert cache_target.VALUE == 0'"
C_MUTATE="sed 's/VALUE = 0/VALUE = 1/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE && touch -t 202601010101 \$MUTATE_FILE"
OUT="$(run "$C/cache_target.py" "$C_TEST" "$C_MUTATE")"
check "existing-python-cache-does-not-hide-mutant" "KILLED" "$OUT"
OUT="$(run "$C/cache_target.py" "$C_TEST" "$C_MUTATE")"
check "python-cache-does-not-poison-next-baseline" "KILLED" "$OUT"
equals "repository-bytecode-cache-is-not-rewritten" "$CACHE_BEFORE" "$(shasum -a 256 "$CACHE_FILE" | cut -d' ' -f1)"

# --- the ledger line is generated, and names the mutation it ran ----------------------------------
OUT="$(run "$W/calc.py" "bash $W/check.sh" "$MUTATE_GUARD")"
check "ledger-names-the-file"      "calc.py"  "$OUT"
check "ledger-names-the-mutation"  "n < -1"   "$OUT"
check "ledger-records-the-baseline"     "green before, red on the mutant, green again once restored" "$OUT"

# --- the original survives a test command that sweeps temp space ----------------------------------
# The first attempt to mutate this script with its own suite as the test command ended in RESTORE
# FAILED and a dirty tree, because the backup was a mktemp file in $TMPDIR. Files only, at depth 1:
# that is what a mktemp file is, and deleting the suite's own root would destroy the subject.
OUT="$(run "$W/calc.py" "find \"\${TMPDIR:-/tmp}\" -maxdepth 1 -type f -name 'tmp.*' -delete 2>/dev/null; bash $W/check.sh" "$MUTATE_GUARD")"
check "sweeping-tmp-does-not-break-restore" "KILLED"  "$OUT"
check "sweeping-tmp-restores-the-file"      "$BEFORE" "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"
absent "no-backup-left-behind" "premutation" "$(ls -A "$W")"

# --- an interrupted run is found by the next one, with the command that undoes it ------------------
# SIGKILL cannot be trapped, so the mutant stays in the file. The original is outside the working
# tree (nothing untracked to commit), and the next run refuses and prints the `mv` that restores it.
K="$(flow_workdir)"; subject "$K"
( cd "$K" && git init -q -b main && git config user.email a@b.c && git config user.name t && git add . && git commit -qm base ) >/dev/null 2>&1
KBEFORE="$(shasum -a 256 "$K/calc.py" | cut -d' ' -f1)"
# (stderr dropped: bash reports the harness it sees killed.)
{ OUT="$(run "$K/calc.py" "if [ -e '$K/.git/seen' ]; then kill -9 \$PPID; else : > '$K/.git/seen'; fi" "$MUTATE_GUARD")"; } 2>/dev/null
check  "killed-run-leaves-the-mutant"        "n < -1"      "$(cat "$K/calc.py")"
equals "killed-run-leaves-nothing-untracked" " M calc.py"  "$(git -C "$K" status --porcelain)"
OUT="$(run "$K/calc.py" "bash $K/check.sh" "$MUTATE_GUARD")"
check  "leftover-original-refused"   "did not restore"  "$OUT"
check  "leftover-original-rc2"       "rc=2"             "$OUT"
check  "leftover-names-the-restore"  "put it back: mv '" "$OUT"
eval "$(printf '%s\n' "$OUT" | sed -n "s/.*put it back: \(mv '.*'\)\$/\1/p")"
equals "the-printed-mv-restores-the-original" "$KBEFORE" "$(shasum -a 256 "$K/calc.py" | cut -d' ' -f1)"
check  "restored-file-mutates-again" "KILLED" "$(run "$K/calc.py" "bash $K/check.sh" "$MUTATE_GUARD")"
# A backup beside the file, as versions before 0.24 left it, is the same refusal.
cp "$W/calc.py" "$W/calc.py.premutation"
OUT="$(run "$W/calc.py" "bash $W/check.sh" "$MUTATE_GUARD")"
check "old-style-leftover-refused"      "did not restore"                    "$OUT"
check "old-style-leftover-names-the-mv" "calc.py.premutation' '$W/calc.py'" "$OUT"
rm -f "$W/calc.py.premutation"

# --- a suite that is already red grades every mutant as killed ------------------------------------
# Reproduced against the first version of this script: test-command `false`, and it reported KILLED.
OUT="$(run "$W/calc.py" "echo boom-from-the-baseline; exit 3" "$MUTATE_GUARD")"
check "already-red-is-not-a-kill" "BASELINE" "$OUT"
check "already-red-rc2"           "rc=2"     "$OUT"
# The refusal says why: the test's own status and output, which used to be thrown away.
check "already-red-names-the-status" "rc=3"                   "$OUT"
check "already-red-shows-the-output" "boom-from-the-baseline" "$OUT"
check "already-red-restores"      "$BEFORE"  "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- a mutation command that fails is not a mutant ------------------------------------------------
# Also reproduced: a command that edits the file and then exits non-zero was graded KILLED.
OUT="$(run "$W/calc.py" "bash $W/check.sh" "printf 'x = 1\n' >> \$MUTATE_FILE; echo sed-says-no >&2; exit 7")"
check "failed-mutation-is-not-a-kill" "MUTATION" "$OUT"
check "failed-mutation-names-the-code" "exited 7" "$OUT"
check "failed-mutation-shows-its-output" "sed-says-no" "$OUT"
check "failed-mutation-restores"      "$BEFORE"  "$(shasum -a 256 "$W/calc.py" | cut -d' ' -f1)"

# --- no syntax check available: refuse, do not grade ----------------------------------------------
cp "$W/calc.py" "$W/thing.unknownext"
OUT="$(run "$W/thing.unknownext" "true" "printf 'x\n' >> \$MUTATE_FILE")"
check "unknown-extension-refused" "no syntax check for this file" "$OUT"
check "unknown-extension-rc2"     "rc=2"                          "$OUT"
absent "unknown-extension-leaves-no-backup" "premutation" "$(ls -A "$W")"

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

# --- the target must be a plain file with one name ------------------------------------------------
# Five separate refusals, found one review round at a time, are one rule: restoring puts a fresh inode
# at the path, so a symlink gets written through, a second hard link keeps the mutant after the subject
# comes back, and anything else cannot be put back at all.
T="$(flow_workdir)"; printf 'x\n' > "$T/plain"; ln "$T/plain" "$T/hard"; ln -s "$T/plain" "$T/link"
ln -s "$T/never" "$T/dangling"; mkdir "$T/adir"
for bad in hard link dangling adir; do
  OUT="$(run "$T/$bad" "true" "true")"
  check "target-$bad-refused" "refusing" "$OUT"
  check "target-$bad-rc2"     "rc=2"     "$OUT"
done
OUT="$(run "$T/absent" "true" "true")"
check "target-absent-refused" "no such file" "$OUT"
absent "refused-targets-leave-no-backup" "premutation" "$(ls "$T")"

# --- the restore cannot be diverted ----------------------------------------------------------------
# Two ways it was: a mutation that swapped the file for a symlink had `cp` write through the link, and
# a staging path built from `$$` could be pre-empted by a symlink the mutation planted, since it can
# read $PPID. Both write outside the subject; both are one assertion now.
V="$(flow_workdir)"; subject "$V"; printf 'do not touch me\n' > "$V/victim"
VICTIM="$(shasum -a 256 "$V/victim" | cut -d' ' -f1)"; VBEFORE="$(shasum -a 256 "$V/calc.py" | cut -d' ' -f1)"
OUT="$(run "$V/calc.py" "bash $V/check.sh" "ln -s $V/victim \$(dirname \$MUTATE_FILE)/.mutate.restore.\$PPID; rm \$MUTATE_FILE && ln -s $V/victim \$MUTATE_FILE")"
equals "diverted-restore-leaves-the-victim-alone" "$VICTIM"  "$(shasum -a 256 "$V/victim" | cut -d' ' -f1)"
equals "diverted-restore-puts-the-subject-back"   "$VBEFORE" "$(shasum -a 256 "$V/calc.py" | cut -d' ' -f1)"
if [ -L "$V/calc.py" ]; then fail "diverted-restore-leaves-a-regular-file"; else pass "diverted-restore-leaves-a-regular-file"; fi

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
# `/run` sends the caller here for "the verdicts, the exit codes, the refusals", so the refusals have
# to be here. They lived only in source comments, which the caller does not read.
check "help-names-the-target-refusals" "hard-linked" "$OUT"
check "help-names-the-leftover-refusal" "did not restore"   "$OUT"
check "help-names-where-the-original-is" "cc-tuner-mutate"  "$OUT"
check "help-names-NOTRUN"              "NOTRUN"             "$OUT"
check "help-names-its-scope"           "not a sandbox" "$OUT"

# --- a restore that cannot happen keeps the original ----------------------------------------------
# kept_original <output>: the path the refusal prints for the original.
kept_original() { printf '%s\n' "$1" | sed -n 's/.*The original is at \(.*\); when the cause is fixed.*/\1/p' | head -n 1; }
R="$(flow_workdir)"; subject "$R"
RBEFORE="$(shasum -a 256 "$R/calc.py" | cut -d' ' -f1)"
OUT="$(run "$R/calc.py" "bash $R/check.sh" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 500 \$(dirname \$MUTATE_FILE)")"
chmod 755 "$R" 2>/dev/null
KEPT="$(kept_original "$OUT")"
check "unrestorable-says-so"        "RESTORE"     "$OUT"
check "unrestorable-rc2"            "rc=2"        "$OUT"
check "unrestorable-names-the-mv"   "put it back: mv '$KEPT' '$R/calc.py'" "$OUT"
equals "the-kept-original-is-the-original" "$RBEFORE" "$(shasum -a 256 "$KEPT" 2>/dev/null | cut -d' ' -f1)"
rm -f "$KEPT"

# --- a signal restores through the same path, and at once -----------------------------------------
# The harness runs in the FOREGROUND and is signalled by a helper the mutation command leaves behind
# ($PPID there is the harness). HUP is in the list because a closed session is how most interrupted
# runs end, and it used to kill the harness with the mutant in place. "At once": bash defers a trap
# until a foreground command returns, so the mutant stayed for the rest of the test (20 s here).
for sig in TERM INT HUP; do
  X="$(flow_workdir)"; subject "$X"
  XBEFORE="$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  T0=$SECONDS
  OUT="$(run "$X/calc.py" "if [ -e '$X/seen' ]; then sleep 20; else : > '$X/seen'; fi" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 400 \$MUTATE_FILE; target=\$PPID; (sleep 1; kill -$sig \$target) >/dev/null 2>&1 &")"
  chmod 644 "$X/calc.py" 2>/dev/null
  # Mode 400, not 000: an unreadable mutant fails the syntax check instead, and the run ends before the
  # signal can arrive.
  check  "signal-$sig-rc2"                       "rc=2"     "$OUT"
  equals "signal-$sig-restores-an-unwritable-mutant" "$XBEFORE" "$(shasum -a 256 "$X/calc.py" | cut -d' ' -f1)"
  absent "signal-$sig-leaves-no-backup"          "premutation" "$(ls -A "$X")"
  if [ $((SECONDS - T0)) -lt 15 ]; then pass "signal-$sig-does-not-wait-for-the-test"; else fail "signal-$sig-does-not-wait-for-the-test ($((SECONDS - T0)) s)"; fi
done

# --- a signal arriving when the restore cannot finish keeps the original --------------------------
# Read-only directory, so the staging copy cannot even be created.
for sig in TERM INT HUP; do
  Y="$(flow_workdir)"; subject "$Y"
  YBEFORE="$(shasum -a 256 "$Y/calc.py" | cut -d' ' -f1)"
  OUT="$(run "$Y/calc.py" "if [ -e '$Y/seen' ]; then sleep 20; else : > '$Y/seen'; fi" "printf 'x=1\n' >> \$MUTATE_FILE; chmod 500 $Y; target=\$PPID; (sleep 1; kill -$sig \$target) >/dev/null 2>&1 &")"
  chmod 755 "$Y" 2>/dev/null
  KEPT="$(kept_original "$OUT")"
  check  "signal-$sig-unrestorable-rc2"            "rc=2"        "$OUT"
  equals "signal-$sig-kept-copy-is-the-original"   "$YBEFORE"    "$(shasum -a 256 "$KEPT" 2>/dev/null | cut -d' ' -f1)"
  rm -f "$KEPT"
done

# --- all three runs see the same working tree -----------------------------------------------------
# The original used to sit beside the file during the mutant run only. A test that refuses stray files
# was green at the baseline, red with the mutant in place and green at the control: KILLED, for a
# mutation that changed a comment.
B="$(flow_workdir)"
( cd "$B" && git init -q -b main && git config user.email a@b.c && git config user.name t \
  && printf '# a comment\nx=1\n' > subject.sh && git add subject.sh && git commit -qm base ) >/dev/null 2>&1
NO_STRAY="cd $B && [ -z \"\$(git ls-files --others --exclude-standard)\" ] && grep -q x=1 subject.sh"
OUT="$(run "$B/subject.sh" "$NO_STRAY" "sed 's/a comment/another/' \$MUTATE_FILE > $B/.git/m && cat $B/.git/m > \$MUTATE_FILE")"
check  "equivalent-mutant-survives-a-tree-inspecting-test" "SURVIVED" "$OUT"
absent "backup-is-not-what-killed-it"                      "KILLED"   "$OUT"
OUT="$(run "$B/subject.sh" "$NO_STRAY" "sed 's/x=1/x=2/' \$MUTATE_FILE > $B/.git/m && cat $B/.git/m > \$MUTATE_FILE")"
check  "real-mutant-still-killed-under-it" "KILLED" "$OUT"
equals "tree-clean-afterwards" "" "$(git -C "$B" status --porcelain)"

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

# A test killed from OUTSIDE is not a test that failed. HUP, INT, KILL and TERM are signals a process
# does not send itself: a closed session, Ctrl-C, the OOM killer, a harness timeout. They arrive as
# 128+n and were once graded KILLED, the mutant credited with a red suite it never caused.
S="$(flow_workdir)"; printf 'x=1\n' > "$S/f.sh"
SIGNAL_MUT="sed 's/x=1/x=2/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE"
for s in TERM KILL; do
  OUT="$(run "$S/f.sh" "bash -c 'grep -q x=1 \"$S/f.sh\" || kill -$s \$\$'" "$SIGNAL_MUT")"
  check  "outside-$s-is-not-a-verdict" "NOTRUN"             "$OUT"
  check  "outside-$s-says-nothing-graded" "nothing was graded" "$OUT"
  check  "outside-$s-exits-2"          "rc=2"               "$OUT"
  absent "outside-$s-not-graded-as-killed" "KILLED"         "$OUT"
done

# Every other failing status is a failing test, because the same command had just passed on the
# original: a shell mutant that deletes a function ends in 127, an assert() in 134, a test's own
# timeout in 124. Refusing those as "the test never ran" reported real kills as nothing proved.
for code in 124 126 127; do
  OUT="$(run "$S/f.sh" "bash -c 'grep -q x=1 \"$S/f.sh\" || exit $code'" "$SIGNAL_MUT")"
  check  "status-$code-is-a-kill" "KILLED"   "$OUT"
  check  "status-$code-is-named"  "rc=$code" "$OUT"
done
OUT="$(run "$S/f.sh" "bash -c 'grep -q x=1 \"$S/f.sh\" || kill -ABRT \$\$'" "$SIGNAL_MUT")"
check "abort-is-a-kill" "KILLED" "$OUT"
printf 'guard() { return 0; }\nguard\n' > "$S/g.sh"
OUT="$(run "$S/g.sh" "sh $S/g.sh" "sed 's/^guard() .*/:/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE")"
check "deleted-shell-function-is-a-kill" "KILLED"  "$OUT"
check "deleted-function-log-says-why"    "guard"   "$OUT"

# Exit 1 is what a suite returns for a failed assertion AND for a fixture that could not reach its
# database. Without the expected reason, an environment failure appearing between baseline and mutant
# grades as a killed mutant while nothing about the guard was exercised.
E="$(flow_workdir)"; printf 'VALUE = 0\n' > "$E/t.py"
cat > "$E/flaky.sh" <<'EOF'
#!/bin/sh
cd "$(dirname "$0")"
# green on the first run, broken environment on every later one
if [ -f .ran ]; then echo "ConnectionError: could not connect to db in setUp"; exit 1; fi
touch .ran
grep -q 'VALUE = 0' t.py && exit 0
echo "AssertionError: VALUE changed"; exit 1
EOF
chmod +x "$E/flaky.sh"
E_MUT="sed 's/VALUE = 0/VALUE = 1/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE"

rm -f "$E/.ran"
OUT="$(run --expect 'AssertionError' "$E/t.py" "$E/flaky.sh" "$E_MUT")"
check  "env-failure-not-proved"      "NOTPROVED"       "$OUT"
check  "env-failure-exits-2"         "rc=2"            "$OUT"
check  "env-failure-shows-the-cause" "ConnectionError" "$OUT"
check  "env-failure-shows-control"   "control run"     "$OUT"
absent "env-failure-not-killed"      "KILLED"          "$OUT"

# The control run is what decides, so the same environment failure is refused with no --expect at all.
rm -f "$E/.ran"
OUT="$(run "$E/t.py" "$E/flaky.sh" "$E_MUT")"
check  "env-failure-refused-without-expect" "NOTPROVED" "$OUT"
absent "env-failure-no-false-kill"          "KILLED"    "$OUT"

# A pattern that a traceback merely echoes must not buy a kill either: matching text is a filter, not
# a proof, which is why the control run exists.
cat > "$E/echoing.sh" <<'EOF'
#!/bin/sh
cd "$(dirname "$0")"
if [ -f .ran ]; then
  printf 'Traceback:\n  self.assertTrue(allowed(x), "guard must allow small value")\nConnectionError: db gone\nFAILED (errors=1)\n'
  exit 1
fi
touch .ran
grep -q 'VALUE = 0' t.py && exit 0
exit 1
EOF
chmod +x "$E/echoing.sh"
rm -f "$E/.ran"
OUT="$(run --expect 'guard must allow small value' "$E/t.py" "$E/echoing.sh" "$E_MUT")"
check  "echoed-pattern-not-a-kill" "NOTPROVED" "$OUT"
absent "echoed-pattern-no-kill"    "KILLED"    "$OUT"

# Every exit path after the backup exists must put the file back. Here the mutation command removes
# the log directory and makes $TMPDIR read-only, so the next log cannot be written: a refusal that has
# nothing to do with the mutant, and the file still comes back. (A private TMPDIR: the glob is ours.)
D="$(flow_workdir)"; printf 'x=1\n' > "$D/f.sh"; mkdir -p "$D/tmpd"
OUT="$( TMPDIR="$D/tmpd" bash "$MUTATE" "$D/f.sh" "true" \
  "sed 's/x=1/x=2/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE; rm -rf '$D'/tmpd/cc-tuner-mutate.*; chmod 500 '$D/tmpd'" 2>&1; printf 'rc=%s\n' "$?" )"
chmod 755 "$D/tmpd" 2>/dev/null
check  "log-failure-refused"        "cannot write logs" "$OUT"
check  "log-failure-rc2"            "rc=2"    "$OUT"
equals "log-failure-restores-file"  "x=1"     "$(cat "$D/f.sh")"
absent "log-failure-leaves-no-backup" "premutation" "$(ls -A "$D" "$D"/tmpd/cc-tuner-mutate-*)"

# The original is gone and cannot be put back: said as that, never as a completed restore.
Z="$(flow_workdir)"; printf 'x=1\n' > "$Z/f.sh"; mkdir -p "$Z/tmpd"
OUT="$( TMPDIR="$Z/tmpd" bash "$MUTATE" "$Z/f.sh" "grep -q x=1 $Z/f.sh" \
  "sed 's/x=1/x=2/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE; rm -f '$Z'/tmpd/cc-tuner-mutate-*/*.premutation" 2>&1; printf 'rc=%s\n' "$?" )"
check  "vanished-original-reported" "RESTORE IMPOSSIBLE" "$OUT"
check  "vanished-original-rc2"      "rc=2"               "$OUT"
absent "vanished-original-no-verdict" "KILLED"           "$OUT"

# `git clean` in a test command used to delete the backup, which sat untracked beside the file. Inside
# the git directory it is out of reach, and the run is graded.
G="$(flow_workdir)"
( cd "$G" && git init -q -b main && git config user.email a@b.c && git config user.name t \
  && printf 'x=1\n' > subject.sh && git add subject.sh && git commit -qm base ) >/dev/null 2>&1
OUT="$( cd "$G" && bash "$MUTATE" subject.sh "git clean -fdq && grep -q x=1 subject.sh" \
  "sed 's/x=1/x=2/' \$MUTATE_FILE > .git/m && cat .git/m > \$MUTATE_FILE" 2>&1; printf 'rc=%s\n' "$?" )"
check  "git-clean-cannot-reach-the-original" "KILLED" "$OUT"
check  "git-clean-run-rc0"                   "rc=0"   "$OUT"
equals "git-clean-run-leaves-a-clean-tree"   ""       "$(git -C "$G" status --porcelain)"
# A git directory that cannot be written is not a reason to refuse: the original goes to $TMPDIR.
chmod 555 "$G/.git"
OUT="$( cd "$G" && bash "$MUTATE" subject.sh "grep -q x=1 subject.sh" \
  "sed 's/x=1/x=2/' \$MUTATE_FILE > \$MUTATE_FILE.m && mv \$MUTATE_FILE.m \$MUTATE_FILE" 2>&1; printf 'rc=%s\n' "$?" )"
chmod 755 "$G/.git"
check  "read-only-git-dir-still-graded" "KILLED" "$OUT"
equals "read-only-git-dir-restores"     "x=1"    "$(cat "$G/subject.sh")"

# An honest kill with the expected reason passes and says so.
cat > "$E/honest.sh" <<'EOF'
#!/bin/sh
cd "$(dirname "$0")"
grep -q 'VALUE = 0' t.py && exit 0
echo "AssertionError: VALUE changed"; exit 1
EOF
chmod +x "$E/honest.sh"
OUT="$(run --expect 'AssertionError' "$E/t.py" "$E/honest.sh" "$E_MUT")"
check "honest-kill-confirmed"  "green again once restored" "$OUT"
check "honest-kill-exits-0"    "rc=0"                      "$OUT"

# ...and a kill whose text does not match the pattern is reported as such, without pretending the
# mutant was innocent: the control was green, so the mutant did break it.
OUT="$(run --expect 'NoSuchMessage' "$E/t.py" "$E/honest.sh" "$E_MUT")"
check  "wrong-pattern-is-unexpected" "UNEXPECTED"     "$OUT"
check  "wrong-pattern-says-mutant-broke-it" "did break the test" "$OUT"
absent "wrong-pattern-not-killed"    "KILLED"         "$OUT"

# ...and an ordinary failing test is still a kill.
OUT="$(run "$S/f.sh" "bash -c 'grep -q x=1 \"$S/f.sh\"'" "$SIGNAL_MUT")"
check "ordinary-failure-still-killed" "KILLED" "$OUT"

exit $fails
