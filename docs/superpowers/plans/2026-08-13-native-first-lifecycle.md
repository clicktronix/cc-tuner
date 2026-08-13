# Native-first lifecycle — implementation plan

**Decision record:** [`docs/adr/2026-08-13-native-first-lifecycle.md`](../../adr/2026-08-13-native-first-lifecycle.md)
**Evidence:** [`docs/spike-native-flow.md`](../../spike-native-flow.md)
**Branch:** `refactor/native-first-lifecycle` — one branch, one PR.

**Goal:** replace cc-tuner's own lifecycle machinery with the platform's, leaving a skill, one
fail-closed merge guard, and a setup check.

**Architecture:** the committed Markdown plan is the only readable store; native tasks are the visible
plan; `git`/`gh` hold the delivery facts. Nothing keeps a second copy of any of them.

**Shape borrowed from prior art, not invented here:** `superpowers:writing-plans` (a dated plan file
under `docs/`, steps as `- [ ]`), `superpowers:executing-plans` (read plan → create tasks → work them),
`mattpocock:to-tickets` (vertical slices, each declaring `Blocked by`), and
`mattpocock:git-guardrails` (a 24-line `PreToolUse` script that denies one command class).

## Global constraints

- **Bash 3.2.** macOS system bash. No associative arrays, no `${var^^}`, no `mapfile`.
- **Every guard ships a test that fails when the guard is reverted.** A test that stays green against
  a reverted guard is not a test of that guard.
- **`tests/run.sh` is green at every commit.** A deliberately failing check is proven by mutating the
  thing it guards, never by committing it red. A red suite makes `git bisect` useless and trains
  everyone to ignore the signal.
- **One rule, one home.** No second copy of a rule, and no second parser for a question something
  already answers.
- **`git`, `gh`, `jq` only** in the shipped runtime. No new runtime dependency and no new language.
- **Commits:** short imperative subject. No Claude attribution trailer.
- **Migration precedes deletion.** Nothing that works today is removed before the thing that replaces
  it runs green, and no commit leaves a public command pointing at a deleted script.

## Two tiers of test, and what each can prove

The distinction matters more than any single task here, because getting it wrong is the defect this
branch exists to remove.

- **Scenario tier** (`tests/scenarios/`, runs in `tests/run.sh`, no auth, no cost). Real git
  repositories, real invocations of the plugin's scripts and hooks with real JSON payloads on stdin,
  assertions on exit code, `permissionDecision`, and files produced. This tier can prove everything
  about the **guard and the hooks**, because those are shell programs with observable inputs.
- **Eval tier** (Task 7, authenticated, costs tokens, run by hand). A real Claude Code session driving
  `spec → plan → run`. This tier is the **only** one that can prove a skill causes `TaskCreate` to be
  called, because in the scenario tier no producer exists.

**The trap, stated so nobody falls into it:** a scenario that asserts something about "the plan file
the skill produced" is asserting about a fixture the test itself wrote. That is a parser test wearing
an end-to-end costume — the same shape as the 82 green `grep` assertions over Markdown. The scenario
tier tests the **validator**; the eval tier tests that the skill's output **passes** it.

## Task graph

| task | blocked by |
|---|---|
| 0 — scenario harness | — |
| 1 — measure skill-hook lifetime | — |
| 2 — `/cc-tuner:plan` and the plan validator | 0 |
| 3 — execution skill | 2 |
| 4 — merge guard | 0, 1 |
| 5 — `SessionStart` restore | 2 |
| 6 — `doctor` | — |
| 7 — `commands/` → `skills/` | 3 |
| 8 — authenticated eval | 4, 5, 7 |
| 9 — deletion | 6, 8 |

Tasks 0, 1 and 6 start at once. The eval runs **after** the migration, because the thing it must
exercise is the final public `/cc-tuner:run`, not an intermediate one. Deletion is last and is blocked
by the eval: the old runtime stays until a real session has been observed completing the new one.

---

## Task 0: Scenario harness

**Blocked by:** none.

**Files:**
- Create: `plugins/cc-tuner/tests/scenarios/lib.sh` — builds a throwaway git repo in `$TMPDIR`,
  returns its path, registers cleanup.
- Create: `plugins/cc-tuner/tests/scenarios/run.sh` — runs every `scenario-*.sh` in the directory.
- Create: `plugins/cc-tuner/tests/scenarios/fixtures/` — hook payloads captured verbatim during the
  spike, one JSON file per event.
