#!/usr/bin/env bash
# Sessions of one product see each other, driven through real sessions. The guard lives in the hooks module
# (hooks/peers.ts); its decisions, record by record, are tested in hooks/peers.test.ts through test_mod.sh.
# This suite runs what only a real session shows: a `claude -p` loads the plugin, and the engine's $.fs and
# $.process.run, git and ps are the real ones. Only the model is a stand-in, a few lines of Python that
# answer each request with the next call of a script. Peers are `sleep` processes with records written here
# in the record schema, their start time read from ps; the record directory is the suite's own
# (CC_TUNER_PEERS_DIR).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

W="$(flow_workdir)"
export CC_TUNER_PEERS_DIR="$W/peers"
mkdir -p "$CC_TUNER_PEERS_DIR"

# Every process this suite starts is stopped by its pid when the suite ends.
STARTED=""
cleanup() { for p in $STARTED; do kill "$p" 2>/dev/null; done; rm -rf "$FLOW_ROOT"; }
trap cleanup EXIT

if ! command -v claude >/dev/null 2>&1; then
  fail "peers (claude is not on PATH; install @anthropic-ai/claude-code to drive the module)"
  exit $fails
fi

# peer -> starts a stand-in Claude process and leaves its pid in $SP.
peer() { sleep 300 >/dev/null 2>&1 & SP=$!; disown "$SP" 2>/dev/null; STARTED="$STARTED $SP"; }

