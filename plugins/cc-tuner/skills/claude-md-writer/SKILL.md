---
name: claude-md-writer
description: Use when creating, refactoring, auditing, or trimming a CLAUDE.md / AGENTS.md / memory file, splitting project instructions into .claude/rules/, or deciding what belongs in CLAUDE.md vs rules vs skills vs hooks vs CLAUDE.local.md. Covers Claude Code memory, the AGENTS.md open format, and a measured audit route for oversized instruction files.
---

# Instruction files

Write the repository's non-obvious conventions once, where the clients that work here will read
or reach them. Preserve scope, authorization and existing manual edits.

- **Author or extend:** use the sections below in order.
- **Audit existing instructions:** follow [audit.md](audit.md), measuring the actual loaded chain
  before rebuilding. A line count alone does not identify what should be deleted.
- **Loader/configuration detail:** consult the relevant section of [reference.md](reference.md)
  and current official documentation when the proposed change depends on that behavior.

## Golden rule

**Every line must change behaviour.** Test each one with the docs' own question: *would removing
this cause Claude to make mistakes?* If a linter already catches it, or Claude already does it
right, the line is a no-op that costs context in every session. A conflict between instructions is
fixed at its source by deleting one side, never by emphasis or load order. For the wording of a line — pointers,
no-ops, negation, pruning — invoke `mattpocock-skills:writing-for-agents` when it is installed; this
skill decides where a line lives and which client loads it.

## Establish the readers and canonical owner

Read existing root/nested instructions, imports, rule indexes and applicable settings. Determine
which clients and versions actually use the repository. Keep one canonical owner for shared rules;
use a pointer for conditional detail. An existing `AGENTS.md` can remain that owner.

Claude Code's built-in `agents-md` mod loads `AGENTS.md` by default only where no CLAUDE file sits
in the working directory or any directory above it, so a repository that has a CLAUDE file still needs
`@AGENTS.md` in it. Confirm the mode and `/context` before adding or removing a bridge; an existing
import can stay. Modes and exceptions: [reference.md](reference.md#native-agentsmd-selection).

AGENTS.md is an open format: plain Markdown, the nearest file in the directory tree wins, and the
user's prompt overrides the file ([reference.md](reference.md#the-agentsmd-open-format)).

Codex builds its instruction chain once at startup and has no lazy loading, so a rule moved into
`.claude/rules/` is invisible to it. Keep short shared invariants in the canonical root file and bridge
conditional detail as in [reference.md](reference.md#lazy-loading-by-client).

Keep the agent-rules discovery block (the `<!-- agent-rules:begin -->` marker in root
`AGENTS.override.md` when that file is non-empty, otherwise in root `AGENTS.md`) byte for byte, first
in the file. It already routes explicit rule reads, so do not generate a per-repository skill or a pointer table
beside it. Without it, prefer setup's canonical discovery block to a second custom router.

## What goes where

| Needed when | Owner |
|---|---|
| Every task, across clients | Short shared invariants in the canonical root file |
| Working in one area | Scoped rule or nested instructions supported by the actual clients |
| Performing a procedure | A skill; supporting references for conditional details |
| A human operates the system | Existing runbook in `docs/` or the repository's equivalent |
| Enforcing a mechanical condition | Existing linter, test, settings or lifecycle hook |
| A personal preference applies everywhere | User-level instructions, once |

### Conditional rules (`.claude/rules/`)

For a constraint needed when Claude reads a matching file, use a scoped rule, for example:

```markdown
---
paths:
  - "src/api/**/*.ts"
---
Validate endpoint input and use the repository's standard error envelope.
```

`paths` belongs on the rule, not on `CLAUDE.md`. Use the repository's real paths and retain
the explicit discovery route for other clients. Loader edge cases (glob budget, unbalanced `[`,
imports, compaction, monorepo excludes) are in [reference.md](reference.md#loader-facts).

Keep critical constraints first. The official Claude target of fewer than 200 lines is a guideline,
not a reason to remove a necessary rule. `@path` imports organize content but load it eagerly;
use ordinary Markdown pointers for material that should be read only when relevant.

State concrete decisions and the action that replaces a known failure. Keep config values, command
lists and architecture inventories with their executable owner. Retain rationale that changes a
choice; move incident narration and historical measurements out of always-loaded instructions.

## Verify the proposed result

Show the diff and explain moved or deleted obligations. For an authorized reorganization, do not
ask again solely because the file is an instruction file. Ask only for an unresolved choice that
settles competing requirements or exceeds the user's scope.

When an instruction is ignored, debug in the order given in [reference.md](reference.md#when-an-instruction-is-ignored).
Check links, rule glob coverage, canonical ownership, and preservation of critical constraints.
For Claude, `/context` shows what actually loaded. For Codex, inspect `codex debug prompt-input`
when available; [audit.md](audit.md) includes the diagnostic and project-budget caveats. Report
unavailable runtime verification as unavailable. File existence or an owner's re-read is not proof
of automatic instruction loading.

## Quality checklist

Before reporting done, confirm each.

- [ ] CLAUDE.md is under 200 lines, counting ancestor files that load in the same session; critical rules come first.
- [ ] Every line passes the golden-rule test; nothing Claude can derive from the codebase itself.
- [ ] Every constraint checked against the linter and formatter: enforced ones deleted, unenforced ones kept.
- [ ] Always-on memory holds no procedure, single-area detail or chronicle (dates, incidents, measurements).
- [ ] Lists owned elsewhere (env vars, versions, counts) are pointers, not copies.
- [ ] No `@path` import a teammate could decline into silence (an external import needs one-time approval).
- [ ] `paths:` only on `.claude/rules/*.md` or a skill; globs quoted, braces within budget, no unbalanced `[`.
- [ ] Must-block rules sit in hooks or settings, and the loaded chain has no conflicting instructions.
- [ ] The lazy-loading lever matches who works in the repo (`.claude/rules/` vs nested `AGENTS.md`).
- [ ] Verified with `/context` that the files loaded, not only that they exist.
