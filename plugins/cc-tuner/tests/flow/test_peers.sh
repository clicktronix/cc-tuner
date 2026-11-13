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

# --- peers are found by repository and by product ---------------------------------------------------
# A: me, in repository A of product acme, with a second checkout (worktree) on branch feat-a.
# B: another repository of acme. C: a repository of another product. D: a repository with no product.
commit_file() { ( cd "$1" && printf '%s\n' "$3" > "$2" && git add "$2" && git commit -q -m "$2" ); }
product_file() { ( cd "$1" && mkdir -p .claude && printf '{"product":"%s"}\n' "$2" > .claude/cc-tuner-resources.json && git add .claude && git commit -q -m product ); }
RA="$(repo)"; RB="$(repo)"; RC="$(repo)"; RD="$(repo)"
product_file "$RA" acme; product_file "$RB" acme; product_file "$RC" other
commit_file "$RA" f.txt one; commit_file "$RA" g.txt one
git -C "$RA" worktree add -q -b feat-a "$W/wa"; WA="$(cd "$W/wa" && pwd -P)"
git -C "$RA" worktree add -q -b feat-b "$W/wb"; WB="$(cd "$W/wb" && pwd -P)"
commit_file "$WA" f.txt theirs
commit_file "$WB" g.txt theirs
commit_file "$RA" f.txt mine
peer; PA=$SP; peer; PB=$SP; peer; PC=$SP; peer; PD=$SP; peer; PW=$SP; peer; PR=$SP
event "$PR" sr before Bash "$RA" >/dev/null
event "$PA" sa before Bash "$WA" >/dev/null
event "$PW" sw before Bash "$WB" >/dev/null
event "$PB" sb before Bash "$RB" >/dev/null
event "$PC" sc before Bash "$RC" >/dev/null
event "$PD" sd before Bash "$RD" >/dev/null
OUT="$(report "$RA" "$PR")"
check  "report-lists-the-same-repository-peer"     "pid $PA  feat-a  $WA" "$OUT"
check  "report-lists-the-second-checkout-peer"     "pid $PW  feat-b  $WB" "$OUT"
check  "report-lists-the-product-peer"             "pid $PB  main  $RB" "$OUT"
absent "report-skips-another-product"              "pid $PC" "$OUT"
absent "report-skips-an-unrelated-repository"      "pid $PD" "$OUT"
absent "report-skips-itself"                       "pid $PR" "$OUT"
OUT="$(report "$RD" "$PD")"
check  "report-without-product-says-no-peers"     "no live peers" "$OUT"
OUT="$(report "$RB" "$PB")"
check  "report-product-is-symmetric"               "pid $PR" "$OUT"
check  "report-product-reaches-the-worktrees"      "pid $PA" "$OUT"

# Claims and edited paths are shown with the branch.
edit_rec sa ".claims = {\"plan.md\": {\"repo\": \"$(rec sa ".checkouts[\"$WA\"].repo")\", \"paths\": [\"docs/\", \"lib/x.ts\"]}}"
event "$PA" sa after Edit "$WA" "$WA/lib/x.ts" >/dev/null
OUT="$(report "$RA" "$PR")"
check "report-shows-claims"       "claims: docs/, lib/x.ts" "$OUT"
check "report-shows-edited-paths" "edited: lib/x.ts" "$OUT"

# --- merge-tree: only same-repository peers, only a conflicting branch -------------------------------
check  "report-conflict-names-the-file"      "conflicts with HEAD: f.txt" "$OUT"
equals "report-conflicts-only-the-conflicting-branch" "1" "$(printf '%s\n' "$OUT" | grep -c 'conflicts with HEAD')"
commit_file "$RB" f.txt other
equals "report-no-merge-tree-across-repositories" "1" "$(report "$RA" "$PR" | grep -c 'conflicts with HEAD')"

# The repository's object store is unchanged by a merge result that did not exist before, on a cold
# cache. The control runs the same merge in a copy without the temporary directory and sees objects.
objects() { find "$1/.git/objects" -type f | wc -l | tr -d ' '; }
RO="$(repo)"; commit_file "$RO" f.txt one
git -C "$RO" switch -q -c feat-o; commit_file "$RO" f.txt theirs
git -C "$RO" switch -q main;      commit_file "$RO" f.txt mine
cp -R "$RO" "$W/control"
git -C "$W/control" merge-tree --write-tree --name-only main feat-o >/dev/null
[ "$(objects "$W/control")" -gt "$(objects "$RO")" ] && pass "report-control-merge-tree-writes-objects" \
  || fail "report-control-merge-tree-writes-objects (the case would not notice a leak)"
