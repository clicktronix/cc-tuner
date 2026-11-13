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

# bash_event <pid> <session> <phase> <cwd> <steps> [seen] -> what `check` answers to one Bash event.
bash_event() {
  jq -nc --arg s "$2" --arg ph "$3" --arg c "$4" --argjson st "$5" --argjson seen "${6:-null}" \
    '{session_id: $s, phase: $ph, tool: "Bash", cwd: $c}
     + (if $st == null then {} else {steps: $st} end) + (if $seen == null then {} else {seen: $seen} end)' \
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

# --- one test drives the shipped adapter end to end ----------------------------------------------------
# A real `claude -p` loads the plugin and runs real tool calls; only the model is a stand-in, a few lines
# of Python that answer each request with the next call of a script. The engine, hooks/register.ts,
# `$.process.run`, peers.sh and git are the real ones, and the Claude pid is the process started here.
cat > "$W/fake_api.py" <<'PY'
import http.server, json, sys
script = [json.loads(line) for line in open(sys.argv[1])]
msg = [0]

def sse(*events):
    return "".join("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e)) for e in events).encode()

class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
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

# e2e <repo> <session id> <script line>... -> runs the script as one `claude -p` session in repo; leaves its pid in $CP.
e2e() {
  local repo="$1" sid="$2" n=0; shift 2
  printf '%s\n' "$@" > "$W/script.jsonl"
  python3 "$W/fake_api.py" "$W/script.jsonl" > "$W/api.port" & API=$!; STARTED="$STARTED $API"
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
else
  fail "guard-e2e (claude is not on PATH; install @anthropic-ai/claude-code to drive the adapter)"
fi

exit $fails
