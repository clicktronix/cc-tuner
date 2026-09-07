---
name: run
description: Work this branch's committed plan to a merged PR — safe ready batches, ticked checkboxes, exact-candidate reviews, green CI, and a merge that pins the head.
argument-hint: '[--auto] <path-to-spec>'
disable-model-invocation: true
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, mcp__context7
---

# /cc-tuner:run

Work the plan for the current branch. `--auto` anywhere selects unattended mode; the remaining
argument is the spec path.

`--auto` authorises task-scoped commit, push, PR creation and merge. It never authorises deploy,
publish, migration, force-push, or work outside the plan.

## Before starting

**Read the spec named in `$ARGUMENTS`.** The argument is the spec path, never the plan path. No path,
no such file, or the resolved plan itself passed as the argument → stop and print the exact spec path
from the plan header; do not silently substitute it and continue. It is not decoration: the
spec carries the target branch, the merge strategy, `auto_ready`, the test plan, the acceptance
criteria and the Definition of Done. Everything below that says "as the spec requires" reads it from
there, and a run that never opened it is a run following defaults nobody chose.

If `auto_ready` is not `yes`, `--auto` is refused — say which unmet condition blocks it.

Then ask for the plan path and read it out of the output — a shell variable does not survive to the
next tool call, so every command below names the file literally:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" resolve
```

`resolve` fails when the branch has no committed plan, or more than one. Either way, stop: finish
`/cc-tuner:spec` first. Never work from a plan that exists only in the conversation.

**Check that the plan is this spec's plan.** Its header carries `**Spec:**` and `**Branch:**`. If the
spec path you were given is not the one the plan names, stop and say so: `/run` takes a spec argument
while the plan is found from the branch, so nothing else stops plan A being worked with spec B's
target, tests, Definition of Done and merge strategy.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check <the path resolve printed> \
  --spec <the spec path from arguments> --branch "$(git branch --show-current)"
```

If the task tools are there, **reconcile the list against the plan** — create what is missing, do not
skip because something is there. The `SessionStart` hook restores slices only, because slices are all
the plan file records; a run that publishes only when `TaskList` is empty therefore leaves a restored
session permanently without the three lifecycle tasks. Create in two passes, `TaskCreate` then
`TaskUpdate addBlockedBy`:

- one task per slice, with its edges from the plan;
- then **verify the feature**, blocked by every slice; **review the candidate**, blocked by verify;
  **deliver**, blocked by review. A chain, not three siblings: they happen in that order, and three
  tasks going ready at once says the opposite.

Then **carry the plan's ticks across**: a slice whose criteria are all `- [x]` is `completed`, and a
restored session must say so before it starts working. The implementation loop reaches only open
slices, so a finished slice left `pending` in the list is one nothing will ever close — and after the
last slice, that is the whole list.

Mark them as you reach them — a list that says everything is done while the candidate is unreviewed is
worse than no list. If the tools are not there, skip this and say so once; the run proceeds either way.

## The loop

