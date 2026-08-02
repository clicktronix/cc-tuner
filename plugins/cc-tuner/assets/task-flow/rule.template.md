<!-- cc-tuner:task-flow v0.10.0 — installed by /cc-tuner:task-flow-setup. Do not hand-edit: re-run the setup command to update. Repo-specific deltas belong in task-flow.local.md next to this file. -->

# Task flow — invariants

Only the rules whose violation loses work, leaks secrets, or breaks history. Everything procedural —
board recipes, epics, worktree cleanup, post-merge sync, merge strategies, changelog, plan lifecycle —
lives in the `cc-tuner:task-flow` skill, which loads when you need it. Where `task-flow.local.md`
conflicts with this file, the local file wins.

## Never

- **Force-push the repository's integration target, or any branch with open review comments.** The
  harm is rewriting history others may have reviewed or built on; the force-push is only how it
  happens. Force-with-lease elsewhere only with explicit sign-off from the user or reviewer.
- **`--no-verify` / `--no-gpg-sign`.** A failing hook is a signal to diagnose, not to silence.
- **`git add -A` / `git add .`.** Stage by explicit path; the sweep is how `.env`, credentials, and
  unrelated WIP reach a commit.
- **`--amend` after a hook rejected the commit.** That commit did not happen, so `--amend` rewrites
  the *previous* one and destroys work. Fix, re-stage, commit again.
- **Commit directly to the repository's integration target.** Resolve it from repo policy or the
  remote default branch, then branch first: `git switch -c <branch>`. On the target with uncommitted
  work: stash → branch → pop.

## Branches

`<type>/<issue>-<kebab-slug>`, ≤50 chars. No issue → `<type>/<short-slug>`, and say why in the PR body.

Types: `feat | fix | refactor | perf | chore | docs | test | build | ci`.

A branch and its PR attach to the **sub-issue** being implemented, never to its parent epic.

## Commits — Conventional Commits v1.0.0

```
<type>[(<scope>)][!]: <imperative subject ≤72 chars, no period>

<body — what changed and why, when that is not obvious from the subject>

[footers: BREAKING CHANGE: <migration note> / Closes #<N> / Refs #<N>]
```

The format is not decoration: release notes are generated from it, so a commit outside the format is
a commit missing from the changelog.

Breaking change: `!` after type/scope plus a `BREAKING CHANGE:` footer carrying the migration note.

One commit = one logical change. A WIP chain during work is fine — squash-on-merge collapses it.

## Pull requests

- `Closes #N` / `Fixes #N` only when the PR fully completes the issue; `Refs #N` for partial or
  stacked work. No issue → say why in the body.
- **Verification is a link, not a transcript.** Point at the green CI run. Do not paste command
  output into the body: it is already in the logs, and it buries the part a human has to read.
- Match the body's length to the change. Say what changed, why, and what is still open. A one-file
  fix does not need sections.
