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
- **Eval tier** (Task 8, authenticated, costs tokens, run by hand). A real Claude Code session driving
  `spec → plan → run`. This tier is the **only** one that can prove a skill causes `TaskCreate` to be
  called, because in the scenario tier no producer exists.

**The trap, stated so nobody falls into it:** a scenario that asserts something about "the plan file
the skill produced" is asserting about a fixture the test itself wrote. That is a parser test wearing
an end-to-end costume — the same shape as the 82 green `grep` assertions over Markdown. The scenario
tier tests the **validator**; the eval tier tests that the skill's output **passes** it.

## The public signature, defined once

Every task below and the eval use exactly these. Fixing the wording in one place stops the eval from
exercising a shape the skills do not have:

```
/cc-tuner:spec <issue number | URL | free-text description>   # produces the spec
/cc-tuner:plan [--auto] <path-to-spec>                        # writes and publishes the plan
/cc-tuner:run  [--auto] <path-to-spec>                        # works this branch's plan
```

`/spec` takes the raw thing, not a spec path — it is what *creates* the spec, and an earlier draft
wrote `/spec <path-to-spec>`, which is circular. It has no `--auto`: producing a spec unattended is
not a mode this flow offers.

`--auto` is a flag in the same position on the other two. `/run` takes the spec path, not the plan
path: the plan is found from the branch, so passing it would be a second way to say the same thing.

## A decision removed rather than resolved

An earlier version of this plan opened with a measurement: how long a skill's frontmatter hooks stay
active, because the merge guard might be declared there instead of in `hooks.json`.

**That measurement is no longer needed, because the choice is gone.** The guard is registered
globally in `hooks.json`, matching `Bash`, and it scopes *itself* — it acts only on `gh pr merge`, and
only when the target PR's changed files include a cc-tuner plan file. Skill-lifetime semantics never enter
the design, so an undefined boundary in the platform cannot make the gate inert.

This is the better kind of simplification: not answering a hard question, but arranging things so it
is never asked. The measurement remains interesting and is recorded as an open item in the ADR — it is
simply not on this branch's path.

## Task graph

| task | blocked by |
|---|---|
| 0 — scenario harness | — |
| 1 — *(removed — see "A decision removed rather than resolved")* | — |
| 2 — `/cc-tuner:plan` and the plan validator | 0 |
| 3 — execution skill | 2 |
| 4 — merge guard | 0 |
| 5 — `SessionStart` restore | 2 |
| 6 — `doctor` | — |
| 7 — `commands/` → `skills/` | 3 |
| 8 — authenticated eval | 4, 5, 7 |
| 9 — deletion | 6, 8 |

Tasks 0 and 6 start at once. The eval runs **after** the migration, because the thing it must
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

## Task 1: *(removed)*

The measurement of skill frontmatter hook lifetime, which this task used to specify, is no longer on
this branch's path. The merge guard is registered globally in `hooks.json` and scopes itself, so the
skill lifecycle never enters the design — see **A decision removed rather than resolved** above.

The experiment is still worth running one day, and stays recorded as an open item in the ADR. Nothing
here is blocked on it.

---

## Task 2: `/cc-tuner:plan` and the plan validator

**Blocked by:** Task 0.

**Files:**
- Create: `plugins/cc-tuner/skills/plan/SKILL.md`
- Create: `plugins/cc-tuner/skills/plan/plan-template.md`
- Create: `plugins/cc-tuner/scripts/plan-lint.sh` — the validator
- Create: `plugins/cc-tuner/scripts/plan-path.sh` — the one branch→path resolver
- Create: `plugins/cc-tuner/tests/scenarios/scenario-plan-lint.sh`
- Create: `plugins/cc-tuner/tests/scenarios/scenario-plan-path.sh`

**Frontmatter:** `disable-model-invocation: true` — a plan is produced when asked for, never inferred.
`argument-hint: '[--auto] <path-to-spec>'`. The mode is an argument, because the skill's own body is
the only place that branches on it and it has no other way in.

**What the skill instructs, and nothing more:**

1. Read the committed spec named in `$ARGUMENTS`. No path, or no such file → stop. Never reconstruct
   a spec from chat.