**The plan file is the state. Ask it what may start:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" ready-batches <the path resolve printed>
```

It prints one `BATCH` record followed by the `SLICE` records in the first safe batch, or nothing when
every slice is done. A parallel batch contains only ready slices whose literal Owned paths the
validator proved pairwise disjoint; otherwise it returns the lowest ready slice alone. Work that
batch, tick what landed, and ask again. The placement reference owns how a parallel batch is handed
out, not whether its paths overlap.

Ask the program rather than reading the graph yourself. The rule is one line to state and easy to get
wrong under `--auto`, and getting it wrong means starting a slice something else was supposed to
finish first. `ready-batches` refuses to answer at all for a plan that does not parse.

The visible task list is a projection of that state, not the state. Where the tools are present, mark
the slice `in_progress` and then `completed` as you go, so a watcher sees it; where they are absent,
nothing about the loop changes.

Three things this adds to the obvious:

- **Tick the plan file and commit it.** When every acceptance criterion of a slice is met, change its
  `- [ ]` to `- [x]` in the plan file and commit. The task list does not survive the session; the file
  does. A ticked file with no matching task is recoverable, a completed task with an unticked file is
  lost. **Tick the spec's acceptance criteria in the same commit**, for whichever of them that slice
  made true: they are the contract's own record and they are provable here, and a spec left at zero
  ticks beside a plan at twenty is how a finished run reads as a failed one. Its Definition of Done is
  not ticked here — those items are only true after the merge, and step 9 records them.
  **Commit message format, including any attribution trailers, comes from the repository's
  conventions** in `.claude/rules/task-flow.md`; where that file is silent, match the repository's
  recent history rather than the harness default.
- **Under `--auto`, refuse a task whose `blockedBy` is not empty.** The platform stores the edge and
  does not enforce it: `TaskUpdate` will move a blocked task to `in_progress` without complaint. Under
  attention that is a visible mistake; unattended nobody is watching. `ready-batches` cannot hand you such
  a slice, so this is the check on a task you reached some other way — a leftover in the list, or one
  you picked by eye rather than from the emitted batch.
- **Without `--auto`, keep local slice commits moving.** Stop before the first outward action
  (push/opening the PR), when a review or acceptance result leaves a real user decision or waiver,
  and before merge. Report what is done and what comes next. A local commit, a successful review or
  a completed routine check is not by itself a reason to interrupt the user.

## Who may stop the run

**This skill owns every approval and every stop.** Skills invoked from here — `tdd`, `code-review`,
`deep-review`, `verify-feature`, `diagnosing-bugs`, `research` — supply methods and findings. None of
them may demand its own confirmation, declare its own gate, or end the loop, and where one reads as
if it does, that text is about its own standalone use and does not apply inside a run.

The reason is not tidiness. Several workflow skills loaded at once each bring a lifecycle, and the
places where they disagree become places the run stops to ask a question nobody needed answered. What
stays strict is the *result*: acceptance criteria, findings, and the candidate's evidence. Continuing
work already approved at `/cc-tuner:spec` is not a new decision and does not need a new yes.

Stop only for the boundaries this skill names: the first outward action without `--auto`, a real user
decision or waiver, an unproved acceptance criterion, and merge.

## Delegating a slice

You are the orchestrator. Implementation of a slice may be handed to a subagent dispatched with the
Agent tool; the decisions may not. That split is not a preference — a subagent starts with none of
this session's context, so it can be handed a job but cannot be handed a judgement.

**Delegate when the slice is worth its brief** — real implementation work, not a two-line edit you
could make while writing the delegation. Under `--auto`, prefer delegating: your own context is the
scarce resource across a long plan.

**The brief is written from the files, never from this conversation** — which is what makes
delegation cheap here, because everything a unit needs is already committed. It carries the spec path
with the instruction to read it, the slice verbatim from the plan (title, Owned paths, Deciding check,
Delivers, criteria), and these standing constraints:

- write only inside the slice's Owned paths;
- make the deciding check pass, having first seen it fail, and say which command showed each;
- do not delegate further: a unit implements its own slice. Nested delegation was measured spawning
  dozens of agents nobody asked for, and a subagent's subagent is a brief written from a brief;
- report what you did NOT verify. You run the slice's deciding check; proving the behaviour against a
  running system is the orchestrator's stage, and it needs to know what is still only compiled;
- commit in this repository's convention; do not push, do not open or comment on a pull request, do
  not merge, and do not claim any review or approval;
- report what changed, the commands run with their results, and anything the slice's text turned out
  to be wrong about.

**What never leaves you.** Reading `mutate.sh` output; deciding a slice is done; the full regression
before the candidate; the review verdict; the Definition of Done; and everything under Delivery. A
unit reports; you decide. Where the native task tools are present, you own the task list too — a
subagent's status updates are not the plan's state.

**Verify what comes back against the tree, not against the report.** Read the unit's diff, run the
deciding check yourself, and confirm it touched nothing outside its Owned paths. A unit's summary is a
claim about work one command can inspect, and the RED-to-GREEN discipline below exists because a claim
is not evidence.

[`references/placement.md`](references/placement.md) carries the rest: which slices may run at once,
which workspace `prototype`, `research`, `domain-modeling` and `diagnosing-bugs` belong in, and the
dispatch mechanics — agent type, model, concurrency, isolation, escalation. Read it before fanning out
or before invoking any of those skills. `deep-review` and `/cc-tuner:spec` name their own agent type
and model for their own read-only fan-outs; where they are silent, placement decides.


## Proving a slice, before it counts as done

A slice is done when its acceptance criteria hold **and** you can show why you believe it. An earlier
revision of this skill said only "work it, complete it", which is not a discipline — it is a hope.

- **RED before GREEN.** Write the failing check first and run it; record the failure. A check that
  was never seen failing has not been shown to test anything.
- **Run the negative proof the spec assigned — not one per slice. When that proof is a mutation, run
  it through the script.** The spec's `Negative/mutation proof` line says what has to be shown, and
  `not applicable — <reason>` with an alternative baseline or diff check is a legitimate answer there.
  Execute what it names; do not invent a mutation for a slice whose spec did not ask for one, and do
  not skip one it did. Which slices should be asked for a mutation is `/cc-tuner:spec`'s decision, and
  it is written there — by the time this skill runs, that spec is committed.

  For a mutation, revert the behaviour the check guards and confirm the check goes RED:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --expect '<what the killed test must say>' \
    <file> "<test command>" "<command that edits \$MUTATE_FILE>"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --help   # the verdicts, the exit codes, the refusals
  ```

  **Read the mutant log it prints; a KILLED line is not the whole answer.** The script confirms a kill
  by restoring the file and running the test again, which rules out an environment that stayed broken —
  but not one that failed only during the mutant run and recovered. That shape is indistinguishable
  from a kill to any generic helper, and the log is where it is visible: a `ConnectionError` where an
  assertion message should be. `--expect` narrows a confirmed kill and is worth passing, but it cannot
  settle this either, because a traceback echoes the source line it was matching.

  It grades the mutation instead of taking your account of it, and it refuses rather than guessing —
  `--help` is the contract, and it cannot drift from the code the way a paragraph here can.

  **A regression test for a shipped defect needs no mutation.** You watched it fail on the pre-fix code
  and pass after: that observation *is* the mutation result, obtained at no extra cost, and running the
  script as well buys a second copy of the same fact for three more runs of the test command. Say so and move on. What
  earns a mutation is a guard whose failure mode nobody has ever seen — a fail-closed check, a
  validator, a budget — where green proves nothing until something is deliberately broken.

  **Run it once for the guard it covers.** The proof belongs to a guard, not to a commit: re-run it
  only if the guard's own code or its test changed. A live run spent ten builds re-proving one budget
  after edits nowhere near it, because "the SHA moved" was read as "the proof expired". A new SHA
  invalidates the review and CI, which are about the whole candidate; it does not invalidate a
  measurement of one guard nothing touched.

  **Paste its lines into the run log; do not retype them.** Live runs reported a mutant SURVIVED that
  a quoting bug never applied, and one "corrected" a right number into a wrong one because a
  hand-rolled harness leaked state between mutants. A mutation result you typed yourself is a claim
  about a claim.
