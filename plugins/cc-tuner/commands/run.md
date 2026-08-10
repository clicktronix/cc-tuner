---
description: Execute a committed spec end to end — publish a visible plan, implement, prove tests, review an immutable candidate, open a PR, verify current-SHA CI, and merge only after DoD. Without --auto, stop at each delivery boundary.
argument-hint: '[--auto] <path-to-spec>'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent, TaskCreate, TaskUpdate, TaskList, TaskGet, Skill, AskUserQuestion, WebFetch, WebSearch, mcp__chrome-devtools
disable-model-invocation: true
---

# /cc-tuner:run

Execute the committed spec named in `$ARGUMENTS`. `--auto` anywhere selects unattended mode; the
remaining argument is the spec path. No path means stop. Never reconstruct a missing spec from chat.

`/run --auto` authorizes task-scoped commit, push, PR creation/update, and merge to the spec's target
after every gate passes. It never authorizes deploy, publish, migration, force-push, or work outside
the spec. Without `--auto`, stop at the boundaries named below.

## State and phase protocol

`${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh` is the source of truth. The Markdown journal is
an append-only narrative for humans; journal prose, plan checkboxes, and a review invocation are never
proof that a gate passed.

All executable examples below consume pre-resolved shell variables (`RUN_ID`, `PHASE`, `TASK_ID`,
`BRANCH`, `TARGET`, `SPEC_PATH`, `CANDIDATE_SHA`, and prepared-file paths). Treat values read from a
spec, issue, Git, or reviewer as data: pass them as quoted arguments and never paste them into shell
source. Angle brackets appear only inside heredoc bodies, where they mark prose you replace before
sending — never inside a command line. Validate the run/task IDs with the state CLI, the spec path
through `runctl init`, and both refs with `git check-ref-format` before the first state-changing
command. A value that cannot be carried through a quoted variable, stdin, or a file is a hard stop.

**Prepared files.** `$COMMIT_MESSAGE_FILE` and `$PR_BODY_FILE` carry free-form text that must not
reach a shell. Write them **during Phase 2, outside the repository worktree** — `$TMPDIR` or the
session scratch directory. Two reasons: after implementation completes the mutation hook denies
`Write`/`Edit` in every later phase, and a stray untracked file inside the worktree fails the clean
tree the candidate requires. Recreate them from state after a resume; they are scratch, not evidence.

At the top of every phase after Phase 0, before any other action:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" resume "$RUN_ID"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" phase "$RUN_ID" enter "$PHASE"
```

Call `enter` only when resume shows the preceding phase completed. A `phase fix` transition already
returns state to `implementation/in_progress`; when repeating Phase 2, resume it without entering it a
second time.

Record state evidence and complete the phase only after its actual gate succeeds. Append narrative
through stdin with a quoted heredoc so shell syntax in evidence is data, never executable text:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" task "$RUN_ID" start "$TASK_ID"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" task "$RUN_ID" complete "$TASK_ID" <<'CC_TUNER_TASK_EVIDENCE'
<exact diff/check/acceptance evidence for this task>
CC_TUNER_TASK_EVIDENCE
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" gate "$RUN_ID" record "$GATE_ID" pass <<'CC_TUNER_GATE_EVIDENCE'
<exact command and result evidence for this gate>
CC_TUNER_GATE_EVIDENCE
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" phase "$RUN_ID" complete "$PHASE"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/journal.sh" append "$RUN_ID" <<'CC_TUNER_EVIDENCE'
<verbatim phase evidence, including literal branch/SHA/PR/check values>
CC_TUNER_EVIDENCE
```

Never pass journal/review/test text through `eval`, `bash -c`, command substitution, or a
double-quoted positional argument.

**HITL boundary:** without `--auto`, report completed evidence and the exact next phase, then stop at
the end of Phases 1–7; the stop at the end of Phase 7 is the merge confirmation and is never skipped.
With `--auto`, continue unless a hard stop fires — including through Phase 8, which merges without
asking once `can-merge` succeeds. Phase 0 flows directly into Phase 1 so the user sees the execution
plan on the initial run.

## Phase 0 — open the run and verify DoR

