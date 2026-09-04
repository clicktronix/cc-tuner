---
name: claude-md-writer
description: Use when creating, refactoring, auditing, or trimming a CLAUDE.md / AGENTS.md / memory file, splitting project instructions into .claude/rules/, or deciding what belongs in CLAUDE.md vs rules vs skills vs hooks vs CLAUDE.local.md. Covers Claude Code memory, the AGENTS.md open format, and a measured audit route for oversized instruction files.
---

# CLAUDE.md Writer

Create and refactor CLAUDE.md, AGENTS.md and `.claude/rules/` files. Every Claude Code memory *fact* here is checked against the source (<https://code.claude.com/docs/en/memory>); AGENTS.md facts against <https://agents.md/>; structuring patterns are labelled where they are convention, not doc. Detailed mechanisms and sources are in [reference.md](reference.md).

Two jobs, and they are different work:

- **Author** a file that does not exist yet, or add to one → the tables below.
- **Audit** a file that grew past its budget → read and follow [audit.md](audit.md). Do not trim it line by line: measure what actually loads, identify why it grew, then rebuild it.

## Golden rules

| Rule | Why |
|---|---|
| **CLAUDE.md < 200 lines** | Loads into context at the start of every session — the only doc-published size *target*. The hard limit is separate: a CLAUDE.md over **4 MiB** is skipped whole, so an oversized file fails silently rather than partially |
| **Critical / always-on rules first** | Earliest instructions get the most adherence |
| **Move task-specific or component-specific content out** | A multi-step procedure or one-area rule belongs in a skill or a path-scoped rule, not in always-on memory |
| **`paths:` frontmatter lives on `.claude/rules/*.md` and on skills — never on CLAUDE.md** | CLAUDE.md loads by directory hierarchy only. Both rules and skills take `paths` in the same glob format; a skill with `paths` is auto-loaded only for matching files |
| **Verify with `/context`, not by reading the file** | `/context` lists what actually loaded under **Memory files**. A file you can see on disk is not evidence it loaded |
| **Pointers over copies** | A pointer stays current when its target's content changes and breaks visibly when its path changes; a pasted copy silently goes stale. Versions, env lists and counts are the usual offenders — they all have an authoritative owner already |
| **Hard enforcement → hooks/settings, not memory** | CLAUDE.md *guides*, it doesn't enforce. Conventions — incl. code style ("use 2-space indent") — are valid CLAUDE.md content per the docs; just don't re-paste what a linter/formatter config already enforces, and use a hook / `permissions.deny` for anything that must be *blocked* |
| **Every line must change behaviour** | The test the docs publish: *"would removing this cause Claude to make mistakes?"* If a linter already catches it, or Claude already does it right, the line is a no-op that costs context in every session |

## Memory load order

Loaded broadest → most specific and **concatenated, not overriding** — a more-specific file is read *later* (so it's freshest), but the docs are explicit that if two instructions conflict Claude may pick one arbitrarily. The fix for a conflict is to remove it, not to rely on precedence. These are layers, not size tiers:

| Layer | Location |
|---|---|
| Managed policy | macOS `/Library/Application Support/ClaudeCode/CLAUDE.md` · Linux/WSL `/etc/claude-code/CLAUDE.md` · Windows `C:\Program Files\ClaudeCode\CLAUDE.md` |
| User | `~/.claude/CLAUDE.md` (every project on this machine) |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` (shared, committed) |
| Local | `./CLAUDE.local.md` (gitignored personal notes — read last at its level) |

Files in **ancestor** directories load too. In a monorepo, launching in `packages/web/` also loads the workspace-root CLAUDE.md — that parent file is part of the same budget, and auditing the child while ignoring the parent measures half the problem.

Two **separate mechanisms**, not precedence layers:
- **`.claude/rules/*.md`** — conditional includes (see below). User-level `~/.claude/rules/` also load (before project rules).
- **Subdirectory `CLAUDE.md`** — loaded on demand when Claude reads files in that directory, not at launch.

## What goes where

| Content | Location |
|---|---|
| Project one-liner, layout, always-do rules, build/test commands | `CLAUDE.md` |
| Critical constraints | `CLAUDE.md`, at the top |
| Domain detail (DB schema, API patterns, deploy steps) | `.claude/rules/<domain>.md` |
| Multi-step procedure / workflow | a skill (`.claude/skills/<name>/SKILL.md`) — custom commands are now the same mechanism, so `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both give you `/deploy` |
| Detail needed only for one area, but as a *procedure* | a skill with `paths` — loads on demand AND only for matching files, cheaper than a rule |
| An operator runbook a human also reads | `docs/how-to/<topic>.md`, named from the file — a runbook has an audience beyond the agent, and a doc is where it stays reviewable |
| Personal preferences, local paths | `CLAUDE.local.md` (gitignored) |
| Code style & conventions Claude should follow | `CLAUDE.md` / `.claude/rules/` — state the convention ("2-space indent") and let the linter/formatter config keep enforcing it; two copies of one rule disagree on the day one is edited |
| Anything that must be *blocked* | a hook or `permissions.deny`, NOT memory (CLAUDE.md isn't enforced) |

## Conditional rules (`.claude/rules/`)

A rules file with a `paths` glob loads ONLY when Claude **reads** a matching file (it triggers on a read of the file, not on every tool use). A rules file with **no** `paths` loads unconditionally at launch, with the same priority as `.claude/CLAUDE.md`.

```yaml
---
paths:
  - "src/api/**/*.ts"
---
# API rules

- Validate every endpoint's input
- Use the standard error envelope
```

`paths` is a YAML **list** (each pattern a `- "glob"` item, quoted as the docs model); add more patterns as more list items. On a *skill*, `paths` also accepts a comma-separated string.

Rules are discovered **recursively**, so `rules/frontend/components.md` works; the directory also supports symlinks, which is how one shared rule set is linked into several projects.

Glob support (from the docs' own examples):

| Pattern | Matches |
|---|---|
| `**/*.ts` | all `.ts` anywhere |
| `src/**/*` | everything under `src/` |
| `*.md` | markdown in the project root only |
| `src/**/*.{ts,tsx}` | brace expansion, multiple extensions |

Two ways a glob silently matches nothing — both fail open, so the rule just never fires:

- **Brace-expansion budget.** A rule's whole `paths` list shares a budget of **1,000 expanded patterns and 4 MiB**. Each brace group multiplies: `{a,b}/{c,d}/*.{ts,tsx}` is 8 patterns. A pattern that would exceed the budget is used **unexpanded**, and its literal braces match no file.
- **Unbalanced `[`.** Glob reads `[` as the start of a bracket expression, so `photos [2024/**` is invalid and matches nothing (the rule's other patterns keep working). Escape it: `photos \[2024/**`.

This is the primary lever when memory grows — **for a repo driven by Claude Code alone.** Check the next section before reaching for it.

## AGENTS.md, and which lever is portable

[AGENTS.md](https://agents.md/) is an open format (OpenAI, Google, Cursor, Factory; 2025) read by Codex and ~20 other tools. Plain Markdown, no required sections. Two hard rules: the **nearest file in the directory tree wins**, and a user's prompt overrides the file.

**Claude Code reads `CLAUDE.md`, not `AGENTS.md`.** For a repo that already keeps `AGENTS.md`, make `CLAUDE.md` import it rather than maintaining two copies, then append anything Claude-specific below:

```markdown
@AGENTS.md

## Claude Code

Use plan mode for changes under `src/billing/`.
```

A symlink (`ln -s AGENTS.md CLAUDE.md`) works when there is nothing Claude-specific to add — but not on Windows without Administrator or Developer Mode, where the import is the portable choice. Either way, confirm with `/context` that `CLAUDE.md` shows under **Memory files**.

Two first-party importers exist and neither replaces the pointer above, because both copy once:
`/init` reads Cursor (`.cursor/rules/`, `.cursorrules`) and Copilot
(`.github/copilot-instructions.md`) rules into the CLAUDE.md it generates, and with
`CLAUDE_CODE_NEW_INIT=1` also `AGENTS.md`, `.devin/rules/`, `.windsurf/rules/`/`.windsurfrules` and
`.clinerules`; `/import` (v2.1.213+) appends a one-time copy of another agent's instruction files to
the matching CLAUDE.md and carries over its MCP servers, commands, subagents and skills. Use them to
seed a file, then keep `@AGENTS.md` as the live link — a one-time copy is the drift this skill warns
about everywhere else.

**`.claude/rules/` is Claude-only.** Codex does not read it. So moving rules out of `AGENTS.md` into `.claude/rules/` makes them invisible to every other agent on the repo — bridge it with a pointer section plus a skill under `.agents/skills/` (see below).

**Codex has no lazy loading at all, and nested `AGENTS.md` is not a substitute for `paths:`.** Codex builds its instruction chain **once per run, at startup**, walking from the project root down to `cwd` and appending each `AGENTS.md` it passes. Reading or editing a file in a subdirectory does **not** pull in that subdirectory's file. "Nearest wins" describes precedence — the closer file lands later in the combined prompt — not deferred loading. A nested file *below* `cwd` is never read. So nested `AGENTS.md` only works under an operational contract: every Codex session starts inside the package it is working on.

| Repo driven by | Lever |
|---|---|
| Claude Code only | `.claude/rules/*.md` with `paths:` — genuinely lazy, fires on a matching read |
| Claude Code **and** Codex | keep `.claude/rules/` for Claude, and bridge Codex: a pointer table in `AGENTS.md` naming rule → glob → purpose, plus a skill in `.agents/skills/` mapping work area → files to read. Advisory, not automatic — see the reliability note below |
| A package with a hard ownership boundary, and a launcher that controls `cwd` | nested `AGENTS.md` + one-line `CLAUDE.md` beside it |

**The bridge is weaker than the loader.** Claude's path rule fires on a matching
read; Codex must classify the task, invoke the skill, and follow its routing.
Keep critical prohibitions as short root invariants or static checks.

**Generate or parity-check the pointer table.** Hand-maintained copies of the
rule's `paths:`, the pointer table, and the skill router drift independently.

### Codex's project-instruction budget

`project_doc_max_bytes` limits project instruction entries across the environments selected for a run. The default is 32 KiB, but configuration can override it. Codex discovers project files from repository root to `cwd` and spends the budget in that order; user-level `~/.codex/AGENTS.md` is added separately and does not reduce it. If a project file exceeds the remaining budget, Codex truncates it and emits a tracing warning, which may not appear in the ordinary UI.

Do not reproduce that loader with a hard-coded subtraction or line count. Inspect the actual model-visible input with `codex debug prompt-input`; [audit.md](audit.md) gives the command and a project-chain diagnostic.

## Auto memory

Separate from CLAUDE.md: Claude can persist runtime learnings to `~/.claude/projects/<project>/memory/MEMORY.md`. The first **200 lines or 25 KB** (whichever first) load at session start; topic files load on demand. It is **machine-local** (shared by all worktrees of the repo, not synced across machines). Toggle via the `/memory` panel or the `autoMemoryEnabled` setting. It captures runtime learnings; CLAUDE.md captures intentional, committed instructions — keep them distinct.

## Imports

```markdown
@README.md
@docs/architecture.md
```

Relative paths resolve from the importing file. Imported files are expanded into context **at launch** (they don't save tokens — they move content, they don't defer it). Max recursion depth: **4 hops**. Keep references one level deep.

Import parsing **skips code spans and fenced blocks**, so to mention a path without importing it, wrap it in backticks: `` `@README` `` stays literal, bare `@README` imports.

**External imports need one-time approval.** An import in a *project* memory file whose path resolves outside the working directory — `@~/.claude/my-notes.md`, say — triggers an approval dialog the first time. **Decline once and the imports stay disabled with no further prompt**, which looks exactly like a file that silently does nothing. Imports in user-scope files (`~/.claude/CLAUDE.md`, `~/.claude/rules/`) load without the dialog — **except in Cowork sessions on the desktop**, which skip any user-scope import resolving outside the session's working directory, and skip a `~/.claude/CLAUDE.md` that is itself a symlink or a `~/.claude/rules/` link pointing outside it. So do not build a team-shared setup on an external import, and do not rely on a home-directory import as the only carrier of a rule: commit the content instead.

## Compaction

Project-root `CLAUDE.md` **survives `/compact`** — it is re-read from disk and re-injected. Nested CLAUDE.md files in subdirectories are **not** re-injected; they reload the next time Claude reads a file in that subdirectory.

So an instruction that vanished after compaction was either conversation-only (write it into CLAUDE.md to make it persist) or lives in a nested file that has not reloaded yet.

## When an instruction is ignored

CLAUDE.md is delivered as a **user message after the system prompt**, not as part of it — Claude reads it and tries to comply, but there is no strict-compliance guarantee. Debug in this order:

1. `/context` → **Memory files**. Missing there means Claude cannot see it; nothing else matters yet.
2. The `InstructionsLoaded` hook logs which instruction files loaded, when, and why — the tool for path-scoped rules and lazily-loaded subdirectory files that "should" have fired.
3. Look for a contradiction across CLAUDE.md, nested CLAUDE.md and `.claude/rules/`. Conflicting instructions get resolved arbitrarily; delete one.
4. Make it concrete. "Use 2-space indentation" beats "format code nicely".
5. Check the size. Past ~200 lines the docs' own diagnosis is that the rule is being lost in noise — run the audit, don't add emphasis.

Escalate by mechanism, not by emphasis — capital letters and "IMPORTANT" do not add enforcement, and emphasising many lines emphasises none:

- must happen at a fixed point in the lifecycle (before every commit, after each edit) → a **hook**
- must be blocked outright → **`permissions.deny`**
- must sit at system-prompt level → **`--append-system-prompt`** (passed every invocation, so it suits scripts rather than interactive use)

## Monorepo / large repos

- `claudeMdExcludes` (a setting, usually in `.claude/settings.local.json`) skips specific ancestor CLAUDE.md files by absolute path or glob.
- Subdirectory `CLAUDE.md` files load on demand — push package-specific instructions down into the package.
- Audit the ancestor chain, not one file: the workspace-root file loads for every child session.

## HTML comments

Block-level `<!-- ... -->` comments in CLAUDE.md are stripped before injection — use them for maintainer notes (review dates, rationale). Comments inside fenced code blocks are preserved.

## Workflows

**New project:** `/init` (set `CLAUDE_CODE_NEW_INIT=1` for the interactive multi-artifact flow) → trim what it generated to facts that apply to *every* task → push domain detail behind the right lever → keep CLAUDE.md well under 200 lines.

**Oversized file:** read and follow [audit.md](audit.md). Gather evidence before editing; do not call a judgement step mechanical or turn one repository's shape into a universal template.

**Several repos at once:** audit each repository against the tools that actually read it. Generic user preferences belong once at user scope; repository files carry only local facts and deviations.

## Quality checklist

- [ ] CLAUDE.md under 200 lines — counting ancestor files that load in the same session?
- [ ] Critical / always-on rules at the top?
- [ ] Nothing left that Claude can derive from the codebase itself (layout, dependency lists, architecture prose)?
- [ ] No multi-step procedures or single-area detail in always-on memory (→ skill, path-scoped rule, or `docs/how-to/`)?
- [ ] No chronicle — dates, measurements, incident narration — in always-on memory?
- [ ] Every stated constraint checked against the linter: enforced ones deleted, unenforced ones kept?
- [ ] Every list that has an owner elsewhere (env vars, versions, counts) replaced by a pointer?
- [ ] Lazy-loading lever matches who works in the repo (`.claude/rules/` vs nested `AGENTS.md`)?
- [ ] `paths:` frontmatter only on `.claude/rules/*.md` or a skill, never on CLAUDE.md?
- [ ] Every glob quoted, brace groups within budget, no unbalanced `[`?
- [ ] `@path/to/file` references instead of duplicated content — and no *external* import a teammate could decline into silence?
- [ ] Must-block rules in hooks/settings, not relying on always-on memory?
- [ ] No generic personal preference copied into every repository file?
- [ ] No conflicting scope or refactoring instructions across the loaded chain?
- [ ] **Verified with `/context` that the files actually loaded**, not just that they exist?
