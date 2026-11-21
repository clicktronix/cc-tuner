---
description: Plan a feature or fix as an approved spec and execution plan for /cc-tuner:run. With --groom, record decisions in the existing issue.
argument-hint: '<issue number | URL | free-text description> | --groom <issue number | URL>'
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, WebSearch, mcp__context7, mcp__cc-tuner__peers_report
---

# /cc-tuner:spec

Produce the approved spec and plan that `/cc-tuner:run` can execute without reopening decisions.
This command owns discovery and readiness; `/run` owns delivery.

**`--groom <issue>`** records decisions in the issue and stops, with no branch, spec or plan: read
[groom.md](references/groom.md) and follow its route instead. Read it too when the issue already
carries a `cc-tuner-groom:` record: it says whose record counts as settled.

## 1. Anchor and read

```bash
ROOT=$(git rev-parse --show-toplevel) && cd "$ROOT" || exit 1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/prereq-check.sh" \
  || echo "prerequisites missing — /spec continues; /cc-tuner:run needs them before delivery"
```

Use this checkout root for commands and paths throughout the spec. Record missing capabilities with
the phase that needs them. Section 5 settles the required review mode before approval. For an
unfamiliar dependency, a current-facts question or two defensible designs, consult
[optional-opinions.md](references/optional-opinions.md). Start local discovery immediately. Ask about
an optional call to the second provider only if the uncertainty persists and the call is not already authorized.

Read, in order:

- `.claude/rules/task-flow.local.md` for repository board and branch deltas;
- `docs/agents/issue-tracker.md`, which owns where issues live and how to create, read and comment on them;
- the issue, when `$ARGUMENTS` names one;
- `CLAUDE.md`, `AGENTS.md`, and applicable `.claude/rules/`;
- architecture records, the code, tests, and consumers the task can affect.

Do not ask for information already present in those sources.

When `docs/agents/issue-tracker.md` is absent, ask once with `AskUserQuestion`: run
`/setup-matt-pocock-skills` now (a user-only command, so the user types it; it asks GitHub / GitLab / local
markdown under `.scratch/` / other, and may add a git remote), then re-read the file;
or continue with `tracker: none`, the spec being the record. Do not write that file yourself.

