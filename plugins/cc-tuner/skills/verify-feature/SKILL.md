---
name: verify-feature
description: Decide what would actually prove a change works, run it, and record what was observed. Invoked by /cc-tuner:run before a candidate is offered for review; usable on its own for "verify this actually works" on any change.
allowed-tools: Bash, Read, Glob, Grep, Skill, WebFetch
---

# Verify Feature

Prove the behaviour, not the build. A green suite says the checks that exist still pass; it says
nothing about the behaviour just written, because that behaviour had no check five minutes ago.

This skill answers one question — **what would show this working, and did it?** — and answers it from
the change in front of you rather than from a table of file extensions. An earlier design classified
changes by path (`*.tsx` is a screen, `migrations/` is a migration) and demanded a fixed proof per
class. Paths do not know what a change does: a `.tsx` file can be a pure formatter, a `.sql` file can
be a comment, and the interesting change is often in neither.

## 1. Read what has to be true

- the spec's **acceptance criteria** — each one names a behaviour and how it is decided;
- the **diff**, in full, and what calls the changed code;
- for work spanning repositories or a spec naming `second-repo`/`shared-task`, read
  [shared-task.md](../run/references/shared-task.md), especially Combined verification, before choosing
  checks; this also applies when invoked without `/run`;
- `[eyes]` criteria specifically: they were written as human-only, and part of this skill's job is to
  find the machine check that retires one. A criterion that says "the inversion reads as an inversion"
  may be provable by asserting the series order in the built chart option.

If the spec named exact commands, they are the floor, not the ceiling: they were chosen before the
code existed.

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

One proof per acceptance criterion, chosen for what that criterion claims. The shape of the change
suggests the instrument:

| what changed | what would show it working |
|---|---|
| a screen or an interaction | open it, interact, look — and say what you saw |
| an endpoint or a handler | a real request through the changed path; status and body |
| a schema change | apply it to a disposable copy, check data, constraints and grants; roll back **only if the contract says it rolls back** |
| a background job or queue consumer | enqueue a real item and observe the effect, not the log line |
| a pure function or a calculation | the exact inputs that used to be wrong, and the output now |
| a build or bundling guard | build, then read the artefact the guard measures |
| a CLI | run it with the arguments a user would, and read stdout and the exit code |

Where a criterion cannot be proved with what exists, say so and name what would be needed. That is a
result, not a failure to produce one.

## 4. Run it and record what was observed

Record, per criterion: the command or the interaction, and **what came back** — the status code, the
row count, the screenshot, the printed value. Not "works as expected".

Never record a criterion as proved on the strength of a typecheck, a lint pass, a suite that was
already green before the change, a diff that looks correct, or a re-reading of the code. Those are
worth running and prove something else.

## 5. Hand back

Return a short record `/run` can paste into the run log and the pull request:

```text
verify-feature @ <sha or "worktree">
  <criterion>  —  <what was run>  →  <what was observed>
  <criterion>  —  NOT PROVED: <what is missing, and what would be needed>
```

A criterion left unproved does not stop the run by itself. `/run` decides what an unproved criterion
means for delivery — this skill establishes facts and does not own the lifecycle.
