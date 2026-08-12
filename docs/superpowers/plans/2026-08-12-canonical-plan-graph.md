# PR 2 — `/cc-tuner:plan` and the Canonical Task Graph — Implementation Plan

> **For agentic workers:** implement task-by-task, in order. Each task ends with its own test run and
> commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the task graph becomes durable state that `runctl` owns and enforces — dependencies,
frontier, ownership — and `/cc-tuner:plan` is the one place it is authored. The visible Claude task
list becomes a recoverable projection of that state instead of a precondition for it.

**Architecture:** `runctl` grows a task schema that carries `blocked_by`, `owned_paths`, `delivers`,
`acceptance` and `checks`, imported **atomically** from a prepared file — a partially imported graph
must not be representable. `task start` gates on the frontier (all blockers completed), not on the
presence of a UI id; a lost UI task is re-created and re-bound through the existing `bind-ui`.
`/cc-tuner:plan` is model-invocable, reads the committed spec, calls `codebase-design` to place seams,
slices into independently verifiable vertical slices with dependency edges, imports the graph, and
stops before implementation. `/run` resumes the graph and executes the frontier instead of
re-planning from prose on every resume.

**Tech Stack:** bash 3.2, `jq`, JSON Schema (draft the repo already uses), markdown command files,
`tests/run.sh`.

## Global Constraints

Same as PR 1, repeated because this plan is executed independently:

- bash 3.2 compatible. No `mapfile`/`readarray`, no associative arrays, no `${var^^}`.
- Every guard ships with a test that FAILS when the guard is reverted, proven by reverting.
- **Mutation proofs never use `git checkout --`** — the implementation is uncommitted and would be
  destroyed. Use `cp <file> <file>.premutation` … `cp <file>.premutation <file>`, then re-run the
  suite to confirm green before committing.
- **Anchor edits on quoted strings, not line numbers** — several tasks edit `runctl.sh`.
- No second copy of a rule and no second parser for one question.
- Short imperative commit subjects. No `Co-Authored-By` and no Claude attribution.
- `bash tests/run.sh` prints `cc-tuner validate ok` at the end of every task.
- Work on a task branch off `main`, separate from PR 1's.

## Decisions this plan encodes

- **The planning rules are cc-tuner's own, and executable.** DAG, frontier, vertical deliverable and
  dependency enforcement are implemented in `runctl` and validated there. `to-tickets` is the
  architectural influence, credited in the ADR and CHANGELOG; its text is neither read at runtime nor
  copied. This is what makes the rules ours: a Matt release cannot change our workflow.
- **`schema_version` bumps to 2, and the hook must learn about it in the same commit.**
  `run-state-hook.sh` selects active state with `.schema_version == 1`. A bump alone would make every
  state file invisible to the hook and silently disarm the mutation and merge gates — the exact class
  of silent-disarm failure observed in Marqa/Stokli. The hook accepts 1 or 2 and a test proves the
  fence stays armed for a v1 state on disk.
- **The graph is imported atomically, through the prepared-file mechanism that already exists.**
  `runctl prepare` already owns a path outside the repository that the mutation fence permits, with
  symlink, ownership and hard-link checks. `prepare` takes a third name, `plan`, rather than opening a
  second hole in the fence — a second exception would be two answers to one question. `plan import`
  itself accepts any readable regular file: it only reads, and the fence governs *writes*, so refusing
  other paths would buy nothing while making the graph untestable from a fixture. `cleanup` must know
  the `plan` name too, or the run's own scratch file blocks its teardown.
- **A visible binding stays a precondition for starting a task; the frontier is added on top.**
  *Revised during implementation.* This plan originally said `task start` should gate on the graph and
  not on `ui_task_id`. That contradicts `visible-plan-before-mutation` in `workflow-contract.json` —
  "the agent publishes a visible lifecycle plan before editing, generating, staging, or delegating task
  paths" — which the existing `task start` enforced through exactly that field, with a test
  (`fix-task-cannot-start-before-visible-binding`) to prove it. The repo's documented contract wins
  over this plan. The two conditions are independent and both hold: the binding says the user can see
  the work, the frontier says the graph permits it. "Losing a visible task never blocks the lifecycle"
  is therefore delivered by recovery — `task bind-ui`, and re-creation on resume — not by dropping the
  requirement.
