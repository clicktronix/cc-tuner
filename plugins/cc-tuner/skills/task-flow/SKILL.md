---
name: task-flow
description: Use when working a task end to end in the user's repos — creating branches, commits and PRs, managing epics and cards on a GitHub Projects board, cleaning up worktrees after a merge, syncing local main, choosing a merge strategy for stacked PRs, or generating release notes from commits. Companion to the .claude/rules/task-flow.md invariants installed by /cc-tuner:task-flow-setup.
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

**Card lifecycle:** In Progress when the branch is created; Done after the merge that **fully
completes** the issue (`Closes`/`Fixes` link). A partial `Refs #N` merge keeps the card In Progress.
One deferred review finding = one issue, never a buried comment-thread list.

## After the merge

Finishing is not the merge — it is the merge plus leaving the machine clean. Run this once the PR is
merged, in the order given:

```bash
git switch main && git pull --ff-only          # local main was stale the moment the PR merged
git worktree list                              # any worktree still pointing at the merged branch?
git worktree remove <path>                     # remove it; --force only when you know the diff is dead
git worktree prune                             # clears stale registrations for directories already gone
git branch --merged main | grep -v '^\*\| main$'   # local branches whose work is already in main
git branch -d <branch>                         # -d refuses if unmerged; never reach for -D to win an argument
git fetch --prune                              # drops remote-tracking refs for branches deleted on the remote
```

`--ff-only` is deliberate: if it refuses, local `main` has commits that are not upstream and that is
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

- Feature → `main`: **squash** + `--delete-branch` — linear trunk, WIP chain collapses.
- Stacked PRs: **merge-commit inside the chain** (preserves ancestry), squash only when the top of
  the stack lands on `main`. Squashing mid-chain orphans the SHAs of every PR above it.
- Re-check the base of each stacked PR after the one below merges.

## Plan lifecycle

1. Draft where superpowers scratches them: `docs/superpowers/plans/` (git-ignored).
2. Worth keeping → promote to `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md`. The plans root is `wiki/`
   when the repo has one, else `docs/` — check, do not assume; the rule no longer carries it.
   Minimum header: `Goal:`, `Architecture:`, then tasks with file paths.
3. First paragraph links the tracking issue; the issue body links the plan back.
4. Completed → move to `<plans-root>/ARCHIVE/PLANS/` **in the same PR that completes the work** —
   never as a standalone doc PR.

## Anti-patterns (case studies)

- **Long-lived staging branch + squash** — real incident 2026-06-04/05: `perf-quality-audit` squashed
  to `main` as PR #50, then 8 follow-up PRs (#51–#58) squash-targeted the dead branch; the final merge
  was impossible and all 8 commits had to be cherry-picked onto a fresh branch (PR #61). Short
  branches straight to `main`.
- **Stale base** — a branch cut days ago whose work was meanwhile squash-merged reads as "6 commits
  ahead" while its base is behind, and the conflicts surface only at merge time. Before starting a
  session on an existing branch, compare it against `origin/main`, not against the tip you remember.
- **Issue off the board** — real incident 2026-06-05: 9 issues created via bare `gh issue create`;
  none reached the board until an explicit request. Always create with `--project` and set
  Status/Priority.
- **Tiny doc-PR spam** — real incident 2026-06-05 (marqa-tech/analyzer PR #23): a standalone PR for
  three wording fixes in one file, on which the user said "we waste time and tokens on that junk".
  Fold a single-file doc fix into an open PR, or batch it with others. This is judgement, not an
  invariant — an urgent fix ships alone — which is why it lives here rather than in the rule.
- **Amend after hook failure** — the commit did not happen; `--amend` rewrites the previous one and
  loses work. Fix → re-stage → new commit.
- **First-words branch name** (`001-make-sure-portfolio-...`) — name by feature, not by the prompt's
  opening words.
- **Orphan branch and its worktree** — work finished in a worktree, PR never opened, branch rots and
  the directory stays on disk. Opening the PR is part of finishing; the cleanup above is the other
  part.

## Pre-PR checklist

- [ ] Branch is based on current `origin/main` (check, do not assume)
- [ ] Commits follow Conventional Commits, `!`/`BREAKING CHANGE:` where applicable
- [ ] Issue exists and is linked (`Closes #N` / `Refs #N`); the card has Status and Priority
- [ ] PR body links the green CI run instead of pasting its output
- [ ] Plan promoted or archived if this PR completes it
- [ ] No `.env`, credentials, or generated files staged

## Why

Every entry reacts to a documented failure, not theoretical hygiene: staging-branch ghost-conflicts
(2026-06-04), board-less issues (2026-06-05), amend-after-hook data loss, and PR bodies that grew
past 4,000 characters because the rule asked for pasted command output. Dates are kept so a future
edit can check whether the failure still reproduces.
