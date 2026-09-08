---
description: Turn an issue, URL, or rough task description into one approved, committed spec and sliced execution plan for /cc-tuner:run.
argument-hint: '<issue number | URL | free-text description>'
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, WebSearch, mcp__context7
disable-model-invocation: true
---

# /cc-tuner:spec

Produce the committed spec and plan that `/cc-tuner:run` can execute without reopening decisions.
This command owns discovery and readiness; `/run` owns delivery.

## 1. Anchor and read

```bash
git rev-parse --show-toplevel || { echo "not a git repo"; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/prereq-check.sh"
```

Read, in order:

- `.claude/rules/task-flow.local.md` for repository board and branch deltas;
- the issue, when `$ARGUMENTS` names one;
- `CLAUDE.md`, `AGENTS.md`, and applicable `.claude/rules/`;
- architecture records, the code, tests, and consumers the task can affect.

Do not ask for information already present in those sources.

**Fan out the reading, keep the conclusions.** When the task's baseline spans several areas — separate
subsystems, a second repository, an unfamiliar dependency — dispatch one read-only subagent per area
with the Agent tool (`Explore` for search, `general-purpose` on `sonnet` for a question that needs
running commands), all in a single message so they run at once. Each gets a literal question and the
paths to look in; none of them decides anything. You read what comes back and write the spec. This is
the cheapest part of the flow to parallelise, because discovery is read-only and the failure mode of a
wrong answer is that you notice it while drafting. Do not delegate the grilling in section 3: the
questions there change the draft, and a subagent cannot see the draft.

## 2. Create the task branch

Resolve the integration target from repository policy, falling back to the remote default branch.
Fetch it and verify the starting point. If currently on the target branch, create the task branch now
using the task-flow naming rule. If already on a feature branch, confirm it belongs to this task and
its PR is not already merged. Never commit the spec directly to the integration branch.

Create the task branch before grilling because `domain-modeling` may write `CONTEXT.md` or ADRs;
`/run` continues this branch rather than creating another.

**Commit message format, including any attribution trailers, comes from the repository's
conventions** in `.claude/rules/task-flow.md`; where that file is silent, match the repository's
recent history rather than the harness default.

## 3. Grill the problem

Invoke `mattpocock-skills:grilling`, using `mattpocock-skills:domain-modeling` for vocabulary. Pull
current dependency documentation through Context7 as questions arise. Ask one question at a time
until the answer no longer changes the draft.

Resolve before calling the task ready:

- the observed problem or desired user outcome;
- architecture ownership, boundaries, and affected consumers;
- explicit scope and rejected alternatives;
- acceptance evidence;
- the first failing regression check or an honest non-code baseline;
- targeted and full verification commands, environment, fixtures, and external dependencies.

A pending `TBD`, “as appropriate”, unknown test command, or unstated expected failure means the spec is not ready.

## 4. Define acceptance and delivery shape

Tag every criterion:

- `[machine]` — an exact command or browser-driving step decides it;
- `[eyes]` — human judgement is irreducible; name the concrete human verification step.

Every `[eyes]` criterion records its human step, machine replacement (or `none`), and dated waiver (or
`none`). Without a replacement or waiver, set `auto_ready: no`; `/run --auto` must refuse it.

Independently reviewed phases, or genuinely separate pieces of work, require an epic with native
sub-issues and one spec per sub-issue. **Two repositories do not, by themselves.** Where the change is
one thing that happens to span repositories — a migration and the code that reads it, a contract and
its consumers — keep one task and issue. Each repository still needs its own branch, PR, local spec
and plan for the existing resolver and review gates. The primary spec owns the shared outcome,
cross-repository prerequisites, combined acceptance checks and merge order; fill `second-repo` with
the companion checkout, branch and local spec path. The companion spec links back through
`shared-task` and records its local contribution and run config, not an independently shippable task.
Review them as one contract. Distinguish merge order from rollout prerequisites: merging a migration
does not prove it was applied. Do not authorise deployment or migration implicitly.

## 5. Draft the executable contract

Read `${CLAUDE_SKILL_DIR}/spec-template.md` and fill every field. Draft the result in the conversation;
do not write it before the approval in section 6. Its final path is
`<plans-root>/PLANS/YYYY-MM-DD-<slug>.md`, using `wiki/` when present and `docs/` otherwise.

**A directory that differs only in case is the same directory — use the one that exists.** macOS is
case-insensitive and Linux is not, so a repository that already keeps specs in `docs/plans/` gets one
folder on a laptop and two in CI if this writes `docs/PLANS/`. Check with
`git ls-files 'docs/*lans*' 'wiki/*lans*'` before creating anything, and write into whatever spelling
the repository already tracks.

For documentation-only or mechanical work, a concrete reason plus an alternative baseline/diff check
may replace the failing check or mutation.