- **Missing review, test or CI evidence always blocks.**
- **`/cc-tuner:plan` is the only model-invocable cc-tuner command** (`/spec` and `/run` carry
  `disable-model-invocation: true`). It therefore stops after publishing the graph, regardless of who
  invoked it — the stop is a property of the command, not a rule about direct invocation.

## File Structure

| File | Responsibility after this PR |
|---|---|
| `plugins/cc-tuner/schemas/run-state.schema.json` | task v2: `title`, `delivers`, `owned_paths`, `acceptance`, `checks`, `blocked_by`; `schema_version` enum `[1, 2]` during the transition |
| `plugins/cc-tuner/scripts/execute-task/runctl.sh` | v1→v2 migration in `load_state`; `plan import\|frontier\|publish`; `task start` gates on frontier; `prepare` accepts `plan` |
| `plugins/cc-tuner/hooks/run-state-hook.sh` | accepts v1 and v2 active state |
| `plugins/cc-tuner/commands/plan.md` | *new* — model-invocable authoring of the graph, stops before implementation |
| `plugins/cc-tuner/commands/spec.md` | hands off to `/cc-tuner:plan` instead of `/run` |
| `plugins/cc-tuner/commands/run.md` | Phase 1 materializes and reconciles the published graph; no prose re-planning |
| `plugins/cc-tuner/scripts/execute-task/prereq-check.sh` | adds the `plan` profile (`codebase-design`) |
| `plugins/cc-tuner/workflow-contract.json` | four new invariants |
| `plugins/cc-tuner/tests/execute-task/test_run_state.sh` | graph regressions |
| `plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh` | v1 state still arms the fence after the bump |
| `plugins/cc-tuner/tests/execute-task/test_contract.sh` | doc-contract assertions for the new flow |
| `docs/adr/` | ADR recording that the planning contract is influenced by `to-tickets` and owned here |

---

### Task 1: Record the graph regressions RED

**Files:**
- Modify: `plugins/cc-tuner/tests/execute-task/test_run_state.sh`

**Interfaces:**
- Produces: the failing suite every later task in this PR turns green. Nothing consumes it.

Write the negative cases before any runtime change, so each later task has a specific failure to
close rather than a claim to make. Cases, each asserting a non-zero exit and a message naming the
cause:

- [ ] **Step 1: Add the cases**

Add to `test_run_state.sh`, using its existing fixture helpers:

1. `unknown-blocker-rejected` — `plan import` with `blocked_by: ["nope"]` exits non-zero naming `nope`.
2. `self-reference-rejected` — a task blocked by itself is refused.
3. `cycle-rejected` — `a → b → a` is refused, and the message names both ids.
4. `duplicate-blocker-rejected` — the same id listed twice is refused.
5. `blocked-task-cannot-start` — `task start` on a task whose blocker is `pending` exits non-zero.
6. `frontier-lists-only-startable-tasks` — with `a` completed and `b` blocked by `a`, `plan frontier`
   prints `b` and not the tasks blocked behind it.
7. `completed-task-cannot-restart` — `task start` on a `completed` task is refused.
8. `ui-id-is-not-required-to-start` — a task with `ui_task_id: null` whose blockers are complete
   starts successfully.
9. `lost-ui-task-can-be-rebound` — `bind-ui` replaces a stale id and `task start` still works.
10. `resume-does-not-duplicate-tasks` — importing the same graph twice leaves the task count unchanged
    and reports the second import as a no-op rather than appending.
11. `overlapping-owned-paths-not-in-one-frontier-batch` — two startable tasks whose `owned_paths`
    overlap are not both offered as parallelizable; `plan frontier --parallel` returns one.
12. `partial-import-is-not-representable` — an import that fails validation leaves `.tasks` exactly as
    it was (assert the byte-identical `jq -S '.tasks'` before and after).

- [ ] **Step 2: Run and confirm every new case fails**

```bash
cd /Users/clicktronix/Projects/ai/cc-tuner
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh; echo "rc=$?"
```

Expected: the pre-existing cases still PASS; all twelve new ones FAIL (`plan` is an unknown
subcommand, `blocked_by` does not exist). `rc=1`. **A new case that passes here is a broken fixture,
not finished work** — fix the fixture before continuing.

- [ ] **Step 3: Commit the RED suite**

```bash
git add plugins/cc-tuner/tests/execute-task/test_run_state.sh
git commit -m "Record the task-graph regressions as failing tests"
```

Committing RED is deliberate: it makes the baseline reviewable and every later commit's transition
observable in history.

---

