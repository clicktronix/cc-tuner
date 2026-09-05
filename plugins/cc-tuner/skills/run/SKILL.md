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

If the task tools are there and `TaskList` is empty, publish the plan's slices — two passes,
`TaskCreate` then `TaskUpdate addBlockedBy`. A fresh session's `SessionStart` context already asks for
this. If they are not there, skip this and say so once; the run proceeds either way.

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
  `- [ ]` to `- [x]` in the plan file and commit. The task list does not survive the session; the file does.
  A ticked file with no matching task is recoverable, a completed task with an unticked file is lost.
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

## Where the work happens

Which slices may run at once, and which workspace each method belongs in, are in
[`references/placement.md`](references/placement.md). Read it before fanning out or before invoking
`prototype`, `research`, `domain-modeling` or `diagnosing-bugs`.

## Delegating a slice, and why the plan makes it possible

You are the orchestrator. Implementation of a slice may be handed to a subagent dispatched with the
Agent tool; the decisions may not. That split is not a preference — a subagent starts with none of
this session's context, so it can be handed a job but cannot be handed a judgement.

**Delegate when the slice is worth its brief.** A subagent costs one written brief and buys back a
context window and, on a cheaper model, most of the tokens. That trade wins for a slice with real
implementation work in it and loses for a two-line edit you could make while writing the delegation.
Under `--auto`, prefer delegating: your own context is the scarce resource across a long plan.

**The brief is written from the files, never from this conversation.** Everything a unit needs is
already committed, which is what makes delegation cheap here:

- the **spec path**, and the instruction to read it — target branch, test plan, DoD live there;
- the **slice verbatim** from the plan: title, Owned paths, Deciding check, Delivers, criteria;
- the repository's instruction files, which a subagent loads on its own (`CLAUDE.md` hierarchy);
- the standing constraints below.

Never write "as we discussed" or refer to a finding from earlier in this session. The unit cannot see
it, and a brief that assumes otherwise produces work that misses the point in a way that reads as
disobedience.

**Constraints every implementation brief carries, stated in it:**

- write only inside the slice's Owned paths;
- make the deciding check pass, having first seen it fail, and say which command showed each;
- commit in this repository's convention; do not push, do not open or comment on a pull request, do
  not merge, and do not claim any review or approval;
- report back: what changed, the commands run with their results, and anything the slice's text turned
  out to be wrong about.

**Model.** Dispatch implementers on `sonnet` — that is where the token saving is, and a slice whose
brief is complete does not need more. Keep `opus` (your own model) for what you do not delegate.
Escalate rather than retry blindly: if a unit comes back failing the same deciding check twice,
re-dispatch once on a more capable model with the failure attached, and if that fails, take the slice
yourself. Three cheap attempts cost more than one expensive one.

**Parallel batches.** `ready-batches` decides which slices may run at once; when it returns more than
one, dispatch them **in a single message** so they run concurrently, and give each unit
`isolation: "worktree"` — proven-disjoint Owned paths still share one index and one checkout, and two
units committing in the same worktree interleave into commits neither of them wrote. Take their
commits into this branch yourself.

**What never leaves you.** Reading `mutate.sh` output; deciding a slice is done; the full regression
before the candidate; the review verdict; the Definition of Done; and everything under Delivery. A
unit reports; you decide. Where the native task tools are present, you own the task list too — a
subagent's status updates are not the plan's state.

**Verify what comes back, against the tree and not against the report.** Read the unit's diff, run the
deciding check yourself, and confirm it touched nothing outside its Owned paths. A unit's summary is a
claim about work you can inspect in one command, and the whole point of the RED-to-GREEN discipline
below is that a claim is not evidence.


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
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" <file> "<test command>" "<command that edits \$MUTATE_FILE>"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutate.sh" --help   # the verdicts, the exit codes, the refusals
  ```

  It grades the mutation instead of taking your account of it, and it refuses rather than guessing —
  `--help` is the contract, and it cannot drift from the code the way a paragraph here can.

  **Paste its lines into the run log; do not retype them.** Live runs reported a mutant SURVIVED that
  a quoting bug never applied, and one "corrected" a right number into a wrong one because a
  hand-rolled harness leaked state between mutants. A mutation result you typed yourself is a claim
  about a claim.
- **Run what the spec's test plan names** — its targeted checks during the slice, its full regression
  once before the candidate.
- **Re-check `[eyes]` as a second fail-safe.** A conforming spec already makes unresolved human-only
  acceptance set `auto_ready: no`; if a stale or hand-edited plan still reaches this point under
  `--auto`, stop and ask. A waiver is the user's to give, recorded with who and when.

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

   Address valid findings. Refute claims outside the spec or repository rules rather than promoting
   every possible mutation, subclass behaviour or speculative extension into a new requirement. An
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
   satisfied it. Then **tick the spec's own boxes and commit it** — its acceptance criteria and its
   Definition of Done, in the same commit, with the candidate's SHA in the message.

   Two files record the same completion, and the plan is ticked slice by slice while the spec is not
   ticked at all until here. Left implicit, that reads as a spec whose every criterion failed while
   the plan says everything passed; the boxes then disagree in the permanent record and the reader has
   no way to tell which one went stale. Ticking the spec at the one moment its DoD is actually
   established is what keeps the two consistent.
8. **Merge, with the strategy the spec names** — `squash` or `merge`, not a default chosen here — and
   pin the head:

   Pass the strategy **and the CI mode** the spec names — both are values it declared, not defaults
   chosen here. Omit `--ci` only when the spec's `ci:` mode is `required`:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" [--ci <mode>] <pr> <squash|merge> <candidate-sha> <review-thread>
   ```

   `--ci any` widens the question to every check reported on the head, for a repository that runs CI
   without branch protection. `--ci 'none:<reason>'` is a recorded waiver for a repository that runs no
   CI on a pull request; the script honours it only while GitHub reports no checks at all, so it can
   never outrank a red or a pending one. If the spec says `none` and checks turn out to exist, that is
   the spec being wrong about the repository — fix the spec, do not drop the flag.

   It re-runs the companion's exact-candidate check, re-reads the public verdict, required checks and
   head, and pins the head, so nothing here has to be carried forward correctly. Do not replace it with a raw `gh pr merge`:
   arbitrary shell and web/API merges are outside the boundary this local workflow can enforce.

   The script refuses a merge without the pin: the head can move between the check and the merge,
   and only GitHub can close that window.
9. **Reconcile after the merge**, as the spec requires: sync the target, delete the branch, close the
   issue.

## When the checked merge path denies

Its reason names the missing fact. Fix the fact. Do not route around it: the script is the checked
delivery path, while raw CLI, web/API merge and direct pushes are explicitly outside its coverage.
