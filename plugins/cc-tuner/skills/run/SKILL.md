---
name: run
description: Work this branch's committed cc-tuner plan to a merged PR — safe ready batches, ticked checkboxes, a verified feature, exact-candidate reviews, green CI, and a merge that pins the head. Use when a committed spec and plan exist for the current branch and the user wants the task implemented or continued.
argument-hint: '[--auto] <path-to-spec>'
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, mcp__context7
---

# /cc-tuner:run

Work the committed plan for the current branch. `--auto` selects unattended mode; the remaining
argument is the spec path. It authorises task-scoped commit, push, PR creation and merge, never
deploy, publish, migration, force-push or work outside the plan.

You may start this command yourself when the user asked for the task to be implemented or
continued and a committed spec exists. Use `--auto` only when the user asked for unattended
delivery; starting the command is not that request.

## Before starting

Read the named spec: it owns acceptance, tests, target, merge strategy, CI and review policy, and
DoD. If the argument is missing or names the plan instead, take the spec from the resolved plan's
`**Spec:**` header, say which one you took, and continue; the `plan-lint check` below proves the pair.
Stop only when neither the argument nor the header names a spec that exists. Refuse `--auto` unless
`auto_ready: yes`.

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

Ask the parser for the next safe batch; do not select slices by eye. Name every slice a unit is
still working on — the parser knows open and done, and only you know running:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" ready-batches <the resolved plan path> --active <n,n,...>
```

Omit `--active` when nothing is running. It emits a `BATCH` and its `SLICE` records: parallel
slices have proven-disjoint literal Owned paths, disjoint also from every active slice; otherwise
one ready slice. Dispatch what it returns without re-deriving it.

**Rolling dispatch.** A slice whose blockers are done starts as soon as a unit is free; do not wait
for the rest of its batch. "Free" is measured against placement's concurrency cap on the **active
set**, not per batch: a returned batch of two joining one running unit is three, and on a
build-heavy repository two is the ceiling, so one of them waits. Ask again after every unit returns, with the active set refreshed from
native task status and your agent handles — including on resume, where the first thing to do is
reconcile which units still exist before dispatching anything.

**An empty batch is not completion.** With `--active` it is also what an all-busy or all-conflicting
plan returns, and the parser says so on stderr. Decide by the plan, not the batch: open slices remain
→ wait for an active unit or diagnose the block; no open slices → verify the feature. A unit's
process ending is not acceptance either — a slice closes only after you have read its diff and its
deciding-check evidence and integrated the commits. A `--active` id the parser does not know is an
error, never ignored: refresh the set rather than guessing.

Under `--auto`, refuse any task with nonempty `blockedBy`, including tasks reached outside this
parser: native task tools do not enforce the edge.

Mark tasks `in_progress` and `completed` as work advances. When a slice's criteria hold, tick the plan
and whichever spec acceptance criteria it established **in the same commit**. When a unit did the
slice, that is the commit integrating its work: the plan is outside the unit's Owned paths. DoD is recorded during
Delivery, not in these commits. Use the repository's commit/trailer conventions from
`.claude/rules/task-flow.md`, falling back to recent history where silent.

## Who may stop the run

This skill owns the lifecycle. Invoked skills supply methods and findings; their standalone
confirmation prompts, gates or completion messages do not interrupt work already approved here.
Acceptance criteria, review findings and candidate evidence remain strict.

Without `--auto`, keep going through commits, push of the task branch and a draft PR — those are
reversible and inside the task — and stop once, before the merge: hand the verified candidate and
the merge command to the user. A user instruction in this session to merge authorises it. In either
mode, a real user decision, waiver or unproved acceptance may require input. Batch related pending
decisions into one concise request and continue available work; do not wait for a finding count or
claim the blocked outcome complete. Routine checks and successful reviews do not require another
confirmation.

**Waiting is not stopping.** While units, CI or a review run in the background, do the next
available work, or wait for their notification. Do not end the turn with a statement of what you
will do next: nothing resumes a run that ended its turn except the user.

## Delegating a slice

Delegate implementation when the work justifies the brief; under `--auto`, prefer delegation for
substantial slices. Dispatch an implementation unit as `cc-tuner:slice-unit` — capped at 300 turns,
so a slice that does not fit comes back marked partial instead of running on. There is no uncapped
fallback: when the host does not list that type, do the slice yourself and say so. The orchestrator
retains the task list, slice completion, mutation interpretation, full regression, runtime
acceptance, review verdict, DoD and delivery, and it owns a partial return: placement's
"Unit size and partial returns" says what happens next.

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
- **Record the deciding check's evidence in the plan**, under the slice, as one line the next reader
  can re-run: `Evidence: <command> → <the deciding output line> @ <sha or worktree>`. The parser
  ignores the line; it exists so completion is a recorded result, not a remembered one. One matching
  line is not proof by itself — you still read the diff and check the criterion is covered — but it
  is what makes reuse honest: evidence names the code it was taken from.
- **Test cadence.** Slices run the spec's targeted checks, which may be one browser or API
  regression test when that is the deciding check. The full regression suite runs once on the
  assembled candidate and once after each batch of review fixes, not after every fix; the full e2e
  suite runs in verify-feature. Reuse observed results when the checked code, dependencies, configuration and
  environment still match; identify the source result and why it applies. Re-run affected checks
  when those inputs change or the evidence is missing/unreliable. Honour explicitly required fresh
  runs. A new commit alone does not require another identical local build; review and CI still bind
  the final SHA.
- **Heavy checks go through the machine's slots.** Full suites, e2e, builds and container starts run
  as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/heavy.sh" --label "<repo>: <what>" -- <command>`, from
  you and from every unit. Other sessions on the machine share the slots
  (`CC_TUNER_HEAVY_SLOTS`, default 1), so a call may wait; run long ones in the background and do
  other work meanwhile. Targeted checks that take seconds run directly.