- **Run what the spec's test plan names** — its targeted checks during the slice, its full regression
  once before the candidate.
- **Re-check `[eyes]` as a second fail-safe.** A conforming spec already makes unresolved human-only
  acceptance set `auto_ready: no`; if a stale or hand-edited plan still reaches this point under
  `--auto`, stop and ask. A waiver is the user's to give, recorded with who and when.

## Verifying the feature, not the build

When every slice is done and before the candidate is offered to any review, invoke
**`cc-tuner:verify-feature`**. It reads the spec's acceptance criteria and the diff, finds what this
repository already provides (commands, fixtures, runbooks, a browser tool, a database), chooses the
instrument per behaviour, runs it, and returns what was observed.

This is the stage that decides an `[eyes]` criterion. A criterion written as human-only sometimes has
a machine representative once the code exists — the built chart option can be asserted where "the
inversion reads as an inversion" cannot — and finding it is part of the stage, not a licence to
downgrade the criterion. What it cannot prove, it reports as unproved and says what would be needed.

**You decide what an unproved criterion means**, not the skill: stop and ask under `--auto`, or carry
it as a named residual risk when the user has already accepted it. Paste its record into the run log
and the pull-request body — it is the part a reviewer cannot reconstruct from the diff.

## Delivery

**A new commit invalidates exact-candidate evidence** — testing, acceptance, the authoritative review,
CI and the Definition of Done. Re-earn those on the new SHA. It does not erase findings already read
or require restarting every advisory review from zero.

1. **Push and open the PR.** Its head is the candidate SHA from here on. The working tree must be
   clean at that commit: a candidate with uncommitted changes is a review of something nobody can
   fetch.
2. **Run each applicable advisory review at most once.** Run `mattpocock-skills:code-review` on the
   first clean candidate, address its valid findings, then classify the resulting candidate. Add
   `deep-review` only when that diff touches a sensitive surface, changes at least 15 production files
   or 500 production lines, spans repositories/services, or changes a major architectural boundary.
   Sensitive surfaces are authentication/authorization/secrets/cryptography; migrations or destructive
   data operations; public APIs, persisted schemas or cross-service contracts; money/pricing/billing;
   infrastructure/CI/deployment/release; and security-relevant input handling. Values, defaults,
   fixtures and configuration count when they decide behaviour on one of those surfaces.

   Do not stack Claude Code's built-in `/code-review` with `deep-review`. A matched deep-review trigger
   wins because the built-in review is capped; otherwise an explicitly requested built-in review may
   occupy the optional deep-review slot. Matt does not run again.

   Address valid findings **here**. Deferring one into an issue is a decision about the user's backlog
   taken on their behalf, and `.claude/rules/task-flow.md` states when it is allowed at all — the diff
   decides, and the fifth deferral stops the run to ask. Refute claims outside the spec or repository
   rules rather than promoting every possible mutation, subclass behaviour or speculative extension
   into a new requirement. An
   advisory note that explicitly reports no violation and offers only optional style or a judgement
   call is not a reason to move the candidate. After a fix, verify the affected finding and proceed
   to the authoritative review; do not fan out the advisory reviews again. They discover issues but
   are not merge gates.
