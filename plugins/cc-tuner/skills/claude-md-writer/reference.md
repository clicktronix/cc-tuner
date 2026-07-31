# CLAUDE.md Writer — reference

Extended detail for the `claude-md-writer` skill. Claude Code memory facts trace to the official memory docs (<https://code.claude.com/docs/en/memory>); the structuring patterns are convention and are labelled as such.

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

## Common mistakes

| Mistake | Fix |
|---|---|
| CLAUDE.md keeps growing past 200 lines | Move domain detail to `.claude/rules/` with `paths`; keep only always-on facts |
| `paths:` frontmatter on CLAUDE.md | Not supported — CLAUDE.md loads by hierarchy. Use a `.claude/rules/` file for conditional loading |
| SQL / API / deploy detail inline | → `rules/database.md`, `rules/api.md`, `rules/deploy.md` |
| Multi-step procedure in CLAUDE.md | → a skill (`.claude/skills/<name>/SKILL.md`). Custom commands are the same mechanism now — `.claude/commands/deploy.md` and `.claude/skills/deploy/SKILL.md` both produce `/deploy`; the skill form adds a directory for supporting files and frontmatter |
| Assuming a file loaded because it exists on disk | `/context` → **Memory files** is the check. `/memory` lists locations, including files that don't exist yet, so it cannot answer this |
| Team-shared CLAUDE.md importing `@~/something` | An external import shows a one-time approval dialog; a teammate who declines gets permanent silence with no second prompt. Commit the content instead |
| Keeping layout / dependency lists / architecture prose in CLAUDE.md | Claude derives these from the codebase. `/doctor`'s trim check cuts exactly this class and keeps pitfalls, rationale and non-default conventions |
| Re-pasting an enforceable linter/formatter config into prose | Keep the config in its tool file; in CLAUDE.md state only the convention to follow ("2-space indent" is a fine CLAUDE.md line — a copy of `.eslintrc` isn't) |
| Relying on CLAUDE.md to *block* an action | CLAUDE.md isn't enforced — use a hook or `permissions.deny` for hard blocks |
| Code pasted into memory | → `@path/to/file` reference; pasted code goes stale silently |
| Only negative rules ("don't X") | Pair with the alternative ("don't X; do Y") |
| Duplicating one CLAUDE.md inside another | `@path/to/shared-file.md` (import; max 4 hops deep) |

## Path-scoped rule behaviour (the non-obvious parts)

- **Trigger is a READ of a matching file** — the docs say path-scoped rules trigger when Claude *reads* a file matching the glob, "not on every tool use". A merely planned write doesn't pull the rule in; Claude actually reading the file does.
- **User-level rules load too.** `~/.claude/rules/*.md` apply to every project on the machine and load *before* project rules — the docs frame this as giving project rules "higher priority", but since memory is concatenated, the safe move is to not let user and project rules contradict in the first place. (Contrary to a common misconception that user-level path rules "never load" — they do.)
- **Quote your globs.** The docs quote every glob in their `paths` examples (e.g. `- "src/**/*.{ts,tsx}"`), and a leading `*` or `{` is unsafe unquoted in YAML anyway. No prose rule *mandates* it, but quoting is the form the docs model — follow it.
- **Rules-file size:** the docs publish a size target only for CLAUDE.md (< 200 lines). There is **no** official line/size number for `.claude/rules/*.md` — keep them focused, but don't cite a "500-line rule" as official; it isn't.
- **Symlinks work**, both for a whole directory and a single file (`ln -s ~/company-standards/security.md .claude/rules/security.md`); circular symlinks are detected. As of v2.1.198 path matching also works when a file is reached through a symlinked path into the project.
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
| `/doctor` | Checkup that proposes trims for a checked-in CLAUDE.md: cuts codebase-derivable content, keeps pitfalls, rationale and non-default conventions (v2.1.206+) |
| `InstructionsLoaded` hook | Logs which instruction files load, when, and why — the debugger for path-scoped rules and lazily-loaded subdirectory files |
| `autoMemoryEnabled` (setting) | Turn the auto-memory `MEMORY.md` system on/off. Set it in a project's settings to disable for that project only |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (env) | Disable auto memory via environment variable |
| `autoMemoryDirectory` (setting) | Relocate the auto-memory directory. Absolute or `~/`-prefixed. Read from any settings scope, but a project-scope value is honoured only after the workspace trust dialog — the same gate as hooks |
| `claudeMdExcludes` (setting, recommended in `.claude/settings.local.json`; arrays merge across layers) | Skip specific ancestor CLAUDE.md files by absolute path or glob. **Managed-policy CLAUDE.md cannot be excluded** |
| `claudeMd` (managed/policy settings only) | Put managed CLAUDE.md content inline in `managed-settings.json` instead of shipping a file. No effect in user/project/local settings |
| `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` (env) | Also load `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/*.md` and `CLAUDE.local.md` from `--add-dir` directories. Off by default |
| `--setting-sources` | Excluding `project` skips project rules; excluding `local` skips `CLAUDE.local.md`. Before v2.1.211 on-demand rules loaded anyway |

## Auto-memory index limits (the part that bites)

The **200-line / 25 KB** ceiling applies to `MEMORY.md` only — CLAUDE.md files load in full at any length (shorter just adheres better).

- Content past the threshold **is not loaded**, silently.
- After a write, Claude Code measures the file: near a limit it reminds Claude to shorten; over a limit the write still succeeds but returns an error telling Claude to rewrite the index, because the overflow is dropped on the next load (v2.1.210+).
- **Frontmatter and block-level HTML comments are stripped before measuring** (v2.1.211+), so they cost nothing against the limit. Earlier versions measured the raw file and could fire the error on content that actually fit.
- A memory file that already has frontmatter gets a `modified` ISO-8601 timestamp on each write (v2.1.214+); files without frontmatter never gain it.
- Topic files are never loaded at startup — Claude reads them on demand.

Subagents do not inherit the main conversation's auto memory; a **fork** is the exception, since it inherits the parent conversation. A subagent's own `memory` field points at a separate directory.

## Sources

Official (authoritative for everything above):

- Memory management — <https://code.claude.com/docs/en/memory>
- Skills (the `paths` field as it exists for skills/rules) — <https://code.claude.com/docs/en/skills>

Community patterns (useful, not normative — verify before relying):

- The "layered documentation" idea is a common community structuring of the official `.claude/rules/` + subdirectory-CLAUDE.md mechanisms; the mechanisms are official, the specific 3-tier framing is not.
