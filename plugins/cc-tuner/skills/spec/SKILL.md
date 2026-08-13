---
description: Turn a rough task into a committed spec /cc-tuner:run can execute — grilled requirements, explicit DoR and DoD, executable test plan, task-branch ownership, and machine-checkable acceptance. Use for "напиши спеку", "spec this out", or before any --auto run.
argument-hint: '<issue number | URL | free-text description>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, AskUserQuestion, WebFetch, WebSearch, mcp__context7
disable-model-invocation: true
---

# /cc-tuner:spec

Produce a committed spec that `/cc-tuner:run` can execute without reopening product or verification
decisions. This command owns discovery and readiness; `/run` owns delivery.

## 1. Anchor and read

```bash
git rev-parse --show-toplevel || { echo "not a git repo"; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh"
```

Read, in order:

- `.claude/rules/task-flow.local.md` for repository board and branch deltas;
- the issue, when `$ARGUMENTS` names one;
- `CLAUDE.md`, `AGENTS.md`, and applicable `.claude/rules/`;
- architecture records, the code, tests, and consumers the task can affect.

Do not ask for information already present in those sources.

## 2. Create the task branch

Resolve the integration target from repository policy, falling back to the remote default branch.
Fetch it and verify the starting point. If currently on the target branch, create the task branch now
using the task-flow naming rule. If already on a feature branch, confirm it belongs to this task and
its PR is not already merged. Never commit the spec directly to the integration branch.

The task branch created here is the branch `/run` continues; `/run` must not create a second branch for
the same spec.

**Before grilling, not after.** Section 3 invokes `domain-modeling`, which writes `CONTEXT.md` and
ADRs into the repository. Those are committed artifacts, so they must land on the task branch; an
earlier revision created the branch after them and wrote them wherever the session happened to be.
If grilling later shows the task should split, splitting a branch is recoverable — an ADR committed
to the integration branch is not.

## 3. Grill the problem

Invoke `mattpocock-skills:grilling`, using `mattpocock-skills:domain-modeling` for vocabulary. Pull
current dependency documentation through Context7 as questions arise. Ask one question at a time
until the answer no longer changes the draft.

Resolve before calling the task ready:

- the observed problem or desired user outcome;
- architecture ownership, boundaries, and affected consumers;
- explicit scope and rejected alternatives;
- acceptance evidence;
- the first failing regression check or an honest non-code baseline;
- targeted and full verification commands, environment, fixtures, and external dependencies.

A pending `TBD`, “as appropriate”, unknown test command, or unstated expected failure means the spec
is not ready.

## 4. Define acceptance and delivery shape

Tag every criterion:

- `[machine]` — an exact command or browser-driving step decides it;
- `[eyes]` — human judgement is irreducible; name the concrete human verification step.

Every `[eyes]` criterion records its human step, machine replacement (or `none`), and dated waiver (or
`none`). An item with neither replacement nor waiver is valid only with `auto_ready: no`: HITL `/run`
stops for the human step, while `--auto` rejects the spec in Phase 0.

More than one PR, more than one repo, or independently reviewed phases require an epic with native
sub-issues and one spec per sub-issue. Otherwise use one issue and one task branch.

## 5. Write the executable contract

Write `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md`, using `wiki/` when present and `docs/` otherwise:

```markdown
# <title>

**Goal:** <what becomes true>
**Issue:** #N | none
**Architecture:** <ownership, data/control flow, and rejected alternatives>

## Definition of Ready
- [x] Problem/baseline: <current failure or missing behavior with evidence>
- [x] Scope: <owned modules and consumers>; out of scope: <boundaries>
- [x] Acceptance: every criterion below has a deciding check
- [x] Test plan: commands, expected first failure, environment, and data are explicit
- [x] Delivery: one branch, one PR, target, tracker, and CI source are explicit

## Acceptance criteria
- [ ] [machine] <criterion> — checked by: <exact command or MCP step>
- [ ] [eyes] <criterion> — checked by: <human step>; machine replacement: <exact check|none>; waiver: <user/date|none>

## Test plan
- Regression test: <path and test/assertion to add or existing failing check>
- First failing check: <exact command>; expected failure: <specific assertion/error proving the gap>
- Targeted checks: <exact commands>
- Full regression: <exact command>
- Static/build checks: <typecheck/lint/build commands or `not applicable — reason`>
- Runtime/acceptance environment: <services, browser/device, fixtures, test data, credentials boundary>
- Negative/mutation proof: <how the test is shown to fail without the fix>

## Implementation tasks
1. <owned file paths> — <independently verifiable change and reason>

## Definition of Done
- [ ] Regression check was observed failing for the expected reason before the fix
- [ ] Targeted, full, static/build, runtime, and acceptance checks passed as specified
- [ ] Complete diff and formatter/autofix output were read; no unexplained files remain
- [ ] Candidate commit passed deep review, mattpocock review, and Codex review on its exact SHA/tree
- [ ] PR head equals the reviewed SHA and required CI is green on that SHA

## Completion and reconciliation
- [ ] PR is merged with the configured method
- [ ] Spec/archive, issue/board, target sync, branches, and worktrees are reconciled

## Run config
branch: <current task branch>
target: <integration branch>
merge: squash|merge
auto_ready: yes|no — <reason when no>
ci: <required GitHub checks on the target branch, and how to observe them>
target_test: <exact command>
full_test: <exact command>
tracker: gh
board: <project title + owner | none>
```

For a documentation-only or mechanical task, `First failing check` and `Negative/mutation proof` may
say `not applicable` only with a concrete reason and an alternative baseline/diff check. Do not use
`not applicable` merely because writing a regression test is inconvenient.

`ci` names the checks the target branch **requires**: delivery reads `gh pr checks --required`, so a
repository whose branch protection requires nothing cannot finish a run. `auto_ready: yes` is valid
only when there is one PR, `ci`, `target_test`, and `full_test` are nonblank,
the DoR is complete, and every `[eyes]` criterion has a machine replacement or waiver. It records
capability, not execution mode; only `/run --auto` requests an unattended run.

Inspect the diff, stage the spec path explicitly, and commit it on the task branch with a Conventional
Commit. `tracker` is always `gh`: create or update the issue so it and the spec link to each other.
The run state starts in `/run`.

## 6. Hand off

Print the spec path and one appropriate next command:

```text
/cc-tuner:run docs/PLANS/2026-07-31-thing.md
/cc-tuner:run --auto docs/PLANS/2026-07-31-thing.md
```

Offer `--auto` only when `auto_ready: yes`. State the current branch and target so a later session can
verify both before editing.

## Verification

- [ ] Repository, issue, instructions, architecture, code, tests, and current docs were read
- [ ] DoR records the baseline, exact first failure, verification commands, environment, and data
- [ ] Every criterion names its deciding command or human step
- [ ] Every `[eyes]` item names replacement/`none` and waiver/`none`
- [ ] Implementation tasks own explicit, independently verifiable paths
- [ ] DoD binds review, PR, and CI evidence to one candidate SHA/tree
- [ ] One spec maps to one task branch and one PR
- [ ] Spec was committed on the task branch and linked to its issue
