---
name: plan
description: Turn a committed spec into a committed plan and a visible task list — vertical slices with explicit blocking edges, validated by plan-lint, published as native tasks.
argument-hint: '[--auto] <path-to-spec>'
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion
---

# /cc-tuner:plan

Produce the plan for the spec named in `$ARGUMENTS`. `--auto` anywhere selects unattended mode; the
remaining argument is the spec path.

## Stop before starting

- **No path, or no such file** — stop and say so.
- **The spec is not committed** — stop. The plan cites it, and a citation of an uncommitted file
  points at nothing a later session can read.
- **A plan already exists for this branch** — `plan-path.sh create` will refuse and name it. Edit that
  plan or remove it; do not write a second.

**Never reconstruct a missing spec from the conversation.** The spec is the input; inventing one makes
the plan an account of what you assumed.

## Slice the work

Each slice is a **tracer bullet**: a narrow but complete path through every layer the change touches,
demoable on its own, sized to fit one fresh context window. Not a layer — "add the schema" is not a
slice, "a request that exhausts its budget fails with one typed error" is.

Give each slice the other slices that must finish before it can start. A slice with none can start
immediately.

**Wide mechanical refactors are the exception.** When one change — a renamed column, a retyped shared
symbol — breaks call sites faster than any single slice can land green, sequence it **expand →
migrate → contract**: add the new form beside the old, migrate call sites in batches each blocked by
the expand, then delete the old form in a slice blocked by every batch. CI stays green batch to batch
because the old form still exists.

## Agree the breakdown, then write it

Attended, present the slices as a numbered list — title, what it delivers, what blocks it — and ask
whether the granularity and the edges are right. Iterate until the user approves. Only then write.

Under `--auto`, write directly.

The approval is a conversation, not a document. Plan mode would produce a second plan file under
`~/.claude/plans/`, and this flow already has exactly one plan, committed, in the repository.

## Write, validate, commit

Ask for the path — it prints one line, and refuses if a plan for this branch already exists, tracked
or not:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" create
```

**Read that path out of the output and use it literally from here on.** A shell variable does not
survive to the next tool call, so `PLAN=$(...)` in one command and `"$PLAN"` in the next is an empty
string — an earlier revision of this skill was written that way and would have linted nothing.

Fill `${CLAUDE_SKILL_DIR}/plan-template.md` into that file, then validate it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check docs/task-plans/<the file you just wrote>.md
```

Fix what it reports and run it again until it is quiet. It refuses a slice with no `Blocked by`, a
blocker that names no slice, a checkbox outside any slice, and a slice with no acceptance criteria.

Commit the plan file. It is the store: an uncommitted plan survives nothing, and the restore hook
reads only tracked files.

## Publish the visible plan

Two passes, because `TaskCreate` takes no dependency argument:

1. `TaskCreate` for every slice, in slice order. Subject is the slice title; description is what it
   delivers plus its acceptance criteria.
2. `TaskUpdate` with `addBlockedBy` for every edge.

Then `TaskList` and check the edges are the ones in the file. The edges are the half a one-pass
implementation drops silently, and a task list without them looks finished when it is not.

## Hand off

Print the plan path and the next command, carrying the same spec path and the same mode:

```text
/cc-tuner:run <the spec path you were given>
/cc-tuner:run --auto <the spec path you were given>
```

## What this skill does not do

It does not start the work. `/cc-tuner:run` reads the plan for this branch and works it.
