#!/usr/bin/env bash
# heavy.sh: machine-wide slots for heavy checks. Several sessions each starting e2e at once is what
# froze the machine. These cases prove the second caller waits, the exit code passes through, a slot
# follows the life of the work (not of a wrapper or a pid file), concurrent callers never overlap,
# and a nested call runs inside its parent's slot instead of waiting for it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HEAVY="$FLOW_PLUGIN/scripts/heavy.sh"
W="$(flow_workdir)"
export CC_TUNER_HEAVY_DIR="$W/slots" CC_TUNER_HEAVY_POLL=0.1
unset CC_TUNER_HEAVY_HELD

# until_logged <file> <marker>: wait until the work under test has started, instead of guessing a
# delay (the supervisor's start-up time is not a constant).
# A marker that never appears fails the case by name rather than letting a later assertion pass on
# a timing accident.
until_logged() {
  local n=0
  until grep -q "$2" "$1" 2>/dev/null; do
    sleep 0.05; n=$((n + 1))
    [ "$n" -lt 1200 ] || { fail "timed out waiting for $2"; return 1; }
  done
}

# The command runs unchanged: output and exit code pass through.
OUT="$(bash "$HEAVY" -- sh -c 'echo hello; exit 3' 2>&1; printf 'rc=%s' "$?")"
check "passes-output" "hello" "$OUT"
check "passes-exit-code" "rc=3" "$OUT"
check "stdin-reaches-command" "piped-in" "$(printf piped-in | bash "$HEAVY" -- cat)"
check "free-after-failure" "all slots free" "$(bash "$HEAVY" status)"

# One slot: the second caller starts only after the first has finished.
LOG="$W/order.log"; : > "$LOG"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label first -- sh -c "echo A-start >> '$LOG'; sleep 1; echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
ERR="$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label second -- sh -c "echo B-start >> '$LOG'" 2>&1)"
wait "$A"
equals "one-slot-serialises" "A-start A-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
check "waiting-caller-says-so" "waiting for one of 1" "$ERR"
check "waiting-caller-names-holder" "first" "$ERR"

# Two slots: both run at once.
: > "$LOG"
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" -- sh -c "echo A-start >> '$LOG'; sleep 1; echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'"
wait "$A"
equals "two-slots-run-together" "A-start B-start A-end" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"

# Many callers racing for one slot never overlap: every start is followed by its own end.
: > "$LOG"
for n in 1 2 3 4 5 6; do
  CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo s$n >> '$LOG'; sleep 0.15; echo e$n >> '$LOG'" 2>/dev/null &
done
wait
PAIRS="$(awk 'NR % 2 == 1 { s = substr($0, 2) } NR % 2 == 0 { if (substr($0, 2) != s || substr($0, 1, 1) != "e") bad = 1 } END { print (NR == 12 && !bad) ? "ok" : "overlap" }' "$LOG")"
equals "racing-callers-never-overlap" "ok" "$PAIRS"

# Work that outlives its starting process keeps the slot: a child that inherited the lock holds it
# until it exits, so the next caller cannot start on top of live work.
: > "$LOG"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "(sleep 1; echo A-end >> '$LOG') & echo A-start >> '$LOG'; exit 0"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'" 2>/dev/null
equals "surviving-child-keeps-slot" "A-start A-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"

# A launcher that starts its work through a process which closes inherited descriptors (Python's
# subprocess does by default) and is then killed must not free the slot while that work runs.
: > "$LOG"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label launcher -- python3 -c "
import os, subprocess, time
open('$W/launcher.pid', 'w').write(str(os.getpid()))
subprocess.Popen(['sh', '-c', 'echo C-start >> $LOG; sleep 1.2; echo C-end >> $LOG'])
time.sleep(30)
" 2>/dev/null &
A=$!
until_logged "$LOG" C-start
kill -9 "$(cat "$W/launcher.pid")"
sleep 0.2
check "killed-launcher-child-keeps-slot" "launcher" "$(bash "$HEAVY" status)"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'" 2>/dev/null
wait "$A" 2>/dev/null
equals "killed-launcher-work-finishes-first" "C-start C-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"

# A launcher that starts work and exits 0 returns its exit code at once, but the slot stays with
# the work until it finishes.
: > "$LOG"
OUT="$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label quick-launcher -- python3 -c "
import subprocess
subprocess.Popen(['sh', '-c', 'echo \$\$ > $W/e.pid; echo E-start >> $LOG; sleep 1.2; echo E-end >> $LOG'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
" 2>&1; printf 'rc=%s' "$?")"
check "clean-launcher-returns-its-code" "rc=0" "$OUT"
until_logged "$LOG" E-start
STATUS="$(bash "$HEAVY" status)"
check "clean-launcher-leftover-holds-slot" "holds the slot for leftover work" "$STATUS"
check "status-names-the-keeper" "keeper=" "$STATUS"
LIVE_SLEEP="$(cat "$W/e.pid")"   # this fixture's own worker, not whatever else runs on the machine
check "status-lists-current-members" "running now: " "$STATUS"
case "$STATUS" in *"$LIVE_SLEEP"*) pass "status-shows-the-live-worker" ;; *) fail "status-shows-the-live-worker ($LIVE_SLEEP not in: $STATUS)" ;; esac
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'" 2>/dev/null
equals "clean-launcher-work-finishes-first" "E-start E-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
until [ "$(bash "$HEAVY" status)" = "heavy.sh: all slots free" ]; do sleep 0.1; done

# Interrupting heavy.sh stops its whole group and frees the slot; nothing is left running.
: > "$LOG"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo D-start >> '$LOG'; sleep 2; echo D-end >> '$LOG'" &
A=$!
until_logged "$LOG" D-start
kill -TERM "$A"; wait "$A" 2>/dev/null
sleep 2.2
equals "interrupt-stops-the-group" "D-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
check  "interrupt-frees-slot" "all slots free" "$(bash "$HEAVY" status)"

# Killed work frees its slot: nothing to reclaim, no pid file to trust. Killing only the supervisor
# with SIGKILL leaves the slot with the work still holding its descriptor, which is intended; here
# the work itself is killed as well.
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label doomed -- sleep 30 &
A=$!
until [ -n "$(pgrep -P "$A" sleep)" ]; do sleep 0.05; done
check "status-names-holder" "doomed" "$(bash "$HEAVY" status)"
DOOMED="$(pgrep -P "$A" sleep)"
kill -9 "$A" $DOOMED; wait "$A" 2>/dev/null
OUT="$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- echo after-kill 2>&1)"
check "killed-work-frees-slot" "after-kill" "$OUT"
absent "killed-work-no-wait" "waiting" "$OUT"
check "status-when-free" "all slots free" "$(bash "$HEAVY" status)"

# A stale owner note with no lock behind it (the old failure: registration without a live holder)
# is not a held slot.
printf 'ghost pid=1\n' > "$W/slots/slot-1.owner"
check "stale-owner-note-ignored" "all slots free" "$(bash "$HEAVY" status)"
check "stale-owner-note-no-wait" "ran" "$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- echo ran 2>&1)"

# Nested: a suite inside a slot that calls heavy.sh for its build runs the build in its own slot.
OUT="$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label outer -- bash "$HEAVY" -- echo inner-ran 2>&1)"
check  "nested-call-runs" "inner-ran" "$OUT"
absent "nested-call-no-wait" "waiting" "$OUT"

check "no-command-refused" "no command" "$(bash "$HEAVY" -- 2>&1)"
check "bad-slots-refused" "positive integer" "$(bash "$HEAVY" --slots 0 -- true 2>&1)"

exit $fails