- Re-check unresolved `[eyes]` criteria even if a stale plan reached `--auto`: stop for the required
  human step or a user waiver recorded with who and when.

## Prepare the candidate

After implementation, read `cc-tuner:task-flow`'s Prepare the candidate and Pre-PR checklist. Complete
archiving and update plan/spec links before the first required review; continue with the new spec
path. The plan itself stays where `plan-path.sh` put it. Validate the updated plan with the same
resolver/linter contract used at startup.

Fetch the integration target before the first candidate and before delivery. If it advanced beyond
this branch, notify the user and integrate it, resolving conflicts within the agreed task. Prefer
merge on published branches or after required review began; rebase only unpublished work before the
first required round when repository policy allows it. Do not force-push to synchronize. Preserve
unrelated WIP; use a separate clean task checkout when necessary and retain it for required review
and merge. Reverify the integrated result. A conflict needing a product decision blocks only its
dependent work. Do not ask again for routine conflict resolution.

Pass a literal synchronized target SHA as the initial review base; keep it and the spec path fixed
for that thread. Later target updates are merged without changing that base. If target advances
after approval, integrate it with a merge commit, refresh affected evidence and obtain approval for
the new candidate; under `review: codex` claim that round with `begin --integration`, which reviews
the integration without spending the cap. A companion older than 0.14 has neither this nor `renew`
(prereq-check prints a NOTE): review the integration as a normal round, and after an authorized new
budget use its documented reset.
On resume, read the existing PR and review state; reuse valid progress, and reconcile an already
merged PR instead of opening or merging it again.

## Verifying the feature

After every slice is done and before offering a candidate for review, invoke `cc-tuner:verify-feature`.
It selects instruments from acceptance criteria and repository capabilities, exercises the behaviour
and returns observations. A machine replacement for an `[eyes]` step must prove the same criterion.

The orchestrator decides what an unproved criterion means: ask under `--auto`, or carry it as a named
residual risk if the user already accepted it. Publish the returned record on the PR as one comment
whose first line is `cc-tuner-verified: <full sha it verified>`; `merge.sh` requires it and accepts
any commit the head contains, so later fix commits need a new record only when the reuse rule says
the evidence no longer covers them.

## Delivery

A new commit needs fresh authoritative approval and CI, with acceptance and DoD evidence covering
the resulting candidate. Local checks follow the evidence-reuse rule above. Previously read findings
and completed advisory passes remain useful; a new SHA does not restart them.
Shared-task delivery also covers the complete repository/SHA set defined in the loaded reference.

1. **Push and open the PR** (draft is fine while work continues). The candidate is its exact head
   SHA, with a clean working tree.
2. **Choose one advisory workflow for the first clean candidate.** Use `deep-review`
   for a sensitive surface, at least 15 production files or 500 production lines,
   multiple repositories/services, or a major architectural boundary. Sensitive surfaces are
   authentication/authorization/secrets/cryptography; migrations or destructive data operations;
   public APIs, persisted schemas or cross-service contracts; money/pricing/billing;
   infrastructure/CI/deployment/release; and security-relevant input handling. Values, defaults,
   fixtures and configuration count when they decide behaviour on these surfaces.
   Deep-review owns packet preparation, sharding and the reviewer count; use its accepted partition
   to state cost before dispatch.

   Otherwise use `mattpocock-skills:code-review`: dispatch exactly its two subagents, Standards and
   Spec, each with `model: "sonnet"`, and keep their reports separate. Its Fowler smells are
   judgement calls: fix a documented-standard or spec finding once validated, and a smell only when
   you agree it costs something here — list the smells you declined. Or use Claude Code's built-in
   `/code-review <level>
   <target>` when requested. Put the level first — a level written after the target is read as part
   of the target. At `high`/`xhigh` the built-in review runs in one context in minutes; at `max` it
   dispatches a verifier per candidate finding (20–40 agents and hours in field runs) on the
   session's model, and it has no Spec axis, so the spec's acceptance stays yours to check. Pass
   base, candidate and spec; run without publishing findings automatically. Deep review already covers Spec and Standards: do not stack
   these workflows. If fixes newly meet a deep-review trigger, escalate once; otherwise verify
   affected findings without restarting advisory passes. These are not merge gates. A deep-review
   `INCOMPLETE` names the lenses/paths nobody read; the table below says who closes that gap.

   Apply `.claude/rules/task-flow.md`: validate findings against the agreed outcome, repository rules
   and evidence; group related fixes by cause and update the current plan. Keep them in existing
   implementation/review tasks unless they need a distinct work unit. A comment does not automatically
   create a native task or issue. Record independent future work through `cc-tuner:task-flow`.
   Refute speculative extensions outside the spec or rules; optional style notes with no violation
   do not move the candidate. After fixes, verify affected findings and continue to required review.
