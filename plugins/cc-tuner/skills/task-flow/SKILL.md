---
name: task-flow
description: Carries the repository procedures around a task — branch, commit and PR conventions, epics and cards on a GitHub Projects board, cleaning up worktrees and runtime processes after a merge, syncing the target branch, merge strategy for stacked PRs, release notes from commits, and the spec lifecycle. Use for those chores, in any repository. To implement a committed cc-tuner plan use /cc-tuner:run, and to write one /cc-tuner:spec; both read this skill's candidate and checklist sections. Companion to the .claude/rules/task-flow.md invariants installed by the task-flow node of /cc-tuner:setup.
---

# Task Flow — procedures

The invariants (prohibitions, branch and commit format, PR linking) live in the repo's
`.claude/rules/task-flow.md`, installed by the task-flow node of `/cc-tuner:setup`. This skill carries the
procedures that do not need to sit in every session's context. Repo deltas — board name, labels,
cached field IDs — go in `.claude/rules/task-flow.local.md`; check it first.

## Epics and sub-issues

GitHub has both mechanisms natively; do not invent a title-prefix convention.

**An epic is an issue whose type is `Epic`.** Issue Types are org-level and render as a badge on the
card, so an epic is filterable in a board view. If the org has no `Epic` type yet, an org admin adds
it once alongside `Task`/`Bug`/`Feature`; until then fall back to a `[Epic]` title prefix and say so.

```bash
gh api graphql -f query='query{organization(login:"<ORG>"){issueTypes(first:20){nodes{id name}}}}'
gh issue create --repo <owner>/<repo> --title "..." --project "<PROJECT TITLE>"   # then set the type
```

**Decomposition is sub-issues**, not a checklist in the body. The parent then carries a real progress
bar (`subIssuesSummary`), and each child gets its own card, branch and PR.

```bash
gh api graphql -f query='query{repository(owner:"<o>",name:"<r>"){issue(number:<N>){
  subIssuesSummary{total completed percentCompleted} subIssues(first:50){nodes{number title state}}}}}'
```

Use an epic for independently deliverable work or phases needing separate scope decisions. A coupled
change across repositories can share one issue; multiple PRs alone do not require an epic. Use `Refs`
on partial PRs and close the shared issue only after the whole result is verified and delivered.

The branch and PR attach to the **sub-issue**. The epic closes when its children close — never link
`Closes <epic>` from a child's PR.

## Board recipes (GitHub Projects)

Use these recipes only when the repository has a configured board. With `board: none`, omit
`--project` from issue creation and skip project commands, fields and project-scope setup.

**Create an issue directly on the board (preferred):**

```bash
gh issue create --repo <owner>/<repo> --title "..." --label "..." --project "<PROJECT TITLE>"
```

`--project` takes the project **title**, not `owner/number`. Then set fields — without
Status/Priority the card sits in the default column and drops out of filtered views:

```bash
gh project list --owner <owner> --limit 100 --format json        # resolve the board TITLE -> its NUMBER
gh project view <NUMBER> --owner <owner> --format json           # project node ID (item-edit's --project-id)
gh project field-list <NUMBER> --owner <owner> --limit 100 --format json   # once per board; field + option IDs
gh project item-add <NUMBER> --owner <owner> --url <issue-url> --format json   # existing issue -> prints the item ID
gh project item-list <NUMBER> --owner <owner> --limit 500 --format json    # find a card's item ID by its content URL
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --single-select-option-id <OID>
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --clear   # restore a field to unset
```

Always pass `--limit` on the `list`/`field-list`/`item-list` calls — they default to **30 rows**, so
on any active board a card beyond the first 30 silently disappears from the lookup and the lifecycle
skips it. If a lookup returns exactly its `--limit` rows, treat the result as possibly truncated:
retry with a larger limit before concluding "not found".

`item-edit` sets **one field per call** — Status and Priority are two separate edits.

**When a move fails.** An empty `item-list` lookup means the card is not on the board (or the lookup
was truncated, above): add it with `item-add`, which prints the item ID, then edit that ID.
Never run `item-edit` with an empty `--id`: the flags shift and it fails with an opaque
`invalid number: PVTSSF_…`. `The single select option Id does not belong to the field` means the
cached IDs are stale (a board rebuilt or an option renamed): refresh them via `field-list`, update the
cache, retry once.

Cache the IDs from `field-list` in `.claude/rules/task-flow.local.md` the first time you fetch them —
they are stable per board, and re-fetching every time is the main friction that makes agents skip the
board.

The `gh project *` commands need the `project` token scope — a missing scope fails with an opaque
GraphQL error. Fix once per machine: `gh auth refresh -s project`.

**Card lifecycle:** on the board when the spec is approved; In Progress when implementation opens
after recording the prior status; In review when the PR opens, where the board has that option; Done
after the merge that **fully completes** the issue (`Closes`/`Fixes` link). A partial `Refs #N` merge
keeps the card In Progress. An epic's card follows its first and last sub-issue. `/cc-tuner:spec` and
`/cc-tuner:run` name each moment; outside them, follow the same sequence.

