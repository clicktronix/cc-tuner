# Delegate the plan to the platform; enforce only where the action is irreversible

**Date:** 2026-08-12
**Status:** proposed — several load-bearing assumptions below are unverified and one question is open.
It becomes accepted only after the spike named at the end.
**Amends:** `2026-08-12-planning-contract.md` — its attribution and "our rules, not upstream text"
decision stands; its "enforced in `runctl`" decision is reversed here. That ADR should not land on
`main`: it accepts a Bash DAG engine this one deletes, and PR #19 is the record of that experiment.

## Context

`/cc-tuner:run` grew from a command into a workflow engine. The current runtime is 3019 lines of
production Bash in this plugin, 1400 of them in `runctl.sh`:

| part of `runctl.sh` | lines |
|---|---|
| `task` + `plan` subcommands | 199 |
| `validate_state_shape` — a hand-written jq twin of `run-state.schema.json` | 86 |
| prepared-file machinery (symlink, ownership, hard-link checks) | 43 |
| graph jq definitions | 36 |
| lock handling (references across the file) | 27 |

`workflow-contract.json` carries 30 invariants. None is read at runtime; a jq assertion in a test
counts them.

Three things forced a re-examination:

1. **A review of PR #19 found five blockers, all reproduced by running the flow.** The
   `spec → plan → run` sequence could not start (no command creates the run between them), the
   prepared plan path was refused by our own mutation fence, `canonical-plan-before-mutation` was
   bypassable through the still-public `task add`, a valid DAG could deadlock the lifecycle because
   nothing checks phase order, and `owned_paths` treated `src/a` and `./src/a` as independent.
2. **The 82 assertions in `test_contract.sh` are `grep -qF` over markdown, and every one passed.**
   They were even mutation-proven — which demonstrates the grep is wired, not that the behaviour
   exists. Contradictions between a document and the runtime are invisible to phrase matching.
3. **The visible plan the whole effort was for is a platform feature.** The original complaint —
   "I still don't see a plan" — was about the native Claude task list not appearing. Its absence was
   caused by `runctl init` never running in sessions that held an older command version, not by
   anything a task graph would fix.

## Observations

Measured directly against the task tools in a live session, not read from documentation:

- **`blockedBy` is advisory.** `TaskUpdate` moved a task with an open blocker to `in_progress`
  without complaint, and `TaskList` then rendered `#23 [in_progress] … [blocked by #22]` — a state
  that should not exist. The platform stores and displays the dependency graph; it does not police it.
  `TaskList`'s "tasks with blockedBy cannot be claimed until dependencies resolve" is a convention for
  the agent reading the list, not a refusal on write.
- **`metadata` does not round-trip.** Fields set through `TaskCreate` (`delivers`, `owned_paths`,
  `acceptance`, `checks`) are surfaced by neither `TaskGet` nor `TaskList`. It can be written and not
  read back, so it cannot hold the plan.
- **A durable artifact is therefore not a fallback, it is the only store.** This is why
  `superpowers:writing-plans` puts files, interfaces and steps in a committed Markdown plan and leaves
  the task list holding subject, status and edges. The structure follows from the constraint.

From the tool contracts, not yet exercised end to end:

- **`EnterPlanMode` / `ExitPlanMode` provide a native plan file and a native approval gate.**
  `ExitPlanMode` reads the plan from the file named in the plan-mode system message and requests the
  user's approval of it. It is interactive by construction, so it covers the attended mode and not
  `--auto`. It is a review-and-approval surface, not a source of architecture: it creates no tasks, no
  committed artifact, and carries none of our slicing rules — and it is reportedly unavailable inside
  agent/subagent contexts, which the spike must confirm. The planning skill therefore writes the
  artifact and creates the tasks either way; plan mode wraps it for the attended path only.
- **`TaskCompleted` already gives a hook point on the native task lifecycle**, and this plugin already
  uses it.

## Root cause

