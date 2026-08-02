---
description: Execute a committed spec end to end — implement, verify, review, open a PR, observe CI, and merge. Without --auto, stop at every phase boundary; with --auto, continue through merge only when the spec is auto-ready and every gate is green.
argument-hint: '[--auto] <path-to-spec>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, SlashCommand, TodoWrite, AskUserQuestion, WebFetch, WebSearch, mcp__chrome-devtools
disable-model-invocation: true
---

# /cc-tuner:run

Execute the committed spec named in `$ARGUMENTS`. `--auto` anywhere selects unattended mode; the
remaining argument is the spec path. No path means stop. Do not reconstruct a missing spec from chat.

Invoking `/run --auto` authorizes the task-scoped branch commit, push, PR creation/update, and merge to
the spec's target after green CI. It never authorizes deploy, publish, migration, force-push, or work
outside the spec. Without `--auto`, each phase boundary below is a hard confirmation point.

## Phase protocol

At the top of every phase after Phase 0, before any other action:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

At its end, append literal values a later phase would otherwise re-derive: spec path, branch, target
SHA, PR number, per-criterion result, and any skip/defer reason.

**HITL boundary:** when `--auto` is absent, report the completed phase and exact next phase, then stop
until the user says to continue. Do not re-litigate the spec. When `--auto` is present, continue without
asking unless a hard stop fires.

## Phase 0 — open the run

1. Run the companion-plugin check:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh"
   ```
2. Read the spec and fill only blank stable-command fields from `.claude/execute-task.md`. The spec wins
   on every field it supplies.
3. Resolve its literal `branch`, `target`, and `auto_ready`. Confirm the current branch equals `branch`,
   is not `target`, and has no already-merged PR. A legacy spec without `branch` may continue only after
   deriving and journaling the task branch unambiguously; never create a second branch blindly.
4. Refuse `--auto` unless `auto_ready: yes`, `ci` is nonblank, the scope is one PR, and every `[eyes]`
   item has a machine replacement or waiver. `auto_ready: no` is authoritative even if the other checks
   appear satisfiable.
5. Open the journal on a clean tree:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/preflight.sh" <literal-run-id> <target>
   ```
   Exit 2 is terminal. An unattended run never absorbs unrelated work.
6. Journal the spec path, full Run config, acceptance criteria verbatim, branch, target, base SHA, and
   the card's prior Status; move the card to In Progress when configured.

Apply the HITL boundary.

## Phase 1 — implement

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

The spec's Tasks list is the scope. Decompose by independently verifiable units and pick
reasoning effort from `${CLAUDE_PLUGIN_ROOT}/assets/tiering/tiering.md`. Independent units may run in
isolated worktrees; dependent ones run in order. Before accepting a delegated unit, read its complete
diff, run the scoped cheap gate, and check its acceptance criteria.

Anything outside Tasks is a finding: journal it and continue within scope. Never expand an unattended
run. Journal each accepted unit, then apply the HITL boundary.

## Phase 2 — cheap gate

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

Run `cheap_gate`. A task-introduced failure is terminal until fixed. Establish an alleged
pre-existing failure against the task base before classifying it. After formatter or `--fix`, read its
diff and re-run both typecheck and lint. Journal exact commands and results, then apply the HITL boundary.

## Phase 3 — acceptance

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

Drive every `[machine]` criterion by its named command or browser step and run the spec's
full `test` once as the regression net. Resolve `[eyes]` exactly as recorded:

- machine replacement → drive it;
- dated waiver → journal it;
- neither → stop in every mode.

Journal each criterion independently, then apply the HITL boundary.

## Phase 4 — review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

Read `${CLAUDE_PLUGIN_ROOT}/assets/tiering/tiering.md` rather than recalling its
sensitive-surface list.

- Run built-in `/code-review` at `xhigh` unless the complete diff is both ≤50 changed lines, ≤5 files,
  and confidently non-sensitive.
- Run `/mattpocock-skills:code-review` and cc-codex-triage `/review` to APPROVE.
- Validate every finding against live code. Record it as fixed, refuted with `file:line`, or deferred to
  a board issue.

After review fixes, re-run the cheap gate and affected acceptance paths. Journal the final review state,
then apply the HITL boundary.

## Phase 5 — reconcile

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

Tick the spec's Tasks and criteria, record shipped versus deferred scope, and move a
completed spec to `<plans-root>/ARCHIVE/PLANS/` in this branch. Re-run required local checks against the
final tree. Apply the HITL boundary; in HITL mode the user's continuation authorizes Phase 6's named
commit/push/PR actions, not merge.

## Phase 6 — commit, push, and open the PR

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

1. Inspect `git status --porcelain -uall` and the complete diff. Stage only explicit task paths; never
   `git add -A` or `git add .`:
   ```bash
   git add -- <path-1> <path-2>
   git diff --cached --check
   ```
2. Run the artifact guard after staging and before commit:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh" <literal-run-id>
   ```
3. Inspect the staged diff, commit with a Conventional Commit, and verify the worktree contains no
   unexplained files:
   ```bash
   git diff --cached
   git commit -m "<type>: <imperative summary>"
   ```
4. Push the task branch with tracking. Find its open PR or create one with the spec goal, issue link,
   scope summary, verification commands, and remaining limitations. Capture and journal the literal PR
   number and pushed HEAD SHA:
   ```bash
   git push -u origin <literal-branch>
   gh pr view --json number,url,headRefOid || gh pr create --body-file <prepared-body-file>
   ```
5. Verify the remote PR head equals that SHA. Run/observe the spec's `ci` against that SHA. A missing,
   skipped, stale, or red required check is not green.

In HITL mode, show the PR and CI state and stop before merge. In `--auto`, continue only after all
required checks on the journaled SHA are green.

## Phase 7 — merge and clean up

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" resume <literal-run-id>
```

Re-run the artifact guard, verify the PR still targets the spec's target, the remote head
still equals the reviewed SHA, required CI is green on that SHA, and no unresolved acceptance/review item
remains.

- `--auto`: merge with the spec's method without asking.
- HITL: require a separate explicit merge confirmation.

Confirm the PR state is actually `MERGED`; an enqueued merge is not complete. Then sync the card only
when possible: `Closes`/`Fixes` → Done, `Refs` → remain In Progress. Board failures after merge are
journaled, not terminal.

Finally switch to the literal target branch, `git pull --ff-only`, remove only the merged branch's clean
worktree, prune, and delete merged local/remote-tracking refs according to task-flow. Never hard-code
`main` when the spec names another target.

## What `--auto` never waives

- Red cheap gate, acceptance check, full test, review, or required CI.
- Bare `[eyes]` criteria or `auto_ready: no`.
- Scope beyond the spec.
- Deploy, publish, data migration, or any outward action after merge.
- Force-push, `--no-verify`, broad staging, unsafe amend, or commit to the target branch.

## Verification

- [ ] Journal resumed at every phase and stores literal branch/SHA/PR values
- [ ] HITL stopped after phases 0–5 and again before merge
- [ ] `--auto` was refused unless the spec explicitly said `auto_ready: yes`
- [ ] Every acceptance criterion was driven by its named check
- [ ] Review findings were fixed, evidenced as false, or filed
- [ ] Guard ran after explicit staging and again before merge
- [ ] Commit, push, PR, and CI were completed in that order
- [ ] CI and merge were verified on the current pushed SHA
- [ ] Completed spec, board state, target branch, and worktrees were reconciled