1. Derive one stable run ID from the spec slug using lowercase ASCII letters, digits, `.`, `_`, and
   `-`; keep it unchanged across restarts. Run the companion-plugin check:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/prereq-check.sh"
   ```
2. Read `${CLAUDE_PLUGIN_ROOT}/workflow-contract.json`, the spec, repository instructions, and
   `.claude/execute-task.md`. The spec wins; defaults may fill only blank stable-command fields.
3. Resolve literal `branch`, `target`, and `auto_ready`. Confirm the current branch equals `branch`, is
   not `target`, and has no already-merged PR. A legacy spec without a branch may continue only after
   unambiguous ownership is recorded; never create a second task branch blindly.
4. Validate the complete Definition of Ready: problem/baseline, architecture and scope, deciding
   checks for every criterion, regression test, exact first failing check and expected failure,
   targeted/full/static/runtime commands, environment/data, one-PR delivery, and current CI source.
   `not applicable` requires the spec's concrete non-code reason.
5. Refuse `--auto` unless `auto_ready: yes`, `ci`, `target_test`, and `full_test` are nonblank, the scope
   is one PR, and every `[eyes]` item has a machine replacement or dated waiver.
6. Open the owned run from a clean repository worktree, then initialize structured state:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/preflight.sh" "$RUN_ID" "$TARGET" --expected-branch "$BRANCH"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" init "$RUN_ID" --mode "$RUN_MODE" --spec "$SPEC_PATH"
   ```
   `init` opens `readiness/in_progress`. On restart, use `runctl.sh resume` instead of reinitializing.
7. Record `gate <run-id> record dor pass` through stdin with the exact DoR evidence, then run
   `phase <run-id> complete readiness`. Journal the spec, run config, acceptance, branch, target,
   base SHA, and prior board status. Move the configured card to In Progress.

Continue directly to Phase 1.

## Phase 1 — publish the execution plan

Resume state and enter `planning`. Before editing, generating, staging, or delegating any task path,
create the visible Claude task plan with `TaskCreate`.

Create one task for every independently verifiable implementation unit, followed by tasks for:

1. Testing & Code Verification;
2. acceptance evidence;
3. candidate finalization and commit;
4. deep-review, mattpocock review, and Codex approval;
5. PR plus current-SHA CI;
6. Definition of Done, merge, and reconciliation.

Create the tasks first, then set their `blockedBy` dependencies with `TaskUpdate` to reflect this
order. Capture every returned Claude task ID and bind it to structured state; descriptions go through
stdin:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" task "$RUN_ID" add "$TASK_ID" "$TASK_PHASE" --ui-task-id "$CLAUDE_TASK_ID" <<'CC_TUNER_TASK'
<scope, owned paths, acceptance slice, and deciding checks>
CC_TUNER_TASK
```

Use `TaskUpdate` and `runctl task start|complete|block` together from now on. Never substitute prose,
the spec Tasks list, or journal text for this UI plan. On resume, reconcile `TaskList` against
`runctl status`; structured state wins and missing visible tasks are recreated and rebound.

Complete `planning`, then apply the HITL boundary.

## Phase 2 — implement

Resume state and enter `implementation`. This is the only phase where agents may mutate product code
or tests. Choose effort from `${CLAUDE_PLUGIN_ROOT}/references/tiering.md` and start the relevant
visible/state task before each unit.

For a code behavior change, write the named regression test first and run the spec's first failing
check. Confirm it fails for the expected reason; a syntax/config/environment failure is not RED. For a
non-code exception, capture the alternative baseline promised by the DoR.

Parallelize only independent code-writing units:

- use one isolated git worktree per unit;
- assign exact non-overlapping paths, acceptance slice, and scoped commands;
- reserve shared contracts, schemas, migrations, generated indexes, and integration files for the
  parent unless one unit owns them exclusively;
- forbid subagents from changing lifecycle state, integrating other units, committing, pushing,
  opening PRs, reviewing, merging, or deleting worktrees.

Subagents may write their scoped tests and run scoped checks. The parent reads each complete diff,
rejects scope leakage, independently runs its scoped gate, and integrates it. The parent owns conflict
resolution and the final tree. If units overlap or one depends on another's uncommitted result, run
them sequentially.

Mark implementation tasks complete only with diff and scoped-test evidence. A newly discovered
out-of-scope problem is journaled and filed, not silently absorbed. Before leaving this mutation
phase, reconcile shipped versus deferred scope in the spec. When this branch completes it, move the
plan with `git mv` to `<plans-root>/ARCHIVE/PLANS/` and atomically update state:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" spec "$RUN_ID" relocate "$NEW_SPEC_PATH"
```

