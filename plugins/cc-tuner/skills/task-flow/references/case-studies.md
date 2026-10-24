# Task-flow case studies

Incidents behind the concise rules in the parent skill, with repository, PR and issue identifiers
removed: check the mechanism against your own history.

## Contents

- [Long-lived staging branch and squash](#long-lived-staging-branch-and-squash)
- [Branch continued after its PR merged](#branch-continued-after-its-pr-merged)
- [Regression test that could never fail](#regression-test-that-could-never-fail)
- [Scope rebutted by file provenance](#scope-rebutted-by-file-provenance)
- [Autofix trusted blindly](#autofix-trusted-blindly)
- [Issue omitted from the board](#issue-omitted-from-the-board)
- [Review findings turned into backlog](#review-findings-turned-into-backlog)
- [Tiny documentation PR](#tiny-documentation-pr)
- [Other loss patterns](#other-loss-patterns)
- [Review and delegation ordering](#review-and-delegation-ordering)

## Long-lived staging branch and squash

A long-lived branch was squash-merged to `main`; eight follow-up PRs still targeted the dead branch, so
their commits had to be cherry-picked onto a fresh one. Use short branches directly against the
intended target.

## Branch continued after its PR merged

A `fix/` branch gained two unrelated commits after its PR was squash-merged. Twelve days later it showed
five commits "ahead" and 35 behind `main`, three of them already merged under other SHAs. Rebasing
conflicted in six files; cherry-picking the two new commits onto a fresh branch applied cleanly.

A branch is finished rather than merely behind when its PR is `MERGED` and apparently unmerged commit
subjects already exist on the target under other SHAs. Cherry-pick genuinely new work forward.

## Regression test that could never fail

A URL-race regression test built its second patch from already-merged state, although production
handlers closed over a render snapshot, so it passed against the broken implementation. Inlining the old
implementation as a throwaway mutant showed red/green in under two minutes. A regression test needs
evidence that it fails against the bug.

## Scope rebutted by file provenance

A cross-writer race was called pre-existing because its shell file was untouched, although the branch's
two new writers made it reachable. Conversely, `git diff <base>...HEAD` showed the branch introduced a
default behind missing archived rows. Defect causality decides scope; file provenance does not.

## Autofix trusted blindly

`eslint --fix` moved value imports into `import type`, and formatting moved a comment past a bare
`return`. Both tools reported success; typecheck exposed both. Checks must cover the code after
autofix, not an earlier green state: read the resulting diff and run the checks relevant to the
affected criteria.

## Issue omitted from the board

Nine issues created with bare `gh issue create` missed the project board. Create with `--project` and
set Status and Priority.

## Review findings turned into backlog

A tool-call audit matched 42 created issues, 41 of them without `--project`. A missing flag does not
prove missing board membership, since the project also had an auto-add workflow.

The larger failure was treating an issue as resolution: one issue described a missing acceptance
criterion while the run reported its findings closed after filing it. Filing an issue is not resolving
it. Required work stays in the run; workers return findings to the orchestrator, and independent future
work is grouped or added to an existing issue. File membership and a deferral-count threshold were both
tried and removed: neither identifies why a defect must be fixed.

## Tiny documentation PR

A docs-only PR with three wording fixes in one file cost more workflow than it was worth. Usually fold a
tiny doc fix into open work or batch it; an urgent fix may still ship alone.

## Other loss patterns

- A commit rejected by a hook did not happen; `--amend` would rewrite the previous commit. Fix,
  re-stage, and create a new commit.
- Name branches by feature, not the prompt's first words.
- Work left only in a branch/worktree is unfinished until it has a PR; remove worktrees only after the
  branch is proven merged.

## Review and delegation ordering

A blanket ban on parallel review contradicted deep-review's independent read-only lenses, and the
wording "parallelism lives in the writing and nowhere else" forbade units their own tests. The boundary
is the shared candidate decision: independent reads and isolated implementation may fan out, while one
orchestrator integrates the work, verifies it and owns delivery.