The threat model was too strong. `lib.sh` says so in its own comment — "anything with shell access can
rewrite this file or the state it guards, and no local check changes that" — and the code then
implements hard-link checks, symlink checks, ownership checks and claim tokens as if it were a
security boundary. Guards against an accidental mistake were built to the standard of guards against a
hostile process that already has unrestricted Bash. That is where the fail-closed dead ends, the
migrations, the recovery paths and the second copy of every rule come from.

## Decision

### Keep — the platform's

| capability | owned by |
|---|---|
| Visible plan, statuses, done/open counts | native tasks |
| Dependency edges and their rendering | `addBlockedBy` / `addBlocks` |
| Plan file and user approval of the plan | `EnterPlanMode` / `ExitPlanMode` (attended runs) |
| A hook point when a task completes | `TaskCompleted` |

### Keep — ours, because nothing else provides it

- The `spec → plan → run` split, and a Definition of Ready in the spec.
- The committed plan artifact: vertical slices with owned paths, acceptance, deciding checks,
  `Blocked by`, and `- [ ]` progress boxes ticked as tasks complete. It is the only readable store and
  the recovery point after a lost session.
- **cc-tuner runs no state machine of its own.** Each fact has an owner that already exists and is
  harder to falsify than a file we write: `candidate` is the current clean HEAD; CI is
  `gh pr checks`; the Codex verdict belongs to cc-codex-triage, which keeps its own review state and
  should continue to; `phase` is the phase of the first unticked box in the plan.
  **Not yet true:** the deep-review and mattpocock attestations are not published anywhere external —
  there is no PR comment or check carrying "reviewer, verdict, exact SHA". Until that exists,
  "PR head ≠ reviewed SHA" cannot be answered from `gh`, and this bullet is a target, not a
  description. Publishing those attestations is a prerequisite of deleting the local record, not a
  consequence of it.
  **Resolved:** `spec.md` accepts `tracker: none`, but `/run` already requires a PR and GitHub CI
  unconditionally, so that mode is inconsistent today. Drop `tracker: none` from `/run`; a local
  delivery mode, if wanted, is a separate design.
- Candidate SHA recorded before review; three reviews bound to that exact SHA; current-head CI; DoD
  before merge.
- The interactive/auto distinction.
- Capability profiles in `prereq-check.sh` — one table, checked per command.
- Method placement — but **by ordering the branch, not by overriding the skill.** The current wording
  fights its upstreams and must be replaced: `domain-modeling` exists to write the glossary and ADR
  "the moment they crystallise" and has a whole section on updating `CONTEXT.md` inline, while
  `spec.md` tells it to defer writing until §4; `prototype` §6 says to commit the throwaway "to a
  throwaway branch, out of main" and leave a pointer on the issue, while `spec.md` says a prototype is
  never committed to any branch. An instruction that contradicts the skill it invokes will be either
  ignored or obeyed at the cost of the method. **Create the task branch before any write-capable
  method runs**, and the conflict disappears instead of being argued with: `grilling` and
  `domain-modeling` then run on the task branch, `research` saves there or is explicitly discarded,
  `prototype` gets its own throwaway branch as its author intends, and `diagnosing-bugs` stays
  read-only or takes a throwaway worktree.

### Delete

| deleted | why |
|---|---|
| `runctl plan import` and its DAG validation | edges are native; the artifact is the store |
| `blocked_by` in run state, schema v2 | duplicates `addBlockedBy` |
| `plan frontier`, `--parallel`, `owned_paths` overlap detection | a filter over `TaskList`, not an engine |
| `bind-ui` and the `TaskList` ↔ state reconciliation pass | exists only to keep a second copy in sync |
| `validate_state_shape`'s jq twin of the JSON Schema | two descriptions of one shape that cannot check each other |
| Write/Edit mutation fence and prepared-file hard-link machinery | a boundary against a process that can bypass it anyway; it produced blocker #2 |
| Manifest search for an "authoritative" companion installation | `claude plugin list --json` returns `id`, `version`, `scope`, `enabled`, `installPath` and `projectPath` directly. `execute_task_manifest_roots` reconstructs that from `installed_plugins.json` with hand-written scope precedence — and never checks `enabled`, which the CLI provides |
| Markdown journal as a second state | the artifact and the task list cover it |
| `plan-published` gate, `task add`, generation/reclaim locks | machinery for the deleted graph |
| 30 invariants | reduce to the handful that are actually enforced |

