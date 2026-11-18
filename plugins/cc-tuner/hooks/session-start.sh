#!/usr/bin/env bash
# SessionStart: ask the agent to rebuild this branch's task list from its committed plan.
#
# ASK, not do: a command hook emits JSON and cannot call TaskCreate, so recovery is advisory and
# depends on the agent following it. Registered for `startup` and `clear` only, because the task list
# survives /compact and resume; the instruction is idempotent anyway (read TaskList first, create only
# what is missing), so a trigger change cannot double the plan.
#
# Silence is a correct output, and the common one: no plan, or nothing left open.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null

# The repository root, because plan-path.sh prints a repo-relative path: from a subdirectory the plan
# resolved and then could not be opened.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" 2>/dev/null || exit 0

emit() {  # emit <context text> -- jq builds the JSON so the text cannot break out of the string
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# A run under --local-only (commits reserved) keeps its plan on disk and nothing in HEAD. Without this
# fallback such a run lost its plan at every /clear, compaction and new session.
LOCAL_PLAN=0
if ! PLAN="$(bash "$SCRIPTS/plan-path.sh" resolve 2>/dev/null)"; then
  PLAN="$(bash "$SCRIPTS/plan-path.sh" resolve --local-only 2>/dev/null)" || exit 0
  LOCAL_PLAN=1
fi

NOTE=""
if [ "$LOCAL_PLAN" -eq 1 ]; then
  KIND="an uncommitted plan on disk"
  DONE_KIND="uncommitted plan"
  SAVE="and leave it on disk: this run does not commit. Resume with /cc-tuner:run --local-only <spec>"
  read_slices() { bash "$SCRIPTS/plan-lint.sh" slices "$PLAN"; }
else
  # A plan whose exact content is already in the remote default branch belongs to work that landed; a
  # branch reused afterwards would otherwise be told to rebuild a finished task. Only identical content
  # counts: a landed plan this branch extended with new slices is still open work.
  DEFAULT_REF="$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  LANDED_BLOB="$( [ -z "$DEFAULT_REF" ] || git rev-parse -q --verify "$DEFAULT_REF:$PLAN" 2>/dev/null || true)"
  PLAN_BLOB="$(git rev-parse -q --verify "HEAD:$PLAN" 2>/dev/null)" || exit 0
  if [ -n "$LANDED_BLOB" ] && [ "$LANDED_BLOB" = "$PLAN_BLOB" ]; then
    exit 0
  fi
  KIND="a committed plan"
  DONE_KIND="committed plan"
  SAVE="and commit it"
  read_slices() {
    set -o pipefail
    git cat-file blob "$PLAN_BLOB" | bash "$SCRIPTS/plan-lint.sh" slices -
  }
  # The list below is HEAD's. The working copy is named, never read in its place: under --local-only it
  # holds the ticks made since the last commit, and in any other run it is an edit in progress.
  git diff --quiet HEAD -- "$PLAN" 2>/dev/null || NOTE="
The working copy of $PLAN differs from HEAD. The list above is HEAD's; a --local-only run keeps its
ticks in the working copy, so read the file before rebuilding.
"
fi

if ! SLICES="$(read_slices 2>/dev/null)"; then
  # A plan that does not parse is not nothing: staying quiet would let the branch look like it has
  # no plan at all.
  emit "cc-tuner: $PLAN does not parse, so the task list was not restored. Run:
  bash \"$SCRIPTS/plan-lint.sh\" check \"$PLAN\""
  exit 0
fi

# Open slices, plus every done slice an open one is blocked by, transitively and with its own edges:
# restoring only the open ones leaves edges pointing at tasks that do not exist.
BODY="$(printf '%s\n' "$SLICES" | awk -F'\t' '
$1 == "SLICE" { state[$2] = $3; blocked[$2] = $4; shown[$2] = ($4 == "-" ? "none" : $4); title[$2] = $5; order[++n] = $2 }
$1 == "CRIT" && $3 == "open" { open_crit[$2] = open_crit[$2] "\n    - [ ] " $4 }
END {
  for (i = 1; i <= n; i++) {
    s = order[i]
    if (state[s] != "open") continue
    if (blocked[s] != "-") {
      m = split(blocked[s], b, /[ \t]*,[ \t]*/)
      for (j = 1; j <= m; j++) if (state[b[j]] == "done") need[b[j]] = 1
    }
  }

  do {
    added = 0
    for (s in need) {
      if (blocked[s] == "-") continue
      m = split(blocked[s], b, /[ \t]*,[ \t]*/)
      for (j = 1; j <= m; j++)
        if (state[b[j]] == "done" && !(b[j] in need)) { need[b[j]] = 1; added = 1 }
    }
  } while (added)

  for (i = 1; i <= n; i++) {
    s = order[i]
    if (!(s in need)) continue
    printf "Slice %s — %s [already done: create it completed, then wire its edges below]\n    Blocked by: %s\n", s, title[s], shown[s]
  }
  for (i = 1; i <= n; i++) {
    s = order[i]
    if (state[s] != "open") continue
    printf "Slice %s — %s\n    Blocked by: %s%s\n", s, title[s], shown[s], open_crit[s]
  }
}')"

# Unticked checkboxes under a section that is not a slice (Verify, Review, Deliver, follow-ups):
# work the plan tracks outside its slices, listed so it is not lost once every slice is done.
OUTSIDE="$(printf '%s\n' "$SLICES" | awk -F'\t' '
$1 == "OPEN" { if ($2 != sec) { sec = $2; printf "%s\n", sec }; printf "    - [ ] %s\n", $3 }')"
[ -z "$OUTSIDE" ] || OUTSIDE="
Open checkboxes outside the slices, by section:

$OUTSIDE
"

if [ -z "$BODY" ]; then
  [ -n "$OUTSIDE" ] || exit 0
  emit "cc-tuner: every slice in this branch's $DONE_KIND is done, and $PLAN still has open
checkboxes outside the slices. If this session continues that work, pick it up from them; if the
session is about something else, ignore this.
$OUTSIDE$NOTE
Tick \`- [ ]\` to \`- [x]\` in $PLAN as they are done, $SAVE."
  exit 0
fi

emit "cc-tuner: this branch has $KIND with unfinished slices: $PLAN.
If this session continues that work, rebuild the task list from it first. Rebuild it from $PLAN
as below; if the session is about something else, ignore this.

If TaskCreate is not in your tool list, skip the rebuild and work from $PLAN itself: it is the store.

Read TaskList first and create only what is missing -- this may run in a session that already has
some of these. Then, in this order, because an edge cannot be added to a task that does not exist and
marking first leaves the wiring to a pass that may not happen:

  1. TaskCreate every slice below that is not already in the list
  2. TaskUpdate addBlockedBy for every \"Blocked by\" edge
  3. TaskUpdate status completed for the slices marked already done

$BODY
$OUTSIDE$NOTE
Tick \`- [ ]\` to \`- [x]\` in $PLAN as criteria are met, $SAVE. The file is the store; the task
list does not survive this session."
