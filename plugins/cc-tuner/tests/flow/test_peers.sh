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

# The machine's own resources file: an exclusive resource over the tools of the stand-in MCP server below.
export CC_TUNER_PEERS_CONFIG="$W/machine-resources.json"
printf '%s\n' '{"resources":[{"key":"lab","kind":"exclusive","tools":["mcp__lab__*"]}]}' > "$CC_TUNER_PEERS_CONFIG"

# Managed settings on the machine put the built-in cc-plugin-sec-default outermost, and it passes `classic.*` events
# past a user-installed plugin's module (Team and Enterprise organizations get it too). Every session here runs
# under them, so a hook that rides a classic event never reaches the model in this suite either.
MANAGED='{"permissions":{"deny":["WebFetch"]}}'

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
lstart() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//'; }

# fixture <name> <pid> <checkout> <writer epoch or null> [start] [paths json] -> a peer's record, as the
# module writes one.
fixture() {
  local common; common="$(cd "$3" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  jq -nc --arg s "$1" --argjson pid "$2" --arg st "${5:-$(lstart "$2")}" --arg top "$3" --arg repo "$common" \
    --argjson w "$4" --argjson paths "${6:-[]}" --arg b "$(git -C "$3" branch --show-current)" \
    '{v: 1, session_id: $s, pid: $pid, start: $st, seen: (now | floor), claims: {}, acks: {}, kept: [],
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
# $CP and every request in $W/api.log. $STDIN, when set, is the session's input; the session is stopped when
# it exits or when the feeder of that input leaves $W/fed.
e2e() {
  local repo="$1" n=0; shift
  rm -f "$W/api.log" "$W/api.port" "$W/fed"
  python3 "$W/fake_api.py" "$W/script.jsonl" "$W/api.log" > "$W/api.port" & API=$!; STARTED="$STARTED $API"
  until [ -s "$W/api.port" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done
  ( cd "$repo" && exec env CLAUDE_CONFIG_DIR="$W/claude-config" ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$W/api.port")" \
      ANTHROPIC_API_KEY=sk-ant-stand-in DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p --model haiku --plugin-dir "$FLOW_PLUGIN" --managed-settings "$MANAGED" \
      --dangerously-skip-permissions "$@" < "${STDIN:-/dev/null}" > "$W/claude.out" 2>&1 ) & CP=$!; STARTED="$STARTED $CP"
  n=0; while kill -0 "$CP" 2>/dev/null && [ "$n" -lt 900 ] && [ ! -e "$W/fed" ]; do sleep 0.1; n=$((n + 1)); done
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
mkdir "$CC_TUNER_PEERS_DIR/.objects.stale" "$CC_TUNER_PEERS_DIR/.objects.fresh"; touch -t 202001010000 "$CC_TUNER_PEERS_DIR/.objects.stale"
RT="$(repo)"
script "$(jq -nc --arg w "$W" --arg rt "$RT" '{when: "", calls: [
  {name: "Bash", input: {command: ("TZ=UTC ps -A -o pid=,lstart= > " + $w + "/ps.txt")}},
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
check  "tool-release-answers" "cc-tuner: chrome is not leased to this session." "$(cat "$W/api.log")"
equals "record-sweep-removes-an-old-object-directory" "no" "$([ -e "$CC_TUNER_PEERS_DIR/.objects.stale" ] && echo yes || echo no)"
equals "record-sweep-keeps-a-recent-one" "yes" "$([ -e "$CC_TUNER_PEERS_DIR/.objects.fresh" ] && echo yes || echo no)"
equals "record-version" "1" "$(e2e_rec .v)"
rm -rf "$CC_TUNER_PEERS_DIR/.objects.fresh"
script '{"when": "", "calls": []}'
CC_TUNER_PEERS_DIR="$W/fresh/peers" e2e "$RT" go
equals "record-directory-is-made-private" "700" "$(stat -f %Lp "$W/fresh/peers" 2>/dev/null || stat -c %a "$W/fresh/peers")"

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
    {name: "Bash", input: {command: ("kill -0 " + $c + " && echo alive$((40 + 2))")}},
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
check  "guard-kill-signal-0-is-a-probe-and-runs" "alive42" "$(cat "$W/api.log")"
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

script '{"when": "", "calls": []}'
e2e "$RB" --session-id 00000000-0000-4000-8000-0000000000e4 "/cc-tuner:agent-rules"
check  "start-line-on-a-slash-command" "cc-tuner: live peers:" "$(cat "$W/api.log")"

script '{"when": "after-clear", "calls": []}' "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "CC_TUNER_ACK=0000abcd git status"}}]}')"
# Each message is typed once the one before it is answered: lines read at once are queued into the first turn, and
# a /clear queued there never clears anything.
user() { jq -nc --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }
rm -f "$W/stdin" "$W/api.log" "$W/fed"; mkfifo "$W/stdin"
{
  user first
  for _ in $(seq 1 300); do [ "$(grep -c '' "$W/api.log" 2>/dev/null)" -ge 2 ] 2>/dev/null && break; sleep 0.1; done; sleep 1
  user /clear; sleep 2
  user after-clear
  for _ in $(seq 1 300); do grep -qF after-clear "$W/api.log" 2>/dev/null && break; sleep 0.1; done; sleep 2
  touch "$W/fed"
} > "$W/stdin" & FEED=$!; STARTED="$STARTED $FEED"
STDIN="$W/stdin" e2e "$RB" --session-id 00000000-0000-4000-8000-0000000000e3 --input-format stream-json --output-format stream-json --verbose
check  "start-line-on-clear" "cc-tuner: live peers:" "$(grep -F 'after-clear' "$W/api.log" | tail -n 1)"
# A session nested under another claude shares its outermost parent's record, which a /clear in the nested one leaves alone.
if [ "$(session_pid)" = "$CP" ]; then equals "record-clear-drops-acks" "null" "$(e2e_rec '.acks["0000abcd"]')"
else printf 'NOTE record-clear-drops-acks not checked: this run is nested under another claude\n'; fi
absent "record-clear-follows-the-new-session-id" "0000000000e3" "$(e2e_rec .session_id)"

# --- resources: a shared stop and an exclusive lease, in real sessions --------------------------------------------
# The stop is a `touch` of a marker file, so the file shows whether the command ran. The tool is the one of a
# stand-in MCP server; the lease is taken by the real `mkdir`.
RR="$(repo)"; mkdir -p "$RR/.claude"
jq -nc --arg c "touch $W/stack-stopped" '{product: "res", resources: [{key: "stack", kind: "shared", start: [], stop: [$c]}]}' > "$RR/.claude/cc-tuner-resources.json"
peer; PR=$SP; fixture pr "$PR" "$RR" null
script "$(jq -nc --arg c "touch $W/stack-stopped" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
e2e "$RR" go
check  "resource-shared-stop-reaches-the-model" "would stop stack, which pid $PR on main also uses" "$(cat "$W/api.log")"
equals "resource-shared-stop-did-not-run" "no" "$([ -e "$W/stack-stopped" ] && echo yes || echo no)"
kill "$PR"; until [ -z "$(lstart "$PR")" ]; do sleep 0.05; done
e2e "$RR" go
equals "resource-shared-stop-runs-when-no-peer-is-live" "yes" "$([ -e "$W/stack-stopped" ] && echo yes || echo no)"

cat > "$W/mcp.py" <<'PY'
import json, sys
for line in sys.stdin:
    m = json.loads(line)
    if m.get("id") is None:
        continue
    method = m["method"]
    r = {}
    if method == "initialize":
        r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "lab", "version": "1"}}
    elif method == "tools/list":
        r = {"tools": [{"name": "ping", "description": "ping", "inputSchema": {"type": "object", "properties": {}}}]}
    elif method == "tools/call":
        r = {"content": [{"type": "text", "text": "pong-from-lab"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
PY
jq -nc --arg p "$W/mcp.py" '{mcpServers: {lab: {command: "python3", args: [$p]}}}' > "$W/mcp.json"
LOCK="$CC_TUNER_PEERS_DIR/lease.lab"
lab() { e2e "$RR" --mcp-config "$W/mcp.json" --strict-mcp-config --session-id "$1" go; }
script "$(jq -nc '{when: "", calls: [{name: "mcp__lab__ping", input: {}}]}')"
lab 00000000-0000-4000-8000-0000000000f1
check  "resource-lease-tool-ran" "pong-from-lab" "$(cat "$W/api.log")"
equals "resource-lease-first-user-takes-it-with-mkdir" "$(session_pid)" "$(jq -r .pid "$LOCK/holder.json")"
peer; PL=$SP
rm -rf "$LOCK"; mkdir "$LOCK"
jq -nc --argjson pid "$PL" --arg st "$(lstart "$PL")" '{v: 1, key: "lab", pid: $pid, start: $st, session: "x", last: (now | floor)}' > "$LOCK/holder.json"
lab 00000000-0000-4000-8000-0000000000f2
check  "resource-lease-deny-names-the-holder" "lab is leased to pid $PL" "$(cat "$W/api.log")"
absent "resource-lease-deny-offers-no-ack" "CC_TUNER_ACK=" "$(grep -F 'lab is leased' "$W/api.log" | head -n 1)"
absent "resource-lease-denied-tool-did-not-run" "pong-from-lab" "$(cat "$W/api.log")"
equals "resource-lease-stays-with-the-holder" "$PL" "$(jq -r .pid "$LOCK/holder.json")"
kill "$PL"; until [ -z "$(lstart "$PL")" ]; do sleep 0.05; done
script "$(jq -nc '{when: "", calls: [{name: "mcp__lab__ping", input: {}}, {name: "mcp__cc-tuner__peers_release", input: {key: "lab"}}]}')"
lab 00000000-0000-4000-8000-0000000000f3
check  "resource-lease-moves-on-death" "pong-from-lab" "$(cat "$W/api.log")"
check  "resource-lease-release-by-the-holder" "cc-tuner: released lab." "$(cat "$W/api.log")"
equals "resource-lease-release-frees-the-lock" "no" "$([ -e "$LOCK" ] && echo yes || echo no)"

# --- the lease script, raced in a real shell: a stale lock goes to exactly one of 20 callers -------------------------
# TAKE is the guard's own script, cut out of hooks/peers.ts and printed by node.
if ! command -v node >/dev/null 2>&1; then
  fail "lease-race (node is not on PATH)"
else
  TAKE="$(node -e "$(sed -n '/^const TAKE =/,/^const SWEEP =/p' "$FLOW_PLUGIN/hooks/peers.ts" | sed '$d'); process.stdout.write(TAKE)")"
  RACE="$W/race"; mkdir -p "$RACE"
  take() { sh -c "$TAKE" sh "$@"; }
  mkdir "$RACE/lease.x"; printf %s '{"v":1,"key":"x","pid":1,"start":"gone","session":null,"last":1}' > "$RACE/lease.x/holder.json"
  SEEN="$(cat "$RACE/lease.x/holder.json")"; RP=""
  for i in $(seq 1 20); do ( take "$RACE/lease.x" "$SEEN" "mine$i"; echo $? > "$RACE/rc.$i" ) & RP="$RP $!"; done
  wait $RP
  equals "lease-race-exactly-one-caller-takes-a-stale-lock" "1" "$(cat "$RACE"/rc.* | grep -c '^0$')"
  WINNER="$(grep -l '^0$' "$RACE"/rc.* | sed 's/.*rc\.//')"
  equals "lease-race-the-lock-holds-the-winner" "mine$WINNER" "$(cat "$RACE/lease.x/holder.json")"
  equals "lease-race-leaves-no-moved-aside-lock" "0" "$(ls "$RACE" | grep -c 'lease\.x\.')"
  mkdir "$RACE/lease.e"
  take "$RACE/lease.e" "" mine; equals "lease-a-fresh-empty-lock-is-not-taken" "1" "$?"
  touch -t 202001010000 "$RACE/lease.e"
  take "$RACE/lease.e" "" mine; equals "lease-an-old-empty-lock-is-taken" "0" "$?"
fi

# --- latency: the module decides in at most 150 ms p95 over 50 calls with 10 records --------------------------------
# Ten live peers in the call's repository, none a writer, so a switch is a note and the commit after it is read too:
# the checkout of each step, the start times of the ten, HEAD, and `git status`. The module logs each decision's time
# to the debug log. Wall time includes the load of the machine, so up to three sessions run and the best p95 decides.
OUTER_DIR="$CC_TUNER_PEERS_DIR"; export CC_TUNER_PEERS_DIR="$W/lat-peers"; mkdir -p "$CC_TUNER_PEERS_DIR"
RL="$(repo)"; git -C "$RL" branch x
mkdir -p "$RL/.claude"; printf '%s\n' '{"product":"lat","resources":[{"key":"stack","kind":"shared","start":["stack up"],"stop":["stack down"]}]}' > "$RL/.claude/cc-tuner-resources.json"
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