### Task 2: Task schema v2, with a migration that keeps the gates armed

**Files:**
- Modify: `plugins/cc-tuner/schemas/run-state.schema.json`
- Modify: `plugins/cc-tuner/scripts/execute-task/runctl.sh` — `load_state`
- Modify: `plugins/cc-tuner/hooks/run-state-hook.sh` — the active-state jq predicate
- Modify: `plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh`

**Interfaces:**
- Produces: the v2 task record. Tasks 3–6 write and read it.

```json
{
  "id": "authenticated-api",
  "title": "Connect authenticated API",
  "phase": "implementation",
  "delivers": "An authenticated request succeeds end to end",
  "owned_paths": ["src/auth/", "tests/auth/"],
  "acceptance": ["An unauthorized request is rejected"],
  "checks": ["pytest tests/auth -q"],
  "blocked_by": ["auth-boundary"],
  "status": "pending",
  "ui_task_id": null,
  "evidence": null,
  "updated_at": "..."
}
```

- [ ] **Step 1: Write the failing hook test**

The bump's real risk is not validation, it is the hook going blind. Add to
`test_run_state_hook.sh`:

```bash
# A schema bump must not disarm the fence. run-state-hook.sh selects active state by
# `.schema_version == N`; if that predicate stops matching, every gate silently allows — which is the
# failure mode that left runs in Marqa and Stokli with no enforcement at all.
for v in 1 2; do
  <fixture: an active state for the current branch with schema_version = $v>
  <invoke the hook as pre-tool-use with an Edit on a task-owned path outside the current phase>
  <assert exit 2 — the mutation is denied>
  echo "PASS fence-armed-for-schema-v$v"   # or FAIL
done
```

- [ ] **Step 2: Run and confirm the v2 case fails**

Expected: `PASS fence-armed-for-schema-v1`, `FAIL fence-armed-for-schema-v2`.

- [ ] **Step 3: Extend the schema**

In `run-state.schema.json`:
- `properties.schema_version`: replace `{"const": 1}` with `{"enum": [1, 2]}`.
- `$defs.task`: add `title` (string, minLength 1), `delivers` (string, minLength 1), `owned_paths`
  (array of non-empty strings, `uniqueItems`), `acceptance` (array of strings), `checks` (array of
  strings), `blocked_by` (array of `#/$defs/id`, `uniqueItems`). Add all six to `required` — the task
  keeps `additionalProperties: false`, so migration must fill them rather than leave them absent.

- [ ] **Step 4: Migrate in one place**

In `runctl.sh`'s `load_state`, after the state is read and before any caller sees it, upgrade a v1
document in place:

```bash
# One migration point. A per-subcommand upgrade would leave whichever path nobody exercised writing
# v1 records into a v2 document, and the schema's additionalProperties:false would then reject the
# file only on the next validation — long after the run that produced it.
if [ "$(jq -r '.schema_version' "$STATE")" = "1" ]; then
  update_state '.schema_version = 2
    | .tasks = [ .tasks[] | . + {
        title: (.title // .description),
        delivers: (.delivers // .description),
        owned_paths: (.owned_paths // []),
        acceptance: (.acceptance // []),
        checks: (.checks // []),
        blocked_by: (.blocked_by // [])
      } ]'
fi
```

A migrated v1 run gets an empty `blocked_by` for every task: it recorded no dependencies, so none can
be invented. That is a truthful upgrade, not a lossy one.

- [ ] **Step 5: Teach the hook both versions**

```bash
grep -n 'schema_version == 1' plugins/cc-tuner/hooks/run-state-hook.sh
```

Replace `.schema_version == 1` with `(.schema_version == 1 or .schema_version == 2)` in that jq
predicate. Both are accepted for the transition: a state file written before this release is still a
run whose gates must hold.

- [ ] **Step 6: Run the suites**

```bash
bash plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh; echo "rc=$?"
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh;      echo "rc=$?"
bash tests/run.sh | tail -3
```

Expected: the hook suite `rc=0` with both `fence-armed-for-schema-v*` passing; `test_run_state.sh`
still red on the twelve graph cases (Task 3 closes those); `cc-tuner validate ok`.

- [ ] **Step 7: Mutation proof**

```bash
cp plugins/cc-tuner/hooks/run-state-hook.sh /tmp/hook.premutation
perl -0pi -e 's/\(\.schema_version == 1 or \.schema_version == 2\)/.schema_version == 1/' \
  plugins/cc-tuner/hooks/run-state-hook.sh
bash plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh | grep '^FAIL'
cp /tmp/hook.premutation plugins/cc-tuner/hooks/run-state-hook.sh
```

