---
name: run
description: Work this branch's committed plan to a merged PR — frontier order, ticked checkboxes, a candidate SHA, a verdict review bound to it, green CI, and a merge that pins the head.
argument-hint: '[--auto] <path-to-spec>'
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, mcp__context7
---

# /cc-tuner:run

Work the plan for the current branch. `--auto` anywhere selects unattended mode; the remaining
argument is the spec path.

`--auto` authorises task-scoped commit, push, PR creation and merge. It never authorises deploy,
publish, migration, force-push, or work outside the plan.

## Before starting

**Read the spec named in `$ARGUMENTS`.** No path, or no such file → stop. It is not decoration: the
spec carries the target branch, the merge strategy, `auto_ready`, the test plan, the acceptance
criteria and the Definition of Done. Everything below that says "as the spec requires" reads it from
there, and a run that never opened it is a run following defaults nobody chose.

If `auto_ready` is not `yes`, `--auto` is refused — say which unmet condition blocks it.

Then ask for the plan path and read it out of the output — a shell variable does not survive to the
next tool call, so every command below names the file literally:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" resolve
```

`resolve` fails when the branch has no committed plan, or more than one. Either way, stop: run
`/cc-tuner:plan` first. Never work from a plan that exists only in the conversation.

**Check that the plan is this spec's plan.** Its header carries `**Spec:**` and `**Branch:**`. If the
spec path you were given is not the one the plan names, stop and say so: `/run` takes a spec argument
while the plan is found from the branch, so nothing else stops plan A being worked with spec B's
target, tests, Definition of Done and merge strategy.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check <the path resolve printed>
```

If `TaskList` is empty, publish the plan's slices first — two passes, `TaskCreate` then
`TaskUpdate addBlockedBy`. A fresh session's `SessionStart` context already asks for this.

## The loop

Take the lowest-numbered task that is `pending` with an empty `blockedBy`. Work it. Complete it.
`TaskList` again.

Three things this adds to the obvious:

- **Tick the plan file and commit it.** When every acceptance criterion of a slice is met, change its
  `- [ ]` to `- [x]` in the plan file and commit. The task list does not survive the session; the file does.
  A ticked file with no matching task is recoverable, a completed task with an unticked file is lost.
- **Under `--auto`, refuse a task whose `blockedBy` is not empty.** The platform stores the edge and
  does not enforce it: `TaskUpdate` will move a blocked task to `in_progress` without complaint. Under
  attention that is a visible mistake; unattended nobody is watching.
- **Without `--auto`, stop at each delivery boundary** — first commit, PR opened, review returned,
  before merge. Report what is done and what comes next.

## Parallelism, only where it is safe

Fan out **only across independent code-writing units**, one isolated git worktree each. Never
parallelise review, a testing decision, or any step of delivery: those read a state that the other
branch is still changing, and two answers about one candidate is not twice the confidence.

Two slices are independent when their `Owned paths` do not overlap. If they do, they are one unit.

## Where each method runs

Ordering, not overrides. cc-tuner never rewrites another plugin's skill; it decides when each runs.
The axis is what a method **persists**, not whether it feels exploratory.

| method | workspace |
|---|---|
| `research`, `domain-modeling` | the task branch — their output is committed, and a saved artifact is a write |
| `prototype` | a disposable branch or worktree — its output is throwaway by definition, and landing it on the task branch is how a spike becomes the implementation by accident |
| `tdd` | the task branch, around the slice's deciding check |
| `diagnosing-bugs`, reading | the task branch |
| `diagnosing-bugs`, probe edits | a disposable workspace — instrumentation and bisect stubs are experiments, and an experiment that lands is a regression waiting |
| `code-review`, deep-review | the candidate SHA |

`/cc-tuner:spec` created the task branch before any of this, because its own grilling phase writes
`CONTEXT.md` and ADRs.

## Proving a slice, before it counts as done

