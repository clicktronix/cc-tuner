#!/usr/bin/env bash
# heavy.sh: machine-wide slots for heavy checks. Several sessions each starting e2e at once is what
# froze the machine. These cases prove the second caller waits, the exit code passes through, a slot
# follows the life of the work (not of a wrapper or a pid file), concurrent callers never overlap,
# and a nested call runs inside its parent's slot instead of waiting for it.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HEAVY="$FLOW_PLUGIN/scripts/heavy.sh"
W="$(flow_workdir)"
# The machine's RAM must not decide any case: capacity is derived from this seam (16 GB -> 2 slots)
# unless a case sets CC_TUNER_HEAVY_SLOTS itself.
# Memory pressure is pinned to normal the same way: no case may depend on how loaded this machine is.
export CC_TUNER_HEAVY_DIR="$W/slots" CC_TUNER_HEAVY_POLL=0.1 CC_TUNER_HEAVY_TOTAL_MB=16384 CC_TUNER_HEAVY_PRESSURE=normal
unset CC_TUNER_HEAVY_HELD CC_TUNER_HEAVY_SLOTS CC_TUNER_HEAVY_PROC CC_TUNER_HEAVY_MEM_WAIT

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

# until_waiting_or_started <err-file> <log> <marker>: a caller that was let through instead of made to
# wait ends this wait at once, so the assertion after it names the real failure instead of a timeout.
until_waiting_or_started() {
  local n=0
  until grep -q "waiting" "$1" 2>/dev/null || grep -q "$3" "$2" 2>/dev/null; do
    sleep 0.05; n=$((n + 1))
    [ "$n" -lt 1200 ] || { fail "timed out waiting for $3 or a wait"; return 1; }
  done
}

# The command runs unchanged: output and exit code pass through.
OUT="$(bash "$HEAVY" -- sh -c 'echo hello; exit 3' 2>&1; printf 'rc=%s' "$?")"
check "passes-output" "hello" "$OUT"
check "passes-exit-code" "rc=3" "$OUT"
check "stdin-reaches-command" "piped-in" "$(printf piped-in | bash "$HEAVY" -- cat)"
check "free-after-failure" "all slots free" "$(bash "$HEAVY" status)"

# One slot: the second caller starts only after the first has finished. The first holds its slot
# until the second has said it is waiting (released by the test, at most 10 s), so a slow start of
# the second caller under load cannot turn into "nobody waited".
LOG="$W/order.log"; : > "$LOG"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label first -- sh -c "echo A-start >> '$LOG'; i=0; while [ ! -f '$W/a.release' ] && [ \$i -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done; echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label second -- sh -c "echo B-start >> '$LOG'" 2> "$W/second.err" &
B=$!
until_logged "$W/second.err" "waiting"
touch "$W/a.release"
wait "$B"
wait "$A"
ERR="$(cat "$W/second.err")"
equals "one-slot-serialises" "A-start A-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
check "waiting-caller-says-so" "waiting for one of 1" "$ERR"
check "waiting-caller-names-holder" "first" "$ERR"

# Two slots: both run at once. A holds its slot until B has started (up to 10 s) instead of
# sleeping a fixed second: on a loaded machine B's start can take longer than a second, and a timed
# window then reads as "B waited". If B really waited, A gives up and the order still shows it.
: > "$LOG"
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" -- sh -c "echo A-start >> '$LOG'; i=0; while ! grep -q B-start '$LOG' && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done; echo A-end >> '$LOG'" &
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
subprocess.Popen(['sh', '-c', 'echo C-start >> $LOG; i=0; while [ ! -f $W/c.release ] && [ \$i -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done; echo C-end >> $LOG'])
time.sleep(30)
" 2>/dev/null &
A=$!
until_logged "$LOG" C-start
kill -9 "$(cat "$W/launcher.pid")"
sleep 0.2
check "killed-launcher-child-keeps-slot" "launcher" "$(bash "$HEAVY" status)"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'" 2>/dev/null &
B=$!
sleep 0.3
touch "$W/c.release"   # C runs until released (at most 10 s): a timed C can end before status is read.
wait "$B"
wait "$A" 2>/dev/null
equals "killed-launcher-work-finishes-first" "C-start C-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"

