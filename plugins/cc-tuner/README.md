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

## /execute-task

A task-lifecycle playbook that walks the main agent through the full development cycle: intake → plan → implement → review → CI/CD → merge. Choose an autonomy level at start time (`brainstorm-only`, `checkpoints`, or `supervised`) to control how often the agent pauses for human input. Hard-stops are built in at each gate — dirty tree, red CI, human-eye acceptance, and CD/merge — so the agent can't silently skip them.

Use it whenever you want a structured, reviewable workflow instead of a free-form "implement this" prompt. Five bundled bash scripts handle the deterministic git/fs work (prereq-check, config-init, preflight, journal, guard-artifacts); per-project settings and overrides live in `.claude/execute-task.md`.

Requires the **superpowers** and **cc-codex-triage** plugins (checked at runtime via prereq-check; cc-tuner installs and works standalone without them).

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

The skill is model-invoked: Claude loads it when your task is about a CLAUDE.md or `.claude/rules/` file (activation is driven by the task and the skill's description, not by file reads). No slash command needed.

## Scope

Claude Code only. It writes Claude Code's memory surfaces (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`) — it does not manage other agents' instruction files.

## License

MIT.
