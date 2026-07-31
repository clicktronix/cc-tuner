---
description: Execute a spec end to end — branch, implement, review, CI, merge. Without --auto it stops between phases for you; with --auto it runs unattended and merges on green CI. Use for "выполни спеку", "run this spec", "ship it".
argument-hint: '[--auto] <path-to-spec>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, SlashCommand, TodoWrite, AskUserQuestion, WebFetch, WebSearch, mcp__chrome-devtools
disable-model-invocation: true
---

# /cc-tuner:run

Takes a spec from `/cc-tuner:spec` and executes it. Everything worth asking was asked when the spec
was written; this command does not re-litigate it.

Parse `$ARGUMENTS`: `--auto` anywhere means unattended, and the rest is the spec path. **No spec path →
stop and say so.** Do not invent a spec from the conversation: an unattended run against an imagined
spec is the worst outcome available here.

## The one rule that makes this work

**Read the journal at the top of every phase, before doing anything else.**

```bash
# Substitute the literal run-id — NOT $RUN_ID. A shell variable set in phase 0 is gone by
# phase 1: every Bash call is a fresh shell. This snippet failing with "run-id required" is
# the same class of bug this whole mechanism exists to fix, so use the literal.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

This is not bookkeeping. Your context will be compacted mid-run; when it is, this command file comes
back (it is re-read) but everything you learned about *where you got to* does not. The journal is the
only thing that survives, and it survives only if you read it. An unread journal is why the previous
version of this command lost its place and started over or stalled.

Each phase below opens with that command, spelled out, for exactly that reason: one statement of
the rule up here loses to a hundred lines of intervening instruction.

So: `resume` at the top of each phase, `append` at the end of it, and append anything a later phase
would otherwise have to re-derive — the PR number, the base SHA, which acceptance criteria already
passed, what you deliberately skipped and why. Write the literal values, never "the number from
before": shell state does not survive between Bash calls either.

## Phase 0 — open the run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh" || exit 1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/preflight.sh" <run-id> <target-branch>   # run-id = the spec slug
```

`prereq-check.sh` failing is terminal — the review phases need those plugins. `preflight.sh` exits 2 on
a dirty tree, which is also terminal: an unattended run must not commit someone else's work in progress.

Read the spec. Journal its path, the acceptance criteria verbatim, and the run config. Where the spec's
**Run config** leaves a field blank, fall back to `.claude/execute-task.md` if the repo has one (the
repo-level defaults for `ci` / `cheap_gate` / `test`); the spec always wins where both specify. **Refuse to
start `--auto` when the spec is not auto-ready**: a bare `[eyes]` criterion, a blank `ci`, or work
spanning more than one PR. Say which, and offer the HITL run instead. Do not silently degrade `--auto`
into something that will stop halfway.

Then create the branch per the task-flow invariants and move the card to In Progress, journaling its
prior Status first.

## Phase 1 — implement

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

Fork per unit of work rather than holding all of it in one context. Independent units go wide with
worktree isolation; dependent ones go in order. Journal each unit as it lands.

Pick each unit's **reasoning effort** per `${CLAUDE_PLUGIN_ROOT}/assets/tiering/tiering.md` (Read it —
it is also the source of the sensitive-surface list phase 4 needs). Mechanical typing runs `low`,
ordinary module work `medium`, anything with the approach still undecided `high`; a sensitive surface
is `xhigh` and you read the whole diff yourself regardless. When torn between two tiers take the
higher one. Every delegated unit passes that file's verification contract — full diff read, cheap
gate, acceptance check — before you accept it.

The spec's Tasks list is the scope. Something outside it that looks necessary is a **finding, not a
licence**: journal it, finish the spec's scope, and raise it at the end. In `--auto` that is the whole
protocol — an unattended run that expands its own scope is the failure mode that makes autonomy
untrustworthy.

## Phase 2 — cheap gate

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

Run the spec's `cheap_gate` (types, lint, unit). Red is a hard stop in every mode — fix before going
on. Do not proceed with a red gate on the theory that a later phase will catch it.

After any formatter or `--fix` run, re-run **typecheck and lint**, and read the diff it produced. The
fixer's own clean report is not evidence; this is a documented build break, not a hypothetical.

## Phase 3 — acceptance

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

Drive every `[machine]` criterion for real, by the exact check the spec names. Running the test suite
is not the same as verifying the criteria, and a criterion you did not drive is a criterion you cannot
tick.

`[eyes]` criteria resolve three ways, per what the spec recorded — this must match the never-waives
list below, so read it as one rule stated twice:

- **machine replacement stated** → drive the replacement check. It is a `[machine]` criterion wearing
  an `[eyes]` label; treat it as one.
