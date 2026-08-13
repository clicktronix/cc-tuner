# cc-tuner plugin

Skills that tune Claude Code's own configuration. One install, no per-project copies to drift.

## Skills

### `claude-md-writer`

Create, refactor, and audit **CLAUDE.md** and **`.claude/rules/`** memory files for Claude Code, following the official memory docs (<https://code.claude.com/docs/en/memory>). Triggers when you create/trim/split a CLAUDE.md, organize instructions into `.claude/rules/`, or decide what belongs in CLAUDE.md vs rules vs `CLAUDE.local.md` vs tool config.

What it covers (Claude Code memory facts checked against the docs):

- **CLAUDE.md < 200 lines** — the only published size target; loads every session.
- **`paths:` frontmatter only on `.claude/rules/*.md`**, never on CLAUDE.md (CLAUDE.md loads by directory hierarchy; conditional loading is a rules-file feature).
- **Documented load order** — managed → user → project → local; files are concatenated, not overriding, and conflicts are resolved arbitrarily (so the fix is to remove conflicts, not lean on precedence). Rules and subdirectory CLAUDE.md are separate mechanisms, not precedence tiers.
- **Code style / conventions belong in CLAUDE.md** (the docs' own example is "use 2-space indent"); only hard *blocks* go to hooks/settings.
- Correct details on **imports** (max 4 hops), **auto memory** (`MEMORY.md`, first 200 lines / 25 KB, machine-local), **path-scoped rules** (trigger on read; user-level rules *do* load), **monorepo** (`claudeMdExcludes`), and **HTML-comment stripping**.

Deep examples and the verified source list are in the skill's `reference.md`.

### `statusline`

A two-line usage-focused statusline for Claude Code:

```
➜ my-project git:(main) S:2 M:1 U:4 | Opus 4.8 xhigh | 1h12m
 | 5h:66%[▓▓▓▓▓░░░]>23:30  7d:9%[▓░░░░░░░]>17:00 | ctx:8%[▓░░░░░░░░░]
```

Rate-limit windows (5h / 7d utilization + reset time), context-window %, git branch with
staged/modified/untracked counts, model + reasoning effort, and session duration. Bars go
green → yellow (≥50%) → red (≥80%). Cross-platform (macOS Keychain, Linux/Windows
`~/.claude/.credentials.json`).

Plugins can't register a statusline themselves, so a setup command wires it into the
user's `settings.json`:

```
/cc-tuner:statusline-setup            # install (also: update | remove | status)
```

The 5h/7d data uses Claude Code's **unofficial** OAuth usage endpoint — it degrades
silently if that ever breaks. The OAuth token is read locally and only sent to
`api.anthropic.com`.

### `task-flow`

Canonical git workflow — branch naming, Conventional Commits (incl. breaking
changes), PR verification gates, GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle), plan lifecycle (`wiki/PLANS/` → `ARCHIVE`,
`docs/` fallback), and anti-pattern case studies with dated incidents.

The always-on core installs per repo via `/cc-tuner:task-flow-setup` (plugins
can't ship `.claude/rules/*`): a versioned template with the plans root detected
from the repo layout, repo-specific deltas in an untouched `task-flow.local.md`,
and optional cleanup of legacy hand-copied rule files.

### `deep-review`

A read-only, exact-candidate review skill for `/run` and direct use. It reviews the complete committed
diff through correctness, spec/scope, repository standards, architecture/systemic effects,
security/data safety, and testing/operability lenses. It may fan out those independent lenses against
the same immutable SHA, then validates and deduplicates their output without a top-ten cap. Its
verdict includes both commit and tree SHA; any later change invalidates approval.

### `smoke-verify`

A per-repo opt-in Stop-hook gate against the top regression source in agentic
coding: fix commits that pass typecheck/lint but were never actually run. In a
repo that opted in via `/cc-tuner:smoke-verify-setup`, a turn that changed
frontend files (configurable regex in `.claude/smoke-verify.cfg`) cannot end
until the change was **exercised for real** — page rendered, failing case
re-run, artifact looked at — and attested with one line of evidence:

```
bash <plugin>/scripts/smoke-verify/mark.sh verified 'opened /fit page, labels render'
```

The attestation binds to the branch + worktree-content fingerprint of the
delta, so editing again re-arms the gate (staging/committing identical content
does not). Explicit user-authorized skips are recorded (`mark.sh skip '<why>'`).
Fail-open everywhere: no config, no matched changes, malformed counter state,
or `cap` blocks (default 3) on an unchanged delta → the turn ends normally.
Scope: the gate fingerprints **uncommitted** changes — attest before
committing; a change committed mid-turn without attestation escapes it. The
hook itself is milliseconds of bash — it never runs any verification, it only
routes the agent to do it.

## /spec and /run

The task loop is split in three. `/cc-tuner:spec` does the asking, creates the task branch, and
commits machine-checkable acceptance criteria. `/cc-tuner:plan` breaks the spec into vertical slices
with explicit blocking edges, commits the plan file, and publishes the slices as native tasks.
`/cc-tuner:run` works that plan to a merged pull request. Each takes `--auto` except `/spec`; without
it they stop at delivery boundaries.

`/cc-tuner:spec <issue | description>` does all the asking. It reads the repo, issue, architecture,
code, tests, and consumers, grills requirements via `mattpocock-skills:grilling` plus
`mattpocock-skills:domain-modeling`, and commits an executable contract. Its DoR names the observed
baseline, first failing check and expected failure, targeted/full checks, environment and data. Every
acceptance criterion names its deciding machine or human step; every `[eyes]` item records a machine
replacement or waiver. Its DoD binds verification, reviews, PR head, and CI to the same candidate.

`/cc-tuner:plan [--auto] <spec>` slices it. Each slice is a tracer bullet with explicit `Blocked by`
edges; the plan is committed and then published as native tasks, in two passes because `TaskCreate`
takes no dependency argument.

`/cc-tuner:run [--auto] <spec>` works that plan. It takes the frontier in order, proves each slice
RED→GREEN with a mutation, ticks it off in the committed file, then commits a candidate, runs
`cc-tuner:deep-review`, the mattpocock review and Codex's required review at that exact SHA, publishes
the verdict as a pull-request review, and merges only with green required CI on the same commit and
`--match-head-commit` pinning it. Independent code-writing units alone may fan out into isolated
worktrees; the parent owns integration and every later gate.

Without `--auto`, `/run` stops at delivery boundaries and again before merge. With `--auto`, it runs
unattended only while every gate is green. `--auto` never waives incomplete DoR, missing RED→GREEN
evidence, failed tests, stale review, unresolved `[eyes]`, missing current-SHA CI, or scope beyond the
spec. After merge it may reconcile only the task lifecycle; deploy, publish, and migration remain
forbidden.

These replace `/cc-tuner:execute-task`, which tried to do both jobs in one pipeline and could do
neither well: its intake step was marked "human gate, always", so full autonomy was structurally
impossible, while the interactive work was compressed into one step of ten.

Run progress lives in the committed plan file and in Claude Code's own task list. There is no state
file: the plan's `- [x]` ticks are the record that survives a session, the task list is the record
that is visible inside one, and `git` and `gh` hold the delivery facts. Nothing keeps a second copy.

The task list survives `/compact` and resume unchanged, which was measured, so nothing is restored
there. A genuinely new session — `startup` or `/clear` — starts with an empty list, and a
`SessionStart` hook asks the agent to rebuild it from the plan, emitting the unfinished slices with
their blocking edges and every finished slice they still depend on. It asks: a command hook cannot
call `TaskCreate`, so recovery is advisory in exactly the way the plan itself is.

One thing denies rather than advises. A `PreToolUse` guard refuses `gh pr merge` on a pull request
carrying a cc-tuner plan unless its head SHA has a verdict review from the authenticated account,
required CI is green on that same SHA, and the command pins the head with `--match-head-commit`. It
allows silently on any pull request that is not a cc-tuner run. It is a guardrail against an agent's
mistake, not a policy: the merge button on github.com, `git push` and the REST API all bypass it.

Requires the **mattpocock-skills** and **cc-codex-triage** plugins (checked at runtime via prereq-check;
cc-tuner installs and works standalone without them).

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

The `claude-md-writer`, `task-flow`, and `deep-review` skills are model-invoked when their descriptions
match; `deep-review` is also available directly as `/cc-tuner:deep-review`. The installers and
lifecycle playbooks remain explicit user commands: `/cc-tuner:statusline-setup`,
`/cc-tuner:task-flow-setup` (the rule is installed only by this command),
`/cc-tuner:smoke-verify-setup` (the hook stays inert until this command writes repo config),
`/cc-tuner:spec`, `/cc-tuner:plan`, and `/cc-tuner:run`.

## Scope

Claude Code only. The plugin writes Claude Code's own surfaces — memory files (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`), user settings (statusline), and per-repo rule installs — it does not manage other agents' instruction files.

## License

MIT.