**Detect the host once the tracker is settled**, because `/setup-matt-pocock-skills` may add a remote (not
under `--groom`, which delivers nothing):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/host.sh"
```

Use the detected host for `host:`. For other hosts or `ambiguous`, follow
[hosts.md](../run/references/hosts.md), including when to record `pending`.

**Fan out the reading, keep the conclusions.** When the task's baseline spans several areas — separate
subsystems, a second repository, an unfamiliar dependency — dispatch one read-only subagent per area
with the Agent tool (`Explore` for search, `general-purpose` on `haiku` at `effort: "high"` for a
question that needs running commands; the model ladder is in `run`'s placement reference), all in a
single message so they run at once. Each gets a literal question and the paths to look in; none of
them decides anything. You read what comes back and write the spec. Do not delegate the grilling in
section 3: an adviser can be handed the draft text, never the decision.

## 2. Create the task branch

Resolve the integration target from repository policy or the remote default. Fetch when available;
offline, use the known base and check the fresh tip before publication. With host `local`, use
`refs/heads/<target>`. If branch creation is reserved, stay in the designated checkout. Otherwise
create the task branch before grilling, since `domain-modeling` may write `GLOSSARY.md` or ADRs.
On an existing branch, confirm it belongs to the task. Check any previous PR when reachable.
Keep task commits off the integration branch.

**Commit message format, including any attribution trailers, comes from the repository's
conventions**, resolved in the order `cc-tuner:task-flow` gives under Commit conventions.

## 3. Grill the problem

Resolve only decisions not already settled by the request, repository or approved spec. Use
`mattpocock-skills:grilling` for unresolved design choices. Ask each of its rounds through
`AskUserQuestion` rather than as prose: up to four questions per call, the recommended option first
and labelled "(Recommended)", each option described by its consequence; a question with no discrete
options stays text. Ask dependent questions after their prerequisites are answered.

Invoke `mattpocock-skills:domain-modeling` here, while the decision is made, whenever the interview
changes a domain term or settles something worth an ADR: it challenges the term and writes
`GLOSSARY.md` / the ADR in the repository's format. A slice may later carry that text into place,
but a unit never decides the model. When the decision adds a module or moves an interface or seam,
invoke `mattpocock-skills:codebase-design` so the ownership and boundaries below are stated in its
terms. Pull current dependency documentation through Context7.
These methods do not add a confirmation beyond section 6; a complete contract needs no new interview.

Resolve before calling the task ready:

- the observed problem or desired user outcome;
- architecture ownership, boundaries, and affected consumers;
- explicit scope and rejected alternatives;
- acceptance evidence;
- the first failing regression check or an honest non-code baseline;
- targeted and full verification commands, environment, fixtures, and external dependencies.

A pending `TBD`, “as appropriate”, unknown test command, or unstated expected failure means the spec is not ready.
When the missing fact can only be learned by building something — the test command of a subsystem
that does not exist yet, an API's real shape — make the first slice a **spike** whose deliverable is
that fact, run `mattpocock-skills:prototype` for it in a disposable workspace, and let the rest of the plan depend on
it. The spec records the spike and what it must establish; `/run` revises the dependent slices after
it lands (see its loop).

## 4. Define acceptance and delivery shape

Tag every criterion:

- `[machine]` — an exact command or browser-driving step decides it;
- `[eyes]` — human judgement is irreducible; name the concrete human verification step.

Every `[eyes]` criterion records its human step, machine replacement (or `none`), and dated waiver (or
`none`). Without a replacement or waiver, set `auto_ready: no`; `/run --auto` must refuse it.

Independently deliverable work or phases requiring separate scope decisions use an epic with native
sub-issues and one spec per sub-issue. Multiple repositories alone do not require an epic.
For coupled work, read [shared-task.md](../run/references/shared-task.md) before drafting the spec;
its spec/plan and task-list sections apply here, under the same approval.

## 5. Draft the executable contract

Read `${CLAUDE_SKILL_DIR}/spec-template.md` and fill it at the size of the task. A one-file fix or a
small change needs Goal, the acceptance criteria with their checks, the first failing check,
`target_test`, `full_test`, `ci`, `review` and `merge`; other sections may read `not applicable —
<reason>`. Larger or riskier work fills every field. Draft the result in the conversation; do not
write it before the approval in section 6. Its final path is
`$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" spec-dir)/YYYY-MM-DD-<slug>.md`: the script picks
`wiki/` or `docs/` and the spelling of the plans directory the repository already tracks. It never
returns `task-plans/`, which holds execution plans.

For documentation-only or mechanical work, a concrete reason plus an alternative baseline/diff check
may replace the failing check or mutation.

Assign a mutation only where a false green is otherwise indistinguishable **and nothing cheaper
produces the same fact**: fail-closed guards, validators and parsers, recovery paths. Do **not**
assign one to a regression test for a shipped defect: that test is watched failing on the pre-fix
code. Elsewhere a baseline or diff check is enough. Where the test command is a full build, say so
in the spec: the proof costs **three** runs of it (baseline, mutant, control). A mutation assignment
also names **what the killed test must say**; `/run` executes the proof as
[mutation-proof.md](../run/references/mutation-proof.md) describes, without inventing another.

Read [the CI policy](../run/references/local-ci.md) before choosing `ci`: it names the mode, checks
and how to observe them on the candidate. `/run` passes the mode verbatim. Set `review:` from
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/companion.sh" review`. Exit 0 prints `codex` or
`none:<reason>`. For `setup:<state>`, offer the setup/enable/update path from the
[companions procedure](../setup/references/companions.md), or an explicit opt-out for this spec
with the user's reason. Recheck after setup. Continue independent discovery while the choice
is pending; settle it before approving the contract.
`auto_ready: yes` requires a defined PR, MR or branch per participating repository, complete DoR,
nonblank `ci`, `target_test`, and `full_test`, and a replacement or waiver for every `[eyes]` item.
Only `/run --auto` requests unattended execution.

Use section 1’s host and set `tracker:` from `docs/agents/issue-tracker.md` (`gh`,
`glab`, `local` or `other`, as that file describes), or `none` when it is absent and the user chose to continue.
With `tracker: none` the spec is the record and no issue is created or updated at any point. With any
other tracker, do not create or update the issue before the approval in section 6.