2. Break the work into vertical slices — each demoable on its own, each sized to a fresh context
   window. Wide mechanical refactors are the exception: sequence them expand → migrate → contract.
3. Write `<root>/task-plans/<YYYY-MM-DD>-<branch-slug>.md` from the template. The filename carries the branch
   slug so two branches cannot collide, and so Task 5 can find *this* branch's plan rather than the
   newest file on disk.

   **One resolver, shared, fail-closed.** `plan-path.sh` is the only code that turns a branch into a
   plan path, and both the skill and the restore hook call it. Computing the slug independently in two
   places is a second parser for one question — the thing this ADR deletes elsewhere — and the two
   would drift on the first branch name containing a slash or an uppercase letter. The resolver
   defines the normalisation once: lowercase, every character outside `[a-z0-9]` to `-`, runs
   collapsed, ends trimmed.

   **Two modes, because the caller's situation differs.** `plan-path.sh create` prints the canonical
   path for a plan that does not exist yet — `/plan` needs exactly this, and a resolver that only ever
   demanded an existing file could never produce the first one. `plan-path.sh resolve` requires
   **exactly one** existing plan and **exits non-zero on zero and on more than one**. Neither is
   guessable: no match may mean no plan or a renamed branch, and two matches mean two plans with equal
   claim. A resolver that picks one is a resolver that is sometimes silently wrong.

   **Each slice is one unambiguously parsable record**, because Task 5 has to rebuild the graph from
   this file alone and a hook is a shell script, not a reader:

   ```markdown
   ## Slice 3 — Wire the retry budget
   Blocked by: 1, 2
   Owned paths: src/retry/, tests/retry/
   Deciding check: pnpm test tests/retry
   Delivers: a request that exhausts its budget fails with one typed error.

   - [ ] budget is read from config, not hardcoded
   - [ ] exhaustion is observable in the returned error
   ```

   `Blocked by` and the rest are slice-level; `- [ ]` lines are **acceptance criteria inside a slice**
   and are not slices. Conflating the two is what an earlier draft of Task 5 did, and it would have
   restored a list of criteria with no titles and no edges.

   **One source of progress: the checkboxes.** A slice is done when every one of its criteria is
   ticked, and unfinished otherwise. An earlier draft carried a slice-level `Status:` as well, while
   the execution skill only ever ticked checkboxes — two records of the same fact, one of them never
   written. That is the duplication this ADR removes elsewhere, so the field is gone and progress is
   derived.
4. Run `plan-lint.sh` on it and fix what it reports.
5. Commit the plan file. It is the store; an uncommitted plan does not survive anything.
6. Publish to native tasks **in two passes** — `TaskCreate` for every slice, then
   `TaskUpdate addBlockedBy` to wire the edges. `TaskCreate` takes no dependency argument, so one pass
   is impossible.

**`--auto` vs attended:** attended, the skill presents the numbered slices and asks about granularity
and edges, iterating until the user approves, and only then writes. With `--auto` it writes directly.

**Not plan mode**, though an earlier revision of this plan said so. `ExitPlanMode` reads
`~/.claude/plans/<name>.md`, a different document from the one this flow commits to `<root>/task-plans/`, so
wrapping the proposal in it would mean two plan documents for one plan — the duplication this ADR
exists to remove. The cost is real and already accepted elsewhere: plan mode physically prevents a
write before approval and a conversation does not, and the ADR already records the plan as advisory in
attended mode.