- Create: `plugins/cc-tuner/tests/scenarios/scenario-harness-selftest.sh`
- Modify: `plugins/cc-tuner/tests/run.sh` — call `scenarios/run.sh`.

This task ships the machinery and **one** scenario: the harness proving itself. The guard scenarios
belong to Task 4, alongside the guard, so no commit in between is red.

- [ ] **Step 1: write `lib.sh` and `run.sh`.** A scenario is a script that exits non-zero on failure;
      `run.sh` reports each by name and fails if any did.
- [ ] **Step 2: write `scenario-harness-selftest.sh`** — builds a repo, asserts it is a git repo with
      the expected fixture layout, and asserts that a deliberately failing assertion inside a
      sub-scenario is reported as a failure by `run.sh`. Without this, "all scenarios passed" and
      "no scenario ran" look identical, which is how the original defect hid.
- [ ] **Step 3: `bash tests/run.sh`.** Green, including the new tier.
- [ ] **Step 4: commit** — `Add end-to-end scenario harness`.

**Acceptance:** deleting the body of a scenario's assertion makes `run.sh` fail, and an empty scenario
directory is reported rather than silently passing.

---

## Task 1: Measure how long a skill's frontmatter hooks stay active

**Blocked by:** none.

The ADR's top open item. It decides whether the merge guard can be declared on the skill instead of in
`hooks.json`, and — worse — whether a guard declared that way is inert for a multi-turn run.

**Files:** none in this repo. A disposable repository, as with the original spike.

- [ ] **Step 1: build the probe.** A skill whose frontmatter declares
      `hooks: { PreToolUse: [{ matcher: "Bash", hooks: [{ type: command, command: <dump.sh> }] }] }`,
      pointing at the spike's one-file-per-event `dump.sh`. Reuse it verbatim — it is already
      race-free.
- [ ] **Step 2: invoke the skill, then run a `Bash` call in the SAME turn.** Expect an event file.
      A silent probe here means the mechanism does not work at all, not that the window is short.
- [ ] **Step 3: send a new user message, then run another `Bash` call.** This is the experiment.
- [ ] **Step 4: send a third message and repeat.** Two post-invocation turns, so a single quiet turn
      cannot be mistaken for a closed window.
- [ ] **Step 5: control.** Register the same script in `hooks.json` for the same matcher and confirm it
      fires on every turn. Without this, a probe that never fires proves nothing — the error the spike
      made four times.
- [ ] **Step 6: before recording any negative result, confirm the session has finished writing.**
      A transcript read mid-flight produced two wrong conclusions in the spike.
- [ ] **Step 7: record the result in `docs/spike-native-flow.md`** as a new numbered section, with the
      same MEASURED / NOT STARTED marking as the rest, and commit.

**Acceptance:** the record states, from observation, whether a frontmatter hook fires (a) in the
invoking turn, (b) in a later turn of the same session. Either answer unblocks Task 4; no answer does
not.

---

## Task 2: `/cc-tuner:plan` and the plan validator

**Blocked by:** Task 0.

**Files:**
- Create: `plugins/cc-tuner/skills/plan/SKILL.md`
- Create: `plugins/cc-tuner/skills/plan/plan-template.md`
- Create: `plugins/cc-tuner/scripts/plan-lint.sh` — the validator
- Create: `plugins/cc-tuner/tests/scenarios/scenario-plan-lint.sh`

**Frontmatter:** `disable-model-invocation: true` — a plan is produced when asked for, never inferred.
`argument-hint: '[--auto] <path-to-spec>'`. The mode is an argument, because the skill's own body is
the only place that branches on it and it has no other way in.

**What the skill instructs, and nothing more:**

1. Read the committed spec named in `$ARGUMENTS`. No path, or no such file → stop. Never reconstruct
   a spec from chat.
2. Break the work into vertical slices — each demoable on its own, each sized to a fresh context
   window. Wide mechanical refactors are the exception: sequence them expand → migrate → contract.
3. Write `docs/plans/<YYYY-MM-DD>-<branch-slug>.md` from the template. The filename carries the branch
   slug so two branches cannot collide, and so Task 5 can find *this* branch's plan rather than the
   newest file on disk.

   **Each slice is one unambiguously parsable record**, because Task 5 has to rebuild the graph from
   this file alone and a hook is a shell script, not a reader:

   ```markdown
   ## Slice 3 — Wire the retry budget
   Status: pending
   Blocked by: 1, 2
   Owned paths: src/retry/, tests/retry/
   Deciding check: pnpm test tests/retry
   Delivers: a request that exhausts its budget fails with one typed error.

   - [ ] budget is read from config, not hardcoded
   - [ ] exhaustion is observable in the returned error
   ```

   `Status` and `Blocked by` are slice-level; `- [ ]` lines are **acceptance criteria inside a slice**
   and are not slices. Conflating the two is what an earlier draft of Task 5 did, and it would have
   restored a list of criteria with no titles and no edges.
