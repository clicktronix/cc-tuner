---
name: verify-feature
description: Decide what would actually prove a change works, run it, and record what was observed. Invoked by /cc-tuner:run before a candidate is offered for review; usable on its own for "verify this actually works" on any change.
allowed-tools: Bash, Read, Glob, Grep, Skill, WebFetch
---

# Verify Feature

Prove the agreed outcome with evidence that directly tests each acceptance criterion. Select checks
from the behaviour and repository capabilities, not file extensions. Existing tests can prove a
criterion when they exercise it; a green suite alone does not establish unrelated behaviour.

## 1. Read what has to be true

- the spec's **acceptance criteria** — each one names a behaviour and how it is decided;
- the **diff**, in full, and what calls the changed code;
- for work spanning repositories or a spec naming `second-repo`/`shared-task`, read
  [shared-task.md](../run/references/shared-task.md), especially Combined verification, before choosing
  checks; this also applies when invoked without `/run`;
- `[eyes]` criteria specifically: they were written as human-only, and part of this skill's job is to
  find the machine check that retires one. A criterion that says "the inversion reads as an inversion"
  may be provable by asserting the series order in the built chart option.

Use the spec's checks and add only what closes an identified acceptance gap. Do not create a new
requirement merely because another tool or test is available.

## 2. Find what this repository already has

Look before inventing. In order:

- test commands and their runners in `package.json`, `Makefile`, `pyproject.toml`, `justfile`;
- fixtures, factories and seed data already used by neighbouring tests;
- testing runbooks — `TESTING.md`, `SMOKE.md`, `CONTRIBUTING.md`, anything under `wiki/` or `docs/`
  describing how this project is exercised by hand;
- what is actually available right now: a running dev server, a database, `chrome-devtools` MCP,
  Playwright, `curl`, a CLI entry point, a REPL.

Name what you found and what you did not. "No browser tooling is available here" is a finding that
changes the plan; pretending otherwise produces a verification nobody ran.

## 3. Choose the proof, per behaviour

Map every criterion to direct evidence; one run may prove several criteria. Inspect earlier results
before running anything: reuse them when the checked code, dependencies, configuration and
environment still match. Record the source run/commit and why it covers this candidate. Re-run
affected checks after relevant changes, missing evidence or uncertainty; honour required fresh runs.
Do not repeat a worker's or `/run`'s check just because this stage has a different name.

Choose the instrument for the claim:

| what changed | what would show it working |
|---|---|
| a screen or an interaction | open it, interact, look — and say what you saw |
| an endpoint or a handler | a real request through the changed path; status and body |
| a schema change | apply it to a disposable copy, check data, constraints and grants; roll back **only if the contract says it rolls back** |
| a background job or queue consumer | enqueue a real item and observe the effect, not the log line |
| a pure function or a calculation | the exact inputs that used to be wrong, and the output now |
| a build or bundling guard | build, then read the artefact the guard measures |
| a CLI | run it with the arguments a user would, and read stdout and the exit code |
| documentation, formatting or a mechanical edit | the agreed baseline/diff, links, lint or generated artifact check that directly decides the criterion |

Where a criterion cannot be proved with what exists, say so and name what would be needed. That is a
result, not a failure to produce one.

## 4. Run it and record what was observed

Record, per criterion: the command or the interaction, and **what came back** — the status code, the
row count, the screenshot, the printed value. Not "works as expected".

Match evidence to the claim: typecheck/lint can prove a typing/formatting criterion, and an approved
non-code baseline/diff check can prove a documentation edit. They do not prove runtime behaviour.
For behavioural changes use observations through the affected path, including an existing test
that directly exercises it. A plausible diff or an unrelated green suite is not that observation.

## 5. Hand back

Return a short record `/run` can paste into the run log and the pull request:

```text
verify-feature @ <sha or "worktree">
  <criterion>  —  <what was run>  →  <what was observed>
  <criterion>  —  NOT PROVED: <what is missing, and what would be needed>
```

A criterion left unproved does not stop the run by itself. `/run` decides what an unproved criterion
means for delivery — this skill establishes facts and does not own the lifecycle.