- [ ] **Step 1: write `plan-lint.sh`** — given a plan file, exit non-zero if a slice lacks
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
accepts is Task 8's assertion, and is not claimed here.

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
  an override — cc-tuner never rewrites another plugin's skill, it only decides where in the sequence
  each one is invoked. The placement, which an earlier draft left as a single sentence:

  The axis is **what each method persists**, not whether it feels exploratory. An earlier draft called
  `research` and `domain-modeling` read-only and put `prototype` on the task branch; both are backwards.

  **This forces the branch earlier than `/run`.** `commands/spec.md:31` invokes `grilling` with
  `domain-modeling`, and `domain-modeling` writes `CONTEXT.md` and ADRs — so `/spec` persists to the
  repository before `/run` is ever called. An earlier draft placed `grill-with-docs` "inside `/spec`,
  no branch, writes only the spec", which is wrong twice. **The task branch is created by `/spec`,
  before its grilling phase**, and the rule below is what makes that non-negotiable.

  | method | workspace | why |
  |---|---|---|
  | `grill-with-docs`, `grilling` | **task branch, created by `/spec` first** | it calls `domain-modeling`, which writes `CONTEXT.md` and ADRs — it is not spec-only |
  | `research`, `domain-modeling` | **task branch** | their output is kept and committed — a saved artifact is a write, however much reading produced it |
  | `prototype` | **disposable branch or worktree** | its output is throwaway by definition; landing it on the task branch is how a spike becomes the implementation by accident |
  | `tdd` | task branch, around the slice's deciding check | that check is the red/green boundary |
  | `diagnosing-bugs` — reading | task branch | inspection persists nothing |
  | `diagnosing-bugs` — probe edits | **disposable workspace** | instrumentation, bisect stubs and print statements are experiments, and an experiment that lands is a regression waiting |
  | `code-review`, deep-review | on the candidate SHA | they must see exactly what the verdict attests to |

  Three enforceable rules, all ordering: nothing that persists runs before the task branch exists —
  which is why `/spec` creates it, not `/run`; anything throwaway runs somewhere throwaway; nothing
  reviews a SHA that has since moved.
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

## Task 4: The merge check

**Blocked by:** Task 0 (the harness).

**Files:**
- Create: `plugins/cc-tuner/scripts/merge.sh` — the check, and the merge
- Create: `plugins/cc-tuner/hooks/merge-guard.sh` — refuses a raw `gh pr merge` and names the script
- Modify: `plugins/cc-tuner/hooks/hooks.json` — `PreToolUse`, matcher `Bash`
- Create: `plugins/cc-tuner/tests/flow/test_merge.sh`, `test_merge_guard.sh`

**The checking is a script, not a parser.** `merge.sh <pr> <squash|merge> <candidate-sha>` re-reads the
verdict review, the required CI checks and the head SHA from GitHub, refuses unless all three agree at
that exact commit, and always adds `--match-head-commit` itself.

