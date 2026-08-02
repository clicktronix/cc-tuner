# Changelog

All notable changes to this project are documented in this file.

## [0.10.0](https://github.com/clicktronix/cc-tuner/compare/v0.9.0...v0.10.0) (2026-08-02)


### ⚠ BREAKING CHANGES

* run guards now bind to a journaled run ID and immutable target SHA.
* spec/run split, effort tiering, /delegate and smoke-verify skill removed ([#11](https://github.com/clicktronix/cc-tuner/issues/11))

### Features

* spec/run split, effort tiering, /delegate and smoke-verify skill removed ([#11](https://github.com/clicktronix/cc-tuner/issues/11)) ([0c97e96](https://github.com/clicktronix/cc-tuner/commit/0c97e96f949e12ffb070e2e3c1ddd47879e85f86))


### Bug Fixes

* complete spec-run delivery lifecycle ([f9bd5d6](https://github.com/clicktronix/cc-tuner/commit/f9bd5d6e1cf72802f3727dc2318ab8cfabd3cfb1))

## [0.9.0](https://github.com/clicktronix/cc-tuner/compare/v0.8.0...v0.9.0) (2026-07-31)


### Features

* /cc-tuner:setup entry point + release-please for versioning ([#8](https://github.com/clicktronix/cc-tuner/issues/8)) ([d8f3f73](https://github.com/clicktronix/cc-tuner/commit/d8f3f73a1443012f9e102dc5a8f6ff922ba5bffb))


### Bug Fixes

* **claude-md-writer:** refresh against current memory docs, correct the /memory claim ([#10](https://github.com/clicktronix/cc-tuner/issues/10)) ([0cb3c7c](https://github.com/clicktronix/cc-tuner/commit/0cb3c7cfdb06ee502beb852a08ba3203f4a76f8b))

## [0.8.0] - 2026-07-31

Ports two PRs (#2, #3) that were authored against the pre-rename `git-flow` files and stranded when
0.7.0 deleted them. Four verification behaviours, each from a documented production incident, each
now measured on a two-arm probe rather than shipped on the incident alone.

### Added

- **Four anti-pattern case studies in the `task-flow` skill.**
  - *Test that could never fail* (2026-07-28) — a regression test built its second patch from the
    already-merged state while every production handler closes over the render snapshot, so it passed
    against the broken implementation and could not have caught the defect it guarded. Inlining the
    old implementation as a throwaway mutant showed red/green in under two minutes.
  - *"Not my file" as a scope rebuttal* (2026-07-28) — a cross-writer race was deferred as
    pre-existing because the cited file was outside the diff, while the branch's own new writers were
    what made the collision reachable. Symmetrically, a "product decision" turned out to be a
    branch-introduced default. Provenance of the **defect** decides, not provenance of the file.
  - *Trusting autofix output* (2026-07-28, twice in one session) — `eslint --fix` folded value
    imports into an `import type` block and the formatter moved a comment past a bare `return`.
    Neither appeared in the fixer's zero-error report; both surfaced on the next typecheck.
  - *Branch continued after its PR merged* (2026-07-26) — a squash-merged branch that kept receiving
    commits reads as "5 commits ahead" while 3 of them are already in `main` under another SHA. A
    trial rebase conflicted in 6 files on the first commit; cherry-picking the 2 genuinely-new commits
    onto a fresh branch applied clean. Replaces the thinner *Stale base* entry from 0.7.0.
- **Two pre-PR checklist items**, folded rather than appended: one covering "nothing is trusted on its
  own success report" (mutant check + post-autofix typecheck/lint), one for deferrals claimed as
  pre-existing.

### Changed

- **The force-push invariant now names the harm.** It read as a tooling restriction; the harm is
  rewriting history others may have reviewed or built on, and the force-push is only the mechanism.
  Behaviour is unchanged — force-with-lease still needs explicit sign-off.
- **Eval scenarios carry a measured RED arm.** The four new `task-flow` scenarios were probed in two
  arms (guidance present vs. withheld) across two framings. `autofix-trusted-blindly` reproduces in
  both framings; `regression-test-never-red` and `pre-existing-scope-rebuttal` hold unaided when
  unhurried and fail under deadline; `branch-continued-after-merge` did not reproduce and is kept as
  insurance, with its own query identified as telegraphing the diagnosis. Each scenario records the
  method caveat that probe subagents inherited the host project's instructions, making the control
  stronger than neutral and the measured effects lower bounds.

## [0.7.0] - 2026-07-31

### Changed

- **Breaking.** Renamed the `git-flow` skill, rule and setup command to `task-flow`. The old name is
  the name of Vincent Driessen's branching model, with its `develop` and `release` branches — the one
  thing the rule explicitly forbids. The scope had also outgrown git: the board, epics, worktrees and
  release notes are not git operations. `/cc-tuner:task-flow-setup` migrates a repo on the old name,
  moving `git-flow.local.md` to `task-flow.local.md` so cached board field IDs survive, and removing
  the superseded `git-flow.md`.
- **The rule now carries invariants only.** Nine prohibitions across 52 lines became five: the ones
  whose violation loses work, leaks secrets or breaks history. Everything procedural moved into the
  skill, which loads when needed instead of sitting in every session's context. Dropped from
  always-on: the 48-hour branch-lifetime cap with its rebase-versus-merge decision tree, and the
  tiny-doc-PR policy — the latter survives as a case study in the skill, since it encodes real user
  feedback but is a judgement call rather than an invariant.
- **`/cc-tuner:task-flow-setup` no longer detects a plans root.** With plan lifecycle moved to the
  skill, the template has no `{{PLANS_ROOT}}` token left to substitute, so the rule installs verbatim
  and the "re-run me after migrating docs to `wiki/`" advice is gone with it. The skill resolves the
  root (`wiki/` if present, else `docs/`) when it actually needs it.
- **PR bodies link the CI run instead of pasting its output.** The old rule demanded a checkbox list
  carrying "real output", which is why measured PR bodies run to 4,137 characters on average in one
  repo, with 9 of 15 over 4,000 and a 15,966-character outlier in another. The output is already in
  the CI logs; in the body it buries the part a human has to read.

### Added

- **Epics and sub-issues** in the skill. An epic is an issue whose type is `Epic` — Issue Types are
  org-level and render as a filterable badge, so no title-prefix convention is needed. Decomposition
  uses native sub-issues, which give the parent a real progress bar. Branch and PR attach to the
  sub-issue; the epic closes when its children do.
- **Post-merge cleanup procedure**: sync local `main` with `--ff-only`, remove the merged branch's
  worktree, prune stale registrations, delete merged local branches, prune remote-tracking refs.
  Previously absent entirely, while worktree-per-task is the working mode.
- **Release-notes guidance**: `release-please` versus `.github/release.yml`, and why an off-format
  commit is a commit missing from the notes.
- **Stale-base anti-pattern**: a branch whose work was squash-merged reads as "ahead" while its base
  is behind, and the conflicts surface only at merge time.
- **`tests/run.sh` validates eval-scenario references.** Every scenario's `tests_reference` has to
  name a file that exists, and a `path#anchor` reference has to name a heading that is still there.
  This rename produced two dangling references and nothing failed. Root-level `*.md` files are now
  in the markdown-link check too; previously only `plugins/` and `docs/` were.

## [0.6.0] - 2026-07-19

Two cost/quality levers: cheaper models for mechanical implementation work,
and a hard gate against "fixed" frontend changes that were never actually run.

### Added

- **`smoke-verify` Stop-hook gate** (per-repo opt-in via
  `/cc-tuner:smoke-verify-setup`). A turn with uncommitted changes matching
  the repo's frontend patterns cannot end until the change was exercised for
  real and attested with one line of evidence (`scripts/smoke-verify/mark.sh
  verified|skip`). The attestation binds to branch + worktree-content
  fingerprint — editing again re-arms the gate; staging/committing identical
  content does not. Scope is the uncommitted delta (verify → attest →
  commit). Fail-open on: no config, no matched changes, malformed counter,
  detached HEAD, and after `cap` blocks (default 3) per unchanged delta. Hook
  and attestation writer share one fingerprint lib so they can never
  disagree. New `smoke-verify` skill documents what counts as verification
  evidence (rendering/running — not typecheck/lint). Regression tests:
  `tests/smoke-verify/` (macOS bash 3.2 + Linux). Those suites now run in CI: `tests/run.sh`
  executes every `plugins/cc-tuner/tests/*/test_*.sh` and asserts the manifest invariants a release
  depends on — version agreement across `plugin.json` and both `marketplace.json` fields, a CHANGELOG
  section for the shipped version, existence of every `${CLAUDE_PLUGIN_ROOT}` path, skill bodies under
  500 lines, and resolvable markdown links. `.github/workflows/validate.yml` runs it on ubuntu-latest
  and macos-latest, so the claimed bash 3.2 support is exercised rather than asserted. Each check is
  mutation-verified. Adds the one missing case: a detached HEAD releases the gate, since
  `rev-parse --abbrev-ref` yields the literal `HEAD` and an attestation has no stable branch to scope
  to. Fixes the release blocker where `marketplace.json` still advertised 0.5.1.
- **`/cc-tuner:delegate`** — free-form task in, tiered fan-out: the main
  model decomposes and verifies, sonnet/opus subagents implement per the
  shared tier table `assets/delegate/tiering.md` (mechanical → sonnet,
  standard → opus, architectural/sensitive → main model; unsure → higher).
  Verification contract per unit: full diff read + cheap gate + acceptance
  criteria; one redispatch on failure, then a tier escalation — never a
  third blind retry.

### Changed

- **execute-task step 3 model tiering** — new `model_tiering` config key
  (default `on`): implementation units dispatch on the tier table's models;
  planning, reviews, and acceptance judgment always stay on the main model.

## [0.5.1] - 2026-07-17

### Fixed

- **statusline: honor `retry-after` on HTTP 429 from the usage endpoint.** The
  unofficial oauth/usage endpoint's throttle window extends on repeated hits
  (observed `retry-after` growing 180s → 1827s under the old fixed 5-min TTL
  retries), so the script's own retries could keep the 5h/7d segment hidden
  indefinitely. On 429 the refresh now records the server's `retry-after`
  (clamped 5–60 min, 15 min when the header is absent) and suspends refresh
  attempts for that window; a successful refresh clears it. Everything else
  (graceful degradation, 30-min staleness gate) is unchanged.

## [0.5.0] - 2026-07-16

Git workflow moves into the plugin: one canonical rule instead of 11 hand-copied
`git-flow.md` files across marqa/stokli workspaces (two drifted variants with
contradictory tiny-PR policies).

### Added

- **`git-flow` skill** — on-demand procedures: GitHub Projects recipes
  (create-on-board, field-ID caching, card lifecycle), merge strategies incl.
  stacked PRs, plan lifecycle (`wiki/PLANS/` → `ARCHIVE`, `docs/` fallback),
  anti-pattern case studies with dated incidents.
- **`/cc-tuner:git-flow-setup`** — installs/updates the canonical
  `.claude/rules/git-flow.md` from a versioned template (plans root detected
  per repo layout), keeps repo deltas in an untouched `git-flow.local.md`,
  offers cleanup of the legacy `no-tiny-doc-prs.md`.
- **Eval scenarios** `tests/scenarios/git-flow/` — both REDs are documented
  production incidents (2026-06-05); GREEN probes recorded (flip 2/2 each).

### Changed

- **`/execute-task`** — board integration: intake moves the card to In
  Progress (journaling the prior status for rollback); after a verified
  MERGED result, a `Closes`/`Fixes` link moves the card to Done while a
  partial `Refs` link keeps it In Progress; step 8
  archives a completed plan inside the same PR. New optional config key
  `board` (blank = board steps skipped).

Canonical policy decisions: advisory-only (no enforcement hooks), tiny doc-PRs
are batched (3+) per direct user feedback 2026-06-05, plans live in
`wiki/PLANS/` with `docs/PLANS/` fallback. Design:
`docs/superpowers/specs/2026-07-16-git-flow-design.md`.

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
