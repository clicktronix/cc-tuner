# Native-flow spike — the measured record

Ported from the disposable repository the spike ran in, so the evidence behind
`docs/adr/2026-08-13-native-first-lifecycle.md` does not live in a throwaway.


Question: how much of the cc-tuner lifecycle does Claude Code already provide, and what is genuinely
missing? No production code is written until this file reports. Findings are recorded here as they are
measured, so a later session can continue without repeating work — which is also the recovery design
under test.

**Method:** each item is either MEASURED (a command was run and the result observed) or ASSUMED (read
from a tool contract). An assumption is not evidence; the point of this spike is to convert the second
kind into the first.

---

## 1. Native tasks and dependencies — MEASURED 2026-08-12

`TaskCreate` / `TaskUpdate` / `TaskList` / `TaskGet`, exercised against two real tasks.

- Dependencies exist and render: `TaskUpdate addBlockedBy` produced
  `#23 [pending] … [blocked by #22]` in `TaskList`.
- **`blockedBy` is not enforced.** `TaskUpdate #23 status=in_progress` with an open blocker succeeded
  and `TaskList` then showed `[in_progress] … [blocked by #22]` — a state that should not exist. The
  platform stores and displays the graph; it does not police it.
- **`metadata` does not round-trip.** Fields set through `TaskCreate` (`delivers`, `owned_paths`,
  `acceptance`, `checks`) are surfaced by neither `TaskGet` nor `TaskList`. Writable, not readable — so
  it cannot hold the plan.

**Consequence:** the durable Markdown plan is not a fallback for durability, it is the only readable
store. Native tasks hold subject, status and edges; everything else lives in the plan file. This is why
`superpowers:writing-plans` is shaped the way it is, and why `subagent-driven-development` keeps a
ledger "not only in todos".

## 2. Task-list lifetime — RESOLVED 2026-08-13

Tasks #22 and #23 vanished from `TaskList` inside one session, and this was recorded as an unexplained
signal. The cause is now known, and it was self-inflicted: after reverting the code those tasks
described, they were deleted with `TaskUpdate status=deleted` — leaving a `completed` task whose change
no longer existed would have been a false record. The first delete succeeded, the second returned
"Task not found", and that was misread as "the list was already empty".

Confirmed on disk: `~/.claude/tasks/2a1cd5e1-…/` still exists and holds only `.highwatermark` (`24`,
the counter past ids 22 and 23) and `.lock`. The task files are gone because they were removed, not
lost.

The observation was correct; the interpretation was not. Worth keeping as an entry rather than
deleting: an unexplained signal recorded honestly stayed available to be explained later, which is the
point of separating what was seen from what it means.

## 2b. Where tasks are actually stored — MEASURED 2026-08-13

```
~/.claude/tasks/<session_id>/
    1.json  2.json  3.json …      one file per task
    .highwatermark                 the id counter
    .lock
```

```json
{ "id": "3", "subject": "Cache the user avatar lookups in Redis",
  "description": "…", "activeForm": "…",
  "status": "pending", "blocks": [], "blockedBy": ["2"] }
```

Plain JSON files in a directory keyed by session id, with the dependency graph persisted in them. Task
ids are per-session (`1`…`5`), not global.

This corrects a plausible-sounding explanation given during the spike — that tasks "live inside the
session state, in `<session>.jsonl`". They do not: the transcript and the task store are separate. The
practical consequence is the opposite of what that explanation implies — the store is an ordinary
directory any process can read, so recovery is mechanically trivial.

It also predicts §5 structurally: a new session means a new directory, so a fresh session starts with
no tasks. Recorded as a prediction, not a result — the difference between "the directory is new" and
"the platform does not carry them over" is exactly the kind of gap this spike keeps finding.

**Not a licence to depend on it.** Reading another session's task directory would be reaching into the
platform's internals — the same class of coupling this whole effort is unwinding. It is evidence about
the mechanism, not an interface.

## 3. Interactive Plan Mode — MEASURED 2026-08-13

**The mode is visible to hooks.** `permission_mode` in the `UserPromptSubmit` payload changed between
two prompts in the same session:

```
"/cc-tuner:spec"       → permission_mode = "bypassPermissions"
"давай составим план"  → permission_mode = "plan"
```

So planning is observable at the boundary, per prompt, with no flag of our own. Combined with §7 this
covers what cc-tuner tracked in `.mode` and in the `--auto` argument: the platform already reports both
whether a command was invoked and what mode the turn is running in.

