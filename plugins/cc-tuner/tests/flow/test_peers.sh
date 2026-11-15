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
# Repositories made here with a plain `git init` commit too where the machine has no git identity (CI runners have none).
export GIT_AUTHOR_NAME='Flow Harness' GIT_AUTHOR_EMAIL=flow@example.invalid GIT_COMMITTER_NAME='Flow Harness' GIT_COMMITTER_EMAIL=flow@example.invalid

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

session_pid() { printf %s "$CP"; }

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
equals "record-names-no-outer-process" "" "$(e2e_rec '.outer // empty')"
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
equals "record-directory-is-made-private" "700" "$(stat -c %a "$W/fresh/peers" 2>/dev/null || stat -f %Lp "$W/fresh/peers")"

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
    {name: "Write", input: {file_path: ($b | sub("b.txt$"; "foreign.txt")), content: "g"}},
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
check  "guard-edit-of-an-untracked-file-is-a-note-on-real-git" "foreign.txt has uncommitted changes this session did not make" "$LOG"
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
equals "record-clear-drops-acks" "null" "$(e2e_rec '.acks["0000abcd"]')"
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

# The machine's shared stop counts where the call's directory is no repository too.
NR="$W/none"; mkdir -p "$NR"; rm -f "$W/none-stopped"
jq -nc --arg c "touch $W/none-stopped" '{resources: [{key: "mstack", kind: "shared", start: [], stop: [$c]}]}' > "$W/machine-stop.json"
peer; PN=$SP; fixture pn "$PN" "$RR" null
script "$(jq -nc --arg c "touch $W/none-stopped" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
CC_TUNER_PEERS_CONFIG="$W/machine-stop.json" e2e "$NR" go
check  "resource-machine-stop-outside-a-repository-reaches-the-model" "would stop mstack, which pid" "$(cat "$W/api.log")"
equals "resource-machine-stop-outside-a-repository-did-not-run" "no" "$([ -e "$W/none-stopped" ] && echo yes || echo no)"
kill "$PN"; until [ -z "$(lstart "$PN")" ]; do sleep 0.05; done

# A session outside any repository that starts a machine shared resource uses it: it leaves a record with no checkout.
rm -f "$W/mstack-started"
jq -nc --arg s "touch $W/mstack-started" '{resources: [{key: "mstart", kind: "shared", start: [$s], stop: []}]}' > "$W/machine-start.json"
script "$(jq -nc --arg c "touch $W/mstack-started" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
CC_TUNER_PEERS_CONFIG="$W/machine-start.json" e2e "$NR" --session-id 00000000-0000-4000-8000-0000000000a1 go
equals "resource-machine-start-outside-a-repository-ran" "yes" "$([ -e "$W/mstack-started" ] && echo yes || echo no)"
equals "resource-machine-start-outside-a-repository-leaves-a-record" "0" "$(e2e_rec '.checkouts | length')"

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

# A holder whose renewal is due meets another session's takeover mutex: it is stopped, not allowed, because the takeover
# may complete a moment later. Once it has, the old holder is stopped naming the new one. The mutex and the takeover
# are staged by the session's own Bash calls between its tool calls; the renewal and the stop are the real code's.
peer; PT=$SP
BACKDATE="printf %s \"\$(jq -c '.last = 1' $LOCK/holder.json)\" > $LOCK/holder.json; mkdir $LOCK.take"
TAKEN="rmdir $LOCK.take; printf %s '$(jq -nc --argjson pid "$PT" --arg st "$(lstart "$PT")" '{v: 1, key: "lab", pid: $pid, start: $st, session: "t", last: (now | floor)}')' > $LOCK/holder.json"
script "$(jq -nc --arg b "$BACKDATE" --arg t "$TAKEN" '{when: "", calls: [
  {name: "mcp__lab__ping", input: {}}, {name: "Bash", input: {command: $b}}, {name: "mcp__lab__ping", input: {}},
  {name: "Bash", input: {command: $t}}, {name: "mcp__lab__ping", input: {}}]}')"