**Blind spots, before the approval.** Once every part of the draft above is written, run this pass;
skip it only for a mechanical or documentation-only change, and say so: a one-file change can still
move authorization or billing. Print `spec-blind-spots: 1 opus × effort high`, then
dispatch `cc-tuner:spec-blind-spots` once with the draft text, the issue, the repository path and
the decisions already made; the agent's definition owns what it looks for. Validate each returned
item against the code and drop what the draft already settles; the rest become grilling questions
asked as section 3 asks them, the user decides, and an adopted answer changes the draft before
section 6. Report the agent's closing status line: an `incomplete: <reason>` goes to the user with
the review in section 6 whatever questions came with it; `completed: no findings` leads straight on.

## 6. Plan and confirm

Turn the contract into **tracer-bullet slices**: each slice is a narrow, independently verifiable path
through every layer it touches, sized for one fresh context window. Name its owned paths, deciding
check, observable delivery, and the other slices that must finish before it can start. A schema layer
or a list of files is not a slice. Mark a slice `Model: opus — <reason>` when its work is one of the
Opus cases in [placement.md](../run/references/placement.md#agent-selection).

Before writing Owned paths, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" --help`; the
executable consumer owns that syntax.

For a wide mechanical change that cannot stay green slice by slice, use **expand → migrate →
contract**: introduce the new form beside the old, migrate consumers in independently checked batches,
then remove the old form only after every batch.

Before presenting, if `mcp__cc-tuner__peers_report` is listed, call it with the target repository's path and
name each peer whose claims, edits or merge conflicts touch the slices' Owned paths.

Present the spec decisions and proposed slices as one concise review: title, delivery, owned paths,
and blockers, plus the card's Priority when a board is named and neither the issue nor
`task-flow.local.md` sets one. Ask once whether the contract, granularity, and edges are right; revise until approved.
This is the only approval before implementation.

After approval, record the issue by `tracker:` when the task permits tracker writes. If a person
owns the write or the tracker is offline, keep its reference and pending action in the spec and
continue writing the approved files.

- `gh` — create or update the issue.
- `glab` — `glab issue create` / `glab issue note`, as `docs/agents/issue-tracker.md` says.
- `local` — follow [local-issues.md](../task-flow/references/local-issues.md) for the issue and its
  `.scratch/<slug>/spec.md` link to the spec. Commit tracked files with the spec. For ignored files,
  record the issue file's absolute path in the spec's Delivery section; `/run` closes it after merge.
- `other` — as that file describes.
- `none` — nothing; the spec is the record.

Then write the approved spec to its final path and ask the repository for the plan path:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" create
```

Use the printed path literally. Fill `${CLAUDE_SKILL_DIR}/plan-template.md`, then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check <the printed plan path> \
  --spec <the approved spec path> --branch "$(git branch --show-current)" --local-only
```

Fix errors and inspect the task diff. If commits are permitted, stage only the reviewed spec, plan
and intended issue or glossary/ADR changes, then commit them together. Otherwise leave them in
this checkout for `/run --local-only`. Preserve unrelated WIP.

## 7. Publish and hand off

When the native task tools are available, publish the visible plan before any implementation edit:

1. `TaskCreate` once per slice, in number order; include delivery and acceptance criteria.
2. `TaskCreate` three more, as a **chain**: **verify the feature**, blocked by every slice; **review
   the candidate**, blocked by verify; **deliver**, blocked by review. Slice completion alone does
   not mean the candidate is verified or delivered.
3. `TaskUpdate` with `addBlockedBy` once per dependency edge.
4. `TaskList` and verify that every edge matches the saved plan.

The saved plan owns execution state. If the tools are
absent, say once that only the visible list and its edges are lost, mention
`{"env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}}` in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` (or
`--allowedTools TaskCreate` for one session), and continue to the handoff. Do not add a second
confirmation after the approved contract and slices.

When board writes are authorized and the spec names a `board:`, read
[board.md](../task-flow/references/board.md) and put the issue's card on it: add it when missing, set Status to Todo unless it already has a later one, and Priority when
unset (the value approved in section 6); for a sub-issue, put the epic's card on the board too.
Report a move that failed.

Print the spec and plan paths, branch, target, and the next command. When the user asked for the
task to be implemented, not only planned, start `/cc-tuner:run` yourself with the spec path. Start
unattended delivery only when the user asked for it and `auto_ready: yes`; otherwise carry out authorized local work.
The command takes the approved **spec path**; `/run` resolves the branch's plan itself:

```text
/cc-tuner:run docs/PLANS/2026-07-31-thing.md
/cc-tuner:run --local-only docs/PLANS/2026-07-31-thing.md
/cc-tuner:run --auto docs/PLANS/2026-07-31-thing.md
```