Expected: `FAIL fence-armed-for-schema-v2`. This is the guard that makes the bump safe; if it does not
fail here, it is not guarding anything.

- [ ] **Step 8: Commit**

```bash
git add plugins/cc-tuner/schemas/run-state.schema.json \
        plugins/cc-tuner/scripts/execute-task/runctl.sh \
        plugins/cc-tuner/hooks/run-state-hook.sh \
        plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh
git commit -m "Carry task dependencies in state and keep the fence armed across the bump"
```

---

### Task 3: Import the graph atomically

**Files:**
- Modify: `plugins/cc-tuner/scripts/execute-task/runctl.sh` — usage block, `prepare`, new `plan`
  subcommand
- Modify: `plugins/cc-tuner/tests/execute-task/test_run_state.sh` (fixtures only; the cases exist)

**Interfaces:**
- Consumes: the v2 task record (Task 2) and the prepared-file mechanism (`ensure_prepared_directory`,
  `PREPARED_DIR`).
- Produces:
  ```
  runctl.sh prepare <run-id> commit-message|pr-body|plan
  runctl.sh plan <run-id> import <prepared-file>
  runctl.sh plan <run-id> frontier [--parallel]
  runctl.sh plan <run-id> publish
  ```
  Task 4 uses `frontier`; Task 5's command uses `prepare … plan`, `import` and `publish`.

- [ ] **Step 1: Accept `plan` as a prepared-file name**

```bash
grep -n "commit-message|pr-body) ;;" plugins/cc-tuner/scripts/execute-task/runctl.sh
```

Extend that case to `commit-message|pr-body|plan` and the error message accordingly. Nothing else in
`prepare` changes: the graph file gets the same outside-the-repository path, ownership, symlink,
hard-link and `chmod 600` treatment the commit message already gets. Reusing it is the point — the
mutation fence keeps exactly one permitted location.

- [ ] **Step 2: Implement `plan import` as validate-everything-then-write-once**

Add the `plan)` case. Structure, with the reasons that shape it:

```bash
plan)
  # The graph is written in one update or not at all. Building it with a sequence of `task add` calls
  # would make a half-imported plan a representable state: the run would hold tasks whose blockers do
  # not exist yet, and `frontier` would answer from it. Validation therefore runs against the WHOLE
  # candidate document before a single field of the live state is touched.
  [ "$#" -ge 3 ] || usage
  state_paths "$2"; lock_state; load_state; assert_active
  case "$3" in
    import) ... ;;
    frontier) ... ;;
    publish) ... ;;
    *) execute_task_die "unknown plan action '$3'" ;;
  esac
  ;;
```

`import` validates, in this order, and dies naming the offending id on the first failure:

1. the file parses as JSON and is an array of task objects;
2. the run is in `planning` — the same restriction `task add` already carries;
3. every `id` matches `execute_task_validate_item_id` and is unique;
4. no id begins with `review-fix-` (reserved for fix-loop tasks);
5. every `phase` is in the schema's enum;
6. `title`, `delivers` are non-empty; `owned_paths` is non-empty for `implementation` tasks;
7. every entry in `blocked_by` names an id present in the same import, with no self-reference and no
   duplicates;
8. the `blocked_by` relation is acyclic — implement as a Kahn peel in `jq`: repeatedly drop tasks
   whose blockers are all already dropped; if a round drops nothing and tasks remain, the remainder is
   the cycle, and the message names those ids;
9. the lifecycle is complete — the import carries at least one `implementation` task and one task in
   each of `testing`, `acceptance`, `candidate`, `review`, `delivery`;
10. `owned_paths` are repo-relative, contain no `..` segment and are not absolute.

Only after all ten does it write, in one `update_state`, replacing `.tasks` wholesale. Re-importing a
byte-identical graph is a no-op that reports `PLAN UNCHANGED <run-id>` and exits 0 — that is what
makes resume idempotent (case 10 of Task 1).

`frontier` prints the ids of tasks whose `status` is `pending` or `blocked` and whose every blocker is
`completed`. With `--parallel` it additionally drops any task whose `owned_paths` overlap a task
already in the printed set, so two slices writing the same directory are never offered as concurrent
work.

