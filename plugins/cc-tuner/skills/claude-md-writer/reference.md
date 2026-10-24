# CLAUDE.md Writer — reference

Extended detail for the `claude-md-writer` skill. Claude Code memory facts trace to the official memory docs (<https://code.claude.com/docs/en/memory>); the structuring patterns are convention and are labelled as such.

## Contents

- [Native AGENTS.md selection](#native-agentsmd-selection)
- [Layered documentation structure](#layered-documentation-structure)
- [Loader facts](#loader-facts)
- [Lazy loading by client](#lazy-loading-by-client)
- [When an instruction is ignored](#when-an-instruction-is-ignored)
- [The AGENTS.md open format](#the-agentsmd-open-format)
- [Common mistakes](#common-mistakes)
- [Path-scoped rule behaviour](#path-scoped-rule-behaviour-the-non-obvious-parts)
- [CLAUDE.local.md](#claudelocalmd)
- [Commands and toggles](#commands--toggles)
- [Auto-memory index limits](#auto-memory-index-limits-the-part-that-bites)
- [Sources](#sources)

## Native AGENTS.md selection

Claude Code ships a built-in `agents-md` mod. Its `instructionFiles` option is the `/config` row
"Project instructions":

- `claude-md-or-agents-md` (default): `AGENTS.md` and `.claude/AGENTS.md` are loaded only when no
  `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` exists in the working directory or any
  directory above it, including directories above the repository: a workspace container's
  `CLAUDE.md` switches the load off for every repository inside it (probed with 2.1.306). Managed,
  user-global (`~/.claude/CLAUDE.md`) and `.claude/rules` files do not count. A `Read` under a subdirectory attaches that directory's `AGENTS.md` unless a
  CLAUDE file of the same directory claims it.
- `claude-md-and-agents-md`: every `AGENTS.md` loads beside the CLAUDE files; a file a `CLAUDE.md`
  already `@`-imports or links to is not loaded a second time.
- `claude-md`: CLAUDE files only. `managed-only`: only the organization's managed file and memory.

The option is read from user, managed or `--settings` files, not from a project's
`.claude/settings.json`. Turning the mod off in `/plugin` also restores CLAUDE-only loading. The native
reader ignores `AGENTS.override.md`, `AGENTS.local.md` and `.agents/`, does not cover `--add-dir`
directories, and `/memory` does not list its files, so it is not identical to Codex's loader. Confirm
with `/config` and `/context`; an existing `@AGENTS.md` import can stay. Do not change user-global
reader settings during a repository audit. Current rules:
<https://code.claude.com/docs/en/memory#agentsmd>.

## Layered documentation structure

A practical layout for a larger project — always-on stays tiny, detail loads conditionally:

```
CLAUDE.md                     # always loaded — keep < 200 lines
.claude/
└── rules/
    ├── database.md           # no paths: → always loaded (small, cross-cutting)
    ├── api.md                # paths: ["src/api/**/*.ts"]
    └── frontend/
        ├── components.md     # paths: ["src/**/*.tsx"]
        └── tokens.md         # paths: ["**/*.{css,ts,tsx}"]
packages/worker/CLAUDE.md     # subdirectory CLAUDE.md — loads on demand
```

- `CLAUDE.md` = facts true for *every* task: one-liner, layout, build/test commands, always-do rules.
- `.claude/rules/*.md` = domain detail. Add `paths` to scope it to the files it concerns; omit `paths` only for small, genuinely cross-cutting rules (the file still loads every session, so keep those few).
- Subdirectory `CLAUDE.md` = package-local instructions; not loaded until Claude touches that directory.

## Loader facts

- **Order.** Managed policy, then user (`~/.claude/CLAUDE.md`), then project (`./CLAUDE.md` or
  `./.claude/CLAUDE.md`), then `./CLAUDE.local.md`. Layers are concatenated, not overriding: a later
  file is read later, and conflicting instructions are resolved arbitrarily, so remove the conflict.
  Managed policy lives in `/Library/Application Support/ClaudeCode/CLAUDE.md` (macOS),
  `/etc/claude-code/CLAUDE.md` (Linux/WSL), `C:\Program Files\ClaudeCode\CLAUDE.md` (Windows).
- **Ancestors and subdirectories.** CLAUDE.md files in ancestor directories load too, so a monorepo
  child session also pays for the workspace-root file; audit the whole chain. A subdirectory
  `CLAUDE.md` loads on demand when Claude reads a file there. `~/.claude/rules/` loads before project rules.
- **Rule globs fail open.** A rule's `paths` list shares a budget of 1,000 expanded patterns and 4 MiB;
  each brace group multiplies (`{a,b}/{c,d}/*.{ts,tsx}` is 8), and a pattern over the budget is used
  unexpanded, so its literal braces match nothing. An unbalanced `[` (`photos [2024/**`) is invalid and
  matches nothing; escape it as `photos \[2024/**`. Rules are discovered recursively and a rule with
  no `paths` loads at launch. On a skill, `paths` also accepts a comma-separated string.
- **Imports.** `@path` resolves relative to the importing file and expands at launch, so it moves
  content without deferring it; the depth limit is 4 hops. Code spans and fenced blocks are not
  parsed, so `` `@README` `` stays literal. An import outside the working directory in a project file
  needs a one-time approval; declining leaves it silently disabled. Commit the content instead of
  relying on a home-directory import.
- **Compaction.** The project-root CLAUDE.md is re-read after `/compact`; nested CLAUDE.md files
  reload on the next read in their directory. An instruction that vanished was conversation-only or
  sits in a nested file that has not reloaded.
- **Auto memory** is separate: the first 200 lines or 25 KB of `MEMORY.md` load at start, topic files on
  demand, machine-local. CLAUDE.md is the intentional, committed layer.
- **Monorepo.** `claudeMdExcludes` skips ancestor CLAUDE.md files by path or glob; push
  package-specific instructions down into the package.
- **HTML comments.** Block-level `<!-- -->` comments are stripped before injection (use them for
  maintainer notes); comments inside fenced code are kept.
- **Seeding.** `/init` (with `CLAUDE_CODE_NEW_INIT=1` it also reads `AGENTS.md`, `.devin/rules/`,
  `.windsurf/rules/`, `.clinerules`) and `/import` copy another agent's files once. Seed with them,
  then keep `@AGENTS.md` as the live link. A symlink `CLAUDE.md` -> `AGENTS.md` works when nothing
  Claude-specific is needed, except on Windows without Administrator or Developer Mode.

## The AGENTS.md open format

[AGENTS.md](https://agents.md/) is an open format read by Codex and about twenty other tools: plain
Markdown, no required sections. Two hard rules: the nearest file in the directory tree wins, and the
user's prompt overrides the file. Claude Code's own loading is in [Native AGENTS.md
selection](#native-agentsmd-selection).

## Lazy loading by client

Codex builds its chain once per run, walking from the project root to `cwd` and appending each
`AGENTS.md` it passes. Reading a file in a subdirectory does not load that directory's file, and a
file below `cwd` is never read. "Nearest wins" is precedence, not deferred loading.

| Repo driven by | Lever |
|---|---|
| Claude Code only | `.claude/rules/*.md` with `paths:`; genuinely lazy, fires on a matching read |
| Claude Code and Codex, `agent-rules` block installed | keep `.claude/rules/` for Claude; the block and the plugin's `agent-rules` skill route Codex. Add nothing per repository |
| Claude Code and Codex, no block | keep `.claude/rules/`, and bridge Codex with a pointer table in `AGENTS.md` (rule, glob, purpose) plus a skill in `.agents/skills/` mapping area to files. Advisory, not automatic; prefer installing the block |
| A package with a hard ownership boundary and a launcher that controls `cwd` | nested `AGENTS.md` plus a one-line `CLAUDE.md` beside it |

The bridge is weaker than the loader: Codex must classify the task and follow the routing. Keep
critical prohibitions as short root invariants or static checks. Keep explicit routes consistent with
their rules ([audit.md](audit.md#5b-check-a-rule-against-its-own-paths)).

## When an instruction is ignored

CLAUDE.md arrives as a user message after the system prompt, with no strict-compliance guarantee.
In order:

1. `/context` -> **Memory files**. If it is missing there, nothing else matters yet.
2. The `InstructionsLoaded` hook logs which CLAUDE files and rules loaded and why.
3. Look for a contradiction across CLAUDE.md, nested files and `.claude/rules/`; delete one side.
4. Make it concrete: "use 2-space indentation" beats "format code nicely".
5. Check size: past about 200 lines the rule is lost in noise; run the audit, do not add emphasis.

Escalate by mechanism, not emphasis: a fixed lifecycle point -> a hook; blocked outright ->
`permissions.deny`; system-prompt level -> `--append-system-prompt` (every invocation, so suited to scripts).

## Common mistakes

| Mistake | Fix |
|---|---|
| `paths:` frontmatter on CLAUDE.md | Not supported — CLAUDE.md loads by hierarchy. Use a `.claude/rules/` file for conditional loading |
| Multi-step procedure in CLAUDE.md | → a skill (`.claude/skills/<name>/SKILL.md`). Custom commands are the same mechanism now — `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both produce `/deploy`; the skill form adds a directory for supporting files and frontmatter |
| Assuming a file loaded because it exists on disk | `/context` → **Memory files** is the check. `/memory` lists locations, including files that don't exist yet, so it cannot answer this |
| Keeping layout / dependency lists / architecture prose in CLAUDE.md | Claude derives these from the codebase. `/doctor`'s trim check cuts exactly this class and keeps pitfalls, rationale and non-default conventions |
| Re-pasting an enforceable linter/formatter config into prose | Keep the config in its tool file; in CLAUDE.md state only the convention to follow ("2-space indent" is a fine CLAUDE.md line — a copy of `.eslintrc` isn't) |
| Relying on CLAUDE.md to *block* an action | CLAUDE.md isn't enforced — use a hook or `permissions.deny` for hard blocks |
| Only negative rules ("don't X") | Pair with the alternative ("don't X; do Y") |
| A 40-line "how to add a feature" tutorial with an invented entity | The docs list long explanations and tutorials as excluded. Name a real module instead: `see src/.../campaigns/` |

## Path-scoped rule behaviour (the non-obvious parts)

- **Trigger is a READ of a matching file** — the docs say path-scoped rules trigger when Claude *reads* a file matching the glob, "not on every tool use". A merely planned write doesn't pull the rule in; Claude actually reading the file does.
- **User-level rules load too.** `~/.claude/rules/*.md` apply to every project on the machine and load *before* project rules — the docs frame this as giving project rules "higher priority", but since memory is concatenated, the safe move is to not let user and project rules contradict in the first place.
- **Quote your globs.** A leading `*` or `{` is unsafe unquoted in YAML, and the docs quote every `paths` example.
- **Rules-file size:** the docs publish a size target only for CLAUDE.md (< 200 lines), none for `.claude/rules/*.md`.
- **Symlinks work**, both for a whole directory and a single file (`ln -s ~/company-standards/security.md .claude/rules/security.md`); circular symlinks are detected. Path matching also works when a file is reached through a symlinked path into the project.
- **Rules vs skill for scoped content.** A `paths`-scoped *rule* still enters context on any read of a matching file. A `paths`-scoped *skill* loads only when Claude judges it relevant AND a matching file is in play — cheaper, but less certain to fire. Use a rule for a constraint that must always be present when touching those files, a skill for a procedure.

## CLAUDE.local.md

Personal, gitignored notes — appended after `CLAUDE.md` at the project root, so they're the last memory Claude reads at that level. Keep them free of conflicts with `CLAUDE.md` rather than relying on "later wins":

```markdown
# Local overrides

- Prefer verbose test output
- Worktrees live in .trees/
- Skip the slow integration suite locally
```

## Commands & toggles

| Thing | Effect |
|---|---|
| `/init` | Generate a starting CLAUDE.md from the codebase |
| `CLAUDE_CODE_NEW_INIT=1` | Make `/init` an interactive multi-phase flow (asks which of CLAUDE.md / skills / hooks to set up) |
| `/context` | **The only way to see what actually loaded** — the **Memory files** list. Use this to confirm a file is in context |
| `/memory` | Lists memory file *locations* across user and project scope — including entries for files that **do not exist yet**, which it creates when selected. Opens files for editing and toggles auto memory. It is a browser, **not** proof of loading; that's `/context` |
| `/doctor` | Checkup that proposes trims for a checked-in CLAUDE.md: cuts codebase-derivable content, keeps pitfalls, rationale and non-default conventions |
| `InstructionsLoaded` hook | Logs which instruction files and rules loaded, and why. Not verified for the `AGENTS.md` files the built-in `agents-md` mod adds; use `/context` for those |
| `autoMemoryEnabled` (setting) | Turn the auto-memory `MEMORY.md` system on/off. Set it in a project's settings to disable for that project only |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (env) | Disable auto memory via environment variable |
| `autoMemoryDirectory` (setting) | Relocate the auto-memory directory. Absolute or `~/`-prefixed. Read from any settings scope, but a project-scope value is honoured only after the workspace trust dialog — the same gate as hooks |
| `claudeMdExcludes` (setting, recommended in `.claude/settings.local.json`; arrays merge across layers) | Skip specific ancestor CLAUDE.md files by absolute path or glob. **Managed-policy CLAUDE.md cannot be excluded** |
| `claudeMd` (managed/policy settings only) | Put managed CLAUDE.md content inline in `managed-settings.json` instead of shipping a file. No effect in user/project/local settings |
| `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (env) | Also load `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/*.md` and `CLAUDE.local.md` from `--add-dir` directories. Off by default |
| `--setting-sources` | Excluding `project` skips project rules; excluding `local` skips `CLAUDE.local.md`. |

## Auto-memory index limits (the part that bites)

The **200-line / 25 KB** ceiling applies to `MEMORY.md` only. A CLAUDE.md is loaded in full up to **4 MiB**, and a file larger than that is **skipped entirely** — not truncated, so nothing in it applies. Below that ceiling length costs adherence, not loading.

- Content past the threshold **is not loaded**, silently.
- **Frontmatter and block-level HTML comments are stripped before measuring**, so they cost nothing against the limit.
- Topic files are never loaded at startup — Claude reads them on demand.

Subagents do not inherit the main conversation's auto memory; a **fork** is the exception, since it inherits the parent conversation. A subagent's own `memory` field points at a separate directory.

## Sources

Official (authoritative for everything above):

- Memory management — <https://code.claude.com/docs/en/memory>
- Skills (the `paths` field as it exists for skills/rules) — <https://code.claude.com/docs/en/skills>
- Best practices, incl. the include/exclude table and the "would removing this cause mistakes?" test — <https://code.claude.com/docs/en/best-practices>
- AGENTS.md open format (nearest-file precedence, no required sections) — <https://agents.md/>
- Codex project-instruction loader and truncation path — <https://github.com/openai/codex/blob/main/codex-rs/core/src/agents_md.rs>
- Codex default `project_doc_max_bytes` — <https://github.com/openai/codex/blob/main/codex-rs/config/defaults.toml>

Community patterns (useful, not normative — verify before relying):

- The genre labels (instruction / procedure / chronicle / copy / generic / duplicate) are this skill's framing, not doc.
- The "layered documentation" idea is a common community structuring of the official `.claude/rules/` + subdirectory-CLAUDE.md mechanisms; the mechanisms are official, the specific 3-tier framing is not.