git -C "$RO" worktree add -q "$W/wo" feat-o; WO="$(cd "$W/wo" && pwd -P)"
peer; PO=$SP; peer; POM=$SP
event "$PO" so before Bash "$WO" >/dev/null
event "$POM" som before Bash "$RO" >/dev/null
rm -rf "$CC_TUNER_PEERS_DIR"/merge/*
BEFORE="$(objects "$RO")"
OUT="$(report "$RO" "$POM")"
check  "report-cold-cache-finds-the-conflict" "conflicts with HEAD: f.txt" "$OUT"
equals "report-object-store-unchanged"        "$BEFORE" "$(objects "$RO")"
equals "report-leaves-no-temporary-objects"   "0" "$(ls -a "$CC_TUNER_PEERS_DIR" | grep -c '^\.objects\.')"

# The result is cached per SHA pair: a changed cache entry is what the next report prints.
CACHE="$(ls "$CC_TUNER_PEERS_DIR"/merge/* | head -n 1)"
equals "report-caches-per-sha-pair" "$(git -C "$RO" rev-parse HEAD)-$(git -C "$WO" rev-parse HEAD)" "$(basename "$CACHE")"
printf '["cached.txt"]' > "$CACHE"
check  "report-reads-the-cache" "conflicts with HEAD: cached.txt" "$(report "$RO" "$POM")"

# --- claim publishes the open Owned paths and prints their overlap -----------------------------------
mkdir -p "$RA/docs/task-plans"
plan() {  # plan <first criterion mark> <second criterion mark>
  printf '%s\n' '**Spec:** docs/PLANS/s.md' '**Branch:** feat/x' '' \
    '## Slice 1 — Old' 'Blocked by: none' 'Owned paths: src/old/' 'Deciding check: t' 'Delivers: d' '' "- [$1] a" '' \
    '## Slice 2 — New' 'Blocked by: 1' 'Owned paths: lib/, docs/y.md' 'Deciding check: t' 'Delivers: d' '' "- [$2] b"
}
plan x ' ' > "$RA/docs/task-plans/p.md"
OUT="$(cd "$RA" && CC_TUNER_PEERS_CLAUDE_PID="$PR" bash "$PEERS" claim docs/task-plans/p.md 2>&1)"
equals "claim-publishes-open-owned-paths" "lib/,docs/y.md" "$(rec sr '.claims["docs/task-plans/p.md"].paths | join(",")')"
check  "claim-prints-the-overlap" "overlap with your claims: lib/ ~ lib/x.ts" "$OUT"
check  "claim-prints-the-peers"   "pid $PA" "$OUT"
absent "claim-overlap-skips-a-done-slice" "src/old" "$OUT"
equals "claim-overlap-is-one-line-per-peer-checkout" "1" "$(printf '%s\n' "$OUT" | grep -c 'overlap with your claims')"
plan x x > "$RA/docs/task-plans/p.md"
( cd "$RA" && CC_TUNER_PEERS_CLAUDE_PID="$PR" bash "$PEERS" claim docs/task-plans/p.md >/dev/null 2>&1 )
equals "claim-drops-a-finished-plan" "0" "$(rec sr '.claims | length')"
OUT="$(cd "$RA" && CC_TUNER_PEERS_CLAUDE_PID="$PR" bash "$PEERS" claim docs/task-plans/missing.md 2>&1; echo "rc=$?")"
check  "claim-reports-a-plan-that-is-missing" "rc=1" "$OUT"

# --- the start line --------------------------------------------------------------------------------
fire() {  # fire <cwd> <session> <source> <pid> -> the hook's raw stdout
  jq -nc --arg s "$2" --arg src "$3" --arg c "$1" '{session_id: $s, source: $src, cwd: $c, hook_event_name: "SessionStart"}' \
    | CC_TUNER_PEERS_CLAUDE_PID="$4" bash "$HOOK" 2>/dev/null
}
ctx() { fire "$@" | jq -r '.hookSpecificOutput.additionalContext // empty'; }

RS="$(repo)"
peer; PS1=$SP; peer; PS2=$SP
equals "start-silent-without-peers-on-startup" "" "$(fire "$RS" t1 startup "$PS1")"
equals "start-silent-without-peers-on-clear"   "" "$(fire "$RS" t1b clear "$PS1")"
equals "start-silent-without-peers-on-resume"  "" "$(fire "$RS" t1b resume "$PS1")"
L="$(ctx "$RS" t2 startup "$PS2")"
check  "start-line-appears-with-a-live-peer"   "live peers: main ($(basename "$RS"), pid $PS1)" "$L"
check  "start-line-says-how-to-read-more"      "peers.sh\" report" "$L"
equals "start-line-is-one-line"                "1" "$(printf '%s\n' "$L" | grep -c .)"
equals "start-hook-prints-the-peers-sh-line"   "$L" "$(start "$PS2" t2 startup "$RS")"
equals "start-output-is-json"                  "0" "$(fire "$RS" t2 startup "$PS2" | jq -e . >/dev/null 2>&1; echo $?)"
check  "start-line-on-clear"  "live peers: main" "$(ctx "$RS" t2c clear "$PS2")"
check  "start-line-on-resume" "live peers: main" "$(ctx "$RS" t2c resume "$PS2")"
check  "start-line-reaches-the-product"       "live peers:" "$(ctx "$RB" t3 startup "$PR")"
equals "start-line-skips-an-unrelated-product" "" "$(fire "$RC" t4 startup "$PC")"

# A task kept at /clear is named even after the peer that made the line necessary has exited.
edit_rec t2 '.kept = ["dev server"]'
stop "$PS1"
L="$(ctx "$RS" t2c startup "$PS2")"
check  "start-line-names-a-kept-task"       "kept at /clear: dev server" "$L"
absent "start-line-drops-an-exited-peer"    "live peers" "$L"
edit_rec t2 '.kept = []'
equals "start-silent-when-the-peer-has-exited" "" "$(fire "$RS" t2c startup "$PS2")"

# The hook takes its parent as the Claude process when nothing says otherwise.
PIDFILE="$W/hook.pid"
bash -c "echo \$\$ > '$PIDFILE'; printf '%s' '{\"session_id\":\"t5\",\"source\":\"startup\",\"cwd\":\"$RS\"}' | bash '$HOOK'" >/dev/null 2>&1
equals "start-hook-takes-its-parent-as-the-session" "$(cat "$PIDFILE")" "$(rec t5 '.pid')"

# Plan restore stays on startup and clear; resume prints the peers line only.
RP="$(repo)"
( cd "$RP" && git switch -q -c feat/x && mkdir -p docs/task-plans && plan ' ' ' ' > docs/task-plans/2026-01-01-feat-x.md && git add -A && git commit -q -m plan )
peer; PP1=$SP; peer; PP2=$SP
event "$PP1" tp1 before Bash "$RP" >/dev/null
check  "start-startup-keeps-plan-restore" "Rebuild it from" "$(ctx "$RP" tp2 startup "$PP2")"
check  "start-startup-adds-the-peers-line" "live peers: feat/x" "$(ctx "$RP" tp2 startup "$PP2")"
check  "start-clear-keeps-plan-restore"   "Rebuild it from" "$(ctx "$RP" tp2 clear "$PP2")"
L="$(ctx "$RP" tp2 resume "$PP2")"
check  "start-resume-prints-the-peers-line" "live peers: feat/x" "$L"
absent "start-resume-skips-plan-restore"    "Rebuild it from" "$L"
HOOKS="$FLOW_PLUGIN/hooks/hooks.json"
equals "start-hooks-json-matchers" "startup|clear resume" \
  "$(jq -r '[.hooks.SessionStart[] | select(.hooks[].command | endswith("session-start.sh")) | .matcher] | join(" ")' "$HOOKS")"

# --- the guard learns from commands: writers, and the branch a session expects ------------------------
# stp <dir> <op> <word>... -> one command step as the adapter sends it; steps <step>... -> the array.
stp() { local d="$1" o="$2"; shift 2; jq -nc --arg d "$d" --arg o "$o" --arg w "$*" '{words: ($w | split(" ")), dir: $d, op: $o, writes: false}'; }
steps() { printf '%s\n' "$@" | jq -sc .; }

# bash_event <pid> <session> <phase> <cwd> <steps> [seen] [ack] -> what `check` answers to one Bash event.
bash_event() {
  jq -nc --arg s "$2" --arg ph "$3" --arg c "$4" --argjson st "$5" --argjson seen "${6:-null}" --arg ack "${7:-}" \
    '{session_id: $s, phase: $ph, tool: "Bash", cwd: $c}
     + (if $st == null then {} else {steps: $st} end) + (if $seen == null then {} else {seen: $seen} end)
     + (if $ack == "" then {} else {ack: $ack} end)' \
    | CC_TUNER_PEERS_CLAUDE_PID="$1" bash "$PEERS" check
}

# call <pid> <session> <cwd> <steps> [shell command] -> a Bash call as the adapter makes it: `before`, the
# command itself in cwd, and `after` with what `before` answered, sent only when it answered something.
call() {
  local ans seen
  ans="$(bash_event "$1" "$2" before "$3" "$4")"
  if [ -n "${5:-}" ]; then ( cd "$3" && eval "$5" ) >/dev/null 2>&1; fi
  seen="$(printf '%s' "$ans" | jq -c '.seen // empty')"
  if [ -n "$seen" ]; then bash_event "$1" "$2" after "$3" null "$seen" >/dev/null; fi
}

expected_of() { rec "$1" ".checkouts[\"$2\"].expected"; }
writer_of() { rec "$1" ".checkouts[\"$2\"].writer | type"; }

RG="$(repo)"; peer; PG=$SP
call "$PG" g1 "$RG" "$(steps "$(stp '' '' git status)")"
for form in "git status" "git log --oneline" "git diff" "git show HEAD" "ls -la" "cat x" "grep -r a ." "rg a" "find . -name x"; do
  edit_rec g1 ".checkouts[\"$RG\"].writer = null"
  # shellcheck disable=SC2086
  call "$PG" g1 "$RG" "$(steps "$(stp '' '' $form)")"
  equals "guard-read-only-form-is-no-writer ($form)" "null" "$(writer_of g1 "$RG")"
done
for form in "npm test" "git commit -m m" "find . -delete" "find . -exec rm {} ;" "rg --pre cmd a" "git diff --output=f" "git" "git --git-dir=x log" "sed -i s/a/b/ f"; do
  edit_rec g1 ".checkouts[\"$RG\"].writer = null"
  # shellcheck disable=SC2086
  call "$PG" g1 "$RG" "$(steps "$(stp '' '' $form)")"
  equals "guard-other-form-is-a-writer ($form)" "number" "$(writer_of g1 "$RG")"
done
edit_rec g1 ".checkouts[\"$RG\"].writer = null"
call "$PG" g1 "$RG" "$(steps "$(stp '' '' cat x | jq -c '.writes = true')")"
equals "guard-redirection-makes-a-writer" "number" "$(writer_of g1 "$RG")"
edit_rec g1 ".checkouts[\"$RG\"].writer = null"
call "$PG" g1 "$RG" "$(steps "$(stp '' '' git status)" "$(stp '' '&&' npm test)")"
equals "guard-one-writer-step-makes-the-call-a-writer" "number" "$(writer_of g1 "$RG")"
edit_rec g1 ".checkouts[\"$RG\"].writer = null"
call "$PG" g1 "$RG" "null"
equals "guard-unparsed-command-is-a-writer" "number" "$(writer_of g1 "$RG")"
edit_rec g1 ".checkouts[\"$RG\"].writer = null"
call "$PG" g1 "$RG" "[]"
equals "guard-no-command-step-is-no-writer" "null" "$(writer_of g1 "$RG")"

# A step's directory decides its checkout: a writer step elsewhere marks that checkout, not the cwd's.
RX="$(repo)"
edit_rec g1 ".checkouts[\"$RG\"].writer = null"
call "$PG" g1 "$RG" "$(steps "$(stp "$RX" '' npm test)")"
equals "guard-step-directory-marks-its-checkout" "number" "$(writer_of g1 "$RX")"
equals "guard-step-directory-spares-the-cwd-checkout" "null" "$(writer_of g1 "$RG")"
call "$PG" g1 "$RG" "$(steps "$(stp "$RG/sub/../" '' npm test)")"
equals "guard-step-directory-inside-the-checkout" "number" "$(writer_of g1 "$RG")"
RY="$(repo)"
call "$PG" g1 "$RG" "$(steps "$(stp "$RY" '' git status)")"
equals "guard-read-only-step-elsewhere-does-not-touch-it" "" "$(rec g1 ".checkouts[\"$RY\"].expected // empty")"

# Edit, Write and NotebookEdit record the path after the call, and mark a writer.
RN="$(repo)"; peer; PN=$SP
event "$PN" g3 after NotebookEdit "$RN" "$RN/a.ipynb" >/dev/null
equals "guard-notebook-edit-records-its-path" "a.ipynb" "$(paths_of g3 "$RN")"
equals "guard-edit-makes-a-writer" "number" "$(writer_of g3 "$RN")"

# The expected branch moves only when HEAD changed during the session's own call that holds a switch.
RE="$(repo)"; peer; PE=$SP
for b in a b c; do git -C "$RE" branch "$b"; done
at() {  # at <expected> <head> -> the record expects the first, the checkout is on the second
  git -C "$RE" switch -q "$2"; edit_rec g2 ".checkouts[\"$RE\"].expected = \"$1\""
}
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git status)")"
equals "guard-expected-is-the-branch-at-first-touch" "main" "$(expected_of g2 "$RE")"
SW="$(stp '' '' git switch -c x)"
at a a
call "$PE" g2 "$RE" "$(steps "$SW" "$(stp '' '&&' git commit -m m)")" "git switch -q -c x && git commit -q --allow-empty -m m"
equals "guard-switch-and-commit-moves-the-expectation" "x" "$(expected_of g2 "$RE")"
at a a
call "$PE" g2 "$RE" "$(steps "$SW" "$(stp '' '&&' false)")" "git switch -q -c y; false"
equals "guard-switch-then-failing-step-moves-the-expectation" "y" "$(expected_of g2 "$RE")"
at a a
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git add f)" "$(stp '' '&&' git commit -m m)")" "git switch -q b"
equals "guard-head-changed-without-a-switch-step-keeps-it" "a" "$(expected_of g2 "$RE")"
equals "guard-no-switch-step-takes-no-snapshot" '{"decision":"allow"}' "$(bash_event "$PE" g2 before "$RE" "$(steps "$(stp '' '' git add f)")")"
# HEAD has already drifted from the expected a to b.
at a b
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git switch nosuch)")" "git switch -q nosuch"
equals "guard-drifted-failed-switch-keeps-it" "a" "$(expected_of g2 "$RE")"
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git switch nosuch)" "$(stp '' ';' true)")" "git switch -q nosuch; true"
equals "guard-drifted-failed-switch-then-true-keeps-it" "a" "$(expected_of g2 "$RE")"
call "$PE" g2 "$RE" "$(steps "$(stp '' '' false)" "$(stp '' '&&' git switch c)")" "false && git switch -q c"
equals "guard-drifted-skipped-switch-keeps-it" "a" "$(expected_of g2 "$RE")"
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git switch c)")" "git switch -q c"
equals "guard-drifted-successful-switch-moves-it" "c" "$(expected_of g2 "$RE")"
at a b
call "$PE" g2 "$RE" "$(steps "$(stp '' '' git checkout --detach)")" "git checkout -q --detach"
equals "guard-detaching-keeps-it" "a" "$(expected_of g2 "$RE")"
git -C "$RE" switch -q a
# A switch in another checkout is read there: the cwd's record is not moved by it.
RW="$(repo)"; git -C "$RW" branch other
call "$PE" g2 "$RE" "$(steps "$(stp "$RW" '' git switch other)")" "git -C '$RW' switch -q other"
equals "guard-switch-elsewhere-moves-that-checkout" "other" "$(expected_of g2 "$RW")"
equals "guard-switch-elsewhere-leaves-the-cwd-checkout" "a" "$(expected_of g2 "$RE")"

# --- the guard stops what would destroy a peer's checkout, files, branch or process -----------------------
# world -> a fresh repository $R where a live peer $P (session p<P>) is a writer and this session $M (session
# $ME) has been; one -> a single step in the cwd; verdict <name> <want> <cwd> <steps> [ack] -> this session's
# Bash call, its answer left in $ANS; key -> the ack key the last stop printed.
world() {
  R="$(repo)"; peer; P=$SP; peer; M=$SP; ME="m$M"
  event "$P" "p$P" before Bash "$R" >/dev/null
  bash_event "$M" "$ME" before "$R" "$(steps "$(stp '' '' git status)")" >/dev/null
}
one() { steps "$(stp '' '' "$@")"; }
inat() { local d="$1"; shift; steps "$(stp "$d" '' "$@")"; }
verdict() {
  ANS="$(bash_event "$M" "$ME" before "$3" "$4" null "${5:-}")"
  equals "$1" "$2" "$(printf '%s' "$ANS" | jq -r .decision)"
}
key() { printf '%s' "$ANS" | jq -r '.reason // empty' | sed -n 's/.*CC_TUNER_ACK=\([0-9a-f]*\).*/\1/p'; }
reason() { printf '%s' "$ANS" | jq -r '.reason // empty'; }
mark_mine() { event "$M" "$ME" after Edit "$R" "$R/$1" >/dev/null; }
peer_rec() { edit_rec "p$P" "$1"; }
now="$(date +%s)"