4. Run `plan-lint.sh` on it and fix what it reports.
5. Commit the plan file. It is the store; an uncommitted plan does not survive anything.
6. Publish to native tasks **in two passes** — `TaskCreate` for every slice, then
   `TaskUpdate addBlockedBy` to wire the edges. `TaskCreate` takes no dependency argument, so one pass
   is impossible.

**`--auto` vs attended:** attended, the skill wraps the proposal in plan mode so the user approves
before anything is written. With `--auto` it writes and publishes directly.

- [ ] **Step 1: write `plan-lint.sh`** — given a plan file, exit non-zero if a slice lacks `Status` or
      `Blocked by`, if a named blocker matches no slice number, or if a `- [ ]` line sits outside any
      slice. The linter is the definition of "parsable"; Task 5's hook and this script must not each
      grow their own parser, so the hook calls this one to extract slices.
- [ ] **Step 2: write `scenario-plan-lint.sh`** — four hand-written fixtures: one valid, one with a
      dangling blocker, one missing `Blocked by`, one with an orphan checkbox. Assert the linter
      accepts the first and rejects the rest. **This tests the linter, not the skill** — no session
      runs here, so nothing about the skill's behaviour is being asserted.
- [ ] **Step 3: write the template, then the SKILL.md.**
- [ ] **Step 4: `bash tests/run.sh`**, green.
- [ ] **Step 5: commit** — `Add cc-tuner:plan skill and plan validator`.

**Acceptance:** the linter rejects a dangling blocker. That the *skill* produces a plan the linter
accepts is Task 7's assertion, and is not claimed here.

---

## Task 3: The execution skill

**Blocked by:** Task 2.

**Files:**
- Create: `plugins/cc-tuner/skills/execute/SKILL.md`

**Carry only what changes behaviour.** `TaskList` already returns `blockedBy` and `owner`, and the task
tools already instruct the model to take tasks in ID order and to verify `blockedBy` is empty before
starting. Restating that is a no-op paid for in context every turn. What is **not** default:

- Tick `- [x]` in the plan file and commit it when a task completes. Two stores, one write each — the
  plan file is what survives the session, the task list is what is visible in it.
- Create the task branch **before** any write-capable method runs. Method placement is ordering, not
  an override.
- Under `--auto` only: refuse to start a task whose `blockedBy` is non-empty. The platform stores the
  edge and does not enforce it, and unattended there is nobody watching.
- Stop at each delivery boundary without `--auto`.

- [ ] **Step 1: write the skill.** Target under 120 lines — `superpowers:executing-plans` does the same
      job in 70. Anything longer is reference material and belongs in a linked file.
- [ ] **Step 2: read it back against the no-op test** — for each line, does it change behaviour versus
      the default? Delete whole sentences that fail, do not trim words.
- [ ] **Step 3: `bash tests/run.sh`**, commit — `Add cc-tuner:execute skill`.

**Acceptance:** the skill is under 120 lines and no line restates a `Task*` tool description.

---

## Task 4: The merge guard

**Blocked by:** Task 0 (the harness) and Task 1 (decides where it is registered).

**Files:**
- Create: `plugins/cc-tuner/hooks/merge-guard.sh`
- Modify: `plugins/cc-tuner/hooks/hooks.json` — or, if Task 1 shows frontmatter hooks stay active
  across turns, `skills/execute/SKILL.md` frontmatter instead.
- Create: `plugins/cc-tuner/tests/scenarios/scenario-merge-guard-denies.sh`
- Create: `plugins/cc-tuner/tests/scenarios/scenario-merge-guard-out-of-scope.sh`
- Create: `plugins/cc-tuner/tests/scenarios/scenario-inert-gate.sh`

**The gate:** deny `gh pr merge` unless the PR head SHA carries a verdict review from the expected
author and CI is green on that same SHA. Modelled on `block-dangerous-git.sh` — read stdin, match the
command, emit a decision. Around 30 lines.