# A launcher that starts work and exits 0 returns its exit code at once, but the slot stays with
# the work until it finishes. The work runs until the test releases it (at most 10 s), not for a
# fixed time: under load a timed worker can finish before `status` is read.
: > "$LOG"
OUT="$(CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label quick-launcher -- python3 -c "
import subprocess
subprocess.Popen(['sh', '-c', 'echo \$\$ > $W/e.pid; echo E-start >> $LOG; i=0; while [ ! -f $W/e.release ] && [ \$i -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done; echo E-end >> $LOG'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
" 2>&1; printf 'rc=%s' "$?")"
check "clean-launcher-returns-its-code" "rc=0" "$OUT"
until_logged "$LOG" E-start
STATUS="$(bash "$HEAVY" status)"
check "clean-launcher-leftover-holds-slot" "holds the slot for leftover work" "$STATUS"
check "status-names-the-keeper" "keeper=" "$STATUS"
LIVE_SLEEP="$(cat "$W/e.pid")"   # this fixture's own worker, not whatever else runs on the machine
check "status-lists-current-members" "running now: " "$STATUS"
case "$STATUS" in *"$LIVE_SLEEP"*) pass "status-shows-the-live-worker" ;; *) fail "status-shows-the-live-worker ($LIVE_SLEEP not in: $STATUS)" ;; esac
# B asks for the slot while E still holds it; releasing E must come before B can start.
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'" 2>/dev/null &
B=$!
sleep 0.3
touch "$W/e.release"
wait "$B"
equals "clean-launcher-work-finishes-first" "E-start E-end B-start" "$(tr '\n' ' ' < "$LOG" | sed 's/ $//')"
until bash "$HEAVY" status | grep -q "all slots free"; do sleep 0.1; done

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

# --- Capacity, weights and arrival order -------------------------------------------------------
order() { tr '\n' ' ' < "$LOG" | sed 's/ $//'; }
# hold_until <release-file>: the work under test runs until the test releases it (at most 10 s).
hold_until() { printf 'i=0; while [ ! -f %s ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done' "'$1'"; }

# Capacity is max(1, floor(total / 8 GB)); a set value wins; --slots is a synonym.
cap() { env "$@" bash "$HEAVY" status | head -n 1; }
check "capacity-16gb-is-2" "capacity 2" "$(cap CC_TUNER_HEAVY_TOTAL_MB=16384)"
check "capacity-7gb-is-1" "capacity 1" "$(cap CC_TUNER_HEAVY_TOTAL_MB=7168)"
check "capacity-1gb-is-1" "capacity 1" "$(cap CC_TUNER_HEAVY_TOTAL_MB=1024)"
check "capacity-8gb-is-1" "capacity 1" "$(cap CC_TUNER_HEAVY_TOTAL_MB=8192)"
check "capacity-24gb-is-3" "capacity 3" "$(cap CC_TUNER_HEAVY_TOTAL_MB=24576)"
check "capacity-64gb-is-8" "capacity 8" "$(cap CC_TUNER_HEAVY_TOTAL_MB=65536)"
check "set-slots-wins-over-ram" "capacity 3" "$(cap CC_TUNER_HEAVY_TOTAL_MB=65536 CC_TUNER_HEAVY_SLOTS=3)"

