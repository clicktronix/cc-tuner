---
name: task-flow
description: Repository chores around a task — branch, commit and PR conventions, GitHub Projects board recipes and card moves, cleanup after a merge, stacked-PR merges and the spec lifecycle. Use for those chores in any repository; to write a plan use /cc-tuner:spec, to implement one /cc-tuner:run.
---

# Task Flow — procedures

The invariants (prohibitions, branch and commit format, PR linking) live in the repo's
`.claude/rules/task-flow.md`, installed by the task-flow node of `/cc-tuner:setup`. This skill carries the
procedures that do not need to sit in every session's context. Repo deltas — board name, labels,
cached field IDs — go in `.claude/rules/task-flow.local.md`; check it first.

## Boards and epics

Before any GitHub Projects command, card move, or decision about epics and sub-issues, read
[board.md](references/board.md). It owns the recipes and the Card lifecycle.

## Recording independent future work

`.claude/rules/task-flow.md` defines what must be fixed in the current task and what remains an open
blocker. This procedure records work outside that obligation.

For independent future work, check current code and work in flight, then search existing issues and
epics for the same cause or deliverable. Add evidence and remaining work to a matching item; group
related findings into one schedulable change. Create a new issue only for a distinct piece of work
that is still needed. An optional suggestion with no planned outcome can remain a review note.

