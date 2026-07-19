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

### `git-flow`

Canonical git workflow — branch naming, Conventional Commits (incl. breaking
changes), PR verification gates, GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle), plan lifecycle (`wiki/PLANS/` → `ARCHIVE`,
`docs/` fallback), and anti-pattern case studies with dated incidents.

The always-on core installs per repo via `/cc-tuner:git-flow-setup` (plugins
can't ship `.claude/rules/*`): a versioned template with the plans root detected
from the repo layout, repo-specific deltas in an untouched `git-flow.local.md`,
and optional cleanup of legacy hand-copied rule files.

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

The attestation binds to the branch + content fingerprint of the delta, so
editing again re-arms the gate. Explicit user-authorized skips are recorded
(`mark.sh skip '<why>'`). Fail-open everywhere: no config, no matched changes,
malformed state, or `cap` blocks (default 3) on an unchanged delta → the turn
ends normally. The hook itself is milliseconds of bash — it never runs any
verification, it only routes the agent to do it.

## /execute-task

A task-lifecycle playbook that walks the main agent through the full development cycle: intake → plan → implement → review → CI/CD → merge. Choose an autonomy level at start time (`brainstorm-only`, `checkpoints`, or `supervised`) to control how often the agent pauses for human input. Hard-stops are built in at each gate — dirty tree, red CI, human-eye acceptance, and CD/merge — so the agent can't silently skip them.

Use it whenever you want a structured, reviewable workflow instead of a free-form "implement this" prompt. Five bundled bash scripts handle the deterministic git/fs work (prereq-check, config-init, preflight, journal, guard-artifacts); per-project settings and overrides live in `.claude/execute-task.md`.

Requires the **superpowers** and **cc-codex-triage** plugins (checked at runtime via prereq-check; cc-tuner installs and works standalone without them).

With `model_tiering: on` in the project config, step 3 dispatches implementation subagents on cheaper models per `assets/delegate/tiering.md` — mechanical units on sonnet, standard units on opus, architectural/sensitive ones on the main model — while planning, reviews, and acceptance always stay on the main model, and every delegated diff is verified before acceptance.

## /delegate

The economical middle ground between doing everything on the main model and the full `/execute-task` lifecycle: `/cc-tuner:delegate <free-form task>` has the main model decompose the task, classify each unit per `assets/delegate/tiering.md`, fan implementation out to sonnet/opus subagents (worktree isolation for parallel edits), and verify every returned diff itself (full diff read + cheap gate + acceptance criteria; failed units get one redispatch, then a tier escalation). No gates, journal, or board — hygiene rules (surgical staging, no outward-facing actions, sensitive surfaces never below the main model) still apply.

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

The `claude-md-writer`, `git-flow`, and `smoke-verify` skills are model-invoked: Claude loads them when the task matches their descriptions — no slash command needed for those. The installers and the lifecycle playbooks are explicit slash commands you run yourself: `/cc-tuner:statusline-setup`, `/cc-tuner:git-flow-setup` (installing the canonical rule into a repo happens ONLY via this command — installing the plugin alone does not write any `.claude/rules/` file), `/cc-tuner:smoke-verify-setup` (same opt-in story: the Stop hook loads with the plugin but stays inert until this command writes the repo's config), `/cc-tuner:execute-task`, and `/cc-tuner:delegate`.

## Scope

Claude Code only. The plugin writes Claude Code's own surfaces — memory files (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`), user settings (statusline), and per-repo rule installs — it does not manage other agents' instruction files.

## License

MIT.
