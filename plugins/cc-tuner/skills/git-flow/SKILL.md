---
name: git-flow
description: Use when creating branches/commits/PRs in the user's repos, managing task cards on a GitHub Projects board (create issue with Status/Priority, move In Progress/Done), promoting or archiving plan documents, or choosing a merge strategy for stacked PRs. Companion to the .claude/rules/git-flow.md rule installed by /cc-tuner:git-flow-setup.
---

# Git Flow — procedures

The always-on invariants (branch naming, commit format, prohibitions, tiny-PR
batching) live in the repo's `.claude/rules/git-flow.md`, installed by
`/cc-tuner:git-flow-setup`. This skill carries the procedures that don't need
to sit in every session's context. Repo deltas (board name, labels): check
`.claude/rules/git-flow.local.md` first.

## Board recipes (GitHub Projects)

**Create an issue directly on the board (preferred):**

```bash
gh issue create --repo <owner>/<repo> --title "..." --label "..." --project "<PROJECT TITLE>"
```

`--project` takes the project **title**, not `owner/number`. Then set fields —
without Status/Priority the card sits in the default column and drops out of
filtered views:

```bash
gh project field-list <NUMBER> --owner <owner> --format json   # once per board; note field + option IDs
gh project item-add <NUMBER> --owner <owner> --url <issue-url>  # for existing issues
gh project item-edit --project-id <PID> --id <ITEM_ID> --field-id <FID> --single-select-option-id <OID>
```

Cache the IDs from `field-list` in `.claude/rules/git-flow.local.md` the first
time you fetch them — they are stable per board, and re-fetching every time is
the main friction that makes agents skip the board.

**Card lifecycle:** In Progress when the branch is created; Done after merge.
One deferred review finding = one issue (never a buried comment-thread list).

## Merge strategies

- Feature → `main`: **squash** + `--delete-branch` — linear trunk, WIP chain collapses.
- Stacked PRs: **merge-commit inside the chain** (preserves ancestry), squash only when the top of the stack lands on `main`. Squashing mid-chain orphans the SHAs of every PR above (see Anti-patterns).
- Re-check the base of each stacked PR after the one below merges.

## Plan lifecycle

1. Draft where superpowers scratches them: `docs/superpowers/plans/` (git-ignored).
2. Worth keeping → promote to `<plans-root>/PLANS/YYYY-MM-DD-<slug>.md` (the installed rule names the root for this repo: `wiki/` or `docs/`). Minimum header: `Goal:`, `Architecture:`, then tasks with file paths.
3. First paragraph links the tracking issue; the issue body links the plan back.
4. Completed → move to `<plans-root>/ARCHIVE/PLANS/` **in the same PR that completes the work** — never as a standalone doc PR.

## Anti-patterns (case studies)

- **Long-lived staging branch + squash** — real incident 2026-06-04/05: `perf-quality-audit` squashed to `main` as PR #50, then 8 follow-up PRs (#51–#58) squash-targeted the dead branch; the final merge was impossible and all 8 commits had to be cherry-picked onto a fresh branch (PR #61). Short branches straight to `main`.
- **Issue off the board** — real incident 2026-06-05: 9 issues created via bare `gh issue create`; none reached the board until an explicit request. Always create with `--project` + set Status/Priority.
- **Tiny doc-PR spam** — real incident 2026-06-05 (marqa-tech/analyzer PR #23): standalone PR for 3 wording fixes in one file; user: "We waste time and tokens on that junk." Fold into an open PR or batch 3+.
- **Amend after hook failure** — the commit did not happen; `--amend` rewrites the previous one and loses work. Fix → re-stage → new commit.
- **First-words branch name** (`001-make-sure-portfolio-...`) — name by feature, not by the prompt's opening words.
- **Orphan branch** — work finished in a worktree, PR never opened, branch rots. Opening the PR is part of finishing.

## Pre-PR checklist

- [ ] Branch off fresh `origin/main` (rebase if >24h old)
- [ ] Commits follow Conventional Commits (incl. `!`/`BREAKING CHANGE:` where applicable)
- [ ] Issue exists, linked (`Closes #N`/`Refs #N`), card has Status/Priority
- [ ] PR body: verification checkbox list with real lint/typecheck/test output
- [ ] Plan promoted/archived if this PR completes it
- [ ] No `.env`, credentials, generated files staged

## Why

Every rule reacts to a documented failure, not theoretical hygiene: staging-branch
ghost-conflicts (2026-06-04), board-less issues (2026-06-05), tiny-PR feedback
(2026-06-05), amend-after-hook data loss (Claude Code default-instruction failure
mode). Dates kept so future edits can check whether the failure still reproduces.
