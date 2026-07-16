<!-- cc-tuner:git-flow v0.5.0 — installed by /cc-tuner:git-flow-setup. Do not hand-edit: re-run the setup command to update. Repo-specific deltas belong in git-flow.local.md next to this file. -->

# Git flow — branches, commits, PRs, tasks

Advisory rules (no enforcement hooks). Procedures — board recipes, merge
strategies, plan lifecycle, anti-pattern case studies — live in the
`cc-tuner:git-flow` skill: invoke it when touching the project board, opening
a non-trivial PR, or managing plan documents. Where `git-flow.local.md`
conflicts with this file, the local file wins.

## Branches

- `<type>/<issue>-<kebab-slug>`, ≤50 chars. No issue → `<type>/<short-slug>`, justify in the PR body.
- Types: `feat | fix | refactor | perf | chore | docs | test | build | ci`.
- Never commit directly to `main` — branch first (`git switch -c <branch>`). On `main` with uncommitted work: stash → branch → pop.
- Branch lifetime ≤ 48h wall-clock. Older **unpublished** branches: rebase onto `origin/main` before the first push. A **pushed branch with review comments** merges `origin/main` instead — rebasing it would demand the force-push forbidden below (force-with-lease only with the reviewer's explicit sign-off).
- No long-lived staging branches (`develop`, `staging`) — squash-merging feature PRs into one breaks ancestry and the next merge to `main` surfaces ghost-conflicts. Short branches straight to `main`; feature flags for incomplete work.

## Commits — Conventional Commits v1.0.0

```
<type>[(<scope>)][!]: <imperative subject ≤72 chars, no period>

<body — what changed and why, if non-trivial>

[footers: BREAKING CHANGE: <migration note> / Closes #<N> / Refs #<N>]
```

- Breaking change: `!` after type/scope (semver-major signal) plus a `BREAKING CHANGE:` footer with the migration note. `!` without the footer → the subject/body MUST describe the break.
- Always a NEW commit — never `--amend` / force-push unless the user explicitly asks. After a failed pre-commit hook the commit did NOT happen; `--amend` would rewrite the *previous* commit and destroy work.
- Never `--no-verify` / `--no-gpg-sign`. A failing hook is a signal to diagnose, not silence.
- Stage explicitly by path — no `git add -A` / `git add .` (sweeps `.env`, credentials, unrelated WIP into commits).
- One commit = one logical change. A WIP chain is fine during work — squash-on-merge collapses it.

## Pull Requests

- Link the issue: `Closes #N` / `Fixes #N` only when the PR fully completes it; `Refs #N` for partial/stacked work. No issue → state why in the body.
- Verification gate: the PR body carries a checkbox list of this repo's lint/typecheck/test results with real output. "I believe the tests pass" is not evidence.
- Feature → `main`: squash-merge with `--delete-branch`. Never force-push `main` or any branch with open review comments.
- **No tiny doc-only PRs:** a single-file doc fix folds into an open PR or waits for a batch of 3+ small changes. Standalone only if urgent AND the user explicitly confirms.

## Tasks (GitHub Projects)

- Anything larger than one commit/PR, every deferred review finding, every audit bug → an issue **created on the project board with Status/Priority set** — a bare `gh issue create` leaves the card off every filtered view (recipes: `cc-tuner:git-flow` skill).
- The card moves with the work: In Progress at start, Done after merge.

## Plans

- Needed when: >1 PR, >2 days, or 3+ components. Not for drive-by fixes or single-file changes.
- Drafts scratch in git-ignored `docs/superpowers/plans/`; a plan worth keeping is promoted to `{{PLANS_ROOT}}/PLANS/YYYY-MM-DD-<slug>.md`; completed plans move to `{{PLANS_ROOT}}/ARCHIVE/PLANS/` (in the same PR that completes them — not a standalone doc PR).
- The plan links its issue in the first paragraph; the branch follows the issue number; the PR body says `Implements plan {{PLANS_ROOT}}/PLANS/<file> → Closes #N` (or `Refs #N` when partial).