**Not three approvals.** §8 of the spike measured that GitHub refuses self-approval and all three
reviewers act as the PR author, so their reviews return `COMMENTED` and `APPROVED` is unreachable
without three separate GitHub identities. An earlier draft of this plan specified three approvals
anyway, contradicting the repository's own evidence file. The gate checks the one thing that is both
external and reachable; deep-review and the `mattpocock` review remain mandatory steps of the flow and
are not gates. See the ADR, **What the gate can actually check**.

**One `gh` interface, and it is `gh pr view --json reviews`.** Verified live against this repository's
PR #19: each element carries `author.login`, `state`, `submittedAt`, `body` and **`commit.oid`** — not
`commit_id`, which is the REST shape returned through `gh api`. The plan names one interface so the
guard and its scenarios cannot drift onto different field names.

**Latest verdict per distinct author.** Reviews accumulate; an author who commented twice, or whose
earlier verdict was superseded, must count once, by their most recent `submittedAt` on the candidate
SHA. Counting rows instead of authors is a false pass waiting to happen.

**Scope is the arming, and there is no arm file.** The guard has an opinion exactly when **this PR's
diff against its base adds or modifies a cc-tuner plan file**. Merely having one on the branch is not
enough: once a plan file merges to `main`, every later branch inherits it and would drag every
unrelated merge into the gate. Outside scope the guard returns `allow` and says nothing. Inside scope
every missing fact denies — no PR, no verdict review at the head SHA, red or absent CI, or a `gh` call
that failed. The reason string names which fact was missing.

- [ ] **Step 1: write the guard**, deny-by-default within scope, reading reviews through the one named
      interface.
- [ ] **Step 2: `scenario-merge-guard-denies.sh`** — in scope, a verdict review on an **older** SHA
      than the head → `deny`. This is the case the whole SHA binding exists for.
- [ ] **Step 3: `scenario-inert-gate.sh`** — the reproduction of the original defect. In scope, **no
      reviews at all, no CI record** → must `deny`. In 0.10.0 the equivalent state allowed. This is
      the single assertion that distinguishes this branch from what shipped.
- [ ] **Step 4: `scenario-merge-guard-out-of-scope.sh`** — the PR's diff touches no plan file → `allow`,
      silently. Include a branch that *inherits* a plan file from `main` without modifying it, since
      that is the case a naive scope check gets wrong. Guards the other direction: the plugin must not
      seize the user's own merges.
- [ ] **Step 5: `scenario-merge-guard-stale-verdict.sh`** — two reviews from the same author on the
      head SHA, the later one negative → `deny`. Asserts latest-per-author rather than any-row-matches.
- [ ] **Step 6: `bash tests/run.sh`**, green.
- [ ] **Step 7: prove the guard by reverting it.** `cp merge-guard.sh merge-guard.sh.premutation`,
      stub the decision to `allow`, run the scenarios, confirm steps 2, 3 and 5 go RED while step 4
      stays green, restore from the copy. Never `git checkout --` here — it would destroy uncommitted
      work in this branch.
- [ ] **Step 8: commit** — `Add fail-closed merge guard`, with the RED/GREEN evidence in the body.

**Acceptance:** the guard denies when its evidence is absent, denies when the verdict is stale or
superseded, and stays silent when no run is happening. All three directions asserted, because any one
alone is a different bug.

**Stated limit, to be repeated in the README:** `gh pr merge` is not the only route to a merge. The web
button, `git push` and the API bypass any local hook. This is a guardrail against an agent's mistake
and must not be described as anything stronger.

---

## Task 5: `SessionStart` restore

**Blocked by:** Task 2.

**Files:**
- Create: `plugins/cc-tuner/hooks/session-start.sh`
- Modify: `plugins/cc-tuner/hooks/hooks.json` — `"matcher": "startup|clear"`.
- Create: `plugins/cc-tuner/tests/scenarios/scenario-restore.sh`

**`compact` is deliberately excluded.** §4 of the spike measured the task graph surviving compaction
and resume byte for byte; asking for a restore there would duplicate every row.

**A `command` hook cannot call `TaskCreate`.** It emits `hookSpecificOutput.additionalContext` and
nothing else, so this asks the agent to restore and cannot make it happen.
`superpowers/hooks/session-start` is the working model, including its manual JSON escaping and its
`printf`-instead-of-heredoc workaround for bash 5.3.

- [ ] **Step 1: find this branch's plan** — `docs/plans/*-<current-branch-slug>.md`, tracked in `git`.
      Not "the newest file", which picks the wrong plan the moment two branches have one. None → emit
      nothing and exit 0; silence is the correct output when there is no plan.