# Switching: a peer that writes in the checkout stops it; a peer that only sits there, or wrote over 2 h ago,
# is a note; a dead peer is nothing. The stop names the peer and offers one way on.
world; git -C "$R" branch x
for c in "git switch x" "git switch -c y" "git checkout x" "git checkout -b y" "git switch --detach"; do
  # shellcheck disable=SC2086
  verdict "guard-switch-stops-next-to-a-writer ($c)" stop "$R" "$(one $c)"
done
check  "guard-stop-names-the-peer"        "pid $P" "$(reason)"
check  "guard-stop-names-its-branch"      "main" "$(reason)"
check  "guard-stop-names-the-checkout"    "$R" "$(reason)"
check  "guard-stop-offers-the-ack"        "run the same command prefixed CC_TUNER_ACK=" "$(reason)"
check  "guard-stop-leaves-the-choice-to-the-agent" "not a question for the user" "$(reason)"
equals "guard-stop-is-short" "yes" "$([ "$(reason | wc -c)" -lt 300 ] && echo yes || echo no)"
verdict "guard-switch-elsewhere-is-allowed"  allow "$R" "$(inat "$(repo)" git switch x)"
verdict "guard-switch-compound-stops"        stop  "$R" "$(steps "$(stp '' '' git status)" "$(stp '' '&&' git switch x)")"
verdict "guard-switch-behind-git-C-stops"    stop  "$(repo)" "$(inat "$R" git switch x)"
verdict "guard-switch-behind-cd-stops"       stop  "$R" "$(steps "$(stp "$R/sub/.." '' git switch x)")"
peer_rec ".checkouts[\"$R\"].writer = $((now - 3 * 3600))"
verdict "guard-switch-after-2h-idle-is-a-note"   note "$R" "$(one git switch x)"
check   "guard-switch-note-names-the-peer"       "pid $P" "$(reason)"
peer_rec ".checkouts[\"$R\"].writer = $((now - 3600))"
verdict "guard-switch-after-1h-idle-still-stops" stop "$R" "$(one git switch x)"
peer_rec ".checkouts[\"$R\"].writer = null"
verdict "guard-switch-next-to-a-cwd-is-a-note"   note "$R" "$(one git switch x)"
peer_rec ".checkouts[\"$R\"].writer = $now"
stop "$P"
verdict "guard-switch-with-a-dead-peer-is-allowed" allow "$R" "$(one git switch x)"
world; git -C "$R" branch x
verdict "guard-switch-stop-sets-no-writer-mark" stop "$R" "$(one git switch x)"
equals  "guard-stopped-call-makes-no-writer" "null" "$(writer_of "$ME" "$R")"
verdict "guard-allowed-writer-call-marks-a-writer" allow "$R" "$(one git branch y)"
equals  "guard-allowed-call-makes-a-writer" "number" "$(writer_of "$ME" "$R")"