A slice is done when its acceptance criteria hold **and** you can show why you believe it. An earlier
revision of this skill said only "work it, complete it", which is not a discipline — it is a hope.

- **RED before GREEN.** Write the failing check first and run it; record the failure. A check that
  was never seen failing has not been shown to test anything.
- **Prove the guard by removing it.** Revert the behaviour the check guards and confirm the check
  goes RED. Copy the file first (`cp x x.premutation`), never `git checkout --`. Run `bash -n` on the
  mutant: a mutation that breaks the syntax proves only that broken files fail.
- **Run what the spec's test plan names** — its targeted checks during the slice, its full regression
  once before the candidate.
- **A human-only acceptance criterion (`[eyes]`) is not self-servable.** Under `--auto`, stop and ask.
  A waiver is the user's to give, recorded with who and when.

## Delivery

**A new commit invalidates everything downstream of it** — testing, acceptance, review, CI and the
Definition of Done. After any fix, the candidate is a new SHA and every one of them is re-earned. This
is the rule the original complaint was about: one review round then a `REQUEST_CHANGES` left standing.

1. **Push and open the PR.** Its head is the candidate SHA from here on. The working tree must be
   clean at that commit: a candidate with uncommitted changes is a review of something nobody can
   fetch.
2. **Review that SHA.** deep-review and `mattpocock-skills:code-review` run and must be addressed.
   They are mandatory steps, not gates — they have no durable, unforgeable home, and counting the
   author's own word twice would not make it evidence.
3. **Obtain the authoritative `--required` approval** from `cc-codex-triage` at that exact SHA.
4. **Publish the verdict**, and only what the marker actually says:

   Substitute the real PR number and the real candidate SHA — these are values you read from `gh` and
   `git` in this turn, not variables carried from an earlier command:

   ```bash
   gh pr review <pr> --comment --body "cc-tuner-verdict: APPROVE <candidate-sha>"
   ```

   On `REQUEST_CHANGES`, publish that instead. Never publish `APPROVE` for a review that did not
   approve — the guard reads this and nothing else.
5. **A published approval stands until the SHA changes.** GitHub does not overwrite reviews, so a
   finding that requires a code change needs a new commit and therefore a new candidate, at which
   point the guard denies by construction because the head no longer matches. A finding that does
   *not* require a change — refuted with a concrete `file:line`, or deferred by the user — leaves the
   candidate alone: re-run the required review on the same SHA and publish its verdict. An earlier
   revision called the approval "terminal", which reads as forbidding that and would have pushed the
   flow into manufacturing an empty commit to move the SHA.
6. **On `REQUEST_CHANGES`, loop.** Fix, re-run the slice's checks and the full regression, commit —
   which makes a new candidate SHA — then review that SHA and publish its verdict. Repeat until it
   approves. Stopping at one round with `REQUEST_CHANGES` standing is not a finished review, and is
   precisely what shipped before.

   A finding you refuted with a concrete `file:line`, or one the user deferred, needs no commit: the
   candidate has not changed, so re-run the required review on the same SHA. Manufacturing an empty
   commit to move the SHA would be inventing evidence, which is the opposite of the point.
7. **Check the Definition of Done from the spec** before merging. Every item, named, with what
   satisfied it.
8. **Merge, with the strategy the spec names** — `squash` or `merge`, not a default chosen here — and
   pin the head:

   Pass the strategy the spec names:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" <pr> <squash|merge|rebase> <candidate-sha>
   ```

   It re-reads the verdict, the required checks and the head from GitHub itself and pins the head, so
   nothing here has to be carried forward correctly. A raw `gh pr merge` is refused by the hook.

   The guard refuses a merge without the pin: the head can move between the check and the merge, and
   only GitHub can close that window.
9. **Reconcile after the merge**, as the spec requires: sync the target, delete the branch, close the
   issue.

## When the guard denies

Its reason names the missing fact. Fix the fact. Do not route around it — the guard is the only gate
in this plugin, and `gh pr merge` is already not the only way to merge.