`publish` records that the graph was published — the fact of first publication, which Task 6's
`canonical-plan-before-mutation` invariant reads — and refuses when `.tasks` is empty.

- [ ] **Step 3: Update the usage block**

```bash
grep -n 'runctl.sh prepare <run-id> commit-message|pr-body' plugins/cc-tuner/scripts/execute-task/runctl.sh
```

Add the three `plan` lines and the extended `prepare` line.

- [ ] **Step 4: Run the graph suite**

```bash
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh; echo "rc=$?"
```

Expected: cases 1–4, 6, 10, 11, 12 from Task 1 now PASS. Cases 5, 7, 8, 9 (`task start` behaviour)
remain FAIL — Task 4 closes them.

- [ ] **Step 5: Mutation proof**

```bash
cp plugins/cc-tuner/scripts/execute-task/runctl.sh /tmp/runctl.premutation
# make the cycle check inert
perl -0pi -e 's/^(\s*)# Kahn peel/$1if false; then # Kahn peel/m' \
  plugins/cc-tuner/scripts/execute-task/runctl.sh   # adjust the anchor to the code as written
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh | grep '^FAIL'
cp /tmp/runctl.premutation plugins/cc-tuner/scripts/execute-task/runctl.sh
```

Expected: `FAIL cycle-rejected`. Repeat once for `partial-import-is-not-representable` by making the
write happen before validation — that one proves atomicity, which is the whole reason this subcommand
exists.

- [ ] **Step 6: Commit**

```bash
bash tests/run.sh | tail -3
git add plugins/cc-tuner/scripts/execute-task/runctl.sh \
        plugins/cc-tuner/tests/execute-task/test_run_state.sh
git commit -m "Import the task graph atomically through a validated prepared file"
```

---

### Task 4: Gate task start on the frontier, not on a UI id

**Files:**
- Modify: `plugins/cc-tuner/scripts/execute-task/runctl.sh` — the `task … start` case
- Modify: `plugins/cc-tuner/tests/execute-task/test_run_state.sh` (fixtures only)

**Interfaces:**
- Consumes: `blocked_by` (Task 2) and `plan frontier` (Task 3).
- Produces: `task start` semantics Task 6's `/run` relies on.

- [ ] **Step 1: Change the start predicate**

```bash
grep -n 'is not startable in phase' plugins/cc-tuner/scripts/execute-task/runctl.sh
```

The current predicate requires `(.ui_task_id | type == "string" and length > 0)`. Replace that clause
with a blocker check:

```bash
# Readiness is a property of the graph, not of the display. Requiring a UI id here made a lost or
# unrenderable Claude task into a stalled run, while a task whose blockers were still open could start
# freely as long as it had an id — exactly backwards.
jq -e --arg id "$TASK_ID" --arg phase "$CURRENT" '
  . as $s
  | any(.tasks[]; .id == $id and .phase == $phase
      and (.status == "pending" or .status == "blocked")
      and all(.blocked_by[]?; . as $b | any($s.tasks[]; .id == $b and .status == "completed")))
' "$STATE" >/dev/null 2>&1 \
  || execute_task_die "task '$TASK_ID' is not on the frontier in phase '$CURRENT': it is missing, already completed, or has open blockers"
```

- [ ] **Step 2: Run and confirm the remaining cases close**

```bash
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh; echo "rc=$?"
```

Expected: cases 5, 7, 8, 9 now PASS; the whole suite `rc=0`.

- [ ] **Step 3: Confirm evidence gating is untouched**

A UI id stops being a precondition for *starting*; it must not stop being how the `TaskCompleted` hook
finds the task it checks evidence for. Re-run the hook suite:

```bash
bash plugins/cc-tuner/tests/execute-task/test_run_state_hook.sh; echo "rc=$?"
```

Expected: `rc=0`, unchanged. If a case fails here, the change went too far — completion evidence
still gates, only readiness moved.

- [ ] **Step 4: Mutation proof**

```bash
cp plugins/cc-tuner/scripts/execute-task/runctl.sh /tmp/runctl.premutation
perl -0pi -e 's/and all\(\.blocked_by\[\]\?;/and all([];/' \
  plugins/cc-tuner/scripts/execute-task/runctl.sh
bash plugins/cc-tuner/tests/execute-task/test_run_state.sh | grep '^FAIL'
cp /tmp/runctl.premutation plugins/cc-tuner/scripts/execute-task/runctl.sh
```

Expected: `FAIL blocked-task-cannot-start`.