Include the observed problem, the intended result and its source review. Follow
[board.md](references/board.md) when a board is configured; otherwise create or update the issue
without project commands. Create it through the tracker `docs/agents/issue-tracker.md` names when it
is not GitHub: `glab issue create`, a new issue file resolved through
[Local issue files](#local-issue-files), or what it describes.

## Local issue files

Before any `tracker: local` read or write, follow [local-issues.md](references/local-issues.md).
It owns location, persistence and closing for primary issues, groom comments and future work.

## After the merge

Finishing is the merge plus a clean machine. Preserve local tracker files through
[Local issue files](#local-issue-files) before removing any worktree. For a remote delivery use the remote, host and project from the
[delivery preflight](../run/references/hosts.md) throughout cleanup:

```bash
git switch <target> && git pull --ff-only "$DELIVERY_REMOTE" <target>
git worktree list                              # any worktree still pointing at the merged branch?
git worktree remove <path>                     # remove it; --force only when you know the diff is dead
git worktree prune                             # clears stale registrations for directories already gone
git branch --merged <target>                   # inspect local branches already merged into the target
git branch -d <branch>                         # -d refuses if unmerged
git fetch --prune "$DELIVERY_REMOTE"
```

After a **squash** merge `-d` always refuses: the branch's commits are not ancestors of the squash
commit, even though their changes landed. Delete it only when the merged PR's head is exactly the
local tip, so nothing local is left out of what merged:

```bash
[ "$(gh pr view <pr> --repo "$DELIVERY_HOST/$DELIVERY_PROJECT" --json state,headRefOid --jq 'select(.state=="MERGED") | .headRefOid')" = \
  "$(git rev-parse <branch>)" ] && git branch -D <branch>
```

A local tip that differs holds commits the PR never carried: look at them, do not delete.

Other hosts check the same fact. On GitLab, `glab mr view <iid> --repo "https://$DELIVERY_HOST/$DELIVERY_PROJECT"` must show state `merged` with its
sha equal to the local tip. With no remote, `git rev-parse refs/heads/<target>` must equal the merged
head, and the local tip must equal it too.

On host `local` (no remote) skip `git pull` and `git fetch --prune`, and sync the target in the
worktree that holds it (`git worktree list`).

When cc-tuner's guard stops the switch or the pull, take a worktree instead of overriding it: sync
the target in the one that holds it (`git worktree list`), or `git worktree add <path> <target>`.

When `--ff-only` refuses, the local target has commits that are not upstream: look at them, do not
merge over them. Do not delete a worktree whose branch never merged: open its PR instead.

## Commit conventions

The message format, including attribution trailers (`Co-Authored-By:`, a session trailer), comes
from the first of these that answers: `.claude/rules/task-flow.local.md`,
`AGENTS.md`/`CLAUDE.md`/`CONTRIBUTING.md`, the shape of recent history, then the defaults in
`.claude/rules/task-flow.md`. For trailers in a repository silent in all four, ask the user once and
record the answer in `task-flow.local.md`: the generated `task-flow.md` is rewritten on every update.
`/spec` and `/run` point here for this order.

## Merge strategies

- Feature → `<target>`: **squash** — linear trunk, WIP chain collapses. The branch goes in After the merge.
- Stacked PRs: **merge-commit inside the chain** (preserves ancestry), squash only when the top of
  the stack lands on `<target>`. Squashing mid-chain orphans the SHAs of every PR above it.
- Re-check the base of each stacked PR after the one below merges.

## Spec lifecycle (`PLANS/`)

These are design documents; `/cc-tuner:spec` writes them and their execution plans. An execution
plan is a different artifact (`task-plans/`): it stays where `plan-path.sh create` put it, is ticked
as work lands, and merges with the task. It is never moved or archived: `plan-path.sh`, SessionStart
and `merge.sh` all find it there.

1. Keep optional drafts in the repo's documented ignored scratch space; do not assume a companion
   plugin path.
2. Worth keeping → promote to `$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-path.sh" spec-dir)/YYYY-MM-DD-<slug>.md`
   (the script picks `wiki/` or `docs/` and the repository's own spelling of the plans directory).
   Minimum header: `Goal:`, `Issue:`, and `Architecture:`. Slices, owned paths, and blockers live in
   the separate execution plan that links back to this spec.
3. When an issue exists, the first paragraph links it and the issue body links the spec back.
4. A PR completing the task moves the spec to `<plans-root>/ARCHIVE/PLANS/` before its first
   candidate review, following Prepare the candidate below — never as a standalone doc PR.

## Anti-patterns (case studies)

Open the [case studies](references/case-studies.md) only to see why a rule exists.

## Prepare the candidate

Before the first candidate verification or review, follow the Pre-PR checklist and the
[CI policy](../run/references/local-ci.md). In a PR completing the task, archive its spec, update the
execution plan's `Spec:` header and all live links, then commit these artifacts with the
implementation. Keep acceptance open until proved; archive placement does not certify completion.
Use the new spec path, kept stable throughout required review, for the rest of the run and report it
for resume; record later DoD evidence on the PR. For shared tasks, update companion links together.

## Pre-PR checklist

- [ ] Branch is based on the current target tip (the selected remote's target, or `refs/heads/<target>` with no remote;
      check, do not assume) and its PR is not already merged
- [ ] Commits follow the repository's convention (Conventional Commits by default, required where release
      notes are generated), `!`/`BREAKING CHANGE:` where applicable
- [ ] Issue is linked (`Closes #N` / `Refs #N`), or the PR explains why none is needed; when a board
      is configured, the card has Status and Priority
- [ ] A new regression check was observed failing as specified, or the approved non-code baseline
      was recorded. Read formatter/autofix diffs. If checked inputs changed, verify affected criteria
      with relevant checks on the resulting state; reuse an existing result only if it was obtained
      after those edits. A no-op or unaffected check can reuse earlier evidence. Do not require
      typecheck and lint universally.
- [ ] Findings follow the scope contract in `.claude/rules/task-flow.md`, including regressions
      and older dependencies needed for acceptance; independent improvements remain optional
- [ ] The verification steps and CI mode for the candidate are known. After creating or reusing the PR,
      record the observed CI result or exact-SHA local evidence as the CI policy requires.
- [ ] Spec archived if this PR completes it; the plan stays in `task-plans/`
- [ ] No credentials, unrelated WIP or unintended generated files staged
