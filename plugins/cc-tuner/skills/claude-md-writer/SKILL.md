---
name: claude-md-writer
description: Use when creating, refactoring, auditing, or trimming a CLAUDE.md / AGENTS.md / memory file, splitting project instructions into .claude/rules/, or deciding what belongs in CLAUDE.md vs rules vs skills vs hooks vs CLAUDE.local.md. Covers Claude Code memory — imports, path-scoped rules, auto memory, managed/user/project/local precedence — plus the AGENTS.md open format, the audit procedure for an oversized file, and what every authored instruction file must say about how to fix things.
---

# CLAUDE.md Writer

Create and refactor CLAUDE.md, AGENTS.md and `.claude/rules/` files. Every Claude Code memory *fact* here is checked against the source (<https://code.claude.com/docs/en/memory>); AGENTS.md facts against <https://agents.md/>; structuring patterns are labelled where they are convention, not doc. Deep examples, live-repo evidence and sources are in [reference.md](reference.md).

Two jobs, and they are different work:

- **Author** a file that does not exist yet, or add to one → the tables below.
- **Audit** a file that grew past its budget → the **Audit procedure**. Do not trim an oversized file line by line. Measure it, diagnose *why* it grew, and rebuild it. A file that got to 500 lines did so by a mechanism, and cutting the ten easiest lines leaves the mechanism running.

## Golden rules

| Rule | Why |
|---|---|
| **CLAUDE.md < 200 lines** | Loads into context at the start of every session — the only doc-published size target |
| **Critical / always-on rules first** | Earliest instructions get the most adherence |
| **Move task-specific or component-specific content out** | A multi-step procedure or one-area rule belongs in a skill or a path-scoped rule, not in always-on memory |
| **`paths:` frontmatter lives on `.claude/rules/*.md` and on skills — never on CLAUDE.md** | CLAUDE.md loads by directory hierarchy only. Both rules and skills take `paths` in the same glob format; a skill with `paths` is auto-loaded only for matching files |
| **Verify with `/context`, not by reading the file** | `/context` lists what actually loaded under **Memory files**. A file you can see on disk is not evidence it loaded |
| **Pointers over copies** | A pointer still resolves after the target changes; a pasted copy silently goes stale. Versions, env lists and counts are the usual offenders — they all have an authoritative owner already |
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

**`.claude/rules/` is Claude-only.** Codex does not read it. So moving rules out of `AGENTS.md` into `.claude/rules/` makes them invisible to every other agent on the repo — bridge it with a pointer section plus a skill under `.agents/skills/` (see below).

**Codex has no lazy loading at all, and nested `AGENTS.md` is not a substitute for `paths:`.** Codex builds its instruction chain **once per run, at startup**, walking from the project root down to `cwd` and appending each `AGENTS.md` it passes. Reading or editing a file in a subdirectory does **not** pull in that subdirectory's file. "Nearest wins" describes precedence — the closer file lands later in the combined prompt — not deferred loading. A nested file *below* `cwd` is never read. So nested `AGENTS.md` only works under an operational contract: every Codex session starts inside the package it is working on.

| Repo driven by | Lever |
|---|---|
| Claude Code only | `.claude/rules/*.md` with `paths:` — genuinely lazy, fires on a matching read |
| Claude Code **and** Codex | keep `.claude/rules/` for Claude, and bridge Codex: a pointer table in `AGENTS.md` naming rule → glob → purpose, plus a skill in `.agents/skills/` mapping work area → files to read. Advisory, not automatic — see the reliability note below |
| A package with a hard ownership boundary, and a launcher that controls `cwd` | nested `AGENTS.md` + one-line `CLAUDE.md` beside it |

**The bridge is one reliability class weaker than the loader, and that is not a rounding error.** Claude's path rule fires deterministically on a matching read. Codex must first judge the skill relevant, then invoke it, then classify every area the task touches, then read every matching file — four gates instead of zero. Measured failure modes: a task that looks self-evident ("rename this field"), a review-only prompt that pulls attention to the diff, scope widening mid-session after the skill already "ran", a task spanning several router rows where only the dominant one gets picked, a session started above the repo root (Codex scans skills from `cwd` upward only), and the skill simply not being present in that checkout. Put critical prohibitions as short invariants in the root file or behind a static check — do not rely on the bridge to deliver them.

**Keep the pointer table generated or parity-checked, not hand-maintained.** Three hand-written copies of one mapping — the rule's `paths:` frontmatter, the pointer table, the skill's routing table — drift. Measured on a live repo carrying exactly this pattern: one rule's frontmatter listed a glob the pointer omitted, the pointer listed a path the frontmatter did not have, and the skill routed that work area to a different file entirely. Three mismatches on one of eight rules.

### Codex's byte budget is a harder limit than the line target

Codex stops adding instruction files once their **combined** size reaches `project_doc_max_bytes` — **32 KiB by default**. The global `~/.codex/AGENTS.md` counts against the same budget. Past the cap, content is not summarised or warned about: it is simply never in the prompt.

This makes an oversized `AGENTS.md` a correctness bug, not a cost problem. Measured 2026-08-28: a 55,103-byte `AGENTS.md` against a 31,424-byte effective budget cut at line 252 of 536 — ten sections past the cut, including database-migration rules, PR conventions and the CI policy. They had been written, believed in force, and never once read by Codex.

Check it before anything else when Codex "ignores" an instruction:

```bash
G=$(wc -c < ~/.codex/AGENTS.md 2>/dev/null || echo 0)
head -c $((32768-G)) AGENTS.md | grep -c ''      # last line Codex sees
```

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

## Audit procedure

For a file that outgrew its budget. Steps 1–5 are mechanical: run them, don't estimate. Adapt the commands to the repo's tooling; the point is that each answer is measured, not recalled.

**1. Measure the whole budget, including ancestors.**

```bash
wc -l CLAUDE.md AGENTS.md ../CLAUDE.md ../AGENTS.md 2>/dev/null
head -3 .claude/rules/*.md          # a rule with no `paths:` counts as always-on
```

Confirm in a live session with `/context` → **Memory files**. Disk is not evidence.

**2. Split by section and look for the outlier.**

```bash
grep -n "^## " AGENTS.md | awk -F: 'NR>1{print prev" -> "($1-p)} {prev=$0;p=$1} END{print prev" -> to EOF"}'
```

A section over a quarter of the file is almost always a runbook that ended up in always-on memory.

**3. Find content that already has a path-scoped home.**

```bash
for id in <the identifiers the file names>; do
  echo "$id: $(grep -l "$id" CLAUDE.md AGENTS.md .claude/rules/*.md 2>/dev/null | tr '\n' ' ')"
done
```

An identifier in both columns is duplicated: the rule fires exactly when it is needed, the copy costs context in every session including the ones with no matching file open.

**4. Find copied lists by diffing them against their owner.** First establish the copy exists — locate the section that enumerates keys (`grep -n "^#\+ .*Environment" AGENTS.md`). No section, step passed. If there is one, extract from **that line range only**:

```bash
sed -n '<from>,<to>p' AGENTS.md | grep -oE '`[A-Z][A-Z0-9_]+`' | tr -d '`' | sort -u > /tmp/doc
grep -oE '^[A-Z][A-Z0-9_]+' .env.example | sort -u > /tmp/own
diff /tmp/own /tmp/doc
```

**Bound the range by hand.** Run over the whole file, this grep reports drift that isn't there: in a Python repo it collects module constants (`WIRE_URL`, `BATCH_ID_KEY`) and calls them missing env vars — measured 2026-08-28 on a file that had no env table at all and already pointed at its owner. A nonzero diff is a reason to look, not a verdict.

Real drift is an argument for deleting the copy and pointing at the owner, not for fixing the copy.

**5. Check what the tooling already catches.** For each constraint the file states, look for the lint/format/type rule that enforces it. Enforced → delete the line. **Not** enforced → that line is the file's highest-value content, and it is also the shortlist for a future hook.

**6. Label every remaining block with exactly one genre.**

| Genre | Sign | Destination |
|---|---|---|
| instruction | "do X", "never Y" | stays |
| procedure | more than two steps, needed occasionally | `docs/how-to/` or a skill |
| chronicle | a date, a measurement, "this cost us a day" | `docs/`, a comment beside the code, or the issue |
| copy | an owner exists elsewhere | delete, link to the owner |
| generic | true of any project | `~/.claude/CLAUDE.md`, once |
| duplicate | already in a path-scoped rule | delete |

Chronicle is the genre that hurts most and looks most valuable. The rationale is worth keeping — but no measurement changes the agent's next action, and counts go stale. Move it, don't delete it.

**7. Rebuild to the target shape** (below) rather than editing in place.

**8. Verify.** `wc -l` against the budget, `/context` for what loaded, `/doctor` for a second opinion on a checked-in file — its trim check cuts what Claude can derive from the codebase and keeps pitfalls, rationale and non-default conventions. The real check is behavioural: a week of work without the lines you cut. If nothing regressed, they were decoration.

## Target shape

Order matters: earliest instructions get the most adherence, so the hard prohibitions come before attention runs out.

```markdown
# <Repo> — agent guide

One line on what this is. Then: this file is the single source of agent rules;
area rules live in <lever>; procedures in docs/how-to/. Do not copy versions,
env lists or counts here — copies go stale.

## Start          5-8 lines: package manager, install, dev
## Gate           the pre-merge commands; a table of change-kind -> extra command
## Never          hard prohibitions, grouped (code / data / CI / git), each with its consequence
## How to fix     see below — mandatory
## Branches       branch naming, commit format, merge strategy
## Where to look  a table of area -> rule file / skill / runbook
```

### The `How to fix` section is mandatory

Every authored CLAUDE.md / AGENTS.md gets it. Without it an agent optimises for the smallest diff that makes the symptom go away, and the codebase accumulates special cases — the failure this section exists to prevent. Write it into the file, in the file's language:

```markdown
## How to fix

- Fix the cause, not the symptom. Name the failing mechanism before editing.
  If you cannot name it, you have not found it yet.
- A special case layered on shared infrastructure means the fix is not deep enough.
  Generalising the mechanism beats adding another branch.
- Refactoring for cleanliness is expected, not risky. If the fix leaves duplication,
  dead code, or a shape the next change has to work around, finish it now.
- Scope it: refactor within the blast radius of the fix — the code the change touches
  and what it forced out of shape. Not the rest of the file.
- Say so. The PR names, in one line, what was touched beyond the minimum and why.
```

The last two bullets are load-bearing. "Do not fear refactoring" without a stated radius and a stated disclosure turns into unreviewable diffs, which is how the opposite rule ("touch only what you must") got written in the first place. Keep all five or the section trades one failure for another.

If the repo already carries a "surgical changes / touch only what you must" rule, this **replaces** it — do not ship both. Two rules that contradict get resolved arbitrarily, and the docs say so explicitly.

## Workflows

**New project:** `/init` (set `CLAUDE_CODE_NEW_INIT=1` for the interactive multi-artifact flow) → trim what it generated to facts that apply to *every* task → push domain detail behind the right lever → add the `How to fix` section → keep CLAUDE.md well under 200 lines.

**Oversized file:** run the **Audit procedure**. Do not start editing before step 5 — the mechanical steps decide most of the cuts, and a file trimmed by intuition regrows.

**Several repos at once:** the mechanical steps port unchanged; the target shape does not. Repos differ in which lever is available (rules vs nested AGENTS.md), whether path-scoped rules already exist, and which tools read the file. Audit each, rebuild each. What *does* generalise is a rule copied into every repo's file — an org-wide CI policy, house coding guidelines — which belongs in one owner document with pointers, or at user scope.

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
- [ ] **`How to fix` section present, with all five bullets** — cause, generalise, refactor, radius, disclose?
- [ ] No surviving "touch only what you must" rule contradicting it?
- [ ] **Verified with `/context` that the files actually loaded**, not just that they exist?