# tree -> a stand-in Claude (pid $SP) with a child (pid $SC); nothing here is ever killed by the guard.
TN=0
tree() {
  TN=$((TN + 1))
  bash -c "sleep 3737 & echo \$! > \"\$1\"; wait" _ "$W/child.$TN" >/dev/null 2>&1 &
  SP=$!; disown "$SP" 2>/dev/null; STARTED="$STARTED $SP"
  local n=0; until [ -s "$W/child.$TN" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done
  SC="$(cat "$W/child.$TN")"; STARTED="$STARTED $SC"
}

repo() { (cd "$(flow_repo)" && pwd -P); }
commit_file() { ( cd "$1" && printf '%s\n' "$3" > "$2" && git add "$2" && git commit -q -m "$2" ); }
lstart() { LC_ALL=C ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//'; }

# fixture <name> <pid> <checkout> <writer epoch or null> [start] [paths json] -> a peer's record, as the
# module writes one.
fixture() {
  local common; common="$(cd "$3" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  jq -nc --arg s "$1" --argjson pid "$2" --arg st "${5:-$(lstart "$2")}" --arg top "$3" --arg repo "$common" \
    --argjson w "$4" --argjson paths "${6:-[]}" --arg b "$(git -C "$3" branch --show-current)" \
    '{session_id: $s, pid: $pid, start: $st, seen: (now | floor), claims: {}, acks: {}, kept: [],
      checkouts: {($top): {repo: $repo, expected: $b, writer: $w, paths: $paths}}}' > "$CC_TUNER_PEERS_DIR/$1.json"
}

# The model stand-in. Each line of the script file is {when, calls}: a conversation whose first message holds
# `when` is answered with its calls in order, one per request, then with "done". Every request is logged.
cat > "$W/fake_api.py" <<'PY'
import http.server, json, sys
scripts = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
log = sys.argv[2]
msg = [0]

def sse(*events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()

def text(m):
    c = m.get("content")
    return c if isinstance(c, str) else " ".join(b.get("text", "") for b in c if isinstance(b, dict))

class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        msgs = body.get("messages", [])
        with open(log, "a") as f:
            f.write(json.dumps(msgs) + "\n")
        first = text(msgs[0]) if msgs else ""
        script = next((s["calls"] for s in scripts if s["when"] in first), [])
        asked = sum(1 for m in msgs if isinstance(m.get("content"), list)
                    for b in m["content"] if isinstance(b, dict) and b.get("type") == "tool_result")
        call = script[asked] if body.get("tools") and asked < len(script) else None
        msg[0] += 1
        block = {"type": "text", "text": ""} if call is None else {"type": "tool_use", "id": "toolu_%d" % msg[0], "name": call["name"], "input": {}}
        delta = {"type": "text_delta", "text": "done"} if call is None else {"type": "input_json_delta", "partial_json": json.dumps(call["input"])}
        usage = {"input_tokens": 1, "output_tokens": 1}
        out = sse({"type": "message_start", "message": {"id": "m%d" % msg[0], "type": "message", "role": "assistant", "model": "fake", "content": [], "usage": usage}},
                  {"type": "content_block_start", "index": 0, "content_block": block},
                  {"type": "content_block_delta", "index": 0, "delta": delta},
                  {"type": "content_block_stop", "index": 0},
                  {"type": "message_delta", "delta": {"stop_reason": "end_turn" if call is None else "tool_use"}, "usage": usage},
                  {"type": "message_stop"})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        self.wfile.write(out)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
print(server.server_address[1], flush=True)
server.serve_forever()
PY

# e2e <repo> <claude args>... -> one `claude -p` session in repo answered by $W/script.jsonl; leaves its pid in
# $CP and every request in $W/api.log. $W/stdin, when present, is the session's input.
e2e() {
  local repo="$1" n=0; shift
  rm -f "$W/api.log" "$W/api.port"
  python3 "$W/fake_api.py" "$W/script.jsonl" "$W/api.log" > "$W/api.port" & API=$!; STARTED="$STARTED $API"
  until [ -s "$W/api.port" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done
  ( cd "$repo" && exec env CLAUDE_CONFIG_DIR="$W/claude-config" ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$W/api.port")" \
      ANTHROPIC_API_KEY=sk-ant-stand-in DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p --model haiku --plugin-dir "$FLOW_PLUGIN" --setting-sources project,local \
      --dangerously-skip-permissions "$@" < "${STDIN:-/dev/null}" > "$W/claude.out" 2>&1 ) & CP=$!; STARTED="$STARTED $CP"
  n=0; while kill -0 "$CP" 2>/dev/null && [ "$n" -lt 900 ]; do sleep 0.1; n=$((n + 1)); done
  { kill "$CP" "$API"; wait "$API"; } 2>/dev/null; rm -f "$W/api.port"
}
script() { printf '%s\n' "$@" > "$W/script.jsonl"; }
bash_call() { jq -nc --arg c "$1" '{name: "Bash", input: {command: $c}}'; }

# outermost <pid> -> the outermost `claude` from pid up, empty when there is none. A nested `claude -p` is its
# outermost parent's session, so a suite run inside Claude Code expects that pid, else the session's own.
outermost() {
  local p="$1" top=""
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    case "$(ps -o comm= -p "$p" | sed 's|.*/||')" in claude|claude.exe) top="$p" ;; esac
    p="$(ps -o ppid= -p "$p" | tr -d ' ')"
  done
  printf '%s' "$top"
}
session_pid() { outermost "$$" | grep . || printf %s "$CP"; }

# e2e_rec <jq filter> -> a field of the record of the session the last e2e ran as, found by its pid.
e2e_rec() {
  local f pid; pid="$(session_pid)"
  for f in "$CC_TUNER_PEERS_DIR"/*.json; do [ "$(jq -r .pid "$f" 2>/dev/null)" = "$pid" ] && { jq -r "$1" "$f"; return; }; done
}
said() { grep -cF -- "$1" "$W/api.log" | tr -d ' '; }

# --- one session: its record, the branch it expects, its edits, and a tool it calls ----------------------------
RT="$(repo)"
script "$(jq -nc --arg w "$W" --arg rt "$RT" '{when: "", calls: [
  {name: "Bash", input: {command: ("ps -A -o pid=,lstart= > " + $w + "/ps.txt")}},
  {name: "Bash", input: {command: "git switch -q -c e2e && git commit -q --allow-empty -m e2e"}},
  {name: "Write", input: {file_path: ($rt + "/notes.txt"), content: "n"}},
  {name: "mcp__cc-tuner__peers_release", input: {key: "chrome"}}]}')"
e2e "$RT" --session-id 00000000-0000-4000-8000-0000000000e1 go
check  "e2e-the-model-stand-in-finished" "done" "$(cat "$W/claude.out")"
equals "record-written-by-the-claude-process" "$(session_pid)" "$(e2e_rec .pid)"
equals "record-carries-the-ps-start-time" "$(awk -v p="$(session_pid)" '$1 == p { $1 = ""; sub(/^ +/, ""); print }' "$W/ps.txt")" "$(e2e_rec .start)"
equals "record-keys-the-real-checkout-path" "true" "$(e2e_rec ".checkouts | has(\"$RT\")")"
equals "guard-switch-moved-the-expectation" "e2e" "$(e2e_rec ".checkouts[\"$RT\"].expected")"
equals "guard-edit-recorded-its-path" "notes.txt" "$(e2e_rec ".checkouts[\"$RT\"].paths | join(\",\")")"
equals "guard-writer-call-marked-a-writer" "number" "$(e2e_rec ".checkouts[\"$RT\"].writer | type")"
check  "tool-release-answers" "cc-tuner: no leases yet." "$(cat "$W/api.log")"

# --- next to peers: the start line, stops, the ack, a note, report and claim, and a tool from a subagent ---------
RB="$(repo)"
commit_file "$RB" f.txt one
git -C "$RB" switch -q -c feat-o; commit_file "$RB" f.txt theirs
git -C "$RB" switch -q main; commit_file "$RB" f.txt mine
mkdir -p "$RB/docs"; printf '%s\n' '## Slice 1 — A' 'Owned paths: lib/' '- [ ] a' > "$RB/docs/p.md"
( cd "$RB" && git add docs && git commit -q -m plan )
git -C "$RB" worktree add -q "$W/wo" feat-o; WO="$(cd "$W/wo" && pwd -P)"
printf 'f\n' > "$RB/foreign.txt"
tree; PB=$SP; PBC=$SC; fixture pb "$PB" "$RB" "$(date +%s)" "" '["lib/x.ts"]'
peer; PO=$SP; fixture po "$PO" "$WO" null
peer; PX=$SP; fixture px "$PX" "$RB" null "Mon Jan  1 00:00:00 2001"
peer; PD=$SP; fixture pd "$PD" "$RB" null; kill "$PD"; until [ -z "$(lstart "$PD")" ]; do sleep 0.05; done
KEY="$(python3 -c 'import sys, zlib; print("%08x" % zlib.crc32(("switch|" + sys.argv[1]).encode()))' "$RB")"
objects() { find "$1/.git/objects" -type f | wc -l | tr -d ' '; }
BEFORE="$(objects "$RB")"
script '{"when": "SUBAGENT-REPORT", "calls": [{"name": "mcp__cc-tuner__peers_report", "input": {}}]}' \
  "$(jq -nc --arg k "$KEY" --arg c "$PBC" --arg b "$RB/b.txt" '{when: "", calls: [
    {name: "Bash", input: {command: "git clean -fd"}},
    {name: "Bash", input: {command: ("kill " + $c)}},
    {name: "Bash", input: {command: "bash -c '"'"'cd . && git switch -q -c z'"'"'"}},
    {name: "Bash", input: {command: ("CC_TUNER_ACK=" + $k + " bash -c '"'"'cd . && git switch -q -c z'"'"'")}},
    {name: "Write", input: {file_path: $b, content: "b"}},
    {name: "mcp__cc-tuner__peers_report", input: {}},
    {name: "mcp__cc-tuner__peers_claim", input: {plan: "docs/p.md"}},
    {name: "Agent", input: {description: "report", prompt: "SUBAGENT-REPORT", subagent_type: "general-purpose"}}]}')"
SIDB=00000000-0000-4000-8000-0000000000e2
e2e "$RB" --session-id "$SIDB" go
LOG="$(cat "$W/api.log")"
check  "start-line-on-startup"                 "cc-tuner: live peers: main ($(basename "$RB"), pid $PB)" "$LOG"
check  "start-line-names-the-tool"             "More: the peers_report tool." "$LOG"
check  "guard-foreign-file-stops-on-real-git"  'would delete foreign.txt in' "$LOG"
check  "guard-kill-of-a-peers-child-stops"     "would stop process $PBC, which belongs to pid $PB" "$LOG"
check  "guard-stop-reaches-the-model"          "run the same command prefixed CC_TUNER_ACK=$KEY" "$LOG"
check  "guard-stop-says-the-choice-is-the-agents" "not a question for the user" "$LOG"
equals "guard-acked-command-ran-without-the-prefix" "z" "$(git -C "$RB" branch --show-current)"
equals "guard-ack-is-recorded"                 "number" "$(e2e_rec ".acks[\"$KEY\"] | type")"
check  "guard-note-reaches-the-model"          "also writes in $RB" "$LOG"
equals "guard-noted-edit-ran"                  "b" "$(cat "$RB/b.txt" 2>/dev/null)"
check  "report-lists-a-live-peer"              "pid $PB  z  $RB" "$LOG"
check  "report-lists-the-worktree-peer"        "pid $PO  feat-o  $WO" "$LOG"
check  "report-shows-edited-paths"             "edited: lib/x.ts" "$LOG"
check  "report-conflict-names-the-file"        "conflicts with HEAD: f.txt" "$LOG"
equals "liveness-pid-reuse-on-real-ps"         "0" "$(said "pid $PX  ")"
equals "record-dead-pid-is-not-live"           "0" "$(said "pid $PD  ")"
equals "report-object-store-unchanged"         "$BEFORE" "$(objects "$RB")"
equals "report-leaves-no-temporary-objects"    "0" "$(ls -a "$CC_TUNER_PEERS_DIR" | grep -c '^\.objects\.')"
check  "claim-prints-the-overlap"              "overlap with your claims: lib/ ~ lib/x.ts" "$LOG"
equals "claim-publishes-open-owned-paths"      "lib/" "$(e2e_rec '.claims["docs/p.md"].paths | join(",")')"
equals "tool-report-from-a-subagent" "true" "$(jq -s --arg p "pid $PB  z  $RB" 'map(select((.[0] | tostring | contains("SUBAGENT-REPORT")) and (tostring | contains($p)))) | length > 0' "$W/api.log")"

# --- resume and /clear bring the start line too ------------------------------------------------------------------
script '{"when": "", "calls": []}'
e2e "$RB" --resume "$SIDB" go
check  "start-line-on-resume" "cc-tuner: live peers:" "$(cat "$W/api.log")"
equals "record-resume-adopts-the-tombstone" "number" "$(e2e_rec ".acks[\"$KEY\"] | type")"

script '{"when": "after-clear", "calls": []}' "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "CC_TUNER_ACK=0000abcd git status"}}]}')"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"first"}}' '{"type":"user","message":{"role":"user","content":"/clear"}}' \
  '{"type":"user","message":{"role":"user","content":"after-clear"}}' > "$W/stdin"
STDIN="$W/stdin" e2e "$RB" --session-id 00000000-0000-4000-8000-0000000000e3 --input-format stream-json --output-format stream-json --verbose
check  "start-line-on-clear" "cc-tuner: live peers:" "$(grep -F 'after-clear' "$W/api.log" | tail -n 1)"
equals "record-clear-drops-acks" "null" "$(e2e_rec '.acks["0000abcd"]')"
absent "record-clear-follows-the-new-session-id" "0000000000e3" "$(e2e_rec .session_id)"

# --- latency: the module decides in at most 150 ms p95 over 50 calls with 10 records --------------------------------
# Ten live peers in the call's repository, none a writer, so a switch is a note and the commit after it is read too:
# the checkout of each step, the start times of the ten, HEAD, and `git status`. The module logs each decision's time
# to the debug log. Wall time includes the load of the machine, so up to three sessions run and the best p95 decides.
OUTER_DIR="$CC_TUNER_PEERS_DIR"; export CC_TUNER_PEERS_DIR="$W/lat-peers"; mkdir -p "$CC_TUNER_PEERS_DIR"
RL="$(repo)"; git -C "$RL" branch x
for i in 1 2 3 4 5 6 7 8 9 10; do peer; fixture "lat$i" "$SP" "$RL" null; done
calls=""; for i in $(seq 1 50); do calls="$calls$(bash_call 'git switch -q x && git commit -q -m m'),"; done
script "{\"when\": \"\", \"calls\": [${calls%,}]}"
ROUNDS=""
for round in 1 2 3; do
  rm -f "$W/debug.log"
  e2e "$RL" --debug-file "$W/debug.log" go
  P95="$(sed -n 's/.*cc-tuner: peers decided note in \([0-9]*\) ms.*/\1/p' "$W/debug.log" | sort -n | awk '{ v[NR] = $1 } END { print (NR < 50 ? "n=" NR : v[48]) }')"
  ROUNDS="${ROUNDS:+$ROUNDS/}$P95"
  case "$P95" in n=*) break ;; esac
  [ "$P95" -le 150 ] && break
done
export CC_TUNER_PEERS_DIR="$OUTER_DIR"
BEST="$(printf '%s' "$ROUNDS" | tr '/' '\n' | grep -v '^n=' | sort -n | head -n 1)"
if [ -n "$BEST" ] && [ "$BEST" -le 150 ]; then pass "latency (p95 $ROUNDS ms per round over 50 calls with 10 records)"
else fail "latency (p95 $ROUNDS ms per round, want at most 150)"; fi

exit $fails