# Foreign files: dirty, staged or untracked files this session did not edit through Edit or Write. Every
# stop has a neighbour that passes once the session owns the file. No peer is needed: the files are the
# user's, Codex's or a tool's, and a dead peer's stay protected.
world; commit_file "$R" g.txt one; mkdir -p "$R/sub"; commit_file "$R" sub/s.txt one
printf 'x\n' >> "$R/.flow-seed"; printf 'u\n' > "$R/u.txt"; printf 'n\n' > "$R/sub/n.txt"
stop "$P"
FOREIGN=("git reset --hard" "git reset --hard HEAD~1" "git stash" "git stash push" "git stash -u" "git restore .flow-seed"
  "git restore ." "git checkout -- .flow-seed" "git checkout ." "git clean -fd" "git commit -a -m m" "git commit -am m"
  "git add -A" "git add --all" "git add ." "git add -u" "git add sub")
for c in "${FOREIGN[@]}"; do
  # shellcheck disable=SC2086
  verdict "guard-foreign-stop ($c)" stop "$R" "$(one $c)"
done
verdict "guard-foreign-stop-unknown-owner"    stop "$R" "$(one git reset --hard)"
check  "guard-foreign-stop-names-the-file"    ".flow-seed" "$(reason)"
check  "guard-foreign-stop-says-unknown-owner" "unknown owner" "$(reason)"
verdict "guard-foreign-stop-behind-git-C"     stop "$(repo)" "$(inat "$R" git reset --hard)"
verdict "guard-foreign-stop-behind-wrappers"  stop "$R" "$(steps "$(stp ../x '&&' git status)" "$(stp '' '-' echo)" "$(stp '' ';' git reset --hard)")"
verdict "guard-foreign-stop-in-a-compound"    stop "$R" "$(steps "$(stp '' '' git status)" "$(stp '' '&&' git reset --hard)")"
# Neighbours that pass while the files are foreign: a dry run, a read, another path, a path that is not dirty.
for c in "git clean -n" "git clean -nd" "git stash list" "git status" "git restore g.txt" "git checkout -- g.txt" "git add g.txt" "git add sub/s.txt" "git stash show"; do
  # shellcheck disable=SC2086
  verdict "guard-foreign-neighbour-allows ($c)" allow "$R" "$(one $c)"