lab 00000000-0000-4000-8000-0000000000f4
check  "resource-lease-busy-renewal-stops" "lab is being taken over by another session; try again shortly" "$(cat "$W/api.log")"
absent "resource-lease-busy-renewal-offers-no-ack" "CC_TUNER_ACK=" "$(grep -F 'being taken over' "$W/api.log" | head -n 1)"
check  "resource-lease-after-the-takeover-names-the-new-holder" "lab is leased to pid $PT" "$(cat "$W/api.log")"
equals "resource-lease-takeover-holder-stays" "$PT" "$(jq -r .pid "$LOCK/holder.json")"
kill "$PT"; until [ -z "$(lstart "$PT")" ]; do sleep 0.05; done
rm -rf "$LOCK" "$LOCK.take"

# --- inspection is inert: the guard's own git reads run nothing the repository, an included file or ~/.gitconfig configures ---
# A clean filter runs while `git status` hashes a changed file, a merge driver while merge-tree merges two commits, and a
# submodule's own filter while status goes into it. A filter appends `by=<GIT_ATTR_NOSYSTEM>` to its marker file: the guard's
# own git reads set GIT_ATTR_NOSYSTEM=1 (GIT_ENV), a plain `git status` does not. The session's host runs a plain `git status`
# of its own at start (Claude Code on Linux: `status --short --ignore-submodules=dirty` for its gitStatus context, which runs
# the repository's clean filters), so a marker file alone cannot tell whose git ran the filter: `ran` is the control's
# question (did any git run it), `guard_ran` the guard's (did a git of the guard's run it).
RI="$(repo)"; MK="$W/inert"; mkdir -p "$MK" "$W/home"
printf '%s\n' 'f filter=evil' 'f merge=evil' 'g filter=plain' 'h filter=glob' 'i filter=inc' > "$RI/.gitattributes"
commit_file "$RI" g one; commit_file "$RI" f one; commit_file "$RI" h one; commit_file "$RI" i one; ( cd "$RI" && git add .gitattributes && git commit -q -m attrs )
git init -q -b main "$W/subsrc"; commit_file "$W/subsrc" x one
printf '%s\n' 'x filter=sf' > "$W/subsrc/.gitattributes"; ( cd "$W/subsrc" && git add .gitattributes && git commit -q -m attrs )
[ -n "$(git -C "$W/subsrc" rev-parse -q --verify HEAD)" ] || echo "FAIL diag subsrc has no commit: $(git -C "$W/subsrc" log --oneline 2>&1 | head -n 3)"
git -C "$RI" -c protocol.file.allow=always submodule add -q "$W/subsrc" sm > "$W/sm.err" 2>&1 || sed "s/^/FAIL diag submodule add: /" "$W/sm.err"; ( cd "$RI" && git commit -q -m sm )
git -C "$RI" switch -q -c side; commit_file "$RI" f side
git -C "$RI" switch -q main; commit_file "$RI" f mine
git -C "$RI" worktree add -q "$W/wi" side; WI="$(cd "$W/wi" && pwd -P)"
peer; PI=$SP; fixture pi "$PI" "$WI" null
git -C "$RI" config filter.evil.process "echo by=\${GIT_ATTR_NOSYSTEM:-plain} >> '$MK/process'; cat"
git -C "$RI" config filter.plain.clean "echo by=\${GIT_ATTR_NOSYSTEM:-plain} >> '$MK/clean'; cat"
git -C "$RI" config filter.plain.required true
git -C "$RI" config merge.evil.driver "touch '$MK/merge'"
printf '[filter "inc"]\n\tclean = echo by=${GIT_ATTR_NOSYSTEM:-plain} >> %s; cat\n' "$MK/include" > "$W/inc.cfg"; git -C "$RI" config include.path "$W/inc.cfg"
printf '[filter "glob"]\n\tclean = echo by=${GIT_ATTR_NOSYSTEM:-plain} >> %s; cat\n' "$MK/global" > "$W/home/.gitconfig"
git -C "$RI/sm" config filter.sf.clean "echo by=\${GIT_ATTR_NOSYSTEM:-plain} >> '$MK/sub'; cat"
# The same size as the committed text, so git hashes the file rather than trusting the size.
printf 'mind\n' > "$RI/f"; printf 'two\n' > "$RI/g"; printf 'two\n' > "$RI/h"; printf 'two\n' > "$RI/i"; printf 'two\n' > "$RI/sm/x"
ran() { [ -e "$MK/$1" ] && echo yes || echo no; }
guard_ran() { grep -qs '^by=1$' "$MK/$1" && echo yes || echo no; }
HOME="$W/home" git -C "$RI" status >/dev/null 2>&1; git -C "$RI" merge-tree --write-tree main side >/dev/null 2>&1
for m in process clean include global sub merge; do equals "inert-control-a-plain-status-runs-the-$m-filter" "yes" "$(ran $m)"; done
[ "$(ran sub)" = yes ] || { echo "FAIL diag sub: $(git -C "$RI" submodule status 2>&1) | $(git -C "$RI/sm" config --get filter.sf.clean 2>&1) | $(git -C "$RI" status --porcelain 2>&1 | tr "\n" " ")"; }
rm -f "$MK"/*
script "$(jq -nc '{when: "", calls: [{name: "mcp__cc-tuner__peers_report", input: {}}, {name: "Bash", input: {command: "git reset --hard"}}]}')"
HOME="$W/home" e2e "$RI" go
check  "inert-the-guard-still-sees-the-changed-file"  "would discard f, g, h" "$(cat "$W/api.log")"
check  "inert-the-report-still-sees-the-conflict"     "conflicts with HEAD: f" "$(cat "$W/api.log")"
equals "inert-status-runs-no-clean-filter"            "no" "$(guard_ran clean)"
equals "inert-status-runs-no-filter-process"          "no" "$(guard_ran process)"
equals "inert-status-runs-no-filter-of-an-included-file" "no" "$(guard_ran include)"
equals "inert-status-runs-no-filter-of-the-global-config" "no" "$(guard_ran global)"
equals "inert-status-runs-no-filter-of-a-submodule"   "no" "$(guard_ran sub)"
equals "inert-merge-tree-runs-no-merge-driver"        "no" "$(ran merge)"

# `merge.default` names the driver for a file whose attributes name none, so an attribute-free merge-tree runs it too. The
# driver only creates a marker file and fails, so the merge conflicts; a plain merge-tree is the control that it runs.
RD="$(repo)"; MD="$W/default-driver"; mkdir -p "$MD"
commit_file "$RD" f one; git -C "$RD" switch -q -c side; commit_file "$RD" f side
git -C "$RD" switch -q main; commit_file "$RD" f mine
git -C "$RD" worktree add -q "$W/wd" side; WD="$(cd "$W/wd" && pwd -P)"
peer; PDF=$SP; fixture pdf "$PDF" "$WD" null
git -C "$RD" config merge.default markerdriver
git -C "$RD" config merge.markerdriver.driver "touch '$MD/default'; false"
git -C "$RD" merge-tree --write-tree main side >/dev/null 2>&1
equals "inert-default-driver-control-a-plain-merge-tree-runs-it" "yes" "$([ -e "$MD/default" ] && echo yes || echo no)"
rm -f "$MD/default"
script "$(jq -nc '{when: "", calls: [{name: "mcp__cc-tuner__peers_report", input: {}}]}')"
e2e "$RD" go
check  "inert-default-driver-the-report-still-sees-the-conflict" "conflicts with HEAD: f" "$(cat "$W/api.log")"
equals "inert-merge-tree-runs-no-merge-default-driver" "no" "$([ -e "$MD/default" ] && echo yes || echo no)"

# `merge.default=text` is not a way to neutralise a driver: a repository that defines `merge.text.driver` makes `text` a
# driver too. merge-tree therefore runs in a temporary bare repository that reads none of the real one's configuration,
# attributes or hooks and borrows its objects; the real object store keeps exactly the files it had.
RT="$(repo)"; MT="$W/text-driver"; mkdir -p "$MT"
commit_file "$RT" f one; git -C "$RT" switch -q -c side; commit_file "$RT" f side
git -C "$RT" switch -q main; commit_file "$RT" f mine
git -C "$RT" worktree add -q "$W/wt" side; WT="$(cd "$W/wt" && pwd -P)"
peer; PTD=$SP; fixture ptd "$PTD" "$WT" null
git -C "$RT" config merge.default text
git -C "$RT" config merge.text.driver "touch '$MT/text'; false"
git -C "$RT" merge-tree --write-tree main side >/dev/null 2>&1
equals "inert-text-driver-control-a-plain-merge-tree-runs-it" "yes" "$([ -e "$MT/text" ] && echo yes || echo no)"
rm -f "$MT/text"
OBJ="$(cd "$RT/.git/objects" && find . -type f | sort | shasum)"
script "$(jq -nc '{when: "", calls: [{name: "mcp__cc-tuner__peers_report", input: {}}]}')"
e2e "$RT" go
check  "inert-text-driver-the-report-still-sees-the-conflict" "conflicts with HEAD: f" "$(cat "$W/api.log")"
equals "inert-merge-tree-runs-no-text-driver" "no" "$([ -e "$MT/text" ] && echo yes || echo no)"
equals "inert-merge-tree-leaves-the-object-store-unchanged" "$OBJ" "$(cd "$RT/.git/objects" && find . -type f | sort | shasum)"

# Git configuration given to one command (`-c`, GIT_CONFIG_COUNT/KEY_n/VALUE_n, GIT_CONFIG_PARAMETERS) is no repository
# setting the guard reads: `-c submodule.recurse=true reset --hard` also resets submodules, whose edits status never shows.
# Such a destructive command stops; a plain `git reset --hard` still runs. The submodule holds a modified tracked file.
RG="$(repo)"; commit_file "$RG" a one
git init -q -b main "$W/subg"; commit_file "$W/subg" x one
git -C "$RG" -c protocol.file.allow=always submodule add -q "$W/subg" sg 2>/dev/null; ( cd "$RG" && git commit -q -m sg )
for c in "git -c submodule.recurse=true reset --hard" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.recurse GIT_CONFIG_VALUE_0=true git reset --hard" \
  "env GIT_CONFIG_PARAMETERS=\"'submodule.recurse'='true'\" git reset --hard" "RECURSE=true git --config-env=submodule.recurse=RECURSE reset --hard"; do
  printf 'edit\n' > "$RG/sg/x"
  script "$(jq -nc --arg c "$c" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
  e2e "$RG" go
  check  "git-config-stops-on-real-git: $c" "per-command git configuration is not inspected" "$(cat "$W/api.log")"
  equals "git-config-keeps-the-submodule-edit: $c" "edit" "$(cat "$RG/sg/x")"
done
printf 'edit\n' > "$RG/sg/x"
script "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "git reset --hard && echo plain-$((40 + 2))"}}]}')"
e2e "$RG" go
check  "git-config-a-plain-reset-hard-still-runs" "plain-42" "$(cat "$W/api.log")"
equals "git-config-a-plain-reset-hard-leaves-the-submodule-alone" "edit" "$(cat "$RG/sg/x")"

# On a CI-only failure, what the session itself printed is the only evidence of why it stopped.
diag_rm() { grep -q "would delete foreign.txt" "$W/api.log" || { tail -n 25 "$W/claude.out" | sed "s/^/FAIL diag $1: /"; grep -o '"tool_result"[^]]\{0,400\}' "$W/api.log" | sed "s/^/FAIL diag $1 result: /"; echo "FAIL diag $1 requests: $(grep -c '"role"' "$W/api.log")"; }; }

# A recursive removal reaches every checkout under its target, not only a target that is itself a checkout root. The
# parent holds a checkout a record of a finished session names (a tombstone) with a file nobody here edited; the session
# runs in another repository. The control removes the same parent once the checkout is clean.
RP="$W/rmparent"; mkdir -p "$RP"; git init -q -b main "$RP/r"; commit_file "$RP/r" a one; RP="$(cd "$RP" && pwd -P)"
printf 'precious\n' > "$RP/r/foreign.txt"
RO="$(repo)"
peer; PRM=$SP; fixture prm "$PRM" "$RP/r" null; kill "$PRM"; until [ -z "$(lstart "$PRM")" ]; do sleep 0.05; done
script "$(jq -nc --arg c "rm -rf $RP" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
e2e "$RO" go
diag_rm rmparent
check  "remove-a-parent-of-a-checkout-with-a-foreign-file-stops" "would delete foreign.txt in $RP/r" "$(cat "$W/api.log")"
equals "remove-a-parent-keeps-the-foreign-file" "precious" "$(cat "$RP/r/foreign.txt")"
rm -f "$RP/r/foreign.txt"
e2e "$RO" go
equals "remove-a-parent-of-a-clean-checkout-runs" "no" "$([ -e "$RP" ] && echo yes || echo no)"

# The same removal from a directory that is no repository is decided too: a removal finds its roots in the records, not in the cwd.
RX="$W/rmabs"; mkdir -p "$RX"; git init -q -b main "$RX/r"; commit_file "$RX/r" a one; RX="$(cd "$RX" && pwd -P)"
printf 'precious\n' > "$RX/r/foreign.txt"
mkdir -p "$W/nonrepo"
peer; PRX=$SP; fixture prx "$PRX" "$RX/r" null; kill "$PRX"; until [ -z "$(lstart "$PRX")" ]; do sleep 0.05; done
script "$(jq -nc --arg c "rm -rf $RX/r" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
e2e "$W/nonrepo" go
diag_rm rmabs
check  "remove-from-a-non-repository-cwd-stops" "would delete foreign.txt in $RX/r" "$(cat "$W/api.log")"
equals "remove-from-a-non-repository-cwd-keeps-the-foreign-file" "precious" "$(cat "$RX/r/foreign.txt")"

# `.git/info/attributes` is the one attribute file git reads even with --attr-source. The filter is defined in .git/config
# and only creates a marker file; a plain `git status` is the control that it runs.
RA="$(repo)"; MA="$W/info-attrs"; mkdir -p "$MA"
commit_file "$RA" k one
git -C "$RA" config filter.infomarker.clean "echo by=\${GIT_ATTR_NOSYSTEM:-plain} >> '$MA/clean'; cat"
mkdir -p "$RA/.git/info"; printf '%s\n' 'k filter=infomarker' >> "$RA/.git/info/attributes"
printf 'two\n' > "$RA/k"
git -C "$RA" status >/dev/null 2>&1
equals "info-attributes-control-a-plain-status-runs-the-filter" "yes" "$([ -e "$MA/clean" ] && echo yes || echo no)"
rm -f "$MA/clean"
script "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "git reset --hard"}}]}')"
e2e "$RA" go
check  "info-attributes-the-guard-still-sees-the-changed-file" "would discard k" "$(cat "$W/api.log")"
equals "info-attributes-the-guard-runs-no-clean-filter" "no" "$(grep -qs '^by=1$' "$MA/clean" && echo yes || echo no)"
rm -f "$MA/clean"
head -c 70000 /dev/zero | tr '\0' '#' >> "$RA/.git/info/attributes"
e2e "$RA" go
check  "info-attributes-an-oversized-file-is-unread" "could not read git status" "$(cat "$W/api.log")"
equals "info-attributes-an-oversized-file-runs-no-filter" "no" "$(grep -qs '^by=1$' "$MA/clean" && echo yes || echo no)"

# --- an untracked file the destination tree holds is lost to reset --hard, checkout -f and switch -f -----------------
# Each command runs in a session that did not write u.txt; the file is the user's, untracked, and a branch holds a file of that name.
RU="$(repo)"
commit_file "$RU" a one; git -C "$RU" switch -q -c src; commit_file "$RU" u.txt tracked; git -C "$RU" switch -q main
BASE="$(git -C "$RU" rev-parse HEAD)"
for c in "git reset --hard src" "git checkout -f src" "git switch -f src"; do
  git -C "$RU" switch -q -f main; git -C "$RU" reset -q --hard "$BASE"; git -C "$RU" clean -qfd; printf 'precious\n' > "$RU/u.txt"
  script "$(jq -nc --arg c "$c" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
  e2e "$RU" go
  check  "untracked-collision-stops-on-real-git: $c" "would discard u.txt in" "$(cat "$W/api.log")"
  equals "untracked-collision-keeps-the-file: $c"    "precious" "$(cat "$RU/u.txt")"
done

# A name that begins with a space is the tree's first entry; NUL-separated output must reach the check untrimmed.
git -C "$RU" switch -q -f main; git -C "$RU" reset -q --hard "$BASE"; git -C "$RU" clean -qfd
git -C "$RU" switch -q -c sp; printf 'tracked\n' > "$RU/ f"; git -C "$RU" add -- " f"; git -C "$RU" commit -qm sp; git -C "$RU" switch -q main
printf 'precious\n' > "$RU/ f"
script "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "git reset --hard sp"}}]}')"
e2e "$RU" go
check  "untracked-collision-leading-space-stops" "would discard" "$(cat "$W/api.log")"
equals "untracked-collision-leading-space-keeps-the-file" "precious" "$(cat "$RU/ f")"
rm -f "$RU/ f"

# A file where the destination has a directory, or a directory where it has a file, is lost too: the paths collide though they differ.
git -C "$RU" switch -q -f main; git -C "$RU" reset -q --hard "$BASE"; git -C "$RU" clean -qfd
git -C "$RU" switch -q -c dd; commit_file "$RU" d tracked; git -C "$RU" switch -q main
git -C "$RU" switch -q -c ee; mkdir -p "$RU/e"; commit_file "$RU" e/g tracked; git -C "$RU" switch -q main
for c in "git reset --hard dd|d/foreign" "git checkout -f dd|d/foreign" "git switch -f dd|d/foreign" "git reset --hard ee|e" "git checkout -f ee|e" "git switch -f ee|e"; do
  git -C "$RU" switch -q -f main; git -C "$RU" reset -q --hard "$BASE"; git -C "$RU" clean -qfd
  case "${c#*|}" in d/foreign) mkdir -p "$RU/d"; printf 'precious\n' > "$RU/d/foreign" ;; e) printf 'precious\n' > "$RU/e" ;; esac
  script "$(jq -nc --arg c "${c%|*}" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
  e2e "$RU" go
  check  "untracked-file-directory-collision-stops-on-real-git: ${c%|*} / ${c#*|}" "would discard ${c#*|} in" "$(cat "$W/api.log")"
  equals "untracked-file-directory-collision-keeps-the-file: ${c%|*} / ${c#*|}"    "precious" "$(cat "$RU/${c#*|}" 2>/dev/null)"
done

# --- a destructive command that recurses into submodules stops: status ignores them, so their edits are not inspected ---
# The submodule's tracked file is modified and the superproject is clean; without recursion `reset --hard` leaves the
# submodule alone, with it the edit is gone.
RM="$(repo)"; git init -q -b main "$W/subsrc2"; commit_file "$W/subsrc2" x one
commit_file "$RM" a one
git -C "$RM" -c protocol.file.allow=always submodule add -q "$W/subsrc2" sm 2>/dev/null; ( cd "$RM" && git commit -q -m sm )
for c in "git reset --hard --recurse-submodules" "git reset --hard"; do
  printf 'precious\n' > "$RM/sm/x"
  script "$(jq -nc --arg c "$c" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
  e2e "$RM" go
  case "$c" in
    *recurse*) check "submodules-recursion-stops-on-real-git" "submodules are not inspected" "$(cat "$W/api.log")"
               check "submodules-recursion-offers-the-ack" "CC_TUNER_ACK=" "$(cat "$W/api.log")"
               equals "submodules-recursion-keeps-the-edit" "precious" "$(cat "$RM/sm/x")" ;;
    *) absent "submodules-no-recursion-is-not-stopped" "CC_TUNER_ACK=" "$(cat "$W/api.log")"
       equals "submodules-no-recursion-leaves-the-submodule-edit" "precious" "$(cat "$RM/sm/x")" ;;
  esac
done
git -C "$RM" config submodule.recurse true; printf 'precious\n' > "$RM/sm/x"
script "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "git reset --hard"}}]}')"
e2e "$RM" go
check  "submodules-config-recursion-stops-on-real-git" "submodules are not inspected" "$(cat "$W/api.log")"
equals "submodules-config-recursion-keeps-the-edit" "precious" "$(cat "$RM/sm/x")"

# A `cd` that may have failed does not move the steps after it: `cd /nonexistent; git reset --hard` runs in the cwd's checkout,
# and a guard that took the `cd` for done would read a directory that is no checkout. The edit is nobody's here; the control
# joins the same `cd` to the reset with `&&`, which is read.
RZ="$(repo)"; commit_file "$RZ" a one; printf 'precious\n' > "$RZ/a"
script "$(jq -nc '{when: "", calls: [{name: "Bash", input: {command: "cd /nonexistent/path; git reset --hard"}}]}')"
e2e "$RZ" go
check  "cd-that-may-have-failed-stops-a-reset-on-real-git" "could not tell which checkout" "$(cat "$W/api.log")"
equals "cd-that-may-have-failed-keeps-the-foreign-edit" "precious" "$(cat "$RZ/a")"
printf 'precious\n' > "$RZ/a"
script "$(jq -nc --arg c "cd $RZ && git reset --hard" '{when: "", calls: [{name: "Bash", input: {command: $c}}]}')"
e2e "$RZ" go
check  "cd-joined-with-and-is-read-on-real-git" "would discard a in" "$(cat "$W/api.log")"
equals "cd-joined-with-and-keeps-the-foreign-edit" "precious" "$(cat "$RZ/a")"

# --- a commit with paths takes only those paths, so a foreign staged file does not stop it ----------------------------
RC="$(repo)"
commit_file "$RC" own one; commit_file "$RC" foreign one
printf 'o2\n' > "$RC/own"; printf 'f2\n' > "$RC/foreign"; git -C "$RC" add foreign
script "$(jq -nc --arg o "$RC/own" '{when: "", calls: [
  {name: "Write", input: {file_path: $o, content: "mine\n"}},
  {name: "Bash", input: {command: "git commit --only own -m only-own"}},
  {name: "Bash", input: {command: "git commit -m plain"}}]}')"
e2e "$RC" go
equals "commit-only-own-ran-on-real-git"            "only-own" "$(git -C "$RC" log -1 --format=%s)"
equals "commit-only-own-left-the-foreign-staged"    "foreign" "$(git -C "$RC" diff --cached --name-only)"
check  "commit-plain-stops-for-the-foreign-staged"  "would commit foreign in" "$(cat "$W/api.log")"

# Paths listed in a file are never read: the file can change before git reads it, so a command given --pathspec-from-file has a
# scope nobody checked and reaches every foreign file. The file here names `foreign`, which is staged and edited again. A commit
# of a literal own path runs, and so does `--only --amend` with no paths, which takes none of the staged files.
RF="$(repo)"
commit_file "$RF" own one; commit_file "$RF" foreign one
printf 'o2\n' > "$RF/own"; printf 'f2\n' > "$RF/foreign"; git -C "$RF" add foreign; printf 'f3\n' > "$RF/foreign"; printf 'foreign\n' > "$RF/paths.txt"
script "$(jq -nc --arg o "$RF/own" '{when: "", calls: [
  {name: "Write", input: {file_path: $o, content: "mine\n"}},
  {name: "Bash", input: {command: "git restore --pathspec-from-file=paths.txt"}},
  {name: "Bash", input: {command: "git commit --pathspec-from-file paths.txt -m from-file"}},
  {name: "Bash", input: {command: "git commit own -m own-path"}},
  {name: "Bash", input: {command: "git commit --only --amend -m reworded"}}]}')"
e2e "$RF" go
check  "restore-pathspec-from-file-stops-for-the-foreign-file"  "would overwrite foreign in" "$(cat "$W/api.log")"
equals "restore-pathspec-from-file-keeps-the-foreign-edit"      "f3" "$(cat "$RF/foreign")"
check  "commit-pathspec-from-file-stops-for-the-foreign-file"   "would commit foreign in" "$(cat "$W/api.log")"
equals "commit-literal-own-path-and-only-amend-ran-on-real-git" "reworded" "$(git -C "$RF" log -1 --format=%s)"
equals "commit-literal-own-path-took-only-that-path"            "own" "$(git -C "$RF" show --name-only --format= HEAD)"
equals "commit-only-amend-left-the-foreign-staged"              "foreign" "$(git -C "$RF" diff --cached --name-only)"

# --- the lease script, raced in a real shell: a stale lock goes to exactly one of 20 callers -------------------------
# TAKE, RENEW and RELEASE are the guard's own scripts, cut out of hooks/peers.ts and printed by node.
if ! command -v node >/dev/null 2>&1; then
  fail "lease-race (node is not on PATH)"
else
  script_of() { node -e "$(sed -n '/^const LOCKED =/,/^const SWEEP =/p' "$FLOW_PLUGIN/hooks/peers.ts" | sed '$d'); process.stdout.write($1)" 2>/dev/null; }
  TAKE="$(script_of TAKE)"; RENEW="$(script_of RENEW)"; RELEASE="$(script_of RELEASE)"
  RACE="$W/race"; mkdir -p "$RACE"
  take() { sh -c "$TAKE" sh "$@"; }
  renew() { sh -c "$RENEW" sh "$@"; }
  release() { sh -c "$RELEASE" sh "$@"; }
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
  # A renewal or a release that read the lock before a takeover must not act on the new holder's lock.
  mkdir "$RACE/lease.r"; printf %s A > "$RACE/lease.r/holder.json"
  renew "$RACE/lease.r" A A2; equals "lease-renewal-by-the-holder-runs" "0" "$?"
  equals "lease-renewal-writes-the-new-text" "A2" "$(cat "$RACE/lease.r/holder.json")"
  take "$RACE/lease.r" A2 B
  renew "$RACE/lease.r" A2 A3; equals "lease-renewal-after-a-takeover-is-refused" "1" "$?"
  equals "lease-renewal-after-a-takeover-leaves-the-new-holder" "B" "$(cat "$RACE/lease.r/holder.json")"
  release "$RACE/lease.r" A2; equals "lease-release-after-a-takeover-is-refused" "1" "$?"
  equals "lease-release-after-a-takeover-leaves-the-new-holder" "B" "$(cat "$RACE/lease.r/holder.json")"
  mkdir "$RACE/lease.r.take"
  release "$RACE/lease.r" B; equals "lease-release-while-a-take-is-under-way-is-busy" "2" "$?"
  renew "$RACE/lease.r" B B2; equals "lease-renewal-while-a-take-is-under-way-is-busy" "2" "$?"
  equals "lease-busy-calls-change-nothing" "B" "$(cat "$RACE/lease.r/holder.json")"
  rmdir "$RACE/lease.r.take"
  release "$RACE/lease.r" B; equals "lease-release-by-the-holder-runs" "0" "$?"
  equals "lease-release-removes-the-lock-and-leaves-no-mutex" "0" "$(ls "$RACE" | grep -c '^lease\.r')"
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
