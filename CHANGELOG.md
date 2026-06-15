# Changelog

All notable changes to this project are documented in this file.

## [0.2.0] - 2026-06-15

### Added

- **`statusline` skill + `/cc-tuner:statusline-setup` command** — a two-line,
  usage-focused statusline for Claude Code. Line 1: dir, git branch with
  staged/modified/untracked counts, model + reasoning effort, session duration.
  Line 2: 5h/7d rate-limit windows (utilization %, colored bar, local reset
  time) and context-window %. Since plugins can't register a statusline
  themselves, the setup command copies the bundled script to
  `~/.claude/cc-tuner-statusline.sh` and wires `statusLine` into the user's
  `settings.json` (with a backup); `update` / `remove` / `status` supported.
- The statusline script is **cross-platform**: reads the OAuth token from the
  macOS Keychain or `~/.claude/.credentials.json` on Linux/Windows (honoring
  `$CLAUDE_CONFIG_DIR`), and uses portable file-mtime (`stat -f` / `stat -c`).

### Notes

- The 5h/7d figures come from Claude Code's **unofficial** OAuth usage endpoint
  (`api/oauth/usage`); it may change without notice and the segment degrades
  silently if unavailable. The token is read locally and only sent to
  `api.anthropic.com`.

## [0.1.0] - 2026-06-14

Initial release. Centralizes the `claude-md-writer` skill that had drifted across
~10 hand-copied project folders into one doc-verified plugin.

### Added

- **`claude-md-writer` skill** — create, refactor, and audit `CLAUDE.md` /
  `.claude/rules/` memory files for Claude Code. Universal (no project- or
  domain-specific content), Claude Code only.
- `reference.md` companion with the layered-docs example, corrected common
  mistakes, path-scoped-rule behaviour, and the verified source list.

### Fixed (vs the drifted per-project copies)

- **Import recursion depth: 5 → 4** (the documented maximum).
- **Memory hierarchy corrected.** The copies listed `CLAUDE.local.md` as
  "lowest" priority and inserted "rules" as a precedence tier. Now: documented
  load order managed → user → project → local, framed as the docs do — files
  are **concatenated, not overriding**, the more-specific one is read later,
  and conflicts are resolved *arbitrarily* (so the fix is to remove the
  conflict, not to rely on precedence). `.claude/rules/` and subdirectory
  CLAUDE.md are *separate mechanisms*, not precedence tiers.
- **"No code-style/lint rules in memory" removed — it contradicted the docs.**
  The official memory docs list "coding standards" and "code styling
  preferences" as valid CLAUDE.md content and use "use 2-space indentation" as
  the model instruction. The skill now says conventions (incl. code style)
  belong in CLAUDE.md; only what must be *blocked* goes to hooks / settings,
  and you simply shouldn't re-paste an enforceable linter config into prose.
- **Import syntax in the reference fixed** from a literal `@import` to the
  documented `@path/to/file` form (a reader could otherwise emit an invalid
  directive).
- **"user-level path-scoped rules never load" removed** — it's backwards;
  `~/.claude/rules/` rules load for every project (before project rules).
- **"Rules files < 500 lines (official)" removed** — no such number is
  documented; only the CLAUDE.md < 200-line target is official.
- **`paths:` frontmatter scope made explicit** — only `.claude/rules/*.md`
  support it; CLAUDE.md loads by directory hierarchy and never takes `paths`.
- **Dropped find-replace rename artifacts** that a naive port had left in some
  copies (an invalid non-Claude rules path among them); the shipped skill is
  Claude Code only.
- Internal threshold inconsistency (200 / 100 / 300 lines across sections)
  normalized to the single documented target (< 200).

### Verified and kept (doc-backed)

- `claudeMdExcludes` setting, HTML block-comment stripping, `CLAUDE_CODE_NEW_INIT=1`
  interactive `/init`, auto memory (`MEMORY.md`, first 200 lines / 25 KB,
  machine-local, `autoMemoryEnabled`), managed CLAUDE.md paths per platform,
  path-scoped rules triggering on read.