Assign a mutation only where a false green is otherwise indistinguishable **and nothing cheaper
produces the same fact**: fail-closed guards, validators and parsers, recovery paths — checks whose
failure mode nobody has watched. Do **not** assign one to a regression test for a shipped defect: that
test is watched failing on the pre-fix code, which is the same evidence for free. Elsewhere a baseline
or diff check is enough. Where the test command is a full build, say so in the spec — the proof then costs **three** runs of it
(baseline, mutant, and the control that confirms the kill) and is worth assigning only if the guard is
worth that. A mutation assignment also
names **what the killed test must say**, the way the first failing check names its expected failure:
`/run` passes it to `--expect`, and without it a test that goes red because the environment broke is
indistinguishable from one the mutant killed. `/run` executes the proof named here; it does not invent another.

`ci` names both the **mode** and the checks. `required` is the default and assumes GitHub branch
protection; `any` is for a repository that runs CI without it. Prefer `any` wherever a workflow can be
dispatched by hand: a manual run still attaches its result to the head commit, so the checks answer
for themselves. `none:<reason>` is only for a repository that runs no CI on a pull request at all, and
it carries **two** obligations, not one: the merge script refuses it whenever GitHub reports any check,
and it refuses it again unless a comment on the pull request carries `cc-tuner-local-ci: <sha> <what
ran, and what it returned>` for that exact commit. `/run` passes the mode verbatim; both refusals are the
script's, not advice. `auto_ready: yes` requires a defined PR per participating repository, complete DoR,
nonblank `ci`, `target_test`, and `full_test`, and a replacement or waiver for every `[eyes]` item.
For a shared task, every local spec must be ready and the combined checks and prerequisites explicit.
Only `/run --auto` requests unattended execution.

Set `tracker: gh` in the draft. Do not create or update the issue before the approval in section 6.

## 6. Plan and confirm

Turn the contract into **tracer-bullet slices**: each slice is a narrow, independently verifiable path
through every layer it touches, sized for one fresh context window. Name its owned paths, deciding
check, observable delivery, and the other slices that must finish before it can start. A schema layer
or a list of files is not a slice.

Before writing Owned paths, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" --help`; the
executable consumer owns that syntax.

For a wide mechanical change that cannot stay green slice by slice, use **expand → migrate →
contract**: introduce the new form beside the old, migrate consumers in independently checked batches,
then remove the old form only after every batch.

Present the spec decisions and proposed slices as one concise review: title, delivery, owned paths,
and blockers. Ask once whether the contract, granularity, and edges are right; revise until approved.
This is the only approval before implementation.

After approval, create or update the issue so it and the spec link to each other, write the approved
spec to its final path, then ask the repository for the plan path:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" create
```

Use the printed path literally. Fill `${CLAUDE_SKILL_DIR}/plan-template.md`, then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check <the printed plan path> \
  --spec <the committed spec path> --branch "$(git branch --show-current)"
```

Fix every error. The exact grammar is `## Slice <n> — <title>` and `Blocked by: <numbers|none>`;
the committed plan is the durable execution state. Inspect `git status` and the complete diff. Stage
the spec, plan, and only the `CONTEXT.md` or ADR changes this invocation intentionally created; stop
and explain any other unexplained file. Commit the reviewed set together using the repository's
convention.

For a shared task, prepare and validate the companion's local spec and plan on its task branch too,
under the same contract approval. Keep Owned paths relative to that plan's repository; do not encode
another checkout as `../...`. Name cross-repository prerequisites in the primary spec's test plan and
in the affected slice's deciding check. Commit a plan in each PR so both enter checked delivery.

## 7. Publish and hand off

For a shared task, publish one combined list after preparing both repositories. Qualify each slice
with its repository and include cross-repository prerequisite edges from the primary spec. Keep one
verify/review/deliver chain for the whole task; do not start a second lifecycle for the companion.

When the native task tools are available, publish the visible plan before any implementation edit:

1. `TaskCreate` once per slice, in number order; include delivery and acceptance criteria.
2. `TaskCreate` three more, as a **chain**: **verify the feature**, blocked by every slice; **review
   the candidate**, blocked by verify; **deliver**, blocked by review. Without them the list reads as
   finished the moment the last slice is ticked, while the work that decides whether any of it ships
   has not started — and a watcher seeing "all done" beside an unreviewed candidate is being told
   something false. Blocked by the slices alone they would all go ready at once, which says they can
   happen in any order; they cannot.
3. `TaskUpdate` with `addBlockedBy` once per dependency edge.
4. `TaskList` and verify that every edge matches the committed plan.

The task list is only a projection; the committed plan remains the source of truth. If the tools are
absent, say once that only the visible list and its edges are lost, mention
`{"env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}}` in `~/.claude/settings.json` — the form that
survives the next session — or `--allowedTools TaskCreate` for this one, and continue to
the handoff. Do not add a second confirmation after the approved contract and slices.

Print the spec and plan paths, branch, target, and the next command. The command takes the committed
**spec path**, never the plan path; `/run` resolves the branch's plan itself. Copy the path printed as
`Spec:`, even though the plan is the artifact `/run` will work:

```text
/cc-tuner:run docs/PLANS/2026-07-31-thing.md
/cc-tuner:run --auto docs/PLANS/2026-07-31-thing.md
```

Offer `--auto` only when `auto_ready: yes`.