### Enforce

Fail-closed in exactly one place: **a hook that refuses `gh pr merge` unless the PR head equals the
recorded candidate SHA, three reviews approved that SHA, and required CI is green on it.** That is the
irreversible, outward-facing action; everything upstream of it is recoverable.

Optionally, under `--auto` only, a single check that refuses to start a task whose `blockedBy` is
non-empty — because `blockedBy` is advisory and nobody is watching. One `TaskList` read, no graph.

## Consequences

- The runtime becomes a skill, one merge hook, and a setup check. No new language, and for a stronger
  reason than the one this ADR first gave: with no state machine of our own there is no controller to
  port. What is left reads `git`, `gh` and the plan file and compares strings — choosing a different
  language for that buys a dependency, not clarity.
- **The plan is advisory in attended mode.** With the mutation fence gone, nothing prevents an edit
  before the plan exists except the model following its instructions and the user watching. This is a
  deliberate trade, recorded here so it is a decision and not a side effect: the observed failure was
  never an agent bypassing the fence, it was the fence being inert because state did not exist.
- Losing the visible task list costs a reconciliation pass from the artifact, never the run.
- `--auto` cannot use `ExitPlanMode`, so the attended and unattended paths differ at exactly one step:
  approval. That difference is one branch in a skill, not a second mechanism.
- Upstream improvements to the platform's task model arrive for free; upstream improvements to
  decomposition discipline do not, because those rules are ours (see the amended ADR).

## Complexity budget

- **Runtime** Bash: the merge guard, and under `--auto` the one frontier check. Nothing else.
  Setup-time checks are a separate category with a separate home (`/cc-tuner:setup` doctor) — stating
  the rule as "Bash only for the merge guard" would either delete the environment check or let it grow
  back unnoticed under a rule it was never covered by.
- One fail-closed gate.
- No more than seven normative invariants, each with something that reads it at runtime.
- **End-to-end scenarios are the primary test.** Phrase-matching assertions may support them, never
  replace them: the current suite is 82 greps that were all green while the flow could not start.

## Sequence

The spike comes first, then one short ADR, then two small vertical PRs. Nothing on this branch is
ported to `main` before that: the `plan` row in the capability registry and the rewritten
`plugins/cc-tuner/README.md` both reference `/cc-tuner:plan`, which a methods-only PR would not ship,
so "Part 1" is not currently separable from the work being discarded.

## What happens to PR #19

- **Rewrite, as a separate small PR from clean `main`:** the method work — task branch created before
  any write-capable method, methods placed as their own skills intend, `setup` doctor simplified onto
  `claude plugin list --json`, no `/plan` and no DAG runtime. The capability profiles are worth keeping
  in that PR, minus the `plan` row.
- **Keep as the entry point to the new work:** the twelve graph regressions, rewritten as executable
  end-to-end scenarios rather than assertions against the deleted Bash graph.
- **Do not carry over:** schema v2, `plan import`, `plan frontier`, graph enforcement in `runctl`.

## Unresolved

- Bootstrap before the first mutation. The defect that actually caused the original complaint —
  `runctl init` never running, leaving every hook inert — is not addressed by anything above. It needs
  a black-box test of what `UserPromptSubmit` receives for a slash invocation before any design is
  chosen; if a slash command cannot be recognised reliably, that must be recorded as a limitation
  rather than presented as a proven gate.
- A session that has already loaded an older version of a command cannot be repaired by anything
  shipped in a newer one. Only a reload or a cache purge fixes an existing session.
- Of Matt Pocock's 22 skills this flow uses 8. `resolving-merge-conflicts` is model-invocable, is not
  used, and `/run` has no conflict path at all. `handoff`, `wayfinder` and `triage` are relevant but
  carry `disable-model-invocation: true`, so they meet the same wall as `to-tickets`.