- [ ] **Step 5: Commit**

```bash
bash tests/run.sh | tail -3
git add plugins/cc-tuner/scripts/execute-task/runctl.sh \
        plugins/cc-tuner/tests/execute-task/test_run_state.sh
git commit -m "Start tasks from the frontier instead of the visible task id"
```

---

### Task 5: Add `/cc-tuner:plan`

**Files:**
- Create: `plugins/cc-tuner/commands/plan.md`
- Create: `docs/adr/2026-08-12-planning-contract.md`
- Modify: `plugins/cc-tuner/scripts/execute-task/prereq-check.sh` — add the `plan` profile
- Modify: `plugins/cc-tuner/tests/execute-task/test_prereq.sh`
- Modify: `plugins/cc-tuner/tests/execute-task/test_contract.sh`

**Interfaces:**
- Consumes: `prepare … plan`, `plan import`, `plan publish` (Task 3); `codebase-design` via the new
  profile.
- Produces: the command Task 6 wires `/spec` and `/run` to.

- [ ] **Step 1: Write the failing assertions**

In `test_contract.sh`, add `PLAN="$ROOT/plugins/cc-tuner/commands/plan.md"` next to the other path
constants, then:

```bash
[ -f "$PLAN" ] && echo "PASS plan-command-exists" || { echo "FAIL plan-command-exists"; fails=1; }
need "plan-is-model-invocable" 'disable-model-invocation: false' "$PLAN"
need "plan-stops-before-implementation" 'stops here regardless of who invoked it' "$PLAN"
need "plan-imports-atomically" 'plan "$RUN_ID" import' "$PLAN"
need "plan-uses-codebase-design" 'mattpocock-skills:codebase-design' "$PLAN"
need "plan-expand-contract-for-wide-refactors" 'expand → migrate → contract' "$PLAN"
```

In `test_prereq.sh`, add a case: with `codebase-design` absent, `--profile plan` exits 1 naming it,
while `--profile spec` still exits 0.

- [ ] **Step 2: Run and confirm both suites fail**

Expected: `FAIL plan-command-exists` plus the five `need` failures, and the new prereq case failing
with `unknown profile 'plan'` (exit 2, not 1).

- [ ] **Step 3: Add the `plan` profile**

In `prereq-check.sh`, accept `plan` in the `--profile` case, and add the registry row:

```
codebase-design|plan|skills/engineering/codebase-design/SKILL.md|/plan places seams and module ownership
```

- [ ] **Step 4: Write `commands/plan.md`**

Frontmatter:

```markdown
---
description: Turn a committed spec into cc-tuner's canonical task graph — vertical slices with owned paths, acceptance, checks and blocking edges — import it into run state, and publish the visible plan. Stops before implementation.
argument-hint: '<path to the committed spec>'
allowed-tools: Bash, Read, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList
disable-model-invocation: false
---
```

Body, in this order:

1. **Verify the profile** — `prereq-check.sh --profile plan`.
2. **Read the committed spec.** Refuse if it is uncommitted or its `Run config` is incomplete; this
   command plans what `/spec` decided and reopens nothing.
3. **Place the seams** — invoke `mattpocock-skills:codebase-design` to name the modules the change
   belongs to and where the boundaries fall. This is the one method `/plan` uses.
4. **Slice.** State the rules as cc-tuner's own, executable ones:
   - each slice is independently verifiable and cuts a complete path through the layers it touches —
     schema, API, UI, tests — not one horizontal layer;
   - `delivers` states the end-to-end behaviour the slice makes work, from the user's perspective;
   - each slice is sized to fit one fresh context window;
   - setup, configuration and documentation fold into the slice that needs them; split only where a
     reviewer could reject one slice while approving its neighbour;
   - `owned_paths` are disjoint between slices that can run concurrently;
   - dependencies form a DAG — `runctl` rejects cycles, unknown blockers and self-reference, so this
     is enforced rather than requested;
   - a **wide refactor** — one mechanical change whose blast radius fans across the codebase, so no
     vertical slice can land green — is sequenced **expand → migrate → contract**: add the new form
     beside the old, migrate call sites in batches each blocked by the expand, delete the old form in a
     slice blocked by every batch.
5. **Add the lifecycle slices** — testing, acceptance, candidate, review, delivery — with the edges
   that put them after the implementation slices.