Complete `implementation` only when every implementation task and final task-path edit is complete,
then apply the HITL boundary.

## Phase 3 — Testing & Code Verification

Resume state and enter `testing`. Do not write fixes in this phase. Execute the spec's test plan:

1. prove the regression check is green and its negative/mutation proof still makes it fail when the
   fix is absent or reversed;
2. run every targeted check;
3. run the full regression command;
4. run typecheck, lint, build, generated-artifact/migration checks, and applicable runtime/browser
   verification;
5. after any formatter or `--fix`, read its complete diff and rerun both typecheck and lint;
6. inspect `git status --porcelain -uall` and the complete diff for unintended behavior or files.

Establish an alleged pre-existing failure against the task base before classifying it. If any fix is
needed, send the reason through stdin:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" phase "$RUN_ID" fix <<'CC_TUNER_FIX'
<why the candidate must change>
CC_TUNER_FIX
```

It returns exactly `FIX_TASK id=<task-id> phase=implementation`; create the matching visible task with
`TaskCreate`, bind its returned Claude task ID with `runctl task "$RUN_ID" bind-ui "$TASK_ID"
"$CLAUDE_TASK_ID"`, then return to Phase 2. A fix transition invalidates downstream evidence, and the
new task cannot start until that binding exists.

Never patch code while state still says `testing` — and this is enforced, not merely asked. Completing
implementation records the worktree content, and the testing gate refuses a tree that moved since,
whichever tool moved it. Regenerated snapshots, lockfiles, and formatter output count: they are
mutations, so either revert them or take them back through `phase fix`.

Record the gate through stdin with exact commands/results, complete `testing`, update the visible
task, and apply the HITL boundary:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" gate "$RUN_ID" record testing pass <<'CC_TUNER_TESTING'
<exact commands and results>
CC_TUNER_TESTING
```

## Phase 4 — acceptance

Resume state and enter `acceptance`. Drive every `[machine]` criterion by its named command or browser
step. Resolve `[eyes]` exactly as recorded:

- drive its machine replacement;
- journal its dated waiver;
- in HITL, present the recorded human step and stop for its result;
- in `--auto`, refuse an item with neither replacement nor waiver.

Record each criterion independently. If acceptance exposes a code fix, use `phase fix` and repeat from
Phase 2. After all criteria pass, record `gate ... acceptance pass`, complete `acceptance`, and apply
the HITL boundary.

## Phase 5 — finalize and commit the candidate

Resume state and enter `candidate`. This phase must not change the tested tree: `runctl` binds the
testing gate to its tree SHA and rejects a different candidate. Inspect status and the complete diff.
Stage only explicit task paths; never `git add -A` or `git add .`:

```bash
git add -- "${TASK_PATHS[@]}"
git diff --cached --check
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/guard-artifacts.sh" "$RUN_ID"
git diff --cached
git commit -F "$COMMIT_MESSAGE_FILE"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" candidate "$RUN_ID" record "$(git rev-parse HEAD)"
```

Require a clean worktree, capture full `HEAD` and tree SHA, then complete `candidate`. From this
point review is valid only for this immutable commit/tree. Apply the HITL boundary.

## Phase 6 — review the immutable candidate

Resume state and enter `review`. Read the complete candidate diff again, then run all three layers:

1. invoke `cc-tuner:deep-review` with the literal base, candidate SHA/tree, and spec; its lenses may
   run serially only when the candidate is within both contract small-diff thresholds and touches no
   sensitive surface, otherwise fan them out against the same immutable candidate;