- [ ] **Step 2: emit the unfinished slices, with their structure.** Per slice: number, title, `Status`,
      `Blocked by`, and its unticked acceptance criteria. **Not a flat list of `- [ ]` lines** — those
      are criteria inside a slice, so emitting them alone would restore a set of checkboxes with no
      titles and no edges, and the dependency graph would be silently lost. Extract via
      `plan-lint.sh`'s parser rather than a second one written here.
- [ ] **Step 3: make the instruction idempotent** — call `TaskList` first, create only the slices that
      are missing, then re-apply `addBlockedBy` for edges not already present. Written this way even
      though `compact` is excluded, so a future trigger change cannot silently double the plan.
- [ ] **Step 4: `scenario-restore.sh`** — a half-done plan emits exactly the unfinished slices **with
      their `Blocked by` values**; a finished plan emits nothing; a branch with no plan file emits
      nothing.
- [ ] **Step 5: `bash tests/run.sh`**, commit — `Restore the plan on session start`.

**Acceptance:** `clear` is covered as well as `startup`; the emitted context carries slice titles and
edges, not just criteria; and the instruction is idempotent against an already-populated task list.
That the agent then rebuilds a `TaskList` whose `blockedBy` matches is Task 8's assertion.

---

## Task 6: `doctor`, and dropping `tracker: none`

**Blocked by:** none.

**Files:**
- Modify: `plugins/cc-tuner/scripts/setup/doctor.sh`
- Delete: the companion-plugin manifest resolver

`claude plugin list --json` returns `id`, `version`, `scope`, `enabled`, `installPath` and
`projectPath` directly. Every line of the resolver that recomputes one of those goes.

- [ ] **Step 1: replace the resolver** with the one `claude plugin list --json` call.
- [ ] **Step 2: drop `tracker: none` everywhere it is named**, not only in `/run` — it also appears in
      `commands/spec.md:140`, in the spec template, and in the tests that assert it. It was always
      inconsistent, since `/run` requires a PR and GitHub CI unconditionally. Removing it from one of
      three sites leaves a documented option that no longer exists.
- [ ] **Step 3: `grep -rn 'tracker: none' plugins/`** returns nothing.
- [ ] **Step 4: `bash tests/run.sh`**, commit — `Simplify doctor onto claude plugin list`.

---

## Task 7: `commands/` → `skills/`

**Blocked by:** Task 3.

Custom commands and skills are the same mechanism now, and skills are the recommended form because
they carry supporting files. `commands/run.md` is 434 lines — the largest single unit in the plugin,
in the form that cannot split. **This runs before both the eval and the deletion:** the eval must
exercise the final public `/cc-tuner:run`, and no commit may leave a public command pointing at a
script that is about to be removed.

**Files:**
- Move: `commands/*.md` → `skills/<name>/SKILL.md`
- Create: `skills/run/references/*.md` for the material that is reference rather than instruction

- [ ] **Step 1: move each command**, preserving its frontmatter.
- [ ] **Step 2: rewrite `run`** onto the new runtime — the skill, the plan file, `git`/`gh`. This is
      where the last live references to `runctl.sh`, `journal.sh` and the prepared-file machinery
      leave the tree.
- [ ] **Step 3: split it** — instructions stay in `SKILL.md`, reference moves behind a pointer. Target
      under 150 lines in the body; the median skill in both reference plugins is under 180.
- [ ] **Step 4: verify every `/cc-tuner:<name>` still resolves**, including the plugin prefix.
- [ ] **Step 5: `bash tests/run.sh`**, commit — `Move commands to skills`.

**Acceptance:** `grep -rn 'runctl\|journal\.sh' plugins/*/commands plugins/*/skills` returns nothing.

---

## Task 8: Authenticated eval

**Blocked by:** Tasks 4, 5, 7.

The only tier that can prove a skill causes `TaskCreate` to be called. It runs by hand, costs tokens,
and needs auth, so it is **not** part of `tests/run.sh` — but it blocks deletion, because without it
nothing has observed the replacement actually working. It runs after Task 7 so that what it exercises
is the shipped `/cc-tuner:run`, not an intermediate form of it.

**Files:**
- Create: `plugins/cc-tuner/tests/eval/README.md` — how to run it and what it costs
- Create: `plugins/cc-tuner/tests/eval/fixture-spec.md`