**Instrumentation gap found and fixed.** The probe's `PreToolUse` matcher was `Bash|Edit|Write`, which
matches neither `ExitPlanMode` nor `Read`/`Glob`/`Grep` — so nothing was captured after the mode
changed. The matcher is now `*`, and `PostToolUse` and `Stop` are wired too. Worth recording as a
finding about method, not just about tooling: a probe that watches three tool names answers questions
only about those three, and its silence looks identical to nothing having happened.

**User decisions are visible to hooks.** A second round captured `AskUserQuestion` at both `PreToolUse`
and `PostToolUse`, and the `PostToolUse` payload carries `tool_input.answers` — the options the user
actually chose:

```
"What should the plan cover?"                    → "§7 — arming the gate"
"…no git remote, so no PR and no CI are possible.
  The cc-tuner spec template requires both…"     → "Local-only, auto_ready: no"
```

That is another class of thing cc-tuner tracked itself: HITL boundaries and "the user confirmed" are
observable at the boundary.

**The run reproduced the `tracker: none` contradiction on its own.** The second question exists because
`/cc-tuner:spec` hit a repo with no remote while its template requires a PR and CI. The ADR reached the
same conclusion by reasoning; a live run reached it by walking into it.

### `ExitPlanMode` — MEASURED 2026-08-13

It fires `PreToolUse`, and the payload carries the whole plan:

```json
{ "hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode",
  "permission_mode": "plan", "effort": {"level":"high"},
  "prompt_id": "8e5b494f-…",
  "tool_input": { "plan": "<the entire plan text>",
                  "planFilePath": "/Users/clicktronix/.claude/plans/shimmying-sprouting-puzzle.md" } }
```

Three things follow:

1. **Plan approval is observable, and the plan itself is readable at that moment.** A hook can inspect
   what is about to be approved. Nothing in cc-tuner needed to publish a plan for this to be true.
2. **The plan file lives at `~/.claude/plans/<generated-name>.md`** — outside the repository,
   machine-local, under a name nobody chose. It is not a project artifact and it is not committed. This
   is direct confirmation, not inference, that a committed plan artifact is still required: plan mode's
   file cannot serve as the durable store or survive a clone.
3. **`prompt_id` correlates a whole turn.** Every `PreToolUse` and `PostToolUse` in the turn carries the
   same `prompt_id` as the `UserPromptSubmit` that started it (verified across 14 consecutive events).
   That is the missing link for arming: a hook can tie any tool call back to the invocation that caused
   it, without inventing run ids.

The payload also carries `effort: {"level": "high"}` — a fourth thing cc-tuner tracked by hand.

### A correction, and what it cost

An earlier revision of this section recorded "`ExitPlanMode` was never invoked" and "the probe is
demonstrably incomplete", from a transcript read taken **while the session was still running**. The
file grew from 27 to 34 lines afterwards, and `ExitPlanMode`, `Write` and `ToolSearch` all appeared.
Both statements were wrong.

The failure is the same one this spike exists to correct, one level up: a snapshot of an in-flight
process was treated as a finished result. Reading the transcript was the right instinct — checking the
probe against an independent source is exactly the control that was missing — but a control taken
mid-flight is not a control. **Before recording a negative result, establish that the producing process
has finished.**

### Matcher semantics — MEASURED 2026-08-13, and the earlier hypothesis refuted

Three `PreToolUse` hooks were registered in parallel — `matcher: "*"`, an explicit tool-name list, and
one with no `matcher` field — each writing a distinct label, so the answer comes from comparison rather
than from assumption. Counted over one `prompt_id` in which all three were active:

| label | Bash | Read | Write | ToolSearch |
|---|---|---|---|---|
| `Pre:star` (`"*"`) | 20 | 1 | 3 | 1 |
| `Pre:list` (explicit names) | 20 | 1 | 2 | 1 |
| `Pre:nomatcher` (field absent) | 20 | 1 | 2 | 1 |

**All three are equivalent, and `Read` does fire `PreToolUse`.** The earlier entry claiming `Read` was
exempt and `"*"` was not a wildcard was wrong: `Read` simply was not called during the window that
entry examined. Absence of a tool from a log is not evidence about hooks unless the tool is known to
have run — which is what a control case is for, and why this one was built as a comparison.

That is the third time in this spike a probe's silence was read as a property of the system. The
comparison design is what caught it; a single instrumented matcher would have produced the same wrong
answer again, more confidently.