done
verdict "guard-foreign-reset-in-a-clean-checkout-allows" allow "$(repo)" "$(one git reset --hard)"
git -C "$R" add .flow-seed
verdict "guard-foreign-staged-commit-stops"   stop "$R" "$(one git commit -m m)"
verdict "guard-foreign-staged-amend-stops"    stop "$R" "$(one git commit --amend --no-edit)"
git -C "$R" reset -q
verdict "guard-add-f-then-commit-stops-for-a-foreign-f" stop "$R" "$(steps "$(stp '' '' git add .flow-seed)" "$(stp '' '&&' git commit -m m)")"
verdict "guard-add-alone-of-a-named-file-allows"        allow "$R" "$(one git add .flow-seed)"
for f in .flow-seed u.txt sub/n.txt; do mark_mine "$f"; done
for c in "${FOREIGN[@]}"; do
  # shellcheck disable=SC2086
  verdict "guard-own-files-allow ($c)" allow "$R" "$(one $c)"
done
git -C "$R" add .flow-seed
verdict "guard-own-staged-commit-allows"      allow "$R" "$(one git commit -m m)"
verdict "guard-add-f-then-commit-allows-an-own-f" allow "$R" "$(steps "$(stp '' '' git add .flow-seed)" "$(stp '' '&&' git commit -m m)")"
printf 'y\n' >> "$R/g.txt"
verdict "guard-restore-of-a-dirty-file-nobody-edited-stops" stop "$R" "$(one git restore g.txt)"

# The stop names the peer that edited a foreign file, and a dead peer's files stay protected.
world; printf 'p\n' >> "$R/.flow-seed"; event "$P" "p$P" after Edit "$R" "$R/.flow-seed" >/dev/null
verdict "guard-foreign-file-of-a-live-peer-stops" stop "$R" "$(one git reset --hard)"
check  "guard-foreign-stop-names-the-peer"       "pid $P on main" "$(reason)"
stop "$P"
verdict "guard-foreign-file-of-a-dead-peer-stays-protected" stop "$R" "$(one git reset --hard)"
check  "guard-foreign-stop-names-the-dead-peer"  "pid $P, exited" "$(reason)"

# Stash drop and clear need a live peer in the repository.
world
for c in "git stash drop" "git stash clear" "git stash drop stash@{1}"; do
  # shellcheck disable=SC2086
  verdict "guard-stash-drop-stops-next-to-a-peer ($c)" stop "$R" "$(one $c)"
done
verdict "guard-stash-drop-behind-git-C-stops" stop "$(repo)" "$(inat "$R" git stash drop)"
verdict "guard-stash-list-allows"             allow "$R" "$(one git stash list)"
peer_rec ".checkouts[\"$R\"].writer = $((now - 3 * 3600))"
verdict "guard-stash-drop-ignores-the-2h-window" stop "$R" "$(one git stash drop)"
stop "$P"
verdict "guard-stash-drop-with-a-dead-peer-allows" allow "$R" "$(one git stash drop)"

# Commit, push and PR run on the branch this session expects, whoever switched it.
world; git -C "$R" branch x; stop "$P"
for c in "git commit -m m" "git push origin main" "gh pr create --fill" "gh pr merge 5" "gh pr merge --squash"; do
  # shellcheck disable=SC2086
  verdict "guard-on-the-expected-branch-allows ($c)" allow "$R" "$(one $c)"
done
git -C "$R" switch -q x
for c in "git commit -m m" "git push origin x" "gh pr create --fill" "gh pr merge 5" "gh pr merge --squash"; do
  # shellcheck disable=SC2086
  verdict "guard-drifted-branch-stops ($c)" stop "$R" "$(one $c)"
done
check  "guard-drift-stop-names-both-branches" "x" "$(reason)"
check  "guard-drift-stop-names-the-expected-one" "main" "$(reason)"
verdict "guard-drifted-commit-behind-git-C-stops" stop "$(repo)" "$(inat "$R" git commit -m m)"
verdict "guard-drifted-status-allows"             allow "$R" "$(one git status)"
verdict "guard-switching-back-then-committing-allows" allow "$R" "$(steps "$(stp '' '' git switch main)" "$(stp '' '&&' git commit -m m)")"
git -C "$R" switch -q main
verdict "guard-switch-and-commit-in-one-call-allows" allow "$R" "$(steps "$(stp '' '' git switch -c z)" "$(stp '' '&&' git commit -m m)")"
git -C "$R" switch -q --detach
verdict "guard-detached-head-commit-stops-too" stop "$R" "$(one git commit -m m)"
git -C "$R" switch -q main

# Deleting a peer's expected branch.
world; git -C "$R" branch feat-p; git -C "$R" branch spare
peer_rec ".checkouts[\"$R\"].expected = \"feat-p\""
for c in "git branch -D feat-p" "git branch -d feat-p" "git branch --delete feat-p spare" "git push origin --delete feat-p"
do
  # shellcheck disable=SC2086
  verdict "guard-deleting-a-peers-branch-stops ($c)" stop "$R" "$(one $c)"
done
verdict "guard-push-colon-refspec-stops"      stop "$R" "$(one git push origin :feat-p)"
verdict "guard-pr-merge-delete-branch-stops"  stop "$R" "$(one gh pr merge --squash --delete-branch feat-p)"
verdict "guard-delete-branch-behind-git-C-stops" stop "$(repo)" "$(inat "$R" git branch -D feat-p)"
check  "guard-branch-stop-names-the-peer"     "pid $P" "$(reason)"
verdict "guard-deleting-another-branch-allows" allow "$R" "$(one git branch -D spare)"
verdict "guard-push-delete-another-branch-allows" allow "$R" "$(one git push origin --delete spare)"
verdict "guard-pr-merge-without-delete-allows" allow "$R" "$(one gh pr merge --squash feat-p)"
verdict "guard-pr-merge-delete-by-number-is-a-note" note "$R" "$(one gh pr merge 7 --delete-branch)"
verdict "guard-listing-branches-allows"       allow "$R" "$(one git branch --list)"
stop "$P"
verdict "guard-deleting-a-dead-peers-branch-allows" allow "$R" "$(one git branch -D feat-p)"

