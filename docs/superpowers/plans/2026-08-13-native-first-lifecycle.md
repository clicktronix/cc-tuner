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
- **One rule, one home.** No second copy of a rule, and no second parser for a question something
  already answers.
- **`git`, `gh`, `jq` only.** No new runtime dependency and no new language.
- **Commits:** short imperative subject. No Claude attribution trailer.
- **Deletion comes after replacement.** Nothing that works today is removed before the thing that
  replaces it runs green.

## Task graph

| task | blocked by |
|---|---|
| 0 — scenario harness | — |
| 1 — measure skill-hook lifetime | — |
| 2 — `/cc-tuner:plan` | 0 |
| 3 — execution skill | 2 |
| 4 — merge guard | 0, 1 |
| 5 — `SessionStart` restore | 2 |
| 6 — `doctor` | — |
| 7 — deletion | 3, 4, 5, 6 |
| 8 — `commands/` → `skills/` | 7 |

Tasks 0, 1 and 6 can start at once. Nothing is deleted until every replacement is green.

---

## Task 0: End-to-end scenario harness

**Blocked by:** none — starts immediately.

The defect this whole branch exists to fix is not the state machine, it is that 82 assertions were
green while `spec → plan → run` could not start. Nothing else in this plan may land until there is a
test that would have caught that.

**Files:**
- Create: `plugins/cc-tuner/tests/scenarios/lib.sh` — builds a throwaway git repo in `$TMPDIR`,
  returns its path, registers cleanup.
- Create: `plugins/cc-tuner/tests/scenarios/run.sh` — runs every `scenario-*.sh` in the directory.
- Create: `plugins/cc-tuner/tests/scenarios/fixtures/` — hook payloads captured verbatim during the
  spike, one JSON file per event.
- Modify: `plugins/cc-tuner/tests/run.sh` — call `scenarios/run.sh`.

**What a scenario is:** a real git repository on disk, a real invocation of the plugin's scripts and
hooks with a real JSON payload on stdin, and an assertion on the observable outcome — the exit code,
the `permissionDecision`, or a file the flow was supposed to produce. Never a `grep` over Markdown.

- [ ] **Step 1: write the failing scenario first.** `scenario-merge-guard-denies.sh`: a repo with no
      approvals, a `gh pr merge` payload, expected `permissionDecision: deny`. It fails now because
      no guard exists yet — that failure is the point, and Task 4 turns it green.
- [ ] **Step 2: write `scenario-inert-gate.sh`** — the reproduction of the original defect. Drive the
      guard in a repo where the arming state is *absent* and assert it does **not** silently allow.
      This is the assertion whose absence let 0.10.0 ship.
- [ ] **Step 3: `bash tests/run.sh`.** Expect the two new scenarios to FAIL and every existing check to
      PASS. Record both in the commit message.
- [ ] **Step 4: commit** — `Add end-to-end scenario harness`.

**Acceptance:** a scenario can fail. Verify by stubbing the guard to always allow and confirming
`scenario-merge-guard-denies.sh` goes red.

**Deliberately out of scope, and named rather than omitted:** model-in-the-loop scenarios via
`claude -p`. They are the only way to test whether the *model* follows the skill, they cost tokens and
need auth, and they do not belong in `tests/run.sh`. If they are wanted they are a separate tier with
a separate entry point — but then the plan's advisory half stays untested, and the ADR says so.

---

## Task 1: Measure how long a skill's frontmatter hooks stay active

**Blocked by:** none — runs in parallel with Task 0.

This is the ADR's top open item. It decides whether Task 4 needs an arming file at all, and — worse —
whether a guard declared in frontmatter fires during a run or is inert.

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
      fires on every turn. Without this, a probe that never fires proves nothing — which is the error
      the spike made four times.
- [ ] **Step 6: before recording any negative result, confirm the session has finished writing.**
      A transcript read mid-flight produced two wrong conclusions in the spike.
- [ ] **Step 7: record the result in `docs/spike-native-flow.md`** as a new numbered section, with the
      same MEASURED / NOT STARTED marking as the rest, and commit.

**Acceptance:** the record states, from observation, whether a frontmatter hook fires (a) in the
invoking turn, (b) in a later turn of the same session. Either answer unblocks Task 4; no answer does
not.

---

## Task 2: `/cc-tuner:plan` — produce the plan

**Blocked by:** Task 0.

