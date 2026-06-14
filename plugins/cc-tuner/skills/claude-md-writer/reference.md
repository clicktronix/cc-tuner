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
| Multi-step procedure in CLAUDE.md | → a skill (`.claude/skills/<name>/SKILL.md`) |
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
| `/memory` | List every memory file loaded this session (CLAUDE.md, CLAUDE.local.md, rules); toggle auto memory |
| `autoMemoryEnabled` (setting) | Turn the auto-memory `MEMORY.md` system on/off |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (env) | Disable auto memory via environment variable |
| `claudeMdExcludes` (setting, recommended in `.claude/settings.local.json`; arrays merge across layers) | Skip specific ancestor CLAUDE.md files by absolute path or glob |

## Sources

Official (authoritative for everything above):

- Memory management — <https://code.claude.com/docs/en/memory>
- Skills (the `paths` field as it exists for skills/rules) — <https://code.claude.com/docs/en/skills>

Community patterns (useful, not normative — verify before relying):

- The "layered documentation" idea is a common community structuring of the official `.claude/rules/` + subdirectory-CLAUDE.md mechanisms; the mechanisms are official, the specific 3-tier framing is not.
