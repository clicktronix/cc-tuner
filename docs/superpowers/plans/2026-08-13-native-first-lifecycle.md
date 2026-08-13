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
| 7 — authenticated eval | 3, 4, 5 |
| 8 — `commands/` → `skills/` | 3 |
| 9 — deletion | 6, 7, 8 |

Tasks 0, 1 and 6 start at once. Deletion is last and is blocked by the eval: the old runtime stays
until a real session has been observed completing the new one.

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
3. Write `docs/plans/<YYYY-MM-DD>-<branch-slug>.md` from the template: per slice a title, what it
   delivers, `Blocked by`, owned paths, the deciding check, and acceptance criteria as `- [ ]`. The
   filename carries the branch slug so two branches cannot collide, and so Task 5 can find *this*
   branch's plan rather than the newest file on disk.
4. Run `plan-lint.sh` on it and fix what it reports.
5. Commit the plan file. It is the store; an uncommitted plan does not survive anything.
6. Publish to native tasks **in two passes** — `TaskCreate` for every slice, then
   `TaskUpdate addBlockedBy` to wire the edges. `TaskCreate` takes no dependency argument, so one pass
   is impossible.

**`--auto` vs attended:** attended, the skill wraps the proposal in plan mode so the user approves
before anything is written. With `--auto` it writes and publishes directly.

- [ ] **Step 1: write `plan-lint.sh`** — given a plan file, exit non-zero if a slice lacks
      `Blocked by`, if acceptance lines are not `- [ ]`, or if a named blocker matches no slice title.
- [ ] **Step 2: write `scenario-plan-lint.sh`** — three hand-written fixtures: one valid, one with a
      dangling blocker, one with a missing `Blocked by`. Assert the linter accepts the first and
      rejects the other two. **This tests the linter, not the skill** — no session runs here, so
      nothing about the skill's behaviour is being asserted.
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

**The gate:** deny `gh pr merge` unless the PR head SHA equals the candidate SHA, that SHA carries
three approving pull-request reviews, and CI is green on it. Modelled on `block-dangerous-git.sh` —
read stdin, match the command, emit a decision. Around 30 lines.

**Scope is the arming, and there is no arm file.** The guard has an opinion exactly when the current
branch carries a committed cc-tuner plan file. Outside that it returns `allow` and says nothing —
otherwise installing cc-tuner would block every unrelated merge in every repository. Inside that scope
every missing fact denies: no plan, no PR, fewer than three approvals on the head SHA, red CI, or a
`gh` call that failed. The reason string names which fact was missing.

**Three approvals means three GitHub PR reviews on the candidate SHA.** `gh pr view --json reviews`
returns each review's `commit_id` and `state`; GitHub stamps the `commit_id` and the plugin cannot
forge it. An attestation that was never posted as a PR review does not count and the guard cannot see
it — that narrowing is in the ADR and is the price of deleting the local state file.

- [ ] **Step 1: write the guard**, deny-by-default within scope.
- [ ] **Step 2: `scenario-merge-guard-denies.sh`** — plan file present, one approval → `deny`.
- [ ] **Step 3: `scenario-inert-gate.sh`** — the reproduction of the original defect. Plan file
      present, **no reviews at all, no CI record** → must `deny`. In 0.10.0 the equivalent state
      allowed. This is the single assertion that distinguishes this branch from what shipped.
- [ ] **Step 4: `scenario-merge-guard-out-of-scope.sh`** — no plan file on the branch → `allow`,
      silently. Guards the other direction: the plugin must not seize the user's own merges.
- [ ] **Step 5: `bash tests/run.sh`**, green.
- [ ] **Step 6: prove the guard by reverting it.** `cp merge-guard.sh merge-guard.sh.premutation`,
      stub the decision to `allow`, run the scenarios, confirm steps 2 and 3 go RED while step 4 stays
      green, restore from the copy. Never `git checkout --` here — it would destroy uncommitted work
      in this branch.
- [ ] **Step 7: commit** — `Add fail-closed merge guard`, with the RED/GREEN evidence in the body.

**Acceptance:** the guard denies when its evidence is absent and stays silent when no run is happening.
Both directions asserted, because either one alone is a different bug.

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
- [ ] **Step 2: emit the unticked lines** as `additionalContext`, with an **idempotent** instruction:
      call `TaskList` first and create only the slices that are missing. Written this way even though
      `compact` is excluded, so that a future trigger change cannot silently double the plan.
- [ ] **Step 3: `scenario-restore.sh`** — half-ticked plan produces context naming exactly the unticked
      slices; fully ticked plan produces nothing; a branch with no plan file produces nothing.
- [ ] **Step 4: `bash tests/run.sh`**, commit — `Restore the plan on session start`.

**Acceptance:** `clear` is covered as well as `startup`, and the emitted instruction is idempotent
against an already-populated task list.

---

## Task 6: `doctor`, and dropping `tracker: none`

**Blocked by:** none.

**Files:**
- Modify: `plugins/cc-tuner/scripts/setup/doctor.sh`
- Delete: the companion-plugin manifest resolver

`claude plugin list --json` returns `id`, `version`, `scope`, `enabled`, `installPath` and
`projectPath` directly. Every line of the resolver that recomputes one of those goes.

- [ ] **Step 1: replace the resolver** with the one `claude plugin list --json` call.
- [ ] **Step 2: drop `tracker: none`** from `/run` — it was always inconsistent, since `/run` requires
      a PR and GitHub CI unconditionally. Edit it wherever `/run` lives at the time; Task 8 moves it.