**Files:**
- Create: `plugins/cc-tuner/skills/plan/SKILL.md`
- Create: `plugins/cc-tuner/skills/plan/plan-template.md`
- Create: `plugins/cc-tuner/tests/scenarios/scenario-plan-shape.sh`

**Frontmatter:** `disable-model-invocation: true` — the plan is produced when asked for, never
inferred. `argument-hint: '<path-to-spec>'`.

**What the skill instructs, and nothing more:**

1. Read the committed spec named in `$ARGUMENTS`. No path, or no such file → stop. Never reconstruct
   a spec from chat.
2. Break the work into vertical slices — each one demoable on its own, each sized to a fresh context
   window. Wide mechanical refactors are the exception: sequence them expand → migrate → contract.
3. Write `docs/plans/<YYYY-MM-DD>-<slug>.md` from the template: per slice a title, what it delivers,
   `Blocked by`, owned paths, the deciding check, and acceptance criteria as `- [ ]`.
4. Commit the plan file. It is the store; an uncommitted plan does not survive anything.
5. Publish to native tasks **in two passes** — `TaskCreate` for every slice first, then
   `TaskUpdate addBlockedBy` to wire the edges. `TaskCreate` takes no dependency argument, so one pass
   is impossible.

**Interactive vs `--auto`:** interactively the skill wraps the proposal in plan mode so the user
approves before anything is written. Under `--auto` it writes and publishes directly.

- [ ] **Step 1: write `scenario-plan-shape.sh`** — given a fixture spec, assert the produced plan file
      parses: every slice has `Blocked by`, acceptance lines are `- [ ]`, and every named blocker
      matches an existing slice title. Fails now, no skill exists.
- [ ] **Step 2: write the template**, then the SKILL.md.
- [ ] **Step 3: `bash tests/run.sh`** — the scenario turns green.
- [ ] **Step 4: commit** — `Add cc-tuner:plan skill`.

**Acceptance:** a slice naming a nonexistent blocker fails the scenario.

---

## Task 3: The execution skill

**Blocked by:** Task 2.

**Files:**
- Create: `plugins/cc-tuner/skills/execute/SKILL.md`

**Carry only what changes behaviour.** `TaskList` already returns `blockedBy` and `owner`, and the
task tools already instruct the model to take tasks in ID order and to verify `blockedBy` is empty
before starting. Restating that is a no-op paid for in context every turn. What is **not** default:

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

**Blocked by:** Task 0 (needs the scenario) and Task 1 (decides the arming).

**Files:**
- Create: `plugins/cc-tuner/hooks/merge-guard.sh`
- Modify: `plugins/cc-tuner/hooks/hooks.json` — or, if Task 1 shows frontmatter hooks stay active
  across turns, `skills/execute/SKILL.md` frontmatter instead, and no arming file.

**The one fail-closed gate:** deny `gh pr merge` unless the PR head SHA equals the reviewed SHA, that
SHA carries three approvals, and CI is green on it. Modelled on `block-dangerous-git.sh` — read stdin,
match the command, emit a decision. Around 30 lines.

- [ ] **Step 1: write the guard.** Deny is the default when the facts cannot be established. An
      unreadable state, an absent PR, a failed `gh` call — every one of them denies. The reason string
      says which fact was missing.
- [ ] **Step 2: register it**, by whichever mechanism Task 1 established.
- [ ] **Step 3: `bash tests/run.sh`** — `scenario-merge-guard-denies.sh` and `scenario-inert-gate.sh`
      both turn green.
- [ ] **Step 4: prove the guard by reverting it.** `cp merge-guard.sh merge-guard.sh.premutation`,
      stub the decision to `allow`, run the scenarios, confirm both go RED, restore from the copy.
      Never `git checkout --` here — it would destroy uncommitted work in this branch.
- [ ] **Step 5: commit** — `Add fail-closed merge guard`, with the RED/GREEN evidence in the body.

**Acceptance:** the guard denies when its state is absent. That single assertion is the whole
difference from 0.10.0.

**Stated limit, to be repeated in the README:** `gh pr merge` is not the only route to a merge. The web
button, `git push` and the API bypass any local hook. This is a guardrail against an agent's mistake
and must not be described as anything stronger.

---

## Task 5: `SessionStart` restore

**Blocked by:** Task 2 (nothing to restore before a plan file exists).

**Files:**
- Create: `plugins/cc-tuner/hooks/session-start.sh`
- Modify: `plugins/cc-tuner/hooks/hooks.json` — `"matcher": "startup|clear|compact"`.

