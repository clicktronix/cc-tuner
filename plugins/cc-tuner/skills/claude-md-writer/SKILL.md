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
| **`paths:` frontmatter lives on `.claude/rules/*.md` and on skills — never on CLAUDE.md** | CLAUDE.md loads by directory hierarchy only. Both rules and skills take `paths` in the same glob format; a skill with `paths` is auto-loaded only for matching files |
| **Verify with `/context`, not by reading the file** | `/context` lists what actually loaded under **Memory files**. A file you can see on disk is not evidence it loaded |
| **Pointers over copies** | Reference files (`@path/to/file`, route maps): a pointer still resolves after the target changes, a pasted copy silently goes stale |
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
| Multi-step procedure / workflow | a skill (`.claude/skills/<name>/SKILL.md`) — custom commands are now the same mechanism, so `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both give you `/deploy` |
| Detail needed only for one area, but as a *procedure* | a skill with `paths` — loads on demand AND only for matching files, cheaper than a rule |
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

This is the primary lever when memory grows: move detail into path-scoped rules so it loads only for the relevant files instead of bloating always-on CLAUDE.md.

## Auto memory

Separate from CLAUDE.md: Claude can persist runtime learnings to `~/.claude/projects/<project>/memory/MEMORY.md`. The first **200 lines or 25 KB** (whichever first) load at session start; topic files load on demand. It is **machine-local** (shared by all worktrees of the repo, not synced across machines). Toggle via the `/memory` panel or the `autoMemoryEnabled` setting. It captures runtime learnings; CLAUDE.md captures intentional, committed instructions — keep them distinct.

## Imports

```markdown
@README.md
@docs/architecture.md
```

Relative paths resolve from the importing file. Imported files are expanded into context **at launch** (they don't save tokens — they move content, they don't defer it). Max recursion depth: **4 hops**. Keep references one level deep.

Import parsing **skips code spans and fenced blocks**, so to mention a path without importing it, wrap it in backticks: `` `@README` `` stays literal, bare `@README` imports.

**External imports need one-time approval.** An import in a *project* memory file whose path resolves outside the working directory — `@~/.claude/my-notes.md`, say — triggers an approval dialog the first time. **Decline once and the imports stay disabled with no further prompt**, which looks exactly like a file that silently does nothing. Imports in user-scope files (`~/.claude/CLAUDE.md`, `~/.claude/rules/`) load without the dialog. So do not build a team-shared setup on an external import; commit the content instead.

## AGENTS.md

**Claude Code reads `CLAUDE.md`, not `AGENTS.md`.** For a repo that already keeps `AGENTS.md` for other agents, make `CLAUDE.md` import it rather than maintaining two copies, then append anything Claude-specific below:

```markdown
@AGENTS.md

## Claude Code

Use plan mode for changes under `src/billing/`.
```

A symlink (`ln -s AGENTS.md CLAUDE.md`) works when there is nothing Claude-specific to add — but not on Windows without Administrator or Developer Mode, where the import is the portable choice. Either way, confirm with `/context` that `CLAUDE.md` shows under **Memory files**.

## Compaction

Project-root `CLAUDE.md` **survives `/compact`** — it is re-read from disk and re-injected. Nested CLAUDE.md files in subdirectories are **not** re-injected; they reload the next time Claude reads a file in that subdirectory.

So an instruction that vanished after compaction was either conversation-only (write it into CLAUDE.md to make it persist) or lives in a nested file that has not reloaded yet.

## When an instruction is ignored

CLAUDE.md is delivered as a **user message after the system prompt**, not as part of it — Claude reads it and tries to comply, but there is no strict-compliance guarantee. Debug in this order:

1. `/context` → **Memory files**. Missing there means Claude cannot see it; nothing else matters yet.
2. The `InstructionsLoaded` hook logs which instruction files loaded, when, and why — the tool for path-scoped rules and lazily-loaded subdirectory files that "should" have fired.
3. Look for a contradiction across CLAUDE.md, nested CLAUDE.md and `.claude/rules/`. Conflicting instructions get resolved arbitrarily; delete one.
4. Make it concrete. "Use 2-space indentation" beats "format code nicely".

Escalate by mechanism, not by emphasis — capital letters and "IMPORTANT" do not add enforcement:

- must happen at a fixed point in the lifecycle (before every commit, after each edit) → a **hook**
- must be blocked outright → **`permissions.deny`**
- must sit at system-prompt level → **`--append-system-prompt`** (passed every invocation, so it suits scripts rather than interactive use)

## Monorepo / large repos

- `claudeMdExcludes` (a setting, usually in `.claude/settings.local.json`) skips specific ancestor CLAUDE.md files by absolute path or glob.
- Subdirectory `CLAUDE.md` files load on demand — push package-specific instructions down into the package.

## HTML comments

Block-level `<!-- ... -->` comments in CLAUDE.md are stripped before injection — use them for maintainer notes (review dates, rationale). Comments inside fenced code blocks are preserved.

## Workflows

**New project:** `/init` (set `CLAUDE_CODE_NEW_INIT=1` for the interactive multi-artifact flow) → trim what it generated to facts that apply to *every* task → push domain detail into `.claude/rules/` → keep CLAUDE.md well under 200 lines.

**Refactor an oversized CLAUDE.md:** run `/doctor` first — its checkup proposes trims for a checked-in CLAUDE.md, cutting what Claude can **derive from the codebase** (directory layouts, dependency lists, architecture overviews) and keeping pitfalls, rationale, and conventions that differ from tool defaults. That derivable-vs-not split is the sharpest test there is for whether a line earns its context, so apply it by hand to anything `/doctor` leaves behind. Then extract task/domain-specific content (SQL, deploy, debugging, API) into `.claude/rules/<domain>.md`, path-scoped where it maps to a directory, or into a skill when it is a procedure. Replace duplicated content with `@`-references — remembering that imports do not reduce context, they only reorganise it.

## Quality checklist

- [ ] CLAUDE.md under 200 lines?
- [ ] Critical / always-on rules at the top?
- [ ] Nothing left that Claude can derive from the codebase itself (layout, dependency lists, architecture prose)?
- [ ] No multi-step procedures or single-area detail in always-on memory (→ skill or path-scoped rule)?
- [ ] `paths:` frontmatter only on `.claude/rules/*.md` or a skill, never on CLAUDE.md?
- [ ] Every glob quoted, brace groups within budget, no unbalanced `[`?
- [ ] `@path/to/file` references instead of duplicated content — and no *external* import a teammate could decline into silence?
- [ ] Must-block rules in hooks/settings, not relying on always-on memory?
- [ ] No stale code snippets pasted into memory?
- [ ] **Verified with `/context` that the files actually loaded**, not just that they exist?