# The Linux reader: MemTotal is in kB and the machine reports a little under its nominal size, so it
# is rounded up to a whole GiB (15.56 GiB reads as 16, not as 1 slot).
mkdir -p "$W/linux/bin" "$W/linux/proc"
printf '#!/bin/sh\necho Linux\n' > "$W/linux/bin/uname"; chmod +x "$W/linux/bin/uname"
linux_cap() {
  printf 'MemTotal:       %s kB\nMemFree:        1 kB\n' "$1" > "$W/linux/proc/meminfo"
  env -u CC_TUNER_HEAVY_TOTAL_MB PATH="$W/linux/bin:$PATH" CC_TUNER_HEAVY_PROC="$W/linux/proc" bash "$HEAVY" status | head -n 1
}
check "linux-memtotal-16gb-rounds-up" "capacity 2" "$(linux_cap 16314632)"
check "linux-memtotal-8gb-rounds-up" "capacity 1" "$(linux_cap 8000000)"
check "linux-memtotal-24gb-rounds-up" "capacity 3" "$(linux_cap 24428000)"
check "linux-memtotal-4gb-is-1" "capacity 1" "$(linux_cap 4000000)"

# The real reader on this machine agrees with an independent reading of the same figure.
WANT="$(python3 - <<'PYEOF'
import platform, subprocess
if platform.system() == "Darwin":
    gib = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"])) // 2**30
