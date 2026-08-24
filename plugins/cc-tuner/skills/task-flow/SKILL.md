---
name: task-flow
description: Use when working a task end to end in the user's repos — creating branches, commits and PRs, managing epics and cards on a GitHub Projects board, cleaning up worktrees after a merge, syncing the target branch, choosing a merge strategy for stacked PRs, or generating release notes from commits. Companion to the .claude/rules/task-flow.md invariants installed by /cc-tuner:task-flow-setup.
---

# Task Flow — procedures

The invariants (prohibitions, branch and commit format, PR linking) live in the repo's
`.claude/rules/task-flow.md`, installed by `/cc-tuner:task-flow-setup`. This skill carries the
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

When to reach for an epic: the work needs more than one PR, or spans more than one repo, or has
phases a human will want to review separately. Below that, a plain issue.

The branch and PR attach to the **sub-issue**. The epic closes when its children close — never link
`Closes <epic>` from a child's PR.

## Board recipes (GitHub Projects)

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

`item-edit` sets **one field per call** — Status and Priority are two separate edits. If an edit
fails against cached IDs, refresh them via `field-list` (IDs go stale when a board is rebuilt),
update the cache, retry once.

Cache the IDs from `field-list` in `.claude/rules/task-flow.local.md` the first time you fetch them —
they are stable per board, and re-fetching every time is the main friction that makes agents skip the
board.

The `gh project *` commands need the `project` token scope — a missing scope fails with an opaque
GraphQL error. Fix once per machine: `gh auth refresh -s project`.

**Card lifecycle:** In Progress when implementation opens after recording the prior status; Done after
the merge that **fully completes** the issue (`Closes`/`Fixes` link). A partial `Refs #N` merge keeps
the card In Progress. One deferred review finding = one issue: an issue is trackable and outlives the PR, while a
comment-thread list closes with the thread that held it.

## After the merge

Finishing is not the merge — it is the merge plus leaving the machine clean. Run this once the PR is
merged, in the order given:

```bash
git switch <target> && git pull --ff-only      # local target was stale the moment the PR merged
git worktree list                              # any worktree still pointing at the merged branch?
git worktree remove <path>                     # remove it; --force only when you know the diff is dead
git worktree prune                             # clears stale registrations for directories already gone
git branch --merged <target>                   # inspect local branches already merged into the target
git branch -d <branch>                         # -d refuses if unmerged; never reach for -D to win an argument
git fetch --prune                              # drops remote-tracking refs for branches deleted on the remote
```

`--ff-only` is deliberate: if it refuses, the local target has commits that are not upstream and that is
something to look at, not to paper over with a merge commit.

Do not delete a worktree whose branch never merged — that is the orphan-branch anti-pattern below,
and the fix is to open the PR, not to erase the evidence.

## Release notes from commits

Conventional Commits are the input to generated release notes, which is why the format is an
invariant rather than a style preference. Two ways to consume them:

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

These are design documents — the ones `/cc-tuner:spec` writes. The execution plans `/cc-tuner:plan`
writes are a different artifact with a different path (`task-plans/`) and a different lifecycle.

1. Keep optional drafts in the repo's documented ignored scratch space; do not assume a companion
   plugin path.
2. Worth keeping → promote to `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md`. The plans root is `wiki/`
   when the repo has one, else `docs/` — check, do not assume; the rule no longer carries it.
   Minimum header: `Goal:`, `Architecture:`, then tasks with file paths.
3. First paragraph links the tracking issue; the issue body links the plan back.
4. Completed → move to `<plans-root>/ARCHIVE/PLANS/` **in the same PR that completes the work** —
   never as a standalone doc PR.

## Anti-patterns (case studies)

For diagnosis examples and their evidence, read the [case studies](references/case-studies.md). The
operative rules are the procedures and checklist in this file; the examples explain why they exist.

## Pre-PR checklist

- [ ] Branch is based on current `origin/<target>` (check, do not assume) and its PR is not already merged
- [ ] Commits follow Conventional Commits, `!`/`BREAKING CHANGE:` where applicable
- [ ] Issue exists and is linked (`Closes #N` / `Refs #N`); the card has Status and Priority
- [ ] **Nothing is trusted on its own success report** — a new regression test was shown red against
      the pre-fix code, and any `--fix`/formatter run was followed by typecheck *and* lint plus a read
      of the diff it produced
- [ ] Nothing deferred as "pre-existing" without `git diff <base>...HEAD` showing the branch does not
      cause it
- [ ] PR body links the green CI run instead of pasting its output. One line saying the mutant check
      was done is not a transcript — it is the part a reviewer cannot reconstruct from the logs
- [ ] Plan promoted or archived if this PR completes it
- [ ] No `.env`, credentials, or generated files staged