- [ ] **Step 3: `bash tests/run.sh`**, commit — `Simplify doctor onto claude plugin list`.

---

## Task 7: Authenticated eval

**Blocked by:** Tasks 3, 4, 5.

The only tier that can prove a skill causes `TaskCreate` to be called. It runs by hand, costs tokens,
and needs auth, so it is **not** part of `tests/run.sh` — but it blocks deletion, because without it
nothing has observed the replacement actually working.

**Files:**
- Create: `plugins/cc-tuner/tests/eval/README.md` — how to run it and what it costs
- Create: `plugins/cc-tuner/tests/eval/fixture-spec.md`

- [ ] **Step 1: attended run.** In a scratch repository: `/cc-tuner:plan <spec>` → confirm plan mode
      asks for approval, the plan file is committed, `plan-lint.sh` accepts it, and `TaskList` shows
      the slices **with their `blockedBy` edges**. The edges are the part a one-pass implementation
      would silently drop.
- [ ] **Step 2: `--auto` run.** Same spec, `--auto`: no plan-mode prompt, plan committed, tasks
      created, and a task whose `blockedBy` is non-empty is refused when attempted out of order.
- [ ] **Step 3: recovery.** Start a fresh session in that repository. Confirm the `SessionStart` hook's
      context arrives and the agent re-creates only the unticked slices. Then run `/clear` and confirm
      the same. Then `/compact` and confirm **no duplication**.
- [ ] **Step 4: the merge guard, live.** Attempt `gh pr merge` on a PR with fewer than three approvals
      on the head SHA and confirm the denial reaches the agent as a refusal it reports, not a silent
      retry.
- [ ] **Step 5: record every outcome** in `tests/eval/README.md` with the date and the session's
      observed behaviour, in the same MEASURED style as the spike. Commit.

**Acceptance:** every step observed in a real session, or the step is recorded as not-yet-run. A step
recorded as passing on the strength of reading the skill's text is exactly the failure mode this whole
branch exists to remove.

---

## Task 8: `commands/` → `skills/`

**Blocked by:** Task 3.

Custom commands and skills are the same mechanism now, and skills are the recommended form because
they carry supporting files. `commands/run.md` is 434 lines — the largest single unit in the plugin,
in the form that cannot split. **This runs before deletion**, so no commit leaves a public command
pointing at a script that is about to be removed.

**Files:**
- Move: `commands/*.md` → `skills/<name>/SKILL.md`
- Create: `skills/run/references/*.md` for the material that is reference rather than instruction

- [ ] **Step 1: move each command**, preserving its frontmatter.
- [ ] **Step 2: rewrite `run`** onto the new runtime — the skill, the plan file, `git`/`gh`. This is
      where the last live references to `runctl.sh`, `journal.sh` and the prepared-file machinery
      leave the tree, which is why it precedes Task 9.
- [ ] **Step 3: split it** — instructions stay in `SKILL.md`, reference moves behind a pointer. Target
      under 150 lines in the body; the median skill in both reference plugins is under 180.
- [ ] **Step 4: verify every `/cc-tuner:<name>` still resolves**, including the plugin prefix.
- [ ] **Step 5: `bash tests/run.sh`**, commit — `Move commands to skills`.

**Acceptance:** `grep -rn 'runctl\|journal\.sh' plugins/*/commands plugins/*/skills` returns nothing.

---

## Task 9: Deletion

**Blocked by:** Tasks 6, 7, 8 — every replacement green, the eval observed, and no public command
still pointing at the old runtime.

**Delete:**
- `scripts/execute-task/runctl.sh` (1179) and `lib.sh` (287)
- `scripts/execute-task/journal.sh`, `guard-artifacts.sh`, `preflight.sh`, `config-init.sh`
- `hooks/run-state-hook.sh` (178) and its registrations
- `schemas/` — the run-state schema and its `jq` twin
- `tests/execute-task/test_run_state.sh` (910), `test_run_state_hook.sh`
- `.claude/execute-task-runs/` handling entirely: state files, generation and reclaim locks, prepared
  files, the hard-link machinery, the Markdown journal

**Keep:** `prereq-check.sh`, reduced to the capability checks something still reads.

- [ ] **Step 1: delete, one commit per subsystem**, so a bisect can land between them.
- [ ] **Step 2: `bash tests/run.sh`** after each — green at every one.
- [ ] **Step 3: `grep -rn runctl plugins/ docs/`** — no live reference survives. A doc naming a deleted
      script is a broken instruction, not a stale comment.
- [ ] **Step 4: reduce the thirty invariants** to those with something that reads them at runtime.
      Cap at seven, per the ADR's complexity budget.

**Acceptance:** the tree has no `*.state.json` code path, and `tests/run.sh` is green.

---

## Definition of done for the branch

- `tests/run.sh` green **at every commit**, and the harness demonstrably able to report a failure.
- The merge guard denies when its evidence is absent and stays silent outside a run — both proven by
  mutation, evidence in the commit.
- The eval record shows a real session completing `spec → plan → visible tasks with edges → recovery`.
- No `runctl`, no state file, no journal, no lock, no schema twin.
- Runtime Bash: the merge guard, the session-start hook, the plan linter, and the `--auto` frontier
  check. Nothing else.
- README states the merge guard's real coverage, without overclaiming.
- One PR.
