---
name: claude-md-writer
description: Use when creating, refactoring, auditing, or trimming a CLAUDE.md / memory file, splitting project instructions into .claude/rules/, or deciding what belongs in CLAUDE.md vs rules vs CLAUDE.local.md vs tool config. Covers Claude Code memory — imports, path-scoped rules, auto memory, and managed/user/project/local precedence.
---

# CLAUDE.md Writer

Create and refactor CLAUDE.md and `.claude/rules/` files for Claude Code, following the official memory docs. Every Claude Code memory *fact* here is checked against the source (<https://code.claude.com/docs/en/memory>); structuring patterns are labelled where they are convention, not doc. Deep examples and sources are in [reference.md](reference.md).

## Golden rules

| Rule | Why |
|---|---|
| **CLAUDE.md < 200 lines** | Loads into context at the start of every session — the only doc-published size target |
| **Critical / always-on rules first** | Earliest instructions get the most adherence |
| **Move task-specific or component-specific content out** | A multi-step procedure or one-area rule belongs in a skill or a path-scoped rule, not in always-on memory |
| **`paths:` frontmatter lives on `.claude/rules/*.md` — never on CLAUDE.md** | CLAUDE.md loads by directory hierarchy only; only rules files support conditional loading |
| **Pointers over copies** | Reference files (`@path/to/file`, route maps); don't paste content that will go stale |
| **Hard enforcement → hooks/settings, not memory** | CLAUDE.md *guides*, it doesn't enforce. Conventions — incl. code style ("use 2-space indent") — are valid CLAUDE.md content per the docs; just don't re-paste what a linter/formatter config already enforces, and use a hook / `permissions.deny` for anything that must be *blocked* |

## Memory load order

Loaded broadest → most specific and **concatenated, not overriding** — a more-specific file is read *later* (so it's freshest), but the docs are explicit that if two instructions conflict Claude may pick one arbitrarily. The fix for a conflict is to remove it, not to rely on precedence. These are layers, not size tiers:

| Layer | Location |
|---|---|
| Managed policy | macOS `/Library/Application Support/ClaudeCode/CLAUDE.md` · Linux/WSL `/etc/claude-code/CLAUDE.md` · Windows `C:\Program Files\ClaudeCode\CLAUDE.md` |
| User | `~/.claude/CLAUDE.md` (every project on this machine) |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` (shared, committed) |
| Local | `./CLAUDE.local.md` (gitignored personal notes — read last at its level) |

Two **separate mechanisms**, not precedence layers:
- **`.claude/rules/*.md`** — conditional includes (see below). User-level `~/.claude/rules/` also load (before project rules).
- **Subdirectory `CLAUDE.md`** — loaded on demand when Claude reads files in that directory, not at launch.

## What goes where

| Content | Location |
|---|---|
| Project one-liner, layout, always-do rules, build/test commands | `CLAUDE.md` |
| Critical constraints | `CLAUDE.md`, at the top |
| Domain detail (DB schema, API patterns, deploy steps) | `.claude/rules/<domain>.md` |
| Multi-step procedure / workflow | a skill (`.claude/skills/<name>/SKILL.md`) |
| Personal preferences, local paths | `CLAUDE.local.md` (gitignored) |
| Code style & conventions Claude should follow | `CLAUDE.md` / `.claude/rules/` — fine to state ("2-space indent"); don't re-paste the linter/formatter config that enforces it |
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

`paths` is a YAML **list** (each pattern a `- "glob"` item, quoted as the docs model); add more patterns as more list items.

Glob support (from the docs' own examples):

| Pattern | Matches |
|---|---|
| `**/*.ts` | all `.ts` anywhere |
| `src/**/*` | everything under `src/` |
| `src/**/*.{ts,tsx}` | brace expansion, multiple extensions |

This is the primary lever when memory grows: move detail into path-scoped rules so it loads only for the relevant files instead of bloating always-on CLAUDE.md.

## Auto memory

Separate from CLAUDE.md: Claude can persist runtime learnings to `~/.claude/projects/<project>/memory/MEMORY.md`. The first **200 lines or 25 KB** (whichever first) load at session start; topic files load on demand. It is **machine-local** (shared by all worktrees of the repo, not synced across machines). Toggle via the `/memory` panel or the `autoMemoryEnabled` setting. It captures runtime learnings; CLAUDE.md captures intentional, committed instructions — keep them distinct.

## Imports

```markdown
@README.md
@docs/architecture.md
@AGENTS.md          # if you also run other agents off a shared baseline
```

Relative paths resolve from the importing file. Imported files are expanded into context **at launch** (they don't save tokens — they move content, they don't defer it). Max recursion depth: **4 hops**. Keep references one level deep.

## Monorepo / large repos

- `claudeMdExcludes` (a setting, usually in `.claude/settings.local.json`) skips specific ancestor CLAUDE.md files by absolute path or glob.
- Subdirectory `CLAUDE.md` files load on demand — push package-specific instructions down into the package.

## HTML comments

Block-level `<!-- ... -->` comments in CLAUDE.md are stripped before injection — use them for maintainer notes (review dates, rationale). Comments inside fenced code blocks are preserved.

## Workflows

**New project:** `/init` (set `CLAUDE_CODE_NEW_INIT=1` for the interactive multi-artifact flow) → trim what it generated to facts that apply to *every* task → push domain detail into `.claude/rules/` → keep CLAUDE.md well under 200 lines.

**Refactor an oversized CLAUDE.md:** count lines; if it's pushing past ~200, split. Extract task/domain-specific content (SQL, deploy, debugging, API) into `.claude/rules/<domain>.md` (path-scoped where it maps to a directory). Replace duplicated content with `@`-references. Leave only what applies to every task.

## Quality checklist

- [ ] CLAUDE.md under 200 lines?
- [ ] Critical / always-on rules at the top?
- [ ] No multi-step procedures or single-area detail in always-on memory (→ skill or path-scoped rule)?
- [ ] `paths:` frontmatter only on `.claude/rules/*.md`, never on CLAUDE.md?
- [ ] `@path/to/file` references instead of duplicated content?
- [ ] Must-block rules in hooks/settings, not relying on always-on memory?
- [ ] No stale code snippets pasted into memory?