- **waiver recorded** → journal it as waived, with the date and who waived it, and continue.
- **neither** → hard stop in every mode, `--auto` included. Stop, show what you have, say what needs
  looking at. A spec should never reach `/run` in this state; phase 0 refuses `--auto` for it.

Also run the spec's `test` (the full suite) once here. The per-criterion checks are the acceptance
bar; `test` is the regression net for everything the spec did not think to name.

Journal each criterion's result individually. After a compaction this is the only record of which ones
already passed, and re-driving all of them is expensive.

## Phase 4 — review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

- **Built-in `/code-review`** at `xhigh`, and **`/mattpocock-skills:code-review`**. Skip the built-in
  only for a diff that is both small (≤ 50 changed lines, ≤ 5 files) and touches none of the sensitive
  surfaces in `${CLAUDE_PLUGIN_ROOT}/assets/tiering/tiering.md` — Read it rather than recalling it.
  **Fail closed:** if you cannot compute the diff size, or cannot confirm a surface is non-sensitive,
  run the review. Skipping needs positive confirmation of both.
- **cc-codex-triage `/review`** to APPROVE.

Validate every finding before acting: confirm it against the code, and refute the wrong ones with
`file:line`. A review comment is a claim, not a verdict — accepting a wrong one costs a real change to
working code.

Journal each finding as confirmed-and-fixed, refuted-with-evidence, or deferred-to-an-issue. One
deferred finding is one issue on the board, never a buried comment thread.

### Re-verify after fixing

If the fixes from this phase touched behaviour or frontend code, **re-drive the affected acceptance
criteria and re-run the cheap gate**. The criteria were verified against code that has since changed
under them; CI at phase 6 is a coarser net and runs later. This is the same rule as re-running
typecheck after `--fix`, applied to review fixes.

## Phase 5 — reconcile

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

Tick the spec's criteria and tasks. Journal shipped versus deferred. If the spec is complete, move it
to `<plans-root>/ARCHIVE/PLANS/` **in this branch** — plan archival rides the PR that completes the
work, never a standalone doc PR.

## Phase 6 — land

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <run-id>
```

1. Capture the PR number **while still on the feature branch** and journal the literal value:
   `gh pr view --json number --jq .number`. After a `--delete-branch` merge you are on the base branch
   where an argument-less `gh pr view` has nothing to resolve.
2. Run the artifact guard against the merge target:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh" <merge-target>
   ```
   Exit 3 means operational artifacts are staged or hiding in branch history — unstage them.
3. CI must be green. Red is terminal in every mode.
4. Merge: `--auto` merges on green CI without asking. Without `--auto`, stop for confirmation.
5. Confirm the PR actually reads `MERGED` (`gh pr merge` can enqueue without merging), then sync the
   card: `Closes`/`Fixes` → Done; `Refs` → leave In Progress and journal the follow-up.
   **Board and PR-lookup failures are journaled, never terminal** — they cannot un-merge anything, and
   an `--auto` run must not report failure because `gh` hiccuped after the merge landed.
6. Clean up per the task-flow skill: `git switch main && git pull --ff-only`, remove the merged
   branch's worktree, prune, delete merged branches.

## What `--auto` never waives

- A red `cheap_gate`, a red CI, or a failing acceptance criterion.
- An `[eyes]` criterion without a recorded waiver.
- **Anything outward-facing beyond the merge** — a deploy, a publish, a data migration. `--auto` covers
  merging to the default branch on green CI. It does not cover shipping to users. If the spec's config
  asks for a deploy, stop before it, show the exact change, classify the side effect, and state the
  rollback path.
- Expanding scope past the spec.
- Force-push, `--no-verify`, `git add -A`, `--amend` after a hook rejection, committing to `main`.

## When the run ends

Report against the spec: which criteria passed and how they were checked, what was deferred and where
it is tracked, what you skipped and why. Link the CI run rather than pasting its output.

If the run stopped early, say where and what unblocks it. The journal path is part of the report —
`journal.sh read <run-id>` is how the next session picks this up without starting over.

## Verification

- [ ] `journal.sh resume` ran at the top of every phase
- [ ] PR number, base SHA and per-criterion results journaled as literal values
- [ ] `--auto` refused up front on a spec that was not auto-ready, rather than stopping mid-run
- [ ] Every `[machine]` criterion driven by the check the spec names, not inferred from a green suite
- [ ] Review findings each confirmed, refuted with `file:line`, or filed as an issue
- [ ] Nothing implemented outside the spec's Tasks; extras journaled as findings
- [ ] Spec archived in the same PR if this completed it