**A hook cannot call `TaskCreate`.** It emits `hookSpecificOutput.additionalContext` and nothing else,
so this asks the agent to restore and cannot make it happen. `superpowers/hooks/session-start` is the
working model, including its manual JSON escaping and its `printf`-instead-of-heredoc workaround for
bash 5.3.

- [ ] **Step 1: find the current plan** — the newest `docs/plans/*.md` reachable from `HEAD` with at
      least one unticked `- [ ]`. None → emit nothing and exit 0. Silence is the correct output when
      there is no plan.
- [ ] **Step 2: emit the unticked lines** as `additionalContext`, with one instruction: re-create these
      as tasks before doing anything else.
- [ ] **Step 3: scenario** — a repo with a half-ticked plan produces context naming exactly the
      unticked slices; a repo with a fully ticked plan produces nothing.
- [ ] **Step 4: commit** — `Restore the plan on session start`.

**Acceptance:** `clear` and `compact` are covered, not only `startup`.

---

## Task 6: `doctor`, and dropping `tracker: none`

**Blocked by:** none.

**Files:**
- Modify: `plugins/cc-tuner/scripts/setup/doctor.sh`
- Modify: `plugins/cc-tuner/commands/run.md` (until Task 8 moves it)
- Delete: the companion-plugin manifest resolver

`claude plugin list --json` returns `id`, `version`, `scope`, `enabled`, `installPath` and
`projectPath` directly. Every line of the resolver that recomputes one of those goes.

- [ ] **Step 1: replace the resolver** with the one `claude plugin list --json` call.
- [ ] **Step 2: drop `tracker: none`** from `/run` — it was always inconsistent, since `/run` requires
      a PR and GitHub CI unconditionally.
- [ ] **Step 3: `bash tests/run.sh`**, commit — `Simplify doctor onto claude plugin list`.

---

## Task 7: Deletion

**Blocked by:** Tasks 3, 4, 5, 6 — every replacement green first.

**Delete:**
- `scripts/execute-task/runctl.sh` (1179) and `lib.sh` (287)
- `scripts/execute-task/journal.sh`, `guard-artifacts.sh`, `preflight.sh`, `config-init.sh`
- `hooks/run-state-hook.sh` (178) and its registrations
- `schemas/` — the run-state schema and its `jq` twin
- `tests/execute-task/test_run_state.sh` (910), `test_run_state_hook.sh`
- `.claude/execute-task-runs/` handling entirely: state files, generation and reclaim locks, prepared
  files, the hard-link machinery, the Markdown journal

**Keep:** `prereq-check.sh`, reduced to the capability checks something still reads.

- [ ] **Step 1: delete, in one commit per subsystem** so a bisect can land between them.
- [ ] **Step 2: `bash tests/run.sh`** after each.
- [ ] **Step 3: `grep -rn runctl plugins/ docs/`** — no live reference survives. A doc naming a deleted
      script is a broken instruction, not a stale comment.
- [ ] **Step 4: reduce the thirty invariants** to those with something that reads them at runtime.
      Cap at seven, per the ADR's complexity budget.

**Acceptance:** the tree has no `*.state.json` code path, and `tests/run.sh` is green.

---

## Task 8: `commands/` → `skills/`

**Blocked by:** Task 7.

Custom commands and skills are the same mechanism now, and skills are the recommended form because
they carry supporting files. `commands/run.md` is 434 lines — the largest single unit in the plugin,
in the form that cannot split.

**Files:**
- Move: `commands/*.md` → `skills/<name>/SKILL.md`
- Create: `skills/run/references/*.md` for the material that is reference rather than instruction

- [ ] **Step 1: move each command**, preserving its frontmatter.
- [ ] **Step 2: split `run`** — instructions stay in `SKILL.md`, reference moves behind a pointer.
      Target under 150 lines in the body; the median skill in both reference plugins is under 180.
- [ ] **Step 3: verify every `/cc-tuner:<name>` still resolves**, including the plugin prefix.
- [ ] **Step 4: `bash tests/run.sh`**, commit — `Move commands to skills`.

---

## Definition of done for the branch

- `bash tests/run.sh` green, and every scenario demonstrably able to fail.
- The merge guard denies when its state is absent — proven by mutation, evidence in the commit.
- No `runctl`, no state file, no journal, no lock, no schema twin.
- Runtime Bash: the merge guard, the session-start hook, and the `--auto` frontier check. Nothing else.
- README states the merge guard's real coverage, without overclaiming.
- One PR.