2. invoke `mattpocock-skills:code-review` against the same candidate;
3. invoke the model-callable reviewer with literal state values (`base_sha`, `candidate.sha`,
   `candidate.tree_sha`, and `spec` from `runctl status`):
   ```text
   /cc-codex-triage:review --required --base <literal-base-sha> --spec <current-repo-relative-spec> --thread review-<literal-run-id> --cap 5 "Review the complete candidate against the spec using unbiased correctness, architecture, systemic, security/data, and testing/operability lenses."
   ```
   `--cap 5` is the whole thread's budget of paid dispatches, first round included — not five repair
   rounds. The command must self-verify its git-common-dir state and return
   `CC_CODEX_REQUIRED_REVIEW APPROVE` with matching `head`, `tree`, `base_sha`, and `spec_path`;
   absence of that exact marker is not approval. Pass that marker verbatim as the evidence for
   `runctl review ... record codex APPROVE`. `runctl` does not merely match the text: it resolves the
   installed cc-codex-triage and compares the marker with `review-state.sh check`, so a marker no
   reviewer plugin still holds is rejected.

   **When the reviewer hard-stops.** `CAP_REACHED` or `DIVERGED` is a terminal answer, not a slow
   `REQUEST_CHANGES`, and retrying `--required` on that thread only fails again. Report the open
   findings and the exhausted budget, then stop: in HITL wait for the user's decision, and in `--auto`
   treat it as a hard stop and block the run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" block "$RUN_ID" <<'CC_TUNER_BLOCK'
   <reviewer hard stop, the open findings, and what the user must decide>
   CC_TUNER_BLOCK
   ```

   Only after that decision may the thread be reset with `/cc-codex-triage:thread-new review-<run-id>`,
   which clears the required-review state so a fresh lifecycle can start. Never reset it to escape a
   verdict.

Do not invoke the bundled `/code-review`. Do not cap findings at ten. Validate every finding against
candidate source and record it as fixed, refuted with `file:line`, or explicitly deferred to a board
issue. A missing reviewer, partial lens, timeout, tool failure, or `REQUEST_CHANGES` is not approval.

Record each result with the literal reviewer id `deep-review`, `mattpocock`, or `codex` — `runctl`
rejects any other spelling:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" review "$RUN_ID" record "$REVIEWER" "$VERDICT" "$CANDIDATE_SHA" <<'CC_TUNER_REVIEW'
<verbatim verdict and finding disposition>
CC_TUNER_REVIEW
```

If a finding is refuted or explicitly deferred without changing the source/test tree, rerun that
reviewer against the same immutable candidate and record its fresh `APPROVE`; the earlier
`REQUEST_CHANGES` remains in `review_history`. Because the same SHA may hold both verdicts, the
later evidence must name what changed the answer — the finding, its disposition, and the `file:line`
that refutes it or the issue it was deferred to. For `codex` that re-review is machine-checked; for
`deep-review` and `mattpocock` this evidence is the only record that a second review happened at all,
so an approval that merely asserts the first verdict was wrong is not one. If a finding requires code or test changes, use
`phase fix`, create/bind its follow-up implementation task from the returned `FIX_TASK` marker, and
repeat Phases 2–6. A new commit invalidates all prior testing, acceptance, review, CI, and DoD
evidence; an older approval can never be copied forward.
Keep Codex thread metadata outside disposable review worktrees so deleting one cannot orphan the review.

Complete `review` only after all three exact-candidate approvals exist, then apply the HITL boundary.

## Phase 7 — publish the reviewed candidate and observe CI

Resume state and enter `delivery`. Verify clean `HEAD` still equals the reviewed candidate. Push that
literal branch and find or create its PR with an explicit title and prepared body:

```bash
git push -u origin "$BRANCH"
gh pr view "$BRANCH" --json number,url,headRefOid,baseRefName \
  || gh pr create --base "$TARGET" --head "$BRANCH" --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
```