6. **Write and import**:
   ```bash
   PLAN_FILE="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" prepare "$RUN_ID" plan)"
   # write the graph JSON to "$PLAN_FILE"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-task/runctl.sh" plan "$RUN_ID" import "$PLAN_FILE"
   ```
7. **Publish the visible plan** — `TaskCreate` per task, `TaskUpdate` for `blockedBy` mirroring
   `blocked_by`, then bind each returned id with `runctl task … bind-ui`. State explicitly that the
   visible list is a projection: if it is lost, it is re-created and re-bound, and the run continues.
8. **Stop.** Say so in the words the test asserts: this command publishes the graph and **stops here
   regardless of who invoked it** — implementation is `/cc-tuner:run`'s phase, and a model that can
   start planning on its own must not be able to continue into writing code.

- [ ] **Step 5: Write the ADR**

`docs/adr/2026-08-12-planning-contract.md`: cc-tuner owns its planning contract — vertical slices,
DAG, frontier, path ownership — implemented and enforced in `runctl`. The shape is influenced by
Matt Pocock's `to-tickets` (MIT, `github.com/mattpocock/skills`); its text is neither read at runtime
nor copied, so an upstream release cannot change this workflow. Record the alternative that was
rejected (reading `to-tickets/SKILL.md` at runtime) and why.

- [ ] **Step 6: Run the suites**

```bash
bash plugins/cc-tuner/tests/execute-task/test_contract.sh; echo "rc=$?"
bash plugins/cc-tuner/tests/execute-task/test_prereq.sh;   echo "rc=$?"
bash tests/run.sh | tail -3
```

Expected: `rc=0` from both and `cc-tuner validate ok`.

- [ ] **Step 7: Mutation proof**

```bash
cp plugins/cc-tuner/commands/plan.md /tmp/plan.premutation
perl -0pi -e 's/stops here regardless of who invoked it/stops here when you invoked it directly/' \
  plugins/cc-tuner/commands/plan.md
bash plugins/cc-tuner/tests/execute-task/test_contract.sh | grep '^FAIL'
cp /tmp/plan.premutation plugins/cc-tuner/commands/plan.md
```

Expected: `FAIL plan-stops-before-implementation`.

- [ ] **Step 8: Commit**

```bash
git add plugins/cc-tuner/commands/plan.md docs/adr/2026-08-12-planning-contract.md \
        plugins/cc-tuner/scripts/execute-task/prereq-check.sh \
        plugins/cc-tuner/tests/execute-task/test_prereq.sh \
        plugins/cc-tuner/tests/execute-task/test_contract.sh
git commit -m "Add cc-tuner:plan and the planning capability profile"
```

---

### Task 6: Wire the flow and record the invariants

**Files:**
- Modify: `plugins/cc-tuner/commands/spec.md` — `## 6. Hand off`
- Modify: `plugins/cc-tuner/commands/run.md` — Phase 1
- Modify: `plugins/cc-tuner/workflow-contract.json`
- Modify: `plugins/cc-tuner/README.md`
- Modify: `plugins/cc-tuner/tests/execute-task/test_contract.sh`

**Interfaces:**
- Consumes: everything above. Produces the shipped flow.

- [ ] **Step 1: Write the failing assertions**

```bash
need "spec-hands-off-to-plan" '/cc-tuner:plan' "$SPEC"
need "run-materializes-the-published-graph" 'materializes the published graph' "$RUN"
need "run-does-not-replan-on-resume" 'never re-derives the graph from prose' "$RUN"
need "run-recreates-lost-visible-tasks" 're-created and re-bound' "$RUN"
```

- [ ] **Step 2: Run and confirm it fails**

Expected: four `FAIL` lines, `rc=1`.

- [ ] **Step 3: Hand off from `/spec` to `/plan`**

In `spec.md`'s `## 6. Hand off`, replace the printed next command with `/cc-tuner:plan <spec path>`
and note that `/cc-tuner:run` follows once the graph is published. Keep the `--auto` offer attached to
`/run` and to `auto_ready: yes`.

- [ ] **Step 4: Rewrite Phase 1 of `/run`**

Replace the body of `## Phase 1 — publish the execution plan` with a materialize-and-reconcile phase:

- resume state and enter `planning`;
- if `runctl plan … frontier` reports no graph, invoke `/cc-tuner:plan` for this spec and continue when
  it has published — `/run` **materializes the published graph and never re-derives the graph from
  prose**;