3. **Obtain the authoritative `--required` approval** from `cc-codex-triage` at that exact SHA.
   Choose one task-specific `--thread <name>` and keep that name for every round and for `merge.sh`;
   the merge boundary re-runs the companion's checker against that thread in this worktree.
4. **Publish the returned verdict immediately, before editing the candidate.** Every completed
   required round gets one public record bound to the SHA it reviewed:

   Substitute the real PR number and the real candidate SHA — these are values you read from `gh` and
   `git` in this turn, not variables carried from an earlier command:

   ```bash
   gh pr review <pr> --comment --body "cc-tuner-verdict: <APPROVE|REQUEST_CHANGES> <candidate-sha>"
   ```

   Copy the verdict from the marker; never turn `REQUEST_CHANGES` into `APPROVE`. The checked merge
   script reads both the final public approval and the companion's required-review state; neither
   substitutes for the other.
5. **A published approval stands until the SHA changes.** GitHub does not overwrite reviews, so a
   finding that requires a code change needs a new commit and therefore a new candidate, at which
   point the script denies by construction because the head no longer matches. A finding that does
   *not* require a change — refuted with a concrete `file:line`, or deferred by the user — leaves the
   candidate alone: re-run the required review on the same SHA and publish its verdict. An earlier
   revision called the approval "terminal", which reads as forbidding that and would have pushed the
   flow into manufacturing an empty commit to move the SHA.
6. **On `REQUEST_CHANGES`, loop through the authoritative review only.** Validate each claim against
   the committed spec, repository rules and a concrete failure. Fix valid findings, re-run the
   affected checks and full regression, commit, then resume the required review on the new SHA. Do not
   restart Matt, `deep-review`, or the built-in review. Stop at the configured cap; resetting a capped
   thread to obtain a more favourable verdict is not part of autonomous delivery.

   A finding you refuted with a concrete `file:line`, or one the user deferred, needs no commit: the
   candidate has not changed, so re-run the required review on the same SHA. Manufacturing an empty
   commit to move the SHA would be inventing evidence, which is the opposite of the point.
7. **Check the Definition of Done from the spec** before merging. Every item, named, with what
   satisfied it — **written into the pull request**, as a comment or a section of the body, not into
   the spec file. Two reasons, and each one alone is enough: a commit here moves the head the approval
   and CI were earned on, so the merge step would refuse the candidate it just approved; and the items
   are facts about delivery — a verdict, a CI run, a merge — which live where delivery lives and can be
   read by someone with no checkout.
8. **Merge, with the strategy the spec names** — `squash` or `merge`, not a default chosen here — and
   pin the head:

   Pass the strategy **and the CI mode** the spec's `ci:` field names — both are values it declared,
   not defaults chosen here. Omit `--ci` when that mode is `required`, and read a spec that names
   checks without naming a mode as `required`: that is what every spec written before the field had
   modes meant:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" [--ci <mode>] <pr> <squash|merge> <candidate-sha> <review-thread>
   ```

   Under `ci: none` the waiver is not enough on its own: a comment on the pull request has to record
   what stood in for CI, naming this exact commit, or the script refuses.

   ```bash
   gh pr comment <pr> --body "cc-tuner-local-ci: <candidate-sha> <the command that ran, and what it returned>"
   ```

   A comment, not the description: `gh pr edit --body` replaces the body, so the one-line way to add
   this to the description deletes the description.

   Be honest about what that is. It is an **attributable claim, not a check**: you write it, nothing
   re-runs it, and it does not make `none` equivalent to CI. It is required because in a repository
   whose policy is to report no checks, "no checks reported" is satisfied by that policy, so a merge
   with nothing written down leaves an auditor nothing at all. Write the real command and the real
   result — a placeholder satisfies the grammar and is a lie on the permanent record.

   If the spec declares `none` and checks turn out to exist, the spec is wrong about the repository:
   fix the spec, do not drop the flag. The script refuses that combination anyway.

   It re-runs the companion's exact-candidate check, re-reads the public verdict, required checks and
   head, and pins the head, so nothing here has to be carried forward correctly. Do not replace it with a raw `gh pr merge`:
   arbitrary shell and web/API merges are outside the boundary this local workflow can enforce.

   The script refuses a merge without the pin: the head can move between the check and the merge,
   and only GitHub can close that window.
9. **Reconcile after the merge**, as the spec requires: sync the target, delete the branch, close the
   issue. Do not commit to the integration target to record anything: `.claude/rules/task-flow.md`
   forbids a direct commit there, and the Definition of Done was already recorded on the pull request
   in step 7, which is where a reader looks for it.

## When the checked merge path denies

Its reason names the missing fact. Fix the fact. Do not route around it: the script is the checked
delivery path, while raw CLI, web/API merge and direct pushes are explicitly outside its coverage.
