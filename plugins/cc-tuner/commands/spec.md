---
description: Turn a rough task into a committed spec /cc-tuner:run can execute — grilled requirements, machine-checkable acceptance criteria, task-branch ownership, and explicit auto-readiness. Use for "напиши спеку", "spec this out", or before any --auto run.
argument-hint: '<issue number | URL | free-text description>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, TodoWrite, AskUserQuestion, WebFetch, WebSearch, mcp__context7
disable-model-invocation: true
---

# /cc-tuner:spec

Produce a committed spec that `/cc-tuner:run` can execute without re-opening product decisions. This
command owns the questions; `/run` owns delivery.

## 1. Anchor and read

```bash
git rev-parse --show-toplevel || { echo "not a git repo"; exit 1; }
```

Read, in order:

- `.claude/rules/task-flow.local.md` for repo-specific board and branch deltas;
- the issue, when `$ARGUMENTS` names one;
- `CLAUDE.md`, `AGENTS.md`, and relevant `.claude/rules/`;
- the code, tests, and consumers the task will touch.

Do not ask for information already present in those sources.

## 2. Grill

Invoke `mattpocock-skills:grilling`, using `mattpocock-skills:domain-modeling` for vocabulary. Pull
current dependency documentation through Context7 as questions arise. Ask one question at a time until
the answers stop changing the draft. A pending `TBD`, "as appropriate", or an unstated first failing
test means the spec is not ready.

## 3. Define acceptance and scope

Tag every criterion:

- `[machine]` — an exact command or browser-driving step decides it;
- `[eyes]` — human judgement is irreducible.

Every `[eyes]` criterion needs either a machine replacement or a dated user waiver. A bare `[eyes]`
criterion makes the spec not auto-ready; never leave that discovery to `/run`.

More than one PR, more than one repo, or independently reviewed phases require an epic with sub-issues
and one spec per sub-issue. Otherwise use one issue and one task branch.

## 4. Create the task branch

Resolve the integration target from repo policy, falling back to the remote default branch. Fetch it
and verify the starting point. If currently on the target branch, create the task branch now using the
task-flow naming rule. If already on a feature branch, confirm it belongs to this task and its PR is not
already merged. Never commit the spec directly to the integration branch.

The task branch created here is the branch `/run` continues; `/run` must not create a second branch for
the same spec.

## 5. Write and commit the spec

Write `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md`, using `wiki/` when present and `docs/` otherwise:

```markdown
# <title>

**Goal:** <what becomes true>
**Issue:** #N | none
**Architecture:** <approach and rejected alternatives>

## Acceptance criteria
- [ ] [machine] <criterion> — checked by: <exact command or MCP step>
- [ ] [eyes] <criterion> — machine replacement: <check> | WAIVED by <user> on <date>

## Tasks
1. <file path> — <change and reason>

## Out of scope
<explicit boundaries>

## Run config
branch: <current task branch>
target: <integration branch>
merge: squash|merge
auto_ready: yes|no — <reason when no>
ci: <exact command or check source>
cheap_gate: <exact command>
test: <exact command>
tracker: gh|glab|none
board: <project title + owner | none>
```

`auto_ready: yes` is valid only when there is one PR, `ci` is nonblank, and no `[eyes]` criterion lacks
a replacement or waiver. It records capability, not execution mode; only `/run --auto` requests an
unattended run.

Inspect the diff, stage the spec path explicitly, and commit it on the task branch with a Conventional
Commit. Create or update the issue so it and the spec link to each other. Journal-free spec work ends
here; the run journal starts in `/run`.

## 6. Hand off

Print the spec path and one appropriate next command:

```text
/cc-tuner:run docs/PLANS/2026-07-31-thing.md
/cc-tuner:run --auto docs/PLANS/2026-07-31-thing.md
```

Offer the `--auto` form only when `auto_ready: yes`. State the current branch and target alongside the
command so a later session can verify both before editing.

## Verification

- [ ] Repo, issue, instructions, code, and current docs read before questioning
- [ ] Every criterion names its deciding command or MCP step
- [ ] No bare `[eyes]`, `TBD`, or executor-owned product decision
- [ ] One spec maps to one task branch and one PR
- [ ] `auto_ready` and its reason are explicit
- [ ] Spec committed on the task branch, never directly on the integration branch
- [ ] Issue and spec link to each other