- reconcile `TaskList` against the graph: structured state wins; visible tasks that are missing are
  **re-created and re-bound** with `runctl task … bind-ui`, and a task already `completed` in state is
  not re-created as pending;
- complete `planning`, then apply the HITL boundary.

Phases 2–8 keep their existing text, with `task start` now answering from the frontier.

- [ ] **Step 5: Record the invariants**

Add to `workflow-contract.json`:

```json
{ "id": "canonical-plan-before-mutation",
  "requirement": "No task path is mutated before the run's task graph is imported and published." },
{ "id": "task-dependencies-live-in-run-state",
  "requirement": "Task dependencies are validated and enforced in run state; a dependency recorded only in prose or in the visible task list does not exist." },
{ "id": "visible-plan-is-a-recoverable-projection",
  "requirement": "The visible task list projects run state. Losing a visible task never blocks the lifecycle; missing review, test or CI evidence always does." },
{ "id": "only-frontier-tasks-may-start",
  "requirement": "A task starts only when every task it is blocked by has completed." }
```

Update `README.md` to describe the `spec → plan → run` flow.

- [ ] **Step 6: Run everything**

```bash
for t in plugins/cc-tuner/tests/*/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILING: $t"; done
bash tests/run.sh </dev/null | tail -5
bash -n plugins/cc-tuner/scripts/execute-task/runctl.sh
```

Expected: no `FAILING:` lines, `cc-tuner validate ok`, `bash -n` silent. If `tests/run.sh` reports a
changed contract SHA, update `EXPECTED_SHARED_CONTRACT_SHA256` and say in the commit that the shared
contract moved.

- [ ] **Step 7: Mutation proof**

```bash
cp plugins/cc-tuner/commands/run.md /tmp/run.premutation
perl -0pi -e 's/never re-derives the graph from prose/re-derives the graph as needed/' \
  plugins/cc-tuner/commands/run.md
bash plugins/cc-tuner/tests/execute-task/test_contract.sh | grep '^FAIL'
cp /tmp/run.premutation plugins/cc-tuner/commands/run.md
```

Expected: `FAIL run-does-not-replan-on-resume`.

- [ ] **Step 8: Commit**

```bash
git add plugins/cc-tuner/commands/spec.md plugins/cc-tuner/commands/run.md \
        plugins/cc-tuner/workflow-contract.json plugins/cc-tuner/README.md \
        plugins/cc-tuner/tests/execute-task/test_contract.sh
git commit -m "Route spec through plan into run and record the graph invariants"
```

---

## Live acceptance before merge

Shell suites cannot observe Claude actually planning. In a **freshly reloaded** session, on a real
repository:

- [ ] `/cc-tuner:spec` on a small task produces a committed spec and hands off to `/cc-tuner:plan`.
- [ ] `/cc-tuner:plan` publishes a graph; `runctl plan … frontier` and the visible task list agree.
- [ ] Deleting a visible task and resuming re-creates and re-binds it; the run continues.
- [ ] `task start` on a blocked task is refused with the frontier message.
- [ ] A run whose state file still says `schema_version: 1` is migrated on first resume and its
      mutation fence still denies an out-of-phase edit.
- [ ] `/cc-tuner:run` on the published graph reaches implementation without re-planning.

Record what was observed. A checkbox ticked without an observation is the failure this list exists to
prevent.

## Out of Scope

- Bootstrap before the first mutation, legacy-journal adoption, and old-session/version detection with
  `/reload-plugins` — the Marqa/Stokli defects. They stay on the roadmap as the next PR and share no
  files with this one. Note the honest limit already established: a session that loaded an old command
  version cannot be fixed by anything shipped in a new version; only a reload or a cache purge fixes an
  existing session.
- Opening cc-codex-triage's model-invocable surface and its review-recovery paths.
- Parity for `codex-tuner` and `codex-cc-triage`. The same canonical graph ports afterwards with
  `update_plan` in place of Claude task ids; the workflow contract stays shared, the harness adapters
  differ. `codex-tuner` is already at contract 1.1.0/14 against this repo's 2.0.0/25, so re-syncing is
  its own coordinated change.

## Release

Minor bump. `release-please` owns the version fields. Ship after PR 1 so the capability profiles it
extends already exist.

Delivery: `cc-tuner:deep-review`, `mattpocock-skills:code-review`, and Codex `--required` on the exact
candidate SHA, Linux and macOS CI green on that SHA, the live-acceptance list above recorded. Merge
only after explicit user confirmation.