else:
    kb = next(int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemTotal:"))
    gib = -(-kb // 2**20)
print(max(1, gib // 8))
PYEOF
)"
check "real-reader-matches-this-machine" "capacity $WANT" "$(env -u CC_TUNER_HEAVY_TOTAL_MB bash "$HEAVY" status | head -n 1)"

# Derived capacity runs two weight-1 checks together without any slot setting.
: > "$LOG"
bash "$HEAVY" -- sh -c "echo A-start >> '$LOG'; i=0; while ! grep -q B-start '$LOG' && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done; echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
bash "$HEAVY" -- sh -c "echo B-start >> '$LOG'"
wait "$A"
equals "derived-capacity-runs-two-together" "A-start B-start A-end" "$(order)"

# A weight above capacity runs alone and says it was clamped.
OUT="$(CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --weight 3 -- echo clamped-ran 2>&1)"
check "overweight-runs" "clamped-ran" "$OUT"
check "overweight-says-clamped" "clamped" "$OUT"
OUT="$(CC_TUNER_HEAVY_SLOTS=4 bash "$HEAVY" --slots 1 --weight 2 -- echo syn-ran 2>&1)"
check "slots-flag-sets-capacity" "capacity 1" "$OUT"
OUT="$(CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --weight 2 -- echo fits 2>&1)"
absent "fitting-weight-not-clamped" "clamped" "$OUT"
check "bad-weight-refused" "positive integer" "$(bash "$HEAVY" --weight 0 -- true 2>&1)"

# Capacity 2: a weight-2 check starts only when both slots are free.
: > "$LOG"; rm -f "$W/a.release" "$W/h.release"
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --label holder -- sh -c "echo A-start >> '$LOG'; $(hold_until "$W/a.release"); echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --weight 2 --label double -- sh -c "echo H-start >> '$LOG'; echo H-end >> '$LOG'" 2> "$W/h.err" &
H=$!
until_logged "$W/h.err" "waiting"
equals "weight-two-waits-for-both-slots" "A-start" "$(order)"
check "weighted-waiter-says-so" "waiting for 2 of 2" "$(cat "$W/h.err")"
touch "$W/a.release"
wait "$H"; wait "$A"
equals "weight-two-starts-after-both-free" "A-start A-end H-start H-end" "$(order)"

# Arrival order: a weight-1 check that arrives while a weight-2 check waits does not start before it,
# and the waiting head keeps the slot it already took.
: > "$LOG"; rm -f "$W/a.release" "$W/h.release"
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --label first -- sh -c "echo A-start >> '$LOG'; $(hold_until "$W/a.release"); echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --weight 2 --label heavyhead -- sh -c "echo H-start >> '$LOG'; $(hold_until "$W/h.release"); echo H-end >> '$LOG'" 2> "$W/h.err" &
H=$!
until_logged "$W/h.err" "waiting"
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --label late -- sh -c "echo C-start >> '$LOG'; echo C-end >> '$LOG'" 2> "$W/c.err" &
C=$!
until_waiting_or_started "$W/c.err" "$LOG" C-start
equals "weight-one-does-not-start-before-waiting-head" "A-start" "$(order)"
STATUS="$(bash "$HEAVY" status)"
check "head-keeps-the-slot-it-took" "heavyhead" "$STATUS"
check "status-shows-holder-weight" "weight=2" "$STATUS"
check "status-shows-queued-pid" "queued: pid=$H " "$STATUS"
check "status-shows-queued-age" "age=" "$STATUS"
check "status-shows-queue-order" "queued: pid=$H " "$(printf '%s' "$STATUS" | sed -n '/queued/{p;q;}')"
touch "$W/a.release"
until_logged "$LOG" H-start
equals "head-starts-when-last-slot-frees" "A-start A-end H-start" "$(order)"
touch "$W/h.release"
wait "$H"; wait "$C"; wait "$A"
equals "arrival-order-is-kept" "A-start A-end H-start H-end C-start C-end" "$(order)"

# A slot held by the pre-change heavy.sh (slot-1..N, weight 1, no queue) blocks the new one.
OLD="$W/heavy-old.sh"
git -C "$FLOW_PLUGIN" show 45795a7:plugins/cc-tuner/scripts/heavy.sh > "$OLD" 2>/dev/null || fail "pre-change heavy.sh not retrievable (fetch-depth 0 needed)"
: > "$LOG"; rm -f "$W/o.release"
CC_TUNER_HEAVY_SLOTS=1 bash "$OLD" --label oldholder -- sh -c "echo O-start >> '$LOG'; $(hold_until "$W/o.release"); echo O-end >> '$LOG'" &
O=$!
until_logged "$LOG" O-start
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" -- sh -c "echo N-start >> '$LOG'" 2> "$W/n.err" &
N=$!
until_logged "$W/n.err" "waiting"
equals "pre-change-holder-blocks-new" "O-start" "$(order)"
touch "$W/o.release"
wait "$N"; wait "$O"
equals "new-starts-after-pre-change-holder" "O-start O-end N-start" "$(order)"

# A pre-change waiter does not overtake a weight-2 head. The old waiter retries every 5 s; the head
# retries every 0.1 s, so it has the freed slot long before the old waiter looks.
: > "$LOG"; rm -f "$W/o.release" "$W/h.release"
CC_TUNER_HEAVY_SLOTS=2 bash "$OLD" --label oldholder -- sh -c "echo O-start >> '$LOG'; $(hold_until "$W/o.release"); echo O-end >> '$LOG'" &
O=$!
until_logged "$LOG" O-start
CC_TUNER_HEAVY_SLOTS=2 bash "$HEAVY" --weight 2 --label heavyhead -- sh -c "echo H-start >> '$LOG'; $(hold_until "$W/h.release"); echo H-end >> '$LOG'" 2> "$W/h.err" &
H=$!
until_logged "$W/h.err" "waiting"
CC_TUNER_HEAVY_SLOTS=2 CC_TUNER_HEAVY_POLL=5 bash "$OLD" --label oldwaiter -- sh -c "echo L-start >> '$LOG'" 2> "$W/l.err" &
L=$!
until_logged "$W/l.err" "waiting"
touch "$W/o.release"
until_logged "$LOG" H-start
equals "pre-change-waiter-does-not-overtake-head" "O-start O-end H-start" "$(order)"
touch "$W/h.release"
wait "$H"; wait "$L"; wait "$O"
equals "pre-change-waiter-starts-after-head" "O-start O-end H-start H-end L-start" "$(order)"

# A waiter that died leaves a ticket nobody holds; it must not block the ones behind it.
: > "$LOG"; rm -f "$W/a.release"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label holder -- sh -c "echo A-start >> '$LOG'; $(hold_until "$W/a.release"); echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label doomedwaiter -- sh -c "echo D-start >> '$LOG'" 2> "$W/d.err" &
D=$!
until_logged "$W/d.err" "waiting"
kill -9 "$D"; wait "$D" 2>/dev/null
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label survivor -- sh -c "echo C-start >> '$LOG'" 2> "$W/c.err" &
C=$!
until_logged "$W/c.err" "waiting"
absent "dead-ticket-not-listed" "pid=$D " "$(bash "$HEAVY" status)"
touch "$W/a.release"
if until_logged "$LOG" C-start; then
  pass "dead-ticket-does-not-block"
else
  kill "$C" 2>/dev/null
fi
wait "$C" 2>/dev/null; wait "$A"
equals "dead-waiter-never-ran" "A-start A-end C-start" "$(order)"

# A waiter whose caller died leaves the queue by itself while the slot is still taken.
: > "$LOG"; rm -f "$W/a.release"
CC_TUNER_HEAVY_SLOTS=1 bash "$HEAVY" --label holder -- sh -c "echo A-start >> '$LOG'; $(hold_until "$W/a.release"); echo A-end >> '$LOG'" &
A=$!
until_logged "$LOG" A-start
CC_TUNER_HEAVY_SLOTS=1 sh -c "bash '$HEAVY' --label orphanwaiter -- sh -c 'echo X-start >> $LOG' 2> '$W/x.err' & echo \$! > '$W/x.pid'; wait" &
P=$!
until_logged "$W/x.err" "waiting"
X="$(cat "$W/x.pid")"
check "queued-waiter-is-listed" "queued: pid=$X " "$(bash "$HEAVY" status)"
kill -9 "$P"; wait "$P" 2>/dev/null
n=0
while kill -0 "$X" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
if kill -0 "$X" 2>/dev/null; then fail "orphaned-waiter-leaves-queue"; kill -9 "$X" 2>/dev/null; else pass "orphaned-waiter-leaves-queue"; fi
absent "orphaned-waiter-not-listed" "pid=$X " "$(bash "$HEAVY" status)"
touch "$W/a.release"; wait "$A"
equals "orphaned-waiter-never-ran" "A-start A-end" "$(order)"
until bash "$HEAVY" status | grep -q "all slots free"; do sleep 0.1; done


# --- Memory pressure ----------------------------------------------------------------------------
# The head of the queue holds its slots and waits while the OS reports pressure; the wait is bounded.
rm -f "$W/slots/memory-deficit"
for LEVEL in warn critical; do
  : > "$LOG"
  CC_TUNER_HEAVY_PRESSURE=$LEVEL CC_TUNER_HEAVY_MEM_WAIT=60 bash "$HEAVY" --label pressured -- sh -c "echo P-start >> '$LOG'" 2> "$W/p.err" &
  P=$!
  until_waiting_or_started "$W/p.err" "$LOG" P-start
  sleep 0.3
  equals "pressure-$LEVEL-head-does-not-start" "" "$(order)"
  check "pressure-$LEVEL-says-what-it-waits-for" "waiting for memory pressure" "$(cat "$W/p.err")"
  STATUS="$(CC_TUNER_HEAVY_PRESSURE=$LEVEL bash "$HEAVY" status)"
  check "pressure-$LEVEL-shown-by-status" "memory pressure: $LEVEL" "$STATUS"
  check "pressure-$LEVEL-head-keeps-its-slot" "pressured" "$STATUS"
  kill "$P" 2>/dev/null; wait "$P" 2>/dev/null
done

# A reading that turns normal lets the head start; the reason is printed once. Driven through the real
# Linux reader on a fixture the test rewrites.
mkdir -p "$W/linux/proc/pressure"
psi() { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$1" > "$W/linux/proc/pressure/memory"; }
linux_env() { env -u CC_TUNER_HEAVY_PRESSURE PATH="$W/linux/bin:$PATH" CC_TUNER_HEAVY_PROC="$W/linux/proc" "$@"; }
: > "$LOG"; psi 25.00
linux_env CC_TUNER_HEAVY_MEM_WAIT=60 bash "$HEAVY" -- sh -c "echo P-start >> '$LOG'" 2> "$W/p.err" &
P=$!
until_waiting_or_started "$W/p.err" "$LOG" P-start
sleep 0.3
equals "pressure-holds-the-head-while-high" "" "$(order)"
psi 3.00
until_logged "$LOG" P-start
wait "$P"
equals "pressure-gone-head-starts" "P-start" "$(order)"
equals "pressure-reason-printed-once" "1" "$(grep -c 'waiting for memory pressure' "$W/p.err")"
absent "pressure-gone-no-forced-line" "started under memory pressure" "$(cat "$W/p.err")"

# Normal pressure does not wait or say anything; an unreadable signal starts and says so.
OUT="$(bash "$HEAVY" -- echo normal-ran 2>&1)"
check "normal-pressure-starts" "normal-ran" "$OUT"
absent "normal-pressure-is-silent" "memory pressure" "$OUT"
OUT="$(CC_TUNER_HEAVY_PRESSURE=unknown bash "$HEAVY" -- echo unknown-ran 2>&1)"
check "unreadable-pressure-starts" "unknown-ran" "$OUT"
check "unreadable-pressure-says-so" "pressure not measured" "$OUT"

# The wait honours the caller going away.
: > "$LOG"
CC_TUNER_HEAVY_PRESSURE=warn CC_TUNER_HEAVY_MEM_WAIT=60 sh -c "bash '$HEAVY' --label orphanpressure -- sh -c 'echo Y-start >> $LOG' 2> '$W/y.err' & echo \$! > '$W/y.pid'; wait" &
P=$!
until_waiting_or_started "$W/y.err" "$LOG" Y-start
Y="$(cat "$W/y.pid")"
kill -9 "$P"; wait "$P" 2>/dev/null
n=0
while kill -0 "$Y" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
if kill -0 "$Y" 2>/dev/null; then fail "pressure-wait-honours-caller-gone"; kill -9 "$Y" 2>/dev/null; else pass "pressure-wait-honours-caller-gone"; fi
check "pressure-wait-says-caller-gone" "the caller is gone" "$(cat "$W/y.err")"
equals "pressure-wait-orphan-never-ran" "" "$(order)"

# The readers parse what the OS prints. Linux: some avg10 >= 10 is pressure; a missing file is not measured.
read_linux() { linux_env bash "$HEAVY" status | grep 'memory pressure'; }
psi 0.00;  check "linux-psi-idle-is-normal" "memory pressure: normal" "$(read_linux)"
psi 9.99;  check "linux-psi-9.99-is-normal" "memory pressure: normal" "$(read_linux)"
psi 10.00; check "linux-psi-10-is-warn" "memory pressure: warn" "$(read_linux)"
psi 52.31; check "linux-psi-high-is-warn" "memory pressure: warn" "$(read_linux)"
rm -f "$W/linux/proc/pressure/memory"
check "linux-psi-missing-is-not-measured" "memory pressure: not measured" "$(read_linux)"
# macOS: kern.memorystatus_vm_pressure_level 1 normal, 2 warn, 4 critical.
mkdir -p "$W/mac/bin"
printf '#!/bin/sh\necho Darwin\n' > "$W/mac/bin/uname"; chmod +x "$W/mac/bin/uname"
printf '#!/bin/sh\n[ "$2" = kern.memorystatus_vm_pressure_level ] || exit 1\necho "$FAKE_LEVEL"\n' > "$W/mac/bin/sysctl"; chmod +x "$W/mac/bin/sysctl"
read_mac() { env -u CC_TUNER_HEAVY_PRESSURE PATH="$W/mac/bin:$PATH" FAKE_LEVEL="$1" bash "$HEAVY" status | grep 'memory pressure'; }
check "macos-level-1-is-normal" "memory pressure: normal" "$(read_mac 1)"
check "macos-level-2-is-warn" "memory pressure: warn" "$(read_mac 2)"
check "macos-level-4-is-critical" "memory pressure: critical" "$(read_mac 4)"
check "macos-unreadable-is-not-measured" "memory pressure: not measured" "$(read_mac '')"
check "macos-unknown-level-is-not-measured" "memory pressure: not measured" "$(read_mac 3)"
# The real reader on this machine returns a reading, not "not measured".
if [ "$(uname -s)" = Darwin ] || [ -r /proc/pressure/memory ]; then
  REAL="$(env -u CC_TUNER_HEAVY_PRESSURE bash "$HEAVY" status | grep 'memory pressure')"
  case "$REAL" in *"memory pressure: "[a-z]*) ;; *) REAL="" ;; esac
  case "$REAL" in *"not measured"*|"") fail "real-pressure-reader-measures-this-machine ($REAL)" ;; *) pass "real-pressure-reader-measures-this-machine" ;; esac