Four earlier revisions put this in the hook, judging the merge inside the agent's Bash command string.
Each round of better parsing produced another form that ran a merge the hook never inspected:
`bash -c`, `eval`, `/usr/local/bin/gh`, a line continuation between `pr` and `merge`, `G=gh; "$G"`,
`$(printf gh)`, and a whitelist for the wrapper's own path that let `echo scripts/merge.sh; gh pr
merge …` through. A shell command is a program; a hook reading it as text is guessing, and that list
does not end. Moving the checks to a script whose inputs are three arguments ends the class.

**The hook's rule is one-directional.** It can over-refuse — `echo gh pr merge` is refused — but it
cannot mis-verify, because it verifies nothing. A raw merge in a form it does not recognise is a
bypass of the same class as the merge button on github.com.

**Out of scope means merge, not refuse.** A pull request with no plan file goes straight through
`merge.sh` unchecked. Refusing there was a deadlock: the hook refuses raw merges and the script
refused everything else, so a repository with cc-tuner installed could not merge an ordinary pull
request at all.

- [ ] **Step 1: write `merge.sh`**, deny-by-default within scope, pass-through outside it, and
      `--check-only` so the eval can observe the positive path without merging.
- [ ] **Step 2: the positive path first.** In scope, verdict at the head, green required CI → merges,
      with the pin. Without this, a script that refused everything would pass every other case.
- [ ] **Step 3: one missing fact at a time**, each refusing: head moved past the review; no verdict;
      red CI; zero required checks. Plus zero-recorded, which is the 0.10.0 reproduction.
- [ ] **Step 4: the caller's belief is checked** — a SHA that is no longer the head refuses.
- [ ] **Step 5: forgery** — wrong author, marker inside other prose, superseded by a later
      `REQUEST_CHANGES`.
- [ ] **Step 6: the hook**, with every historical bypass form as a case, and the sanctioned wrapper
      call allowed — not by a whitelist, but because it contains no `pr merge`.
- [ ] **Step 7: `bash tests/run.sh`**, green, then commit.

**Acceptance:** the positive path merges, each single missing fact refuses, an ordinary pull request
still merges, and every bypass form listed above is refused.

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

- [ ] **Step 1: find this branch's plan** — `<root>/task-plans/*-<current-branch-slug>.md`, tracked in `git`.
      Not "the newest file", which picks the wrong plan the moment two branches have one. None → emit
      nothing and exit 0; silence is the correct output when there is no plan.
- [ ] **Step 2: emit the unfinished slices, with their structure.** Per slice: number, title,
      `Blocked by`, and its unticked acceptance criteria. No `Status` field — progress is derived from
      the checkboxes and there is no second record of it. **Not a flat list of `- [ ]` lines** either:
      those are criteria inside a slice, so emitting them alone would restore a set of checkboxes with
      no titles and no edges, and the dependency graph would be silently lost. Extract via
      `plan-lint.sh`'s parser rather than a second one written here.
- [ ] **Step 2b: emit finished slices that are still referenced.** An unfinished slice's `Blocked by`
      may name a slice that is already done. Restoring only the unfinished ones leaves that edge
      pointing at a task that does not exist, and the restored graph is quietly wrong. Emit every
      referenced blocker, marked done.

      **One algorithm, not a choice.** An earlier draft offered "create it completed, or omit the edge
      deliberately", while the eval asserts the restored graph matches the original — two instructions
      that cannot both be satisfied. The sequence is fixed: **create every referenced completed slice
      as a task, wire all `addBlockedBy` edges, then mark those slices `completed`.** In that order,
      because an edge cannot be added to a task that does not exist yet, and marking first would leave
      the wiring to a second pass that may not happen.
- [ ] **Step 3: make the instruction idempotent** — call `TaskList` first, create only the slices that
      are missing, then re-apply `addBlockedBy` for edges not already present. Written this way even
      though `compact` is excluded, so a future trigger change cannot silently double the plan.
- [ ] **Step 4: `scenario-restore.sh`** — a half-done plan emits exactly the unfinished slices **with
      their `Blocked by` values**; a finished plan emits nothing; a branch with no plan file emits
      nothing. Plus the case the naive implementation gets wrong: **an unfinished Slice 3 blocked by a
      finished Slice 2** must emit Slice 2 as well, marked done — not an edge into nothing.
- [ ] **Step 5: `bash tests/run.sh`**, commit — `Restore the plan on session start`.

**Acceptance:** `clear` is covered as well as `startup`; the emitted context carries slice titles and
edges, not just criteria; and the instruction is idempotent against an already-populated task list.
That the agent then rebuilds a `TaskList` whose `blockedBy` matches is Task 8's assertion.

---

## Task 6: `doctor`, and dropping `tracker: none`

**Blocked by:** none.

**Files:**
- Modify: `plugins/cc-tuner/scripts/setup/doctor.sh`

`claude plugin list --json` returns `id`, `version`, `scope`, `enabled`, `installPath` and
`projectPath` directly, so `doctor.sh` stops calling the manifest resolver.

**It does not answer "which installation applies" — the precedence rule still has to exist.** Checked
against a live Claude Code 2.1.231: cc-tuner comes back as **two** rows, `scope: "project"` with a
`projectPath` and `scope: "user"` with `projectPath: null`, **both `enabled: true`**, and there is no
`active` field. So this task replaces the manifest *parsing*, not the selection: prefer a row whose
`scope` is local or project **and** whose `projectPath` is this repository, then fall back to `user`;
ignore any row whose `projectPath` names a different project. Taking the first row, or any row, is a
coin flip between two installations — and reporting the wrong version is exactly the failure that
started this rework.

**The resolver itself is not deleted here.** `execute_task_manifest_roots` lives in `lib.sh`, which is
sourced by the execute-task scripts and `run-state-hook.sh`. Removing it while those consumers exist
breaks them in the same commit. This task changes the one caller that has a native replacement; the
function goes in Task 9, after its remaining consumers do. (`smoke-verify` is not among them — it has
its own `scripts/smoke-verify/lib.sh`.)

- [ ] **Step 1: point `doctor.sh` at `claude plugin list --json`** and stop it calling the resolver.
- [ ] **Step 2: retire the `none` tracker everywhere it is expressible**, not only in `/run`. It is
      written several ways: the prose at `commands/spec.md:140`, the **template's `tracker: gh|none`
      at `commands/spec.md:124`**, and any config or test that accepts it as a value. It was always
      inconsistent, since `/run` requires a PR and GitHub CI unconditionally.
- [ ] **Step 3: check semantically, not by literal string.** `grep -rn 'tracker: none'` misses
      `tracker: gh|none`, a `["gh","none"]` array, and the template — the exact miss that left it
      behind last time. Grep for the **field**, `grep -rn 'tracker' plugins/`, and read each hit.
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
- [ ] **Step 2b: rewrite `spec` so it creates the task branch before grilling.** `commands/spec.md:29`
      invokes `grilling` with `domain-modeling` today, and `domain-modeling` writes `CONTEXT.md` and
      ADRs — so `/spec` persists to the repository with no branch. The placement rule in Task 3 says
      the branch comes first; without this step that rule is a paragraph nobody implements. Move
      branch creation ahead of section 2 of the command.
- [ ] **Step 2c: scenario for the order** — run `/spec`'s branch-creation step against a fixture and
      assert the branch exists before any write outside the spec file. A placement rule with no test
      is a comment.
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

- [ ] **Step 0: run against THIS checkout, and prove it.** Launch with
      `claude --plugin-dir <repo>/plugins/cc-tuner`, which the reference designates for local plugin
      testing and which takes precedence over an installed marketplace copy. Then **record the
      resolved plugin path and the repository SHA in the eval log**. Without this the eval can exercise
      the installed 0.10.0 and report a pass — which is not a hypothetical, it is precisely the
      original defect: sessions holding a frozen `${CLAUDE_PLUGIN_ROOT}` while everyone read the new
      code.
- [ ] **Step 1: attended, the whole flow, starting at `/spec`.** In a scratch repository:
      `/cc-tuner:spec <description>`, then `/cc-tuner:plan <spec>`, then `/cc-tuner:run <spec>`. An
      earlier draft began at `/plan` while claiming to prove `spec → plan → run`; `/spec` is also
      where the task branch is created and where `domain-modeling` first writes, so skipping it skips
      the placement rule entirely. Confirm the branch exists before `CONTEXT.md` is written, and then:
      /plan presents the slices and waits for approval before writing anything,
      the plan file is committed, `plan-lint.sh` accepts it, `TaskList` shows the slices **with their
      `blockedBy` edges**, `/run` works them in frontier order, ticks the checkboxes, and stops at each
      delivery boundary. The edges are the part a one-pass implementation would silently drop.
- [ ] **Step 2: `--auto`, the whole flow, in a fresh repository, branch and session.** Not a
      continuation of step 1: reusing that workspace would let `--auto` inherit the attended run's
      plan file and task list, and it would pass without ever creating either. `/cc-tuner:spec`, then
      `/cc-tuner:plan --auto <spec>`, then `/cc-tuner:run --auto <spec>` — same signature, `--auto` in
      the same position: no approval
      question, plan committed, tasks created, boundaries not stopped at, and a task whose `blockedBy`
      is non-empty refused when attempted out of order.
- [ ] **Step 2b: producer → guard, the whole positive path.** Confirm the run posts the verdict review
      **only after** the `--required` approval marker, that `gh pr view --json reviews` returns it with
      `commit.oid` equal to the head SHA, and then **run `merge.sh --check-only <pr> <strategy> <sha>`
      against that real PR and CI and confirm it reports the candidate would be accepted** — the flag
      exists for exactly this, because a check that can only be run by merging is one nobody runs
      twice.
      Steps 4 below and the scenarios cover denial; without this the live positive path is never
      exercised end to end, and a producer that writes a marker the guard cannot read would pass
      everything.
- [ ] **Step 3: recovery, asserted on the graph.** Start a fresh session in that repository. Confirm
      the `SessionStart` context arrives and that the rebuilt `TaskList` carries **the same
      `blockedBy` edges as before**, not merely the same number of rows. Then `/clear` and confirm the
      same. Then `/compact` and confirm **no duplication**.
- [ ] **Step 4: the merge guard, live.** On a PR whose head SHA carries no verdict review, attempt
      `gh pr merge` and confirm the denial reaches the agent as a refusal it reports, not a silent
      retry.
- [ ] **Step 5: record every outcome** in `tests/eval/README.md` with the date and the observed
      behaviour, in the same MEASURED style as the spike. Commit.

**Acceptance:** **every step above** observed PASS in a real session — 0, 1, 2, 2b, 3, 4 and 5. An
earlier draft said "all five steps" while listing seven, which would have let the two that matter most
fall outside acceptance: step 0, which proves the eval tested this checkout rather than the installed
version, and step 2b, the only live proof that the producer writes something the guard can read.
**A step recorded as not-yet-run leaves
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

- [ ] **Step 1: free the one surviving consumer of `execute-task/lib.sh` FIRST.** `prereq-check.sh`
      sources it at line 39 and survives this task, so deleting `lib.sh` in the same commit breaks it —
      green-at-every-commit violated. Inline the helpers it actually uses, including
      `execute_task_manifest_roots` if it still needs it after Task 6, run the suite, commit. Only
      then is `lib.sh` free to go.

      **`smoke-verify` is not a consumer.** `mark.sh` and `smoke-verify-hook.sh` source their own
      `scripts/smoke-verify/lib.sh`; an earlier draft listed them here on the strength of a
      `grep -l lib.sh`, which matches the string anywhere including comments. Checking who sources
      *which* file is the difference between a correct deletion order and a broken one.
- [ ] **Step 2: handle a legacy run — a warning plus one real refusal.** A repository still holding
      `.claude/execute-task-runs/*.state.json` is mid-flight on a runtime that no longer exists; left
      unhandled the old machinery does not merely disappear, it silently fails open — the defect being
      deleted, reintroduced by the deletion.

      **`SessionStart` cannot stop anything.** The reference is explicit: *"Can block? No — shows
      stderr to user only."* An earlier draft of this step specified a hard stop there, which would
      have shipped a warning labelled as a gate. So it splits:

      - `SessionStart` emits an **advisory** notice naming the leftover file and what to do — finish
        the run under the old plugin version, or delete the state and re-plan. Advisory, and called
        that.
      - the **merge guard** — already fail-closed and already in a blocking event — denies while a
        legacy state file is present. That places the one real refusal where a mistake actually costs
        something, and adds no new fence.

      Migration of the old state is explicitly not offered; detection is.
- [ ] **Step 3: delete, one commit per subsystem**, so a bisect can land between them.
- [ ] **Step 4: `bash tests/run.sh`** after each — green at every one.
- [ ] **Step 5: `grep -rn runctl plugins/ docs/`** — no live reference survives. A doc naming a deleted
      script is a broken instruction, not a stale comment.
- [ ] **Step 6: reduce the thirty invariants** to those with something that reads them at runtime.
      Cap at seven, per the ADR's complexity budget.

**Acceptance:** nothing in the tree **creates or modifies** a `*.state.json`; the only code that still
mentions one is the **read-only** legacy detector, so "an existing legacy run is detected" and "no
state-file code path" are not in conflict — an earlier draft asserted both without saying which kind
of access survives. And `tests/run.sh` is green at every commit in the sequence.

---

## Definition of done for the branch

- `tests/run.sh` green **at every commit**, and the harness demonstrably able to report a failure.
- The merge guard denies when its evidence is absent or stale, and stays silent outside a run — all
  proven by mutation, evidence in the commit.
- The eval record shows every step PASS in a real session: `spec → plan → visible tasks with edges →
  recovery preserving those edges → a live merge denial`.
- No `runctl`, no state file, no journal, no lock, no schema twin.
- Runtime Bash: `merge.sh`, the `PreToolUse` hook that routes merges to it, the session-start hook,
  the plan linter, `plan-path.sh`, and the `--auto` frontier
  check. Nothing else.
- README states the merge guard's real coverage, without overclaiming.
- One PR.
