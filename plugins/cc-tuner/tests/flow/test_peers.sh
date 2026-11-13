#!/usr/bin/env bash
# peers.sh: sessions of one product see each other. Peers are simulated by `sleep` processes standing
# in for Claude pids (CC_TUNER_PEERS_CLAUDE_PID), with a record directory of the suite's own
# (CC_TUNER_PEERS_DIR); repositories are real, and so is the merge-tree they are compared with.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PEERS="$FLOW_PLUGIN/scripts/peers.sh"
HOOK="$FLOW_PLUGIN/hooks/session-start.sh"
W="$(flow_workdir)"
export CC_TUNER_PEERS_DIR="$W/peers"
unset CC_TUNER_PEERS_CLAUDE_PID CLAUDE_PID

# Every process this suite starts is stopped by its pid when the suite ends.
STARTED=""
cleanup() { for p in $STARTED; do kill "$p" 2>/dev/null; done; rm -rf "$FLOW_ROOT"; }
trap cleanup EXIT

# peer -> starts a stand-in Claude process and leaves its pid in $SP.
peer() { sleep 300 >/dev/null 2>&1 & SP=$!; disown "$SP" 2>/dev/null; STARTED="$STARTED $SP"; }

# stop <pid> -> kills a stand-in and waits until the process table no longer lists it.
stop() {
  kill "$1" 2>/dev/null
  until [ -z "$(ps -o lstart= -p "$1" 2>/dev/null)" ]; do sleep 0.05; done
}

# repo -> a repository on disk, printed by its real path (the one a record keys by).
repo() { (cd "$(flow_repo)" && pwd -P); }

# event <pid> <session> <phase> <tool> <cwd> [path] [ok] -> what `peers.sh check` answers to one event.
event() {
  jq -nc --arg s "$2" --arg ph "$3" --arg t "$4" --arg c "$5" --arg p "${6:-}" --arg ok "${7:-}" \
    '{session_id: $s, phase: $ph, tool: $t, cwd: $c}
     + (if $p == "" then {} else {path: $p} end) + (if $ok == "false" then {ok: false} else {} end)' \
    | CC_TUNER_PEERS_CLAUDE_PID="$1" bash "$PEERS" check
}

# start <pid> <session> <source> <cwd> -> the start line `peers.sh check` renders for a SessionStart.
start() {
  jq -nc --arg s "$2" --arg src "$3" --arg c "$4" '{session_id: $s, phase: "start", source: $src, cwd: $c}' \
    | CC_TUNER_PEERS_CLAUDE_PID="$1" bash "$PEERS" check
}

# report <cwd> <pid> -> `peers.sh report` run from cwd as the session of that pid.
report() { (cd "$1" && CC_TUNER_PEERS_CLAUDE_PID="$2" bash "$PEERS" report 2>&1); }

# edit_rec <session> <jq filter> -> rewrites that record in place, as a crashed or older writer might.
edit_rec() { jq -c "$2" "$CC_TUNER_PEERS_DIR/$1.json" > "$W/edit.tmp" && mv "$W/edit.tmp" "$CC_TUNER_PEERS_DIR/$1.json"; }