### The probe was corrupting its own record

Two lines were unparseable (`Expecting ',' delimiter`, `Expecting value`) — the three parallel hooks
fire simultaneously for one tool call and their `>>` appends tore each other apart. It also explains
the 2-vs-3 discrepancies in the table above.

A probe that corrupts its own output is worse than one that misses events: the damage arrives as
malformed data rather than as absence, so it is read as a fact about the subject. Fixed by writing
**one file per event** into `.claude/probe/events/` — separate files cannot interleave.

### Still open about hooks

`Stop` has never fired, across every turn of the whole session, while configured in project
`settings.json`. Hypothesis to test, not to assume: cc-tuner registers `Stop` in a **plugin**
`hooks.json` and it demonstrably works there, so the difference may be the registration site rather
than the event. `SubagentStop` is wired for the same reason.

Still to establish about plan mode itself:
- Does approval transition straight to implementation?
- Does plan mode create any tasks? (assumed: no)
- **Is it available inside an agent/subagent context?** (claimed unavailable; unverified)

## 4. Compaction and resume — MEASURED 2026-08-13

A first attempt measured nothing: `/compact` was run in a session that had **never called
`TaskCreate`** (39 Bash, 7 Read, 6 Write, 3 AskUserQuestion, 2 ToolSearch, 1 Skill, 1 ExitPlanMode —
no task tool at all). An empty list afterwards said nothing about compaction, because there was nothing
to lose. Fourth instance in this spike of an absence being read as a result.

**Baseline now on record**, captured by the probe before any further compaction — five tasks, all
`pending`, no `blockedBy` edges, one `TaskList` call, and **no `TaskUpdate`**:

```
Fix flaky timeout in the checkout retry test
Add pagination to the /api/orders endpoint
Cache the user avatar lookups in Redis
Document the local development setup in README
Upgrade the CI runner to Node 22
```

Also measured on the way: **`TaskCreate` and `TaskList` fire `PreToolUse` and `PostToolUse`**, caught
identically by all three matchers. Task creation is observable at the hook — a fifth thing cc-tuner
tracked itself.

### Baseline completed 2026-08-13

Three `TaskUpdate` calls captured, giving a baseline that can distinguish all three survival questions:

```
taskId 1 → status: completed
taskId 2 → status: in_progress
taskId 3 → addBlockedBy: ["2"]
```

| task | state before compaction |
|---|---|
| #1 | `completed` |
| #2 | `in_progress` |
| #3 | `pending`, blocked by #2 |
| #4, #5 | `pending` |

The edge is a live one: #3 is blocked by a task that is in progress rather than finished, so a
surviving edge is distinguishable from an edge that merely resolved.

### Result — MEASURED 2026-08-13: nothing is lost

`TaskList` responses captured on both sides of `/compact` followed by a session `resume`. `PostToolUse`
carries `tool_response`, so these are the platform's own answers, not a reading of the screen:

| | before | after `/compact` + `resume` |
|---|---|---|
| rows | 5 | 5 |
| `#1` | `completed` | `completed` |
| `#2` | `in_progress` | `in_progress` |
| `#3` | `pending`, `blockedBy: ["2"]` | `pending`, `blockedBy: ["2"]` |
| `#4`, `#5` | `pending` | `pending` |

**Rows, statuses and the blocking edge all survive compaction and resume, unchanged.**

This refutes the assumption the rejected implementation was built on. `blocked_by` in run state,
`bind-ui`, the `TaskList`↔state reconciliation pass and the
`visible-plan-is-a-recoverable-projection` invariant all existed because the native graph was presumed
fragile enough to need a second copy kept in sync. It is not.

### What "I don't see the tasks" meant, again

The widget is a rendering in the transcript, not the state. After `/exit` there is nothing to draw,
while `TaskList` in the same session still returned the full graph. Fifth time in this spike that "not
visible" meant "not displayed" or "not requested" rather than "not there" — the same shape as the
complaint that started the whole effort, where the plan was missing because `TaskCreate` was never
called, not because a plan engine was.

### Also measured on the way

- **`Stop` fires.** Its earlier silence was an artifact of the previous probe, not a property of the
  event. The registration-site hypothesis recorded in §3 was wrong; it is withdrawn.
- **`SessionStart` distinguishes its cause:** `source: "compact"` and `source: "resume"` arrive as
  separate events. A recovery step can run exactly when it is needed instead of on every start.
