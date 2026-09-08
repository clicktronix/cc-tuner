---
name: run
description: Work this branch's committed plan to a merged PR — safe ready batches, ticked checkboxes, exact-candidate reviews, green CI, and a merge that pins the head.
argument-hint: '[--auto] <path-to-spec>'
disable-model-invocation: true
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, mcp__context7
---

# /cc-tuner:run

Work the committed plan for the current branch. `--auto` selects unattended mode; the remaining
argument is the spec path. It authorises task-scoped commit, push, PR creation and merge, never
deploy, publish, migration, force-push or work outside the plan.

## Before starting

Read the named spec: it owns acceptance, tests, target, merge strategy, CI policy and DoD. If the
argument is missing, absent on disk or names the plan instead, stop and report the spec path from the
plan header when available; do not silently substitute it. Refuse `--auto` unless `auto_ready: yes`.

For work spanning repositories or a spec naming `second-repo`/`shared-task`, read
[shared-task.md](references/shared-task.md) before resolving plans. Apply it throughout this run,
including combined verification and preflight of every candidate before the first merge.

Resolve the branch's plan, then validate its spec and branch headers:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" resolve
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check <the path resolve printed> \
  --spec <the spec path from arguments> --branch "$(git branch --show-current)"
```

Read the returned path and use it literally in later calls. A missing or ambiguous plan, or a
spec/branch mismatch, stops the run: finish `/cc-tuner:spec` first. Never execute a conversation-only
plan or use one spec's tests and delivery config for another plan.

When native task tools exist, reconcile the list against the plan even if the list is nonempty.
`SessionStart` restores slices only. Create missing tasks with `TaskCreate`, then set edges with
`TaskUpdate addBlockedBy`:

- one task per slice with the plan's dependencies;
- **verify the feature**, blocked by every slice → **review the candidate** → **deliver**.

Carry all completed slice checkboxes into task status before starting; otherwise the loop, which
visits only open slices, cannot close stale pending tasks. Update statuses as stages execute. If
native tools are absent, say so once and continue with the plan file as durable state.

## The loop

Ask the parser for the first safe batch; do not select slices by eye:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" ready-batches <the resolved plan path>
```

It emits a `BATCH` and its `SLICE` records, or nothing when all slices are done. Parallel slices have
proven-disjoint literal Owned paths; otherwise it returns one ready slice. Work the returned batch,
prove each slice, tick what landed and ask again. Under `--auto`, refuse any task with nonempty
`blockedBy`, including tasks reached outside this parser: native task tools do not enforce the edge.

Mark tasks `in_progress` and `completed` as work advances. When a slice's criteria hold, tick the plan
and whichever spec acceptance criteria it established **in the same commit**. DoD is recorded during
Delivery, not in these commits. Use the repository's commit/trailer conventions from
`.claude/rules/task-flow.md`, falling back to recent history where silent.

## Who may stop the run

This skill owns the lifecycle. Invoked skills supply methods and findings; their standalone
confirmation prompts, gates or completion messages do not interrupt work already approved here.
Acceptance criteria, review findings and candidate evidence remain strict.

Without `--auto`, keep local slice commits moving; stop before the first outward action (push/PR)
and before merge. In either mode, a real user decision, waiver or unproved acceptance may require
input. Batch related pending decisions into one concise request and continue available work; do not
wait for a finding count or claim the blocked outcome complete. Routine checks and successful reviews
do not require another confirmation. Honour the validation refusals and required-review cap below.

## Delegating a slice

Delegate implementation when the work justifies the brief; under `--auto`, prefer delegation for
substantial slices. The orchestrator retains the task list, slice completion, mutation interpretation,
full regression, runtime acceptance, review verdict, DoD and delivery.

Before dispatching any implementation unit, read [placement.md](references/placement.md): it defines
the brief and return checks, model choice, isolation, concurrency and escalation. Read it also before
invoking `prototype`, `research`, `domain-modeling` or `diagnosing-bugs`. `deep-review` and `/spec` name
their own read-only agent type/model; where silent, placement decides.

## Proving a slice

- **RED before GREEN:** run the failing check first and record the expected failure. Use the honest
  non-code baseline/diff check where the spec explicitly permits it.
- Execute the spec's negative proof; `not applicable — <reason>` with its alternative is valid.
  Do not invent mutations. A shipped-bug regression observed RED before the fix needs no extra one.
  **If the spec assigns a mutation**, read [mutation-proof.md](references/mutation-proof.md) before
  running `mutate.sh`; the orchestrator must inspect its failure evidence, not just the verdict.
- Run the spec's targeted checks during implementation and full regression before the candidate.
- Re-check unresolved `[eyes]` criteria even if a stale plan reached `--auto`: stop for the required
  human step or a user waiver recorded with who and when.