# Removing a worktree that is a peer's cwd, or holds foreign files.
world; git -C "$R" worktree add -q -b wt "$W/wt$P"; WT="$(cd "$W/wt$P" && pwd -P)"
event "$P" "p$P" before Bash "$WT" >/dev/null
for c in "git worktree remove $WT" "git worktree remove --force $WT" "rm -rf $WT" "rm -r $WT" "rm -fr $WT/"; do
  # shellcheck disable=SC2086
  verdict "guard-removing-a-peers-cwd-stops ($c)" stop "$R" "$(one $c)"
done
verdict "guard-removing-the-parent-of-a-peers-cwd-stops" stop "$R" "$(one rm -rf "$(dirname "$WT")")"
verdict "guard-removal-behind-bash-c-stops"   stop "$R" "$(steps "$(stp "$W" '' rm -rf "wt$P")")"
check  "guard-removal-stop-names-the-peer"    "pid $P" "$(reason)"
verdict "guard-removing-another-directory-allows" allow "$R" "$(one rm -rf "$R/build")"
verdict "guard-removing-a-file-allows"        allow "$R" "$(one rm "$WT/x")"
git -C "$R" worktree add -q -b wt2 "$W/wt2$P"; WT2="$(cd "$W/wt2$P" && pwd -P)"
verdict "guard-removing-a-clean-worktree-allows" allow "$R" "$(one git worktree remove "$WT2")"
printf 'f\n' > "$WT2/foreign.txt"
verdict "guard-removing-a-worktree-with-foreign-files-stops" stop "$R" "$(one git worktree remove --force "$WT2")"
verdict "guard-rm-rf-of-a-worktree-with-foreign-files-stops" stop "$R" "$(one rm -rf "$WT2")"
check  "guard-worktree-stop-names-the-file"   "foreign.txt" "$(reason)"
event "$M" "$ME" after Write "$WT2" "$WT2/foreign.txt" >/dev/null
verdict "guard-removing-a-worktree-of-own-files-allows" allow "$R" "$(one git worktree remove --force "$WT2")"
stop "$P"
verdict "guard-removing-a-dead-peers-worktree-allows" allow "$R" "$(one git worktree remove "$WT")"