- **`PostToolUse` carries the tool's response, not only its input** — `{"success": true, "taskId": "3",
  "updatedFields": ["blockedBy"]}`, and for status changes a `statusChange` with both old and new
  value. Hooks observe outcomes, not just intentions.

## 5. A new independent session — MEASURED 2026-08-13

A session started from scratch in the same repository — `session_id` `84640122-…`, not a `--resume` of
`09dda281-…`:

```json
TaskList → { "tasks": [] }
```

**Nothing carries over.** On disk, `~/.claude/tasks/84640122-…/` does not exist at all, while
`~/.claude/tasks/09dda281-…/` still holds all five task files with their statuses and the
`blockedBy: ["2"]` edge intact. The tasks were not lost; they belong to a session this one is not.

The structural prediction in §2b held, and it was worth confirming rather than assuming: "the
directory is keyed by session" and "the platform does not carry tasks over" are different claims, and
only the second one is what a design can rest on.

**This is the load-bearing result of the spike.** A committed plan artifact is not a precaution against
an unlikely loss — it is the only thing that survives the boundary that gets crossed most often.
Recovery is therefore part of the normal flow, not an error path: on a fresh session, read the plan and
re-create the tasks that are not yet ticked. `SessionStart` arrives with `source: "startup"`, distinct
from `compact` and `resume`, so that step can run exactly when it applies.

## 6. Checkbox progress in the plan file — NOT STARTED

To establish: is ticking `- [ ]` on task completion enough to reconstruct state, when combined with git
history? What does it fail to capture?

## 7. Bootstrap of the first run — MEASURED 2026-08-13

### The fail-open, reproduced — MEASURED

Against this repo, with no `.claude/execute-task-runs/` state, using the shipped
`cc-tuner/plugins/cc-tuner/hooks/run-state-hook.sh`:

```
Edit src/slug.py          → rc=0   (allowed)
gh pr merge 1 --squash    → rc=0   (allowed)
```

Two commands reproduce the entire Marqa/Stokli failure. And it qualifies §8: **the merge guard is
inert too.** The guard called "the one proven piece" is proven only *given state*; with none it allows
the merge like everything else. Any design that keeps one fail-closed gate must therefore answer what
arms it, not only what it checks — otherwise the same defect survives the simplification intact.

### What a slash invocation looks like to a hook — MEASURED 2026-08-13

`/cc-tuner:spec` typed in a session in this repo. Captured events, in order:

```
1  SessionStart      source=startup
2  UserPromptSubmit  prompt="/cc-tuner:spec"
3-9 PreToolUse       Bash ×7
```

`UserPromptSubmit` payload keys: `session_id`, `transcript_path`, `cwd`, `prompt_id`,
`permission_mode`, `hook_event_name`, `prompt`.

**The raw slash command is visible.** `prompt` carries `/cc-tuner:spec` literally — the invocation, not
the expanded command body. It arrives **before every tool call**, so a bootstrap that must happen ahead
of the first mutation is implementable: `UserPromptSubmit` recognises the invocation and arms the run;
`PreToolUse` then has something to check.

This was the assumption the whole enforcement story rested on and that nobody had verified. It holds.

Two further facts the payload gives for free:

- `permission_mode` is present (`bypassPermissions` in this session). Whether a run is attended is
  therefore observable at the hook, without cc-tuner tracking an `--auto` flag of its own.
- `cwd` and `session_id` are present, so the bootstrap needs no discovery of its own.

**Still unmeasured:** whether `UserPromptSubmit` can *block*, and what it can pass forward to the turn.
Arming is a side effect, so a hook that only writes a sentinel and exits 0 is enough for the
bootstrap — but if the design ever wants the prompt refused outright, that is a separate measurement.

## 8. Exact-SHA review and the merge guard — MEASURED 2026-08-13

**A PR review is a working attestation vehicle, and the SHA is GitHub's, not ours.**

Read from a public repo (`cli/cli`), no side effects: each review carries `user`, `state`
(`APPROVED` / `COMMENTED` / `CHANGES_REQUESTED`), `submitted_at`, and **`commit_id`** — the head SHA
at the moment the review was submitted.

Write half, probed on this project's own closed PR #19:

```
gh pr review 19 --comment --body "…"
→ {"user":"clicktronix","state":"COMMENTED","commit_id":"81a49baf57c8…"}
gh pr view 19 --json headRefOid  → 81a49baf57c8…
```

- Posting works, including on a **closed** PR.
- `commit_id` exactly equals `headRefOid`, and it is stamped by GitHub. A local file recording "we
  reviewed SHA X" can be written at any time; a review at SHA X can only exist if it was submitted
  while X was head. That is the property the local record never had.
- **`state` is `COMMENTED`, not `APPROVED`** — GitHub refuses self-approval, and all three of our
  reviewers act as the PR author. So the verdict must travel in the body, which the author can edit.
  The SHA binding is external and strong; the verdict is prose and weak. Better than a local file, not
  a proof.

**Merge interception already works and is already tested.** `run-state-hook.sh` matches
`gh pr merge` in a `PreToolUse` Bash payload and exits 2; `test_run_state_hook.sh:181` feeds
`{"tool_name":"Bash","tool_input":{"command":"gh pr merge 123 --squash"}}` and asserts the block. The
guard we intend to keep is the one piece of the current machinery that is proven.

**Open:** `gh pr merge` is not the only way to merge. The button on github.com, `git push` to the
target branch, and the API all bypass a local hook entirely. The guard is a guardrail against an
agent's mistake — as the ADR says — and must not be described as anything stronger.

---

## Conclusions

Seven of eight items measured. §6 (checkbox progress) is untested and is the only thing below resting
on judgement rather than observation.

### What the platform provides, measured

Every one of these arrives in a hook payload, with no bookkeeping of our own:

| fact | where it comes from |
|---|---|
| a slash command was invoked, raw and unexpanded | `UserPromptSubmit.prompt`, before any tool call |
| which mode the turn runs in | `permission_mode` (`plan`, `bypassPermissions`, …) |
| reasoning effort | `effort.level` |
| the whole turn, correlated | `prompt_id`, identical across the turn's `Pre`/`PostToolUse` |
| a plan was submitted for approval, and its full text | `PreToolUse` on `ExitPlanMode`, `tool_input.plan` |
| what the user chose | `PostToolUse` on `AskUserQuestion`, `tool_input.answers` |
| a task was created, updated, listed | `Pre`/`PostToolUse` on `Task*` |
| the *outcome* of a call, not only its input | `PostToolUse.tool_response` — `success`, `statusChange` with old and new value |
| why this session started | `SessionStart.source`: `startup` / `compact` / `resume` |

The task graph — rows, statuses and `blockedBy` edges — survives compaction and resume unchanged.

### The two limits, also measured

1. **`blockedBy` is data, not a gate.** `TaskUpdate` moves a blocked task to `in_progress` without
   complaint. The platform stores and draws the graph; it does not enforce it.
2. **Nothing crosses a session boundary.** Tasks are keyed by `session_id`; a fresh session starts
   empty. Compaction and resume are safe; a new session is not.

### What follows for cc-tuner

Of the machinery built in the rejected PR, exactly one piece answers a real gap: **refusing to start a
task whose blockers are open**, and only where nobody is watching. Everything else — `blocked_by` in
run state, `plan import`, `plan frontier`, `bind-ui`, the state↔`TaskList` reconciliation pass, schema
v2 — duplicated a graph that the platform already keeps more reliably than the copy did.

The committed Markdown plan is not a durability fallback. It is the single readable store, for two
independent reasons: `metadata` written through `TaskCreate` cannot be read back, and nothing survives
a new session. Native tasks hold subject, status and edges; the plan holds owned paths, acceptance,
checks and progress. That is the shape `superpowers:writing-plans` already has, and now the constraint
that produces it is measured rather than inherited.

Plan mode is an approval surface, not an architecture: it creates no tasks, its file lives at
`~/.claude/plans/<generated-name>.md` outside the repository, and it is interactive by construction.

The merge guard remains the one fail-closed gate — but §7 measured that it is **inert without state**,
exactly like every other gate. A design that keeps one gate must say what arms it, or it keeps the
defect that started this and deletes only the code around it.

### The method finding

Four separate times, a probe's silence was read as a property of the system: a matcher narrower than
assumed, a wildcard presumed broken, a transcript read mid-flight, an absent task list that had never
been populated. Each looked exactly like a result. What caught them was never more instrumentation —
it was a control: a second matcher to compare against, an independent source, waiting for the producer
to finish, checking whether the subject had ever occurred.

The same shape as the defect this work started from: 82 assertions that were `grep` over markdown, all
green, while the flow could not start. **An instrument that cannot fail visibly does not measure
anything**, and that applies to a test suite as much as to a hook probe.
