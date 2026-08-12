---
description: Turn a committed spec into cc-tuner's canonical task graph — vertical slices with owned paths, acceptance, checks and blocking edges — import it into run state and publish the visible plan. Stops before implementation.
argument-hint: '<path to the committed spec>'
allowed-tools: Bash, Read, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList
disable-model-invocation: false
---

# /cc-tuner:plan

Author the task graph `/cc-tuner:run` executes. This command owns decomposition; `/spec` owns what to
build and `/run` owns delivery. It plans what `/spec` already decided and reopens no product question.

## 1. Verify the profile and read the spec

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh" --profile plan
```

Read the spec named by `$ARGUMENTS`. Refuse to plan when it is uncommitted, when its `Run config` is
incomplete, or when its Definition of Ready still carries a `TBD` — those are `/spec`'s to finish.
Resolve `RUN_ID` from the spec's run: the journal and state live at
`.claude/execute-task-runs/<run-id>.*`. The run must exist and be in `planning`.

## 2. Place the seams

Invoke `mattpocock-skills:codebase-design` to name the modules the change belongs to and where the
boundaries fall. This is the one method this command uses: the slicing below is only as good as the
module ownership it cuts along.

## 3. Slice

Each entry is one **vertical slice**, not a layer:

- it cuts a complete path through every layer it touches — schema, API, UI, tests — and is verifiable
  on its own;
- `delivers` states the end-to-end behaviour the slice makes work, from the user's perspective;
- it is sized to fit one fresh context window;
- setup, configuration and documentation fold into the slice that needs them; split only where a
  reviewer could reject one slice while approving its neighbour;
- `owned_paths` are disjoint between slices meant to run concurrently — `plan frontier --parallel`
  drops a slice whose paths overlap one already in the batch, so overlapping ownership silently costs
  parallelism;
- `blocked_by` names the slices that must complete first. `runctl` rejects cycles, self-references,
  duplicates and unknown ids, so these edges are enforced rather than requested.

A **wide refactor** is the exception: one mechanical change whose blast radius fans across the
codebase, so no vertical slice can land green. Sequence it **expand → migrate → contract** — add the
new form beside the old, migrate call sites in batches each blocked by the expand, then delete the old
form in a slice blocked by every batch.

Then add the lifecycle slices — one each for `testing`, `acceptance`, `candidate`, `review`,
`delivery` — with edges putting them after the implementation slices. `plan import` refuses a graph
missing any of them.

## 4. Import the graph

Ask `runctl` for the file to write; it is the one location the mutation fence permits.

```bash
PLAN_FILE="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" prepare "$RUN_ID" plan)"
```

Write a JSON array to that path. Every object carries exactly these keys:

```json
[
  {
    "id": "auth-boundary",
    "title": "Auth boundary",
    "phase": "implementation",
    "delivers": "An unauthenticated call is rejected at the boundary",
    "owned_paths": ["src/auth/"],
    "acceptance": ["an unauthenticated call is rejected"],
    "checks": ["make test-auth"],
    "blocked_by": []
  }
]
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" plan "$RUN_ID" import "$PLAN_FILE"
```

The import validates the whole graph before writing anything, and reports every problem it found with
the id it belongs to. Fix them all and re-run; a rejected import leaves the previous graph untouched.
Re-importing an unchanged graph prints `PLAN UNCHANGED` and is a no-op, which is what makes a resume
safe.

## 5. Publish the visible plan

Create one visible task per graph task with `TaskCreate`, mirror `blocked_by` with `TaskUpdate`'s
`blockedBy`, then bind each returned id:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" task "$RUN_ID" bind-ui "$TASK_ID" "$CLAUDE_TASK_ID"
```

Structured state is the source of truth and the visible list projects it. A binding is required before
a task may start, so a visible task that goes missing is re-created and re-bound — the run continues
either way. Record the publication:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" plan "$RUN_ID" publish
```

That is idempotent and keeps the first publication of the current graph; importing a different graph
clears it, so what it dates is always the plan the run holds.

## 6. Stop

Print the frontier and the next command:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" plan "$RUN_ID" frontier
```

```text
/cc-tuner:run <spec path>
```

This command publishes the graph and **stops here regardless of who invoked it**. Implementation is
`/cc-tuner:run`'s phase. This is the only model-invocable cc-tuner command, so the stop is a property
of the command and not a rule about direct invocation: a model that can start planning on its own must
not be able to continue into writing code.

## Verification

- [ ] The spec was committed and complete before planning started
- [ ] Every implementation slice is vertical, owns explicit paths, and states what it delivers
- [ ] `owned_paths` are disjoint across slices intended to run concurrently
- [ ] A wide refactor is sequenced expand → migrate → contract, not forced into one slice
- [ ] Every lifecycle phase has a task and the edges order them after implementation
- [ ] `plan import` accepted the graph and `plan publish` recorded it
- [ ] Every graph task is bound to a visible task
- [ ] No file outside the prepared plan path was written
