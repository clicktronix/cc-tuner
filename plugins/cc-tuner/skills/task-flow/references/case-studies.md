# Task-flow case studies

These incidents explain the concise rules in the parent skill. Dates and concrete outcomes are kept so
a future audit can check whether the failure still reproduces.

## Long-lived staging branch and squash

On 2026-06-04/05, `perf-quality-audit` was squash-merged to `main` as PR #50. Eight follow-up PRs
(#51–#58) targeted the dead branch; the final merge was impossible, so all eight commits had to be
cherry-picked onto a fresh branch (PR #61). Use short branches directly against the intended target.

## Branch continued after its PR merged

On 2026-07-26, stokli/backend PR #213 squash-merged `fix/portfolio-performance-correctness`, after
which the same branch gained two unrelated `chore:` commits. Twelve days later it showed five commits
"ahead" and 35 behind `main`; three of those five were already merged under other SHAs. Rebasing
conflicted in six files on the first old commit, while cherry-picking the two new commits onto a fresh
branch applied cleanly.

A branch is finished rather than merely behind when its PR is `MERGED` and apparently unmerged commit
subjects already exist on the target under other SHAs. Cherry-pick genuinely new work forward.

## Regression test that could never fail

During marqa-tech/platform PR #399 review on 2026-07-28, a URL-race regression test built its second
patch from already-merged state even though production handlers closed over a render snapshot. It
passed against the broken implementation. Inlining the old implementation as a throwaway mutant
showed red/green in under two minutes. A regression test needs evidence that it fails against the bug.

## Scope rebutted by file provenance

In the same review, a cross-writer race was called pre-existing because its shell file was untouched,
although the branch's two new writers made it reachable. Conversely, `git diff <base>...HEAD` showed
that the branch introduced a default behind missing archived rows. Defect causality decides scope;
file provenance does not.

## Autofix trusted blindly

Also in PR #399, `eslint --fix` moved value imports into `import type`, and formatting moved a comment
past a bare `return`. Both tools reported success; typecheck exposed both failures. Read an autofix
diff and re-run typecheck and lint.

## Issue omitted from the board

On 2026-06-05, nine issues created with bare `gh issue create` missed the project board until a later
manual request. Create with `--project` and set Status and Priority.

## Tiny documentation PR

On 2026-06-05, marqa-tech/analyzer PR #23 contained three wording fixes in one file and incurred more
workflow cost than value. Usually fold a tiny doc fix into open work or batch it; an urgent fix may
still ship alone.

## Other loss patterns

- A commit rejected by a hook did not happen; `--amend` would rewrite the previous commit. Fix,
  re-stage, and create a new commit.
- Name branches by feature, not the prompt's first words.
- Work left only in a branch/worktree is unfinished until it has a PR; remove worktrees only after the
  branch is proven merged.
