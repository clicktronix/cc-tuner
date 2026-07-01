# Changelog

All notable changes to this project are documented in this file.

## [0.4.0] - 2026-07-01

Tuning of `/execute-task`'s review stage after two more cross-agent review passes.

### Changed

- **`/execute-task` review is now diff-scaled.** Step 5 (`/code-review` at
  `xhigh`) is **skipped for small, non-sensitive diffs** — within the config's
  budget (default ≤ 50 changed lines and ≤ 5 files) and touching none of:
  auth/secrets/crypto, migrations or destructive data ops, public API,
  money/payments/pricing, infra/CI/deploy config, or security-relevant input
  handling. Codex `/review` (always on) covers those, so small diffs keep one
  full review engine instead of two. Any sensitive-surface touch runs `xhigh`
  regardless of size. Tunable via the config's `review_passes`.
- **Step 4 (smoke/acceptance) is explicit about behavior verification** —
  exercise the DoR/DoD acceptance criteria (`[machine]` via chrome-devtools MCP
  for UI flows and the config's `test` scripts for backend, `[eyes]` a human
  hard-stop), running the full smoke rather than just the cheap unit gate. The
  old undefined `verify` token was dropped.

### Added

- **Step 1.5 — Research** between intake and plan: pull current library/API docs
  via Context7 MCP (WebFetch fallback when Context7 isn't configured) and
  web-search unfamiliar territory, skippable when no lookup would change the
  plan. Read-only and autonomous, with an egress caveat (send generic technical
  queries, never proprietary ticket text).

## [0.3.0] - 2026-06-26

### Added

- **`/execute-task`** — a task-lifecycle playbook command (intake → plan →
  implement → review → CI/CD → merge) driven by the main agent, with a
  start-time autonomy level (`brainstorm-only` / `checkpoints` / `supervised`)
  and honest hard-stops (prereq, dirty tree, red gate, human-eye acceptance,
  CD/merge). Five bundled bash scripts (prereq-check, config-init, preflight,
  journal, guard-artifacts) handle the deterministic git/fs work; per-project
  settings live in `.claude/execute-task.md`. Requires the `superpowers` and
  `cc-codex-triage` plugins (prereq-checked at runtime; cc-tuner still installs
  standalone).
- The gate scripts are **fail-closed**: a filesystem or git error never reads as
  a clean tree / created config / empty change set. Runs-dir detection uses git
  pathspecs (not substring matching); the artifact guard is **history-aware**
  (rejects run artifacts hiding in `<target>..HEAD` that a non-squash merge would
  publish); and the run-journal survives re-runs, monorepo subdirs, linked
  worktrees, and unborn/detached HEAD. Hardened across six review passes, each
  gated to APPROVE with regression tests (26 checks on bash 3.2.57).

## [0.2.1] - 2026-06-15

Hardening of the 0.2.0 statusline after a 3-round cross-agent (Codex) review.

### Fixed

- **Git staged/modified counts were always zero** — `--no-optional-locks` was
  passed as a `git diff` option, which git rejects; the env form
  `GIT_OPTIONAL_LOCKS=0` is used now.
- **Stale rate-limit data could show forever** on a permanent fetch failure. A
  `fetched_at` stamp now gates rendering; the 5h/7d segment is dropped once data
  is older than 30 min.
- **Fresh-install fetch failures retried every render** (paying the 5s timeout)
  because there was no cache to touch — a negative cache marker now suppresses
  retries until the TTL.
- **Insecure shared `/tmp` cache** — the cache + lock now live in a private
  per-user dir (`chmod 700`) keyed by uid and a hash of the effective
  `CLAUDE_CONFIG_DIR`, so usage data can't leak across users or accounts.
- **`/cc-tuner:statusline-setup` could report success while failing** — the
  install/remove `settings.json` edits now require valid JSON, guard the backup
  and the `jq`/`mv` steps, use a same-directory temp file for an atomic replace,
  and only claim success after it lands. The remove path validates JSON before
  touching anything.
- **Reset-time parsing** normalizes a trailing `Z` so it works on Python < 3.11.

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
