<!-- cc-tuner:task-flow v0.12.0 — installed by /cc-tuner:task-flow-setup. Do not hand-edit: re-run the setup command to update. Repo-specific deltas belong in task-flow.local.md next to this file. -->

# Task flow — invariants

Only the rules whose violation loses work, leaks secrets, or breaks history. Everything procedural —
board recipes, epics, worktree cleanup, post-merge sync, merge strategies, changelog, spec lifecycle —
lives in the `cc-tuner:task-flow` skill, which loads when you need it. That skill lives in the
plugin cache: a repository also worked by Codex, Cursor or a Claude session without the plugin
cannot read it, so whichever procedures such a session must not skip — post-merge cleanup and the
merge strategy are the usual two — belong in `task-flow.local.md`. Where `task-flow.local.md`
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

**Attribution trailers:** answer this in `task-flow.local.md`, not here — this file is generated
and an answer written into it is lost on the next `/cc-tuner:task-flow-setup update`.

Whether a commit made by an agent carries `Co-Authored-By:` or a session trailer is a decision each
repository makes — some want the authorship visible, some want the history to read as the team's.
cc-tuner does not hold an opinion; it reads the local file, which wins on conflict. Left unanswered,
an agent falls back to whatever its harness does by default, which is how a repository ends up with
a convention nobody chose.

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
- **Verification is a link, not a transcript.** Point at the green CI run. Do not paste command
  output into the body: it is already in the logs, and it buries the part a human has to read.
  Use the spec's CI mode and the checks actually attached to its candidate, including push/manual
  runs. A paused or pending check is not absent CI. When no hosted checks are available, the declared
  `none:<reason>` mode requires a local evidence record for that SHA. `cc-tuner:task-flow` links the
  CI policy; repository-specific commands and evidence formats belong in `task-flow.local.md`.
- Match the body's length to the change. Say what changed, why, and what is still open. A one-file
  fix does not need sections.