fi

# After CC_TUNER_HEAVY_MEM_WAIT the head starts anyway, says so, and leaves a deficit mark: checks that
# arrive while it is live do not wait again. Both the mark and its end are visible in status.
rm -f "$W/slots/memory-deficit"; : > "$LOG"
OUT="$(CC_TUNER_HEAVY_PRESSURE=critical CC_TUNER_HEAVY_MEM_WAIT=4 bash "$HEAVY" -- sh -c "echo F-start >> '$LOG'" 2>&1)"
check "forced-start-says-so" "heavy.sh: started under memory pressure after 4s" "$OUT"
equals "forced-start-runs-the-command" "F-start" "$(order)"
check "status-shows-deficit-mark" "memory deficit mark: active" "$(CC_TUNER_HEAVY_PRESSURE=critical bash "$HEAVY" status)"
OUT="$(CC_TUNER_HEAVY_PRESSURE=critical CC_TUNER_HEAVY_MEM_WAIT=60 bash "$HEAVY" -- echo next-ran 2>&1)"
check "check-under-deficit-mark-starts" "next-ran" "$OUT"
absent "check-under-deficit-mark-does-not-wait" "waiting" "$OUT"
absent "check-under-deficit-mark-no-second-forced-line" "started under memory pressure" "$OUT"
n=0
while CC_TUNER_HEAVY_PRESSURE=critical bash "$HEAVY" status | grep -q "deficit mark" && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); done
absent "deficit-mark-ends" "deficit mark" "$(CC_TUNER_HEAVY_PRESSURE=critical bash "$HEAVY" status)"
: > "$LOG"
CC_TUNER_HEAVY_PRESSURE=critical CC_TUNER_HEAVY_MEM_WAIT=60 bash "$HEAVY" -- sh -c "echo R-start >> '$LOG'" 2> "$W/r.err" &
P=$!
until_waiting_or_started "$W/r.err" "$LOG" R-start
sleep 0.3
equals "expired-deficit-mark-waits-again" "" "$(order)"
kill "$P" 2>/dev/null; wait "$P" 2>/dev/null
rm -f "$W/slots/memory-deficit"
until bash "$HEAVY" status | grep -q "all slots free"; do sleep 0.1; done

check "no-command-refused" "no command" "$(bash "$HEAVY" -- 2>&1)"
check "bad-slots-refused" "positive integer" "$(bash "$HEAVY" --slots 0 -- true 2>&1)"

# `status` read a holder file between its truncate and its write and printed "unknown holder"
# (release PR #64, ubuntu CI). The window is too short to hit on demand, so the guard is on the
# writes: every one replaces the file whole through write_owner.
if grep -nE 'open\(owner_path\([^)]*\), *"[wa]"' "$HEAVY" >/dev/null; then
  fail "owner-file-written-in-place"
else
  pass "owner-file-replaced-whole"
fi

if python3 "$(dirname "$0")/test_heavy_owner.py"; then
  pass "owner-publication-is-atomic-to-status"
else
  fail "owner-publication-is-atomic-to-status"
fi

exit $fails
