---
name: run
description: Implement or resume this branch's approved cc-tuner plan through verification, review and authorized delivery.
argument-hint: '[--auto | --local-only] <path-to-spec>'
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion, WebFetch, mcp__context7, mcp__cc-tuner__peers_claim, mcp__cc-tuner__peers_report, mcp__cc-tuner__peers_release
---

# /cc-tuner:run

**Plugin root: `${CLAUDE_PLUGIN_ROOT}`.** Only this file gets the variable filled in: wherever a reference
or a route writes `${CLAUDE_PLUGIN_ROOT}/…` or `<plugin root>/…`, use this path.

Work the approved plan in this checkout. The argument is the spec path. Start `/run` yourself
when the user requested implementation or continuation. Use `--auto` only for requested unattended
delivery. Apply the task and repository permissions in [Merge authorization](#who-may-stop-the-run).

## Before starting

Start previews, dedicated MCP servers and test containers as `task-flow`'s Runtime cleanup says;
[Ending the run](#ending-the-run) stops them.

Read the named spec: it owns acceptance, tests, target, merge strategy, CI and review policy, and
DoD. If the argument is missing or names a plan, read the spec from the plan's `**Spec:**` header and
say which one you took. Stop if neither names a spec that exists. `auto_ready: yes` is required for
unattended delivery. If the sole obstacle is a destination or publication prerequisite, continue the
approved local work and hold delivery. Missing acceptance or an unresolved human-only criterion still
needs the spec's normal decision.

**Re-detect the host** with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup/host.sh"`. For every delivery host,
follow [hosts.md](references/hosts.md) before the first slice. A delivery prerequisite can wait
while the approved base, local implementation and checks are available.

For work spanning repositories or a spec naming `second-repo`/`shared-task`, read
[shared-task.md](references/shared-task.md) before resolving plans. Apply it throughout this run,
including combined verification and preflight of every candidate before the first merge.

Resolve the plan from the checkout root. Set `SPEC` to the repository-relative spec path and
`plan_mode=()` for a committed plan or `plan_mode=(--local-only)` for an approved local handoff.
Run these in one Bash call:

```bash
ROOT=$(git rev-parse --show-toplevel) && cd "$ROOT" || exit 1
PLAN=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" resolve "${plan_mode[@]}") || exit 1
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" check "$PLAN" \
  --spec "$SPEC" --branch "$(git branch --show-current)" "${plan_mode[@]}"
```

A committed plan and spec must match HEAD. Resolve subsequent paths from this same root, including
the absolute plan path passed to `peers_claim`. If the contract is missing or ambiguous, finish
`/cc-tuner:spec` before implementing it.

When native task tools exist, reconcile the list against the plan even if the list is nonempty.
`SessionStart` restores slices and lists open checkboxes outside them, nothing more. Create missing
tasks with `TaskCreate`, then set edges with `TaskUpdate addBlockedBy`:

- one task per slice with the plan's dependencies;
- **verify the feature**, blocked by every slice → **review the candidate** → **deliver**.

Mark tasks completed for every ticked slice before starting. Update statuses as stages execute. If
native tools are absent, say so once and continue with the plan file as durable state.

**The board.** For an authorized board, use the `cc-tuner:task-flow` Board recipes. Add the
card if missing, set it In Progress before work, and move an unstarted parent epic with it.
Report failed moves now and at handoff, then continue. Delivery owns the later moves.

## The loop

Get the next safe batch from the parser, passing every running slice:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-lint.sh" ready-batches <the resolved plan path> --active <n,n,...>
```

Omit `--active` when idle. Dispatch returned `SLICE` records within placement's concurrency cap.
Refresh the active set from task status and agent handles after each return and on resume. Start
ready work as slots open. Under `--auto` check each `blockedBy` edge; native tasks do not enforce it.

An empty `BATCH` with open slices means all are active, blocked or conflicting. Wait for a writer
or resolve the blocker. Close a slice after reading its diff and deciding-check evidence on the
assembled result. Verify the feature once all slices close.

After a spike, revise dependent slices and any affected spec facts. For every plan edit (including
ticks, path transfers and archive links), check the edited files with the startup `plan-lint.sh check`
arguments **plus `--local-only` before commit**. Where commits are permitted, commit the reviewed
change and repeat the HEAD check before dispatching or resuming. Local-only work keeps the disk plan.

Within approved scope, split remaining work or move an Owned path between open slices yourself, and
add a file no slice names to the slice that needs it. Wait for affected writers to return or
coordinate their handoff first. Update ownership, blockers and evidence; apply the edit check above
and refresh the task list and peer claims. Ask only when the outcome, acceptance or an external
owner's work would change.

Peers: if `mcp__cc-tuner__peers_claim` is listed, call it with the plan before the first slice,
after each tick and before integrating the target. Before starting a slice whose Owned paths a peer's
claims, edits or conflicts touch, name the peer and the overlapping path.

Update task status as work progresses. Tick the slice and proved spec criteria together. For a
delegated slice the orchestrator owns this integration commit. In local-only mode save the ticks
on disk. Follow `cc-tuner:task-flow` for commit messages and trailers. Record DoD at delivery.

## Who may stop the run

This skill owns the lifecycle. Invoked skills supply methods and findings; their standalone
confirmation prompts, gates or completion messages do not interrupt work already approved here.
Acceptance criteria, review findings and candidate evidence remain strict.

**Merge authorization.** User and repository permissions govern each write, including commits, push,
PR/MR creation, comments, board updates and merge. A request for PR delivery covers its ordinary
branch push, draft PR and evidence comments wherever repository policy permits them. `--auto` or an explicit request to merge
authorizes a merge within those boundaries. It grants no deployment, release or migration authority.
Continue through the last permitted action. When only merge is reserved, run the checked preflight
and hand over the candidate and command.

**Local handoff.** When commits are reserved, select `--local-only` from the start; the user can
also request it. Work in this checkout, serialize edits, tick the local plan and verify the
actual worktree. Skip commit-based integration and archiving; record local review of the complete
task diff, including new files. When only publication is reserved or unavailable, verify the
committed candidate and do the advisory review locally. In either case return the base SHA,
task diff and new paths, checks and observed results, and the first pending delivery action.
Only a clean committed candidate can earn a public verification marker, exact-SHA verdict or merge.
Resume the normal route after the permitted operator commits or publishes, checking the new inputs.
Keep unresolved acceptance, scope choices and waivers pending while independent work continues.

While units, CI or review are running, do available work or wait for completion in the same turn.

## Delegating a slice

Delegate implementation when the work justifies the brief; under `--auto`, prefer delegation for
substantial slices. Dispatch an implementation unit as `cc-tuner:slice-unit`, whose turn cap makes
a slice that does not fit come back marked partial instead of running on. If the host does not list
that type, do the slice yourself and say so. The orchestrator retains the task list, slice
completion, mutation interpretation, full regression, runtime acceptance, review verdict, DoD and
delivery, and it owns a partial return.

Before dispatching any implementation unit, read [placement.md](references/placement.md): it defines
the brief and return checks, model choice, isolation, concurrency, escalation and what a partial
return triggers. Read it also before invoking `prototype`, `domain-modeling` or `diagnosing-bugs`.
`deep-review` and `/spec` name their own read-only agent type/model; where silent, placement decides.

## Proving a slice

- **RED before GREEN:** run the failing check first and record the expected failure. Use the honest
  non-code baseline/diff check where the spec explicitly permits it.
- Execute the spec's negative proof; `not applicable — <reason>` with its alternative is valid.
  Do not invent mutations. **If the spec assigns a mutation**, read
  [mutation-proof.md](references/mutation-proof.md) before running `mutate.sh`; inspect its failure
  evidence, not just the verdict.
- **Record the deciding check's evidence in the plan**, under the slice, as one line the next reader
  can re-run: `Evidence: <command> → <the deciding output line> @ <sha or worktree>`. The parser
  ignores the line. It names the code the result was taken from; it does not replace reading the diff.
- **Test cadence.** Slices run the spec's targeted checks, as placement's Heavy checks assigns them.
  The full regression suite runs at the spec's `full_test_cadence`: `per-candidate` (the default,
  also when the field is absent) runs it once on the assembled candidate and once after each batch of
  review fixes; `per-batch` also runs it after each integrated batch of slices. The full e2e suite
  runs in verify-feature. Reuse a result only when the checked code, dependencies, configuration and
  environment are unchanged, and name the source result. Re-run affected checks when those inputs
  change or the evidence is missing or unreliable, and whenever a fresh run is explicitly required.
  A new commit alone does not require another identical local build; review and CI still bind the
  final SHA.
- **Heavy checks go through the machine's slots,** as [placement.md](references/placement.md#heavy-checks)
  defines, including the command you put in every unit's brief.
- Re-check unresolved `[eyes]` criteria even if a stale plan reached `--auto`: stop for the required
  human step or a user waiver recorded with who and when.

## Prepare the candidate

For publication, follow `cc-tuner:task-flow`'s Prepare the candidate and Pre-PR checklist.
Archive a completed spec and update its live links before pinning review. Keep the plan at its
resolved path and validate the changed headers. For `tracker: local` use
[local-issues.md](../task-flow/references/local-issues.md) to decide whether and where to close the issue.

Fetch the target before the first publishable candidate and before delivery. If offline, verify
and review against the known local base and record the pending sync. Integrate an advanced target
within scope, then reverify affected evidence. Prefer merge on published branches or after review
began; rebase only unpublished work when policy permits. Preserve unrelated WIP, using a clean
task checkout when needed. A conflict that needs a product decision blocks only its dependent work.

Pass a literal synchronized target SHA as the initial review base; keep it and the spec path fixed
for that thread. Later target updates are merged without changing that base. If target advances
after approval, integrate it with a merge commit, refresh affected evidence and obtain approval for
the new candidate; under `review: codex` claim that round with `begin --integration`, which reviews
the integration without spending the cap.

On resume, read the existing PR and review state, and reconcile an already merged PR instead of
opening or merging it again.

## Verifying the feature

After every slice is done and before offering a candidate for review, run `cc-tuner:verify-feature`
in a `general-purpose` subagent with `model: "sonnet"` and `effort: "high"`, or the model and effort
[placement](references/placement.md#agent-selection) assigns to a complex verification. Create a
private scratch directory outside the checkout (for example with `mktemp -d`). Pass the verifier an
absolute output path there, the spec,
candidate worktree and SHA, heavy-check command and cleanup instructions. Use a fresh file for each
verification. The verifier writes the record and returns its path and verified SHA or worktree base.
Use the same file contract when running the skill yourself.

Read the file before delivery. Keep it through handoff or publication. If evidence needs another
check, record your own observations in the DoD or have the verifier produce a fresh file. Keep every
`NOT PROVED` line. Resolve human-only criteria with the user, a proved machine replacement or a dated
waiver. A later change needs fresh evidence when it affects what the record covered.

## Delivery

For `--local-only`, finish the local handoff after verification. Review the complete worktree
against the spec and repository rules yourself when delegated reviewers are unavailable or outside
the task's permissions. Record the findings locally and leave committed-candidate review pending.

For a committed candidate, read [delivery.md](references/delivery.md) before the first push and
again on resuming delivery. Follow its route through review, verdict, DoD and the last authorized step.

## Ending the run

Before every final answer — after the merge, at the handoff before it, or on a block — stop what this
run started, as `task-flow`'s Runtime cleanup says: TaskStop each background task, close the browser
pages it opened, remove each container it created. What the user asked to keep running stays, and so
does a task the guard refuses to stop. The answer then carries one line:

```text
resources: closed | retained <what, and why> | none
```