**Recording independent future work.** `.claude/rules/task-flow.md` defines what must be fixed in the
current task and what remains an open blocker. This procedure records work outside that obligation.

For independent future work, check current code and work in flight, then search existing issues and
epics for the same cause or deliverable. Add evidence and remaining work to a matching item; group
related findings into one schedulable change. Create a new issue only for a distinct piece of work
that is still needed. An optional suggestion with no planned outcome can remain a review note.

Include the observed problem, the intended result and its source review. Follow the board recipes
above when a board is configured; otherwise create or update the issue without project commands.

## Runtime cleanup

Start a preview, a dedicated MCP server or a disposable container as a Bash call with
`run_in_background: true`, and run a container attached (`docker run --rm --init`, not `-d`).
Stop each with TaskStop when its consumers finish, including work handed back without a merge.
Claude Code stops the rest when the session exits, and cc-tuner's hook stops them on `/clear`.
When the user asks to keep one running past the session, start it detached instead and name it in
the final answer.

## After the merge

Finishing is the merge plus a clean machine. Run this once the PR is merged, in the order given:

```bash
git switch <target> && git pull --ff-only      # local target was stale the moment the PR merged
git worktree list                              # any worktree still pointing at the merged branch?
git worktree remove <path>                     # remove it; --force only when you know the diff is dead
git worktree prune                             # clears stale registrations for directories already gone
git branch --merged <target>                   # inspect local branches already merged into the target
git branch -d <branch>                         # -d refuses if unmerged
git fetch --prune                              # drops remote-tracking refs for branches deleted on the remote
```

After a **squash** merge `-d` always refuses: the branch's commits are not ancestors of the squash
commit, even though their changes landed. Delete it only when the merged PR's head is exactly the
local tip, so nothing local is left out of what merged:

```bash
[ "$(gh pr view <pr> --json state,headRefOid --jq 'select(.state=="MERGED") | .headRefOid')" = \
  "$(git rev-parse <branch>)" ] && git branch -D <branch>
```

A local tip that differs holds commits the PR never carried: look at them, do not delete.

`--ff-only` is deliberate: if it refuses, the local target has commits that are not upstream and that is
something to look at, not to paper over with a merge commit.

Do not delete a worktree whose branch never merged — that is the orphan-branch anti-pattern below,
and the fix is to open the PR, not to erase the evidence.

## Commit conventions

The message format, including attribution trailers, comes from the first of these that answers:
`.claude/rules/task-flow.local.md`, `.claude/rules/task-flow.md`, `AGENTS.md`/`CLAUDE.md`/
`CONTRIBUTING.md`, the shape of recent history. For trailers in a repository silent in all four, ask
the user once and record the answer in `task-flow.local.md`. This section is the single owner of
that order; `/spec` and `/run` point here.

**Attribution trailers are the repository's call, not the plugin's.** Whether an agent's commit
carries `Co-Authored-By:` or a session trailer is a preference: some repositories want the authorship
visible, some want the history to read as the team's. A repository records its answer in
`task-flow.local.md`, because the generated `task-flow.md` is rewritten on every update and would
lose it.

## Release notes from commits

Conventional Commits are the default format; it is required where release notes are generated from
commit messages, and optional where they are not. Two ways to consume them:

- **`release-please`** (GitHub Action) — reads the commits since the last release, opens a release PR
  that bumps the version and writes `CHANGELOG.md`. Use it where a version number exists in more than
  one manifest: it keeps them in sync, which is a class of bug hand-editing keeps reintroducing.
- **`.github/release.yml`** — GitHub's built-in autogeneration. Cheaper to adopt, but it groups
  merged PRs by label, so it reads PR titles rather than commit history and does not bump versions.

Whichever is in use, a commit outside the Conventional format is a commit that will be missing from
the notes; that is the actual cost of an off-format commit.

## Merge strategies

- Feature → `<target>`: **squash** + `--delete-branch` — linear trunk, WIP chain collapses.
- Stacked PRs: **merge-commit inside the chain** (preserves ancestry), squash only when the top of
  the stack lands on `<target>`. Squashing mid-chain orphans the SHAs of every PR above it.
- Re-check the base of each stacked PR after the one below merges.

## Spec lifecycle (`PLANS/`)

These are design documents — `/cc-tuner:spec` writes them and their execution plans. Execution plans
are a different artifact with a different path (`task-plans/`): a plan stays where
`plan-path.sh create` put it for its whole life, is ticked as work lands, and merges with the task.
It is never moved or archived — `plan-path.sh`, SessionStart and `merge.sh` all find it there.

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

- [ ] Branch is based on current `origin/<target>` (check, do not assume) and its PR is not already merged
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
- [ ] PR links the candidate's green CI under its declared mode, or records the exact-SHA local
      result for `none:<reason>` as the CI policy above requires
- [ ] Spec archived if this PR completes it; the plan stays in `task-plans/`
- [ ] No credentials, unrelated WIP or unintended generated files staged