# Kill: a process that descends from a peer's Claude. A peer stand-in is a bash with a child; this session's
# stand-in has one too, and nothing here is ever killed: the guard only reads the process table.
TN=0
tree() {  # tree [cmd] -> a stand-in Claude (pid $SP) with a child running cmd (default: sleep 300), child pid in $SC
  TN=$((TN + 1))
  bash -c "${1:-sleep 300} & echo \$! > \"\$1\"; wait" _ "$W/child.$TN" >/dev/null 2>&1 &
  SP=$!; disown "$SP" 2>/dev/null; STARTED="$STARTED $SP"
  local n=0; until [ -s "$W/child.$TN" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done
  SC="$(cat "$W/child.$TN")"; STARTED="$STARTED $SC"
}
R="$(repo)"
tree "sleep 3737"; P=$SP; PC=$SC; event "$P" "p$P" before Bash "$R" >/dev/null
tree "sleep 3838"; M=$SP; MC=$SC; ME="m$M"; event "$M" "$ME" before Bash "$R" >/dev/null
sleep 300 >/dev/null 2>&1 & UN=$!; disown "$UN" 2>/dev/null; STARTED="$STARTED $UN"
verdict "guard-kill-of-a-peers-child-stops"      stop  "$R" "$(one kill "$PC")"
check   "guard-kill-stop-names-the-peer"         "pid $P" "$(reason)"
verdict "guard-kill-signal-of-a-peers-child-stops" stop "$R" "$(one kill -9 "$PC")"
verdict "guard-kill-of-the-peer-itself-stops"    stop  "$R" "$(one kill "$P")"
verdict "guard-kill-behind-git-C-dir-stops"      stop  "$(repo)" "$(inat "$R" kill "$PC")"
verdict "guard-kill-of-an-own-child-allows"      allow "$R" "$(one kill "$MC")"
verdict "guard-kill-of-an-unrelated-process-allows" allow "$R" "$(one kill "$UN")"
verdict "guard-pkill-matching-a-peers-child-stops" stop "$R" "$(one pkill -f 3737)"
verdict "guard-pkill-signal-matching-a-peers-child-stops" stop "$R" "$(one pkill -9 -f 3737)"
verdict "guard-pkill-matching-an-own-child-allows" allow "$R" "$(one pkill -f 3838)"
verdict "guard-pkill-matching-nothing-allows"    allow "$R" "$(one pkill -f 3939)"
mkdir -p "$W/bin"; ln -sf /bin/sleep "$W/bin/peersleep"; ln -sf /bin/sleep "$W/bin/mysleep"
tree "$W/bin/peersleep 300"; stop "$P"; P=$SP; event "$P" "p$P" before Bash "$R" >/dev/null
tree "$W/bin/mysleep 300";   stop "$M"; M=$SP; ME="m$M"; event "$M" "$ME" before Bash "$R" >/dev/null
verdict "guard-killall-a-peers-process-stops"    stop  "$R" "$(one killall peersleep)"
verdict "guard-killall-an-own-process-allows"    allow "$R" "$(one killall mysleep)"
# A port: `kill $(lsof -ti :N)` and `lsof -ti :N | xargs kill`, whose target is read from the same lsof.
printf '%s\n' 'import socket, sys, time' 's = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)' \
  'open(sys.argv[1], "w").write(str(s.getsockname()[1])); time.sleep(300)' > "$W/listen.py"
tree "python3 '$W/listen.py' '$W/port.1'"; stop "$P"; P=$SP; PC2=$SC; event "$P" "p$P" before Bash "$R" >/dev/null
n=0; until [ -s "$W/port.1" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done; PORT="$(cat "$W/port.1")"
verdict "guard-kill-of-a-port-owner-stops"       stop  "$R" "$(steps "$(stp '' '' lsof -ti ":$PORT")" "$(stp '' '' kill)")"
verdict "guard-xargs-kill-of-a-port-owner-stops" stop  "$R" "$(steps "$(stp '' '' lsof -ti ":$PORT")" "$(stp '' '|' kill)")"
verdict "guard-kill-of-a-port-nobody-holds-allows" allow "$R" "$(steps "$(stp '' '' lsof -ti :1)" "$(stp '' '' kill)")"
verdict "guard-kill-of-an-unreadable-pid-is-a-note" note "$R" "$(one kill '$PID')"
stop "$P"
verdict "guard-kill-of-a-dead-peers-child-allows" allow "$R" "$(one kill "$PC2")"

# Notes: an edit next to a writer, or of a path a peer claims, runs; each is said once an hour.
world
edit_ev() { jq -nc --arg s "$ME" --arg c "$R" --arg p "$1" '{session_id: $s, phase: "before", tool: "Edit", cwd: $c, path: $p}' | CC_TUNER_PEERS_CLAUDE_PID="$M" bash "$PEERS" check; }
ANS="$(edit_ev "$R/a.txt")"
equals "guard-edit-next-to-a-writer-is-a-note" "note" "$(printf '%s' "$ANS" | jq -r .decision)"
check  "guard-edit-note-names-the-peer"        "pid $P" "$(printf '%s' "$ANS" | jq -r .reason)"
equals "guard-edit-note-once-an-hour"          "allow" "$(edit_ev "$R/b.txt" | jq -r .decision)"
edit_rec "$ME" ".acks = (.acks | with_entries(.value = 1))"
equals "guard-edit-note-again-after-the-hour"  "note" "$(edit_ev "$R/b.txt" | jq -r .decision)"
equals "guard-edit-before-marks-no-writer"     "null" "$(writer_of "$ME" "$R")"
peer_rec ".claims = {\"plan.md\": {\"repo\": \"$(rec "p$P" ".checkouts[\"$R\"].repo")\", \"paths\": [\"lib/\"]}} | .checkouts[\"$R\"].writer = null"
ANS="$(edit_ev "$R/lib/x.ts")"
equals "guard-edit-of-a-claimed-path-is-a-note" "note" "$(printf '%s' "$ANS" | jq -r .decision)"
check  "guard-claim-note-names-the-claim"       "lib/" "$(printf '%s' "$ANS" | jq -r .reason)"
equals "guard-edit-of-an-unclaimed-path-allows" "allow" "$(edit_ev "$R/src/x.ts" | jq -r .decision)"
stop "$P"
equals "guard-edit-with-a-dead-peer-allows"     "allow" "$(edit_ev "$R/lib/y.ts" | jq -r .decision)"
world
equals "guard-edit-in-another-repository-allows" "allow" "$(edit_ev "$(repo)/a.txt" | jq -r .decision)"
world
verdict "guard-git-with-an-option-first-is-a-note" note "$R" "$(one git --git-dir=x reset --hard)"

# The ack: the key a stop printed passes that action on that target, for 30 min, and nothing else.
world; printf 'x\n' >> "$R/.flow-seed"; printf 'u\n' > "$R/u.txt"; R2="$(repo)"; printf 'x\n' >> "$R2/.flow-seed"
event "$M" "$ME" before Bash "$R2" >/dev/null
verdict "guard-ack-setup-stops" stop "$R" "$(one git reset --hard)"; K="$(key)"
equals  "guard-ack-key-is-printed" "8" "${#K}"
verdict "guard-ack-passes-the-same-command" allow "$R" "$(one git reset --hard)" "$K"
equals  "guard-ack-is-recorded" "number" "$(rec "$ME" ".acks[\"$K\"] | type")"
verdict "guard-ack-holds-without-the-prefix-for-30-min" allow "$R" "$(one git reset --hard)"
verdict "guard-ack-does-not-pass-another-action" stop "$R" "$(one git clean -fd)"
verdict "guard-ack-does-not-pass-another-target" stop "$R2" "$(one git reset --hard)"
verdict "guard-ack-does-not-pass-another-checkout-by-git-C" stop "$(repo)" "$(inat "$R2" git reset --hard)"
verdict "guard-ack-passes-the-same-action-by-git-C" allow "$(repo)" "$(inat "$R" git reset --hard)"
verdict "guard-ack-of-another-key-passes-nothing" stop "$R2" "$(one git reset --hard)" "deadbeef"
edit_rec "$ME" ".acks[\"$K\"] = $((now - 31 * 60))"
verdict "guard-ack-expires-after-30-min" stop "$R" "$(one git reset --hard)"
verdict "guard-ack-prefix-renews-it" allow "$R" "$(one git reset --hard)" "$K"
edit_rec "$ME" ".acks = {}"
verdict "guard-ack-needs-the-printed-key-not-a-guess" stop "$R" "$(one git reset --hard)" "00000000"
start "$M" "$ME" clear "$R" >/dev/null
equals  "guard-ack-is-dropped-at-clear" "{}" "$(rec "$ME" '.acks | tojson')"

# --- latency: the guard decides in at most 150 ms p95 over 50 calls with 10 records ------------------------
# Ten live peers in the call's repository, none a writer, so a switch is a note and the commit after it is
# read too: the checkout of each step, the process table entries of the ten, HEAD, and `git status`.
OUTER_DIR="$CC_TUNER_PEERS_DIR"; export CC_TUNER_PEERS_DIR="$W/lat-peers"
RL="$(repo)"; git -C "$RL" branch x
for i in 1 2 3 4 5 6 7 8 9 10; do
  peer; event "$SP" "lat$i" before Bash "$RL" >/dev/null; edit_rec "lat$i" ".checkouts[\"$RL\"].writer = null"
done
peer; ML=$SP; bash_event "$ML" lat-me before "$RL" "$(steps "$(stp '' '' git status)")" >/dev/null
LAT="$(python3 - "$PEERS" "$RL" "$ML" <<'PY'
import json, os, subprocess, sys, time
peers, repo, pid = sys.argv[1:4]
steps = [{"words": ["git", "switch", "x"], "dir": "", "op": "", "writes": False},
         {"words": ["git", "commit", "-m", "m"], "dir": "", "op": "&&", "writes": False}]
ev = json.dumps({"session_id": "lat-me", "phase": "before", "tool": "Bash", "cwd": repo, "steps": steps})
env = dict(os.environ, CC_TUNER_PEERS_CLAUDE_PID=pid)
# Wall time includes the load of the machine, so up to three rounds run and the best p95 decides: a slow
# guard fails all three, a busy machine rarely does.
rounds = []
for _ in range(3):
    ts = []
    for _ in range(50):
        t = time.perf_counter()
        r = subprocess.run(["bash", peers, "check"], input=ev, text=True, capture_output=True, env=env)
        ts.append((time.perf_counter() - t) * 1000)
    ts.sort()
    rounds.append(int(ts[47]))
    if rounds[-1] <= 150:
        break
print(min(rounds), json.loads(r.stdout)["decision"], "/".join(map(str, rounds)))
PY
)"
export CC_TUNER_PEERS_DIR="$OUTER_DIR"
LAT_DECISION="${LAT#* }"; LAT_DECISION="${LAT_DECISION%% *}"
equals "latency-measures-the-whole-decision" "note" "$LAT_DECISION"
if [ "${LAT%% *}" -le 150 ]; then pass "latency (p95 ${LAT##* } ms over 50 calls with 10 records)"; else fail "latency (p95 ${LAT##* } ms per round, want at most 150)"; fi

# --- one test drives the shipped adapter end to end ----------------------------------------------------
# A real `claude -p` loads the plugin and runs real tool calls; only the model is a stand-in, a few lines
# of Python that answer each request with the next call of a script. The engine, hooks/register.ts,
# `$.process.run`, peers.sh and git are the real ones, and the Claude pid is the process started here.
cat > "$W/fake_api.py" <<'PY'
import http.server, json, sys
script = [json.loads(line) for line in open(sys.argv[1])]
log = sys.argv[2]
msg = [0]

def sse(*events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()

class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        open(log, "w").write(json.dumps(body.get("messages", [])))
        asked = sum(1 for m in body.get("messages", []) if isinstance(m.get("content"), list)
                    for b in m["content"] if isinstance(b, dict) and b.get("type") == "tool_result")
        call = script[asked] if body.get("tools") and asked < len(script) else None
        msg[0] += 1
        block = {"type": "text", "text": ""} if call is None else {"type": "tool_use", "id": "toolu_%d" % asked, "name": call["name"], "input": {}}
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

# e2e <repo> <session id> <script line>... -> runs the script as one `claude -p` session in repo; leaves its pid in $CP
# and, in $W/api.log, everything the model was told over the session.
e2e() {
  local repo="$1" sid="$2" n=0; shift 2
  printf '%s\n' "$@" > "$W/script.jsonl"
  python3 "$W/fake_api.py" "$W/script.jsonl" "$W/api.log" > "$W/api.port" & API=$!; STARTED="$STARTED $API"
  until [ -s "$W/api.port" ] || [ "$n" -ge 100 ]; do sleep 0.05; n=$((n + 1)); done
  ( cd "$repo" && exec env CLAUDE_CONFIG_DIR="$W/claude-config" ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$W/api.port")" \
      ANTHROPIC_API_KEY=sk-ant-stand-in DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p go --model haiku --session-id "$sid" --plugin-dir "$FLOW_PLUGIN" --setting-sources project,local \
      --dangerously-skip-permissions < /dev/null > "$W/claude.out" 2>&1 ) & CP=$!; STARTED="$STARTED $CP"
  n=0; while kill -0 "$CP" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
  kill "$CP" "$API" 2>/dev/null; rm -f "$W/api.port"
}

# outermost <pid> -> the outermost `claude` from pid up, empty when there is none. A nested `claude -p`
# is its outermost parent's session, so a suite run inside Claude Code expects that pid, else the stand-in's.
outermost() {
  local p="$1" top=""
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$(ps -o comm= -p "$p" | sed 's|.*/||')" = claude ] && top="$p"
    p="$(ps -o ppid= -p "$p" | tr -d ' ')"
  done
  printf '%s' "$top"
}

# e2e_rec <jq filter> -> a field of the record of the session the last e2e ran as: inside Claude Code every
# nested session is the outermost one's, so the record is found by pid, not by the session id.
e2e_rec() {
  local f pid; pid="$(outermost "$$" | grep . || printf %s "$CP")"
  for f in "$CC_TUNER_PEERS_DIR"/*.json; do [ "$(jq -r .pid "$f" 2>/dev/null)" = "$pid" ] && { jq -r "$1" "$f"; return; }; done
}

if command -v claude >/dev/null 2>&1; then
  RT="$(repo)"; SID=00000000-0000-4000-8000-0000000000e2
  e2e "$RT" "$SID" \
    '{"name":"Bash","input":{"command":"git status"}}' \
    '{"name":"Bash","input":{"command":"git switch -q -c e2e && git commit -q --allow-empty -m e2e"}}' \
    "{\"name\":\"Write\",\"input\":{\"file_path\":\"$RT/notes.txt\",\"content\":\"n\"}}"
  check  "guard-e2e-the-model-stand-in-finished" "done" "$(cat "$W/claude.out")"
  equals "guard-e2e-session-is-the-claude-process" "$(outermost "$$" | grep . || printf %s "$CP")" "$(rec "$SID" '.pid')"
  equals "guard-e2e-switch-moved-the-expectation" "e2e" "$(expected_of "$SID" "$RT")"
  equals "guard-e2e-edit-recorded-its-path"       "notes.txt" "$(paths_of "$SID" "$RT")"
  equals "guard-e2e-writer-call-marked-a-writer"  "number" "$(writer_of "$SID" "$RT")"
  # A peer writes in the checkout: the wrapped switch is stopped, the same command prefixed with the printed key
  # runs with the prefix stripped, and an edit next to the peer carries a note the model reads.
  RB="$(repo)"; peer; PB2=$SP; peer; MB=$SP
  event "$PB2" "pb$PB2" before Bash "$RB" >/dev/null
  bash_event "$MB" "mb$MB" before "$RB" "$(one git status)" >/dev/null
  bash_event "$MB" "mb$MB" before "$RB" "$(one git switch z)" > "$W/stop.json"
  KEYB="$(jq -r .reason "$W/stop.json" | sed -n 's/.*CC_TUNER_ACK=\([0-9a-f]*\).*/\1/p')"
  SIDB=00000000-0000-4000-8000-0000000000e3
  e2e "$RB" "$SIDB" \
    '{"name":"Bash","input":{"command":"bash -c '"'"'cd . && git switch -q -c z'"'"'"}}' \
    "{\"name\":\"Bash\",\"input\":{\"command\":\"CC_TUNER_ACK=$KEYB bash -c 'cd . && git switch -q -c z'\"}}" \
    "{\"name\":\"Write\",\"input\":{\"file_path\":\"$RB/b.txt\",\"content\":\"b\"}}"
  check  "guard-e2e-stop-reaches-the-model"     "run the same command prefixed CC_TUNER_ACK=$KEYB" "$(cat "$W/api.log")"
  check  "guard-e2e-stop-says-the-choice-is-the-agents" "not a question for the user" "$(cat "$W/api.log")"
  equals "guard-e2e-acked-command-ran-without-the-prefix" "z" "$(git -C "$RB" branch --show-current)"
  equals "guard-e2e-ack-is-recorded"            "number" "$(e2e_rec ".acks[\"$KEYB\"] | type")"
  check  "guard-e2e-note-reaches-the-model"     "also writes in" "$(cat "$W/api.log")"
  equals "guard-e2e-noted-edit-ran"             "b" "$(cat "$RB/b.txt" 2>/dev/null)"
else
  fail "guard-e2e (claude is not on PATH; install @anthropic-ai/claude-code to drive the adapter)"
fi

exit $fails
