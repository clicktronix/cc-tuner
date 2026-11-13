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

# event <pid> <session> <phase> <tool> <cwd> [path] -> what `peers.sh check` answers to one event.
event() {
  jq -nc --arg s "$2" --arg ph "$3" --arg t "$4" --arg c "$5" --arg p "${6:-}" \
    '{session_id: $s, phase: $ph, tool: $t, cwd: $c} + (if $p == "" then {} else {path: $p} end)' \
    | CC_TUNER_PEERS_CLAUDE_PID="$1" bash "$PEERS" check
}

# rec <session> <jq filter> -> a field of that session's record.
rec() { jq -r "$2" "$CC_TUNER_PEERS_DIR/$1.json" 2>/dev/null; }

# --- record: written on first touch ---------------------------------------------------------------
R1="$(flow_repo)"
peer; P1=$SP
event "$P1" s1 before Bash "$R1" >/dev/null
equals "record-written" "$P1" "$(rec s1 '.pid')"

exit $fails
