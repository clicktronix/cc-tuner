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
OUT="$(run "$W/calc.py" "bash $W/check.sh" "grep -v 'this string is not in the file' \$MUTATE_FILE > /dev/null")"
check "no-change-is-not-a-result" "NO-CHANGE" "$OUT"
check "no-change-exits-2"         "rc=2"      "$OUT"
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
check "ledger-records-the-syntax-check" "py_compile clean" "$OUT"

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

# --- the running script is not a legal target ------------------------------------------------------
OUT="$(run "$MUTATE" "true" "true")"
check "self-mutation-refused" "refusing to mutate the running script" "$OUT"
check "self-mutation-rc2"     "rc=2"                                  "$OUT"

# --- refusals that are not about mutants at all ---------------------------------------------------
OUT="$(run "$W/does-not-exist.py" "true" "true")"
check "missing-file-refused" "no such file" "$OUT"
check "missing-file-rc2"     "rc=2"         "$OUT"

OUT="$(run "$W/calc.py" "true")"
check "wrong-arity-refused" "usage:" "$OUT"

exit $fails