3. **Obtain the verdict from the owner the spec's `review:` names.**

   | | `codex` (default) | `none:<reason>` |
   |---|---|---|
   | verdict owner | cc-codex-triage `--required` at the exact SHA, one task-specific `--thread` for all rounds and `merge.sh`, in the candidate worktree | you: after step 2's findings are fixed or refuted with `file:line` evidence, you judge the candidate |
   | after a fix commit | a new required round on the new SHA | re-check the affected findings on the new SHA, not a new fan-out, then judge again |
   | deep-review `INCOMPLETE` | name the unread lenses/paths in the round's brief | read those paths yourself before judging, or ask the user to accept the gap |
   | review cap (`--cap`, default 5) | stop paid rounds, keep fixing what is safe, ask the user once: more rounds (`review-state.sh renew <thread> --by <who>`, same thread) or merge on their decision | — |
   | user decides to merge without an approval | merge under `--review 'none:<who> decided at the cap'` with a decision record (step 4) | decision record (step 4) |

   An advisory review that returns reports rather than a verdict (Matt's two axes) is input to the
   owner, never a verdict to copy. A finding refuted with evidence or deferred by the user needs no
   code change: re-judge the same SHA. Do not manufacture an empty commit to move the candidate, and
   do not reset a thread to seek a more favourable verdict.
4. **Publish each verdict immediately, for the SHA that was judged.** Take the SHA from the verdict
   itself (the companion's marker, or the commit you judged), read the PR's full `headRefOid` in
   this turn, and compare: if the head moved, the verdict belongs to the old SHA — review the
   difference to the new head instead of relabelling it. Abbreviated SHAs do not match the gate:

   ```bash
   gh pr review <pr> --comment --body "cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <judged-sha>"
   ```

   `gh pr comment` with the same first line is read too. Never turn a `REQUEST_CHANGES` into
   `APPROVE`. A user's decision to merge anyway is a separate record, published only after they gave
   it in this session, naming them and what they accepted:

   ```bash
   gh pr comment <pr> --body "cc-tuner-accepted: <head-sha> <who>: <what was accepted>"
   ```

   `merge.sh` honours it only under `--review none:<reason>` and only for that exact head.
5. **Record the spec's DoD before merge.** Name each item and its evidence in a PR comment or body
   section. Do not commit this record to the spec: that moves the reviewed SHA, and later writing it
   directly to the integration target violates repository rules.
6. **Mark the PR ready and deliver through the checked script.** When the candidate is verified,
   judged and its DoD recorded, run `gh pr ready <pr>` if it is a draft — GitHub will not merge a
   draft, and some repositories run their full checks only on ready PRs, so wait for those checks.
   Recheck target advancement as described above. Under `--auto`, merge with the spec's strategy,
   CI mode, pinned head and same review thread:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" [--ci <mode>] [--review none:<reason>] <pr> <squash|merge> <candidate-sha> [<review-thread>]
   ```

   Omit `--ci` for `required`; legacy specs naming checks without a mode mean `required`. The thread
   is required under `review: codex`. An ordinary pull request outside a run is merged with
   `--unmanaged`, which the script refuses for a PR that carries a plan or names a review.
   If any participating spec declares `none:<reason>`, read [local-ci.md](references/local-ci.md)
   before this step and record the exact candidate's local evidence as it requires.
   For a shared task, complete the reference's preflight of **all** candidates before any merge,
   then follow its declared-order and partial-delivery recovery instructions.

   Without `--auto`, run this command with `--check-only` and hand the passing candidate and merge
   command to the user. `--check-only` requires everything a merge does; it only skips the final
   merge action. Keep deliver pending until the merge is observed.

   The script rechecks required review, public verdict, the verify-feature record, the selected CI
   checks and PR head.
   Fix any refusal; do not substitute raw CLI/web/API merge or direct push. The head pin prevents
   merging a commit that moved after verification.
7. **Reconcile after merge.** Sync targets and clean up task branches/worktrees through
   `cc-tuner:task-flow`. Close the issue only when the whole agreed result and delivery prerequisites
   are complete. Do not commit a completion record directly to an integration target.