- [ ] **Step 1: attended run.** In a scratch repository: `/cc-tuner:plan <spec>` → confirm plan mode
      asks for approval, the plan file is committed, `plan-lint.sh` accepts it, and `TaskList` shows
      the slices **with their `blockedBy` edges**. The edges are the part a one-pass implementation
      would silently drop.
- [ ] **Step 2: `--auto` run.** Same spec, `--auto`: no plan-mode prompt, plan committed, tasks
      created, and a task whose `blockedBy` is non-empty is refused when attempted out of order.
- [ ] **Step 3: recovery, asserted on the graph.** Start a fresh session in that repository. Confirm
      the `SessionStart` context arrives and that the rebuilt `TaskList` carries **the same
      `blockedBy` edges as before**, not merely the same number of rows. Then `/clear` and confirm the
      same. Then `/compact` and confirm **no duplication**.
- [ ] **Step 4: the merge guard, live.** On a PR whose head SHA carries no verdict review, attempt
      `gh pr merge` and confirm the denial reaches the agent as a refusal it reports, not a silent
      retry.
- [ ] **Step 5: record every outcome** in `tests/eval/README.md` with the date and the observed
      behaviour, in the same MEASURED style as the spike. Commit.

**Acceptance:** all five steps observed PASS in a real session. **A step recorded as not-yet-run leaves
this task incomplete and Task 9 blocked** — an earlier draft allowed not-yet-run to count, which would
have let the deletion proceed on no evidence at all. A step recorded as passing on the strength of
reading the skill's text is the exact failure mode this branch exists to remove.

---

## Task 9: Deletion

**Blocked by:** Tasks 6 and 8 — every replacement green, the eval observed PASS on every step, and no
public command still pointing at the old runtime.

**Delete:**
- `scripts/execute-task/runctl.sh` (1179) and `lib.sh` (287)
- `scripts/execute-task/journal.sh`, `guard-artifacts.sh`, `preflight.sh`, `config-init.sh`
- `hooks/run-state-hook.sh` (178) and its registrations
- `schemas/` — the run-state schema and its `jq` twin
- `tests/execute-task/test_run_state.sh` (910), `test_run_state_hook.sh`
- `.claude/execute-task-runs/` handling entirely: state files, generation and reclaim locks, prepared
  files, the hard-link machinery, the Markdown journal

**Keep:** `prereq-check.sh`, reduced to the capability checks something still reads.

- [ ] **Step 1: rewrite `prereq-check.sh` off `lib.sh` FIRST.** It sources it at line 39
      (`. "$(...)/lib.sh"`), so deleting `lib.sh` while keeping `prereq-check.sh` breaks it in the same
      commit and violates green-at-every-commit. Inline the handful of helpers it actually uses, run
      the suite, commit — then `lib.sh` is free to go.
- [ ] **Step 2: add a hard stop for a legacy run.** A repository that still has
      `.claude/execute-task-runs/*.state.json` is mid-flight on a runtime that no longer exists. The
      `SessionStart` hook detects it and stops with an instruction to finish or adopt the run under
      the new flow. Without this the old runtime does not merely disappear — it silently fails open,
      which is the defect being deleted, reintroduced by the deletion itself. Migration of the state
      is explicitly not offered; detection is.
- [ ] **Step 3: delete, one commit per subsystem**, so a bisect can land between them.
- [ ] **Step 4: `bash tests/run.sh`** after each — green at every one.
- [ ] **Step 5: `grep -rn runctl plugins/ docs/`** — no live reference survives. A doc naming a deleted
      script is a broken instruction, not a stale comment.
- [ ] **Step 6: reduce the thirty invariants** to those with something that reads them at runtime.
      Cap at seven, per the ADR's complexity budget.

**Acceptance:** the tree has no `*.state.json` code path, an existing legacy run is detected rather
than silently ignored, and `tests/run.sh` is green at every commit in the sequence.

---

## Definition of done for the branch

- `tests/run.sh` green **at every commit**, and the harness demonstrably able to report a failure.
- The merge guard denies when its evidence is absent or stale, and stays silent outside a run — all
  proven by mutation, evidence in the commit.
- The eval record shows every step PASS in a real session: `spec → plan → visible tasks with edges →
  recovery preserving those edges → a live merge denial`.
- No `runctl`, no state file, no journal, no lock, no schema twin.
- Runtime Bash: the merge guard, the session-start hook, the plan linter, and the `--auto` frontier
  check. Nothing else.
- README states the merge guard's real coverage, without overclaiming.
- One PR.