# records_of <pid> -> how many record files carry that pid.
records_of() { local n=0 f; for f in "$CC_TUNER_PEERS_DIR"/*.json; do [ -e "$f" ] && [ "$(jq -r .pid "$f" 2>/dev/null)" = "$1" ] && n=$((n + 1)); done; printf '%s' "$n"; }

# rec <session> <jq filter> -> a field of that session's record.
rec() { jq -r "$2" "$CC_TUNER_PEERS_DIR/$1.json" 2>/dev/null; }

# --- record: written on first touch ---------------------------------------------------------------
R1="$(repo)"
peer; P1=$SP
event "$P1" s1 before Bash "$R1" >/dev/null
equals "record-written" "$P1" "$(rec s1 '.pid')"
equals "record-carries-start-time" "$(ps -o lstart= -p "$P1" | sed 's/^ *//; s/ *$//')" "$(rec s1 '.start')"
equals "record-names-the-session" "s1" "$(rec s1 '.session_id')"
equals "check-answers-allow" '{"decision":"allow"}' "$(event "$P1" s1 before Bash "$R1")"

# The expected branch is the branch at first touch; a later switch does not move it.
equals "record-expected-first-touch" "main" "$(rec s1 ".checkouts[\"$R1\"].expected")"
( cd "$R1" && git switch -q -c other )
event "$P1" s1 before Bash "$R1" >/dev/null
equals "record-expected-stays" "main" "$(rec s1 ".checkouts[\"$R1\"].expected")"

# Edited paths: after a successful Edit or Write, relative to the checkout, read from the target path.
paths_of() { rec "$1" ".checkouts[\"$2\"].paths | join(\",\")"; }
event "$P1" s1 before Edit "$R1" "$R1/src/a.txt" >/dev/null
equals "record-edit-before-is-not-recorded" "" "$(paths_of s1 "$R1")"
event "$P1" s1 after Edit "$R1" "$R1/src/a.txt" >/dev/null
equals "record-edit-after-is-recorded" "src/a.txt" "$(paths_of s1 "$R1")"
event "$P1" s1 after Write "$R1" "src/b.txt" >/dev/null
equals "record-write-relative-path" "src/a.txt,src/b.txt" "$(paths_of s1 "$R1")"
event "$P1" s1 after Edit "$R1" "$R1/src/c.txt" false >/dev/null
event "$P1" s1 after Bash "$R1" "$R1/src/d.txt" >/dev/null
equals "record-failed-or-bash-call-adds-no-path" "src/a.txt,src/b.txt" "$(paths_of s1 "$R1")"
R2="$(repo)"
event "$P1" s1 after Edit "$R1" "$R2/other.txt" >/dev/null
equals "record-scope-is-the-target-not-the-cwd" "other.txt" "$(paths_of s1 "$R2")"
equals "record-cwd-checkout-keeps-its-paths" "src/a.txt,src/b.txt" "$(paths_of s1 "$R1")"

# Parallel writers lose no path, and parallel first touches make one record.
peer; P2=$SP
pids=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do event "$P2" s2 after Edit "$R1" "$R1/p$i.txt" >/dev/null & pids="$pids $!"; done
wait $pids
equals "record-parallel-no-path-lost" "12" "$(rec s2 ".checkouts[\"$R1\"].paths | length")"
equals "record-parallel-first-touch-one-record" "1" "$(records_of "$P2")"

# --- liveness: a record lives while its process lives, and a tombstone keeps for 24 h ---------------
peer; P3=$SP
event "$P3" s3 before Bash "$R1" >/dev/null
peer; PME=$SP
event "$PME" me before Bash "$R1" >/dev/null
check "report-lists-a-live-peer" "pid $P3" "$(report "$R1" "$PME")"
stop "$P3"
OUT="$(report "$R1" "$PME")"
absent "record-dead-pid-is-not-live" "pid $P3" "$OUT"
equals "record-dead-pid-becomes-a-tombstone" "number" "$(rec s3 '.dead | type')"
equals "record-tombstone-keeps-its-edits" "src/a.txt" "$(rec s1 ".checkouts[\"$R1\"].paths[0]")"

# A live pid with another start time is a different process: the record is not live.
peer; P4=$SP
event "$P4" s4 before Bash "$R1" >/dev/null
check "liveness-control-matching-start-is-live" "pid $P4" "$(report "$R1" "$PME")"
edit_rec s4 '.start = "Mon Jan  1 00:00:00 2001"'
if report "$R1" "$PME" | grep -q "pid $P4"; then
  fail "liveness-pid-reuse (a record whose pid was reused reads as live)"
else
  pass "liveness-pid-reuse"
fi
equals "record-reused-pid-becomes-a-tombstone" "number" "$(rec s4 '.dead | type')"

# The tombstone is removed after 24 h and kept before.
now="$(date +%s)"
edit_rec s3 ".dead = $((now - 25 * 3600))"
edit_rec s4 ".dead = $((now - 23 * 3600))"
report "$R1" "$PME" >/dev/null
equals "record-tombstone-expires-after-24h" "no" "$([ -e "$CC_TUNER_PEERS_DIR/s3.json" ] && echo yes || echo no)"
equals "record-tombstone-kept-within-24h" "yes" "$([ -e "$CC_TUNER_PEERS_DIR/s4.json" ] && echo yes || echo no)"

# --- resume adopts the tombstone; /clear drops acks and claims -------------------------------------
peer; P5=$SP
event "$P5" s5 after Edit "$R1" "$R1/kept.txt" >/dev/null
stop "$P5"
report "$R1" "$PME" >/dev/null
equals "record-resume-setup-is-a-tombstone" "number" "$(rec s5 '.dead | type')"
peer; P5B=$SP
start "$P5B" s5 resume "$R1" >/dev/null
equals "record-resume-adopts-the-pid" "$P5B" "$(rec s5 '.pid')"
equals "record-resume-revives" "null" "$(rec s5 '.dead')"
equals "record-resume-keeps-its-edits" "kept.txt" "$(paths_of s5 "$R1")"
equals "record-resume-makes-no-second-record" "1" "$(records_of "$P5B")"

peer; P6=$SP
event "$P6" s6 before Bash "$R1" >/dev/null
edit_rec s6 '.acks = {"k": 1} | .claims = {"plan.md": {"repo": "x", "paths": ["a"]}} | .kept = ["dev server"]'
start "$P6" s6b clear "$R1" >/dev/null
equals "record-clear-drops-acks" "{}" "$(rec s6 '.acks | tojson')"
equals "record-clear-drops-claims" "{}" "$(rec s6 '.claims | tojson')"
equals "record-clear-keeps-the-kept-task" "dev server" "$(rec s6 '.kept[0]')"
equals "record-clear-follows-the-new-session-id" "s6b" "$(rec s6 '.session_id')"
equals "record-clear-stays-one-record" "1" "$(records_of "$P6")"

# --- a record that does not parse is skipped with a note --------------------------------------------
printf '{not json' > "$CC_TUNER_PEERS_DIR/bad.json"
printf '[]' > "$CC_TUNER_PEERS_DIR/shape.json"
OUT="$(report "$R1" "$PME")"
check "record-malformed-is-noted" "skipped malformed record bad.json" "$OUT"
check "record-wrong-shape-is-noted" "skipped malformed record shape.json" "$OUT"
check "record-malformed-skips-only-itself" "pid $P6" "$OUT"
rm -f "$CC_TUNER_PEERS_DIR/bad.json" "$CC_TUNER_PEERS_DIR/shape.json"

# --- a nested `claude -p` counts as the outermost claude above it ----------------------------------
# The stand-ins are symlinks named claude, started detached so no real claude sits above them.
N="$W/nest"; mkdir "$N"; ln -s /bin/bash "$N/claude"
printf '%s\n' 'echo $$ > "$1/outer.pid"' '"$1/claude" "$1/inner.sh" "$1" &' 'wait' > "$N/outer.sh"
printf '%s\n' 'echo $$ > "$1/inner.pid"' 'sleep 300 &' 'echo $! > "$1/sleep.pid"' 'wait' > "$N/inner.sh"
( "$N/claude" "$N/outer.sh" "$N" </dev/null >/dev/null 2>&1 & )
n=0; until [ -s "$N/sleep.pid" ] || [ "$n" -ge 200 ]; do sleep 0.05; n=$((n + 1)); done
STARTED="$STARTED $(cat "$N/outer.pid" "$N/inner.pid" "$N/sleep.pid" 2>/dev/null | tr '\n' ' ')"
event "$(cat "$N/inner.pid")" s7 before Bash "$R1" >/dev/null
equals "record-nested-claude-is-its-outermost" "$(cat "$N/outer.pid")" "$(rec s7 '.pid')"
event "$(cat "$N/outer.pid")" s7 before Bash "$R1" >/dev/null
equals "record-nested-and-outer-share-one-record" "1" "$(records_of "$(cat "$N/outer.pid")")"

exit $fails
