<!-- cc-tuner:task-flow v0.19.0 — installed by /cc-tuner:setup install task-flow. Do not hand-edit: re-run that command to update. Repo-specific deltas belong in task-flow.local.md next to this file. -->

# Task flow — invariants

Procedures — board recipes, epics, cleanup, merge strategies, release notes — live in the
`cc-tuner:task-flow` skill. Where `task-flow.local.md` conflicts with this file, the local file wins.

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

## Branches and commits — repository policy first, then these defaults

The repository's own convention wins: `task-flow.local.md`, `AGENTS.md`/`CLAUDE.md`, a
`CONTRIBUTING.md`, or the shape of its recent history. The defaults below apply only where it is
silent.

**Branch default:** `<type>/<issue>-<kebab-slug>`, ≤50 chars. No issue → `<type>/<short-slug>`, and
say why in the PR body. Types: `feat | fix | refactor | perf | chore | docs | test | build | ci`.
A branch and its PR attach to the **sub-issue** being implemented, never to its parent epic.

**Commit default:** Conventional Commits v1.0.0.

```
<type>[(<scope>)][!]: <imperative subject ≤72 chars, no period>

<body — what changed and why, when that is not obvious from the subject>

[footers: BREAKING CHANGE: <migration note> / Closes #<N> / Refs #<N>]
```

Where release notes are generated from commits (release-please and similar), a commit outside the
format is missing from the changelog.

Breaking change: `!` after type/scope plus a `BREAKING CHANGE:` footer carrying the migration note.

One commit = one logical change. A WIP chain during work is fine — squash-on-merge collapses it.

**Attribution trailers:** if `task-flow.local.md` and the repository's own instructions are silent,
ask once and record the answer in `task-flow.local.md`.

## Pull requests

- `Closes #N` / `Fixes #N` only when the PR fully completes the issue; `Refs #N` for partial or
  stacked work. No issue → say why in the body.
- **Fix this task's bugs, regressions and missing acceptance criteria**, including missing work they
  depend on. File location, repository, severity, size and finding count do not decide scope. Update
  the plan when a fix needs more work; a reviewer's independent improvement is not a new requirement.
- **Tracking a defect does not resolve it.** An unmet acceptance criterion remains open until proved
  or explicitly waived by the user. If access or a user decision blocks it, continue available work
  and report the dependency; do not claim completion. Recording independent future work does not
  pause the run or require a new confirmation for work already authorised.
- **Use the configured board for tracked work.** Add new issues when creating them and confirm reused
  issues are on it. With `board: none`, use issues without project commands or project permissions.
- **Verification is a link, not a transcript.** Point at the green CI run; command output stays in
  the logs, where it does not bury the part a human has to read.
- Match the body's length to the change. Say what changed, why, and what is still open. A one-file
  fix does not need sections.