Verify PR base, remote head, candidate, all three review results, and pushed SHA agree. Observe the
spec's required hosted checks on that exact SHA. Missing, skipped, stale, cancelled, billing-blocked,
or red checks are not green. `runctl` reads `gh pr checks --required`, so the proof is GitHub's
**required** checks on the PR's target branch: a repository whose branch protection requires nothing
has no hosted evidence to offer and delivery stops there — configure a required check, or the run
cannot complete. Record CI only after exact-SHA proof; this binds delivery state to the PR, and
`runctl` re-reads its head and required checks both now and at merge time:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" ci "$RUN_ID" record success "$CANDIDATE_SHA" --pr "$PR_NUMBER" <<'CC_TUNER_CI'
<the required checks observed green on this exact SHA>
CC_TUNER_CI
```

Evaluate every pre-merge Definition of Done item from source evidence, not checkboxes. Record the DoD
gate only when all are true, complete `delivery`, and require both `runctl can-advance` and
`runctl can-merge` to succeed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" gate "$RUN_ID" record dod pass --sha "$CANDIDATE_SHA" <<'CC_TUNER_DOD'
<per-item Definition of Done evidence for this candidate>
CC_TUNER_DOD
```

In every mode show the PR, candidate SHA, reviews, CI, and DoD. HITL stops here for a separate explicit
merge confirmation. `--auto` continues only when `can-merge` succeeds.

## Phase 8 — merge and reconcile

Resume state; do not re-enter or rewrite completed delivery state. Re-run the artifact guard and
`runctl can-merge`. Verify the PR is still open, still targets the literal target, and still points at
the exact candidate with green required CI and no unresolved acceptance/review item.

- `--auto`: merge with the spec's method without asking.
- HITL: the user's explicit continuation after Phase 7 authorizes this merge only.

Pass both the recorded PR number and candidate SHA to GitHub's atomic head guard; choose the literal
`--squash` or `--merge` flag from the spec:

```bash
gh pr merge "$PR_NUMBER" --squash --match-head-commit "$CANDIDATE_SHA"
```

If the remote head moves after the last live check, GitHub must reject the merge rather than merge
unreviewed code.

Confirm the PR state is actually `MERGED`; an enqueued merge is not complete. Synchronize the issue
and board: `Closes`/`Fixes` → Done; partial `Refs` → remain In Progress. Board failures after merge are
journaled, not terminal.

While still on the owned branch, append the `MERGED` state, board result, and literal cleanup plan,
then finish structured state with the same post-merge evidence over quoted stdin:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" finish "$RUN_ID" <<'CC_TUNER_COMPLETION'
<literal merged PR, issue/board, spec/archive, and cleanup evidence>
CC_TUNER_COMPLETION
```

Switch to the literal target, `git pull --ff-only`, remove only merged clean worktrees, prune, and
delete merged local/remote-tracking refs according to task-flow. Never append to branch-owned state
after switching targets and never hard-code `main` when the spec names another target.

## What `--auto` never waives

- Incomplete DoR or visible execution plan.
- A missing/false RED, red targeted/full/static/runtime/acceptance check, or unexplained diff.
- Unresolved `[eyes]` criteria under `--auto`, or `auto_ready: no`.
- Missing or stale exact-candidate review approval, current-SHA CI, or DoD evidence.
- Scope beyond the spec, including deploy, publish, data migration, or unrelated cleanup.
- Force-push, `--no-verify`, broad staging, unsafe amend, or commit to the target branch.

## Verification

Each item names the invariants in `${CLAUDE_PLUGIN_ROOT}/workflow-contract.json` it discharges. Read
the requirement there — a paraphrase kept here would be a second copy of the rule, and the copy is
what drifts.

- [ ] `structured-run-state`, `resume-before-every-phase`
- [ ] `visible-plan-before-mutation`
- [ ] `definition-of-ready-before-implementation`, `red-green-regression-proof`
- [ ] `implementation-only-fanout`, `owner-verifies-delegation`
- [ ] `testing-before-candidate`, `machine-and-human-acceptance`
- [ ] `intentional-staging-before-commit`, `immutable-candidate-before-review`
- [ ] `exhaustive-review-no-cap`, `review-bound-to-candidate`, `sensitive-diffs-require-review-fanout`
- [ ] `reviewer-hard-stop-is-not-approval`
- [ ] `changes-invalidate-downstream-evidence`
- [ ] `current-sha-ci-verification`, `ordered-delivery`
- [ ] `definition-of-done-before-merge`, `post-merge-reconciliation-only`
- [ ] `hitl-stops-at-boundaries`, `explicit-auto-readiness`, `one-spec-one-branch-one-pr`,
      `spec-before-run`, `clean-run-baseline`