## Verifying the feature

After every slice is done and before offering a candidate for review, invoke `cc-tuner:verify-feature`.
It selects instruments from acceptance criteria and repository capabilities, exercises the behaviour
and returns observations. A machine replacement for an `[eyes]` step must prove the same criterion.

The orchestrator decides what an unproved criterion means: ask under `--auto`, or carry it as a named
residual risk if the user already accepted it. Put the returned evidence record in the run log and PR.

## Delivery

A new commit invalidates exact-candidate evidence: testing, acceptance, authoritative review, CI and
DoD must cover the new SHA. It does not erase findings already read or restart every advisory review.
Shared-task delivery also covers the complete repository/SHA set defined in the loaded reference.

1. **Push and open the PR.** The candidate is its exact head SHA, with a clean working tree.
2. **Run each applicable advisory review at most once.** Run `mattpocock-skills:code-review` on the
   first clean candidate, address valid findings, then classify the resulting candidate. Add
   `deep-review` for a sensitive surface, at least 15 production files or 500 production lines,
   multiple repositories/services, or a major architectural boundary. Sensitive surfaces are
   authentication/authorization/secrets/cryptography; migrations or destructive data operations;
   public APIs, persisted schemas or cross-service contracts; money/pricing/billing;
   infrastructure/CI/deployment/release; and security-relevant input handling. Values, defaults,
   fixtures and configuration count when they decide behaviour on these surfaces.

   Do not stack built-in `/code-review` with `deep-review`. A matched deep-review trigger wins;
   otherwise an explicitly requested built-in review may occupy that optional slot. Matt does not
   run again. These advisory reviews discover findings; they are not merge gates.

   Apply `.claude/rules/task-flow.md`: validate findings against the agreed outcome, repository rules
   and evidence; group related fixes by cause and update the current plan. Keep them in existing
   implementation/review tasks unless they need a distinct work unit. A comment does not automatically
   create a native task or issue. Record independent future work through `cc-tuner:task-flow`.
   Refute speculative extensions outside the spec or rules; optional style notes with no violation
   do not move the candidate. After fixes, verify affected findings and continue to required review.
3. **Obtain authoritative `--required` approval** from `cc-codex-triage` at the exact candidate SHA.
   Choose one task-specific `--thread <name>` and retain it for all rounds and `merge.sh`; the checker
   must run in the same candidate worktree.
4. **Publish each completed required verdict immediately, before editing the candidate.** Read the
   actual PR number and SHA in this turn and copy the returned verdict without changing it:

   ```bash
   gh pr review <pr> --comment --body "cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <candidate-sha>"
   ```

   The public record and companion's required-review state are both required; neither replaces the
   other. Never turn `REQUEST_CHANGES` into `APPROVE`.
5. **Re-review when the decision changes.** A code fix creates a new SHA and needs new approval.
   A finding refuted with concrete `file:line` evidence or deferred by the user needs no code change:
   re-run the required review on the same SHA and publish its verdict. Do not manufacture an empty
   commit to move the candidate, or treat an earlier approval as forbidding a later review.
6. **On `REQUEST_CHANGES`, repeat authoritative review only.** Validate claims against the committed
   spec, repository rules and concrete failures. Fix valid findings, run affected checks and full
   regression, commit and re-review the new SHA. Do not restart Matt, deep-review or built-in review.
   Stop at the configured cap; do not reset the thread to seek a more favourable verdict.
7. **Record the spec's DoD before merge.** Name each item and its evidence in a PR comment or body
   section. Do not commit this record to the spec: that moves the reviewed SHA, and later writing it
   directly to the integration target violates repository rules.
8. **Merge through the checked script.** Use the spec's strategy and CI mode, with the pinned head
   and the same review thread:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" [--ci <mode>] <pr> <squash|merge> <candidate-sha> <review-thread>
   ```

   Omit `--ci` for `required`; legacy specs naming checks without a mode mean `required`.
   If any participating spec declares `none:<reason>`, read [local-ci.md](references/local-ci.md)
   before this step and record the exact candidate's local evidence as it requires.
   For a shared task, complete the reference's preflight of **all** candidates before any merge,
   then follow its declared-order and partial-delivery recovery instructions.

   The script rechecks required-review state, public verdict, the selected CI checks and PR head.
   Fix any refusal; do not substitute raw CLI/web/API merge or direct push. The head pin prevents
   merging a commit that moved after verification.
9. **Reconcile after merge.** Sync targets and clean up task branches/worktrees through
   `cc-tuner:task-flow`. Close the issue only when the whole agreed result and delivery prerequisites
   are complete. Do not commit a completion record directly to an integration target.
