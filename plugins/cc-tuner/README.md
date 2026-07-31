# cc-tuner plugin

Skills that tune Claude Code's own configuration. One install, no per-project copies to drift.

## Skills

### `claude-md-writer`

Create, refactor, and audit **CLAUDE.md** and **`.claude/rules/`** memory files for Claude Code, following the official memory docs (<https://code.claude.com/docs/en/memory>). Triggers when you create/trim/split a CLAUDE.md, organize instructions into `.claude/rules/`, or decide what belongs in CLAUDE.md vs rules vs `CLAUDE.local.md` vs tool config.

What it covers (Claude Code memory facts checked against the docs):

- **CLAUDE.md < 200 lines** — the only published size target; loads every session.
- **`paths:` frontmatter only on `.claude/rules/*.md`**, never on CLAUDE.md (CLAUDE.md loads by directory hierarchy; conditional loading is a rules-file feature).
- **Documented load order** — managed → user → project → local; files are concatenated, not overriding, and conflicts are resolved arbitrarily (so the fix is to remove conflicts, not lean on precedence). Rules and subdirectory CLAUDE.md are separate mechanisms, not precedence tiers.
- **Code style / conventions belong in CLAUDE.md** (the docs' own example is "use 2-space indent"); only hard *blocks* go to hooks/settings.
- Correct details on **imports** (max 4 hops), **auto memory** (`MEMORY.md`, first 200 lines / 25 KB, machine-local), **path-scoped rules** (trigger on read; user-level rules *do* load), **monorepo** (`claudeMdExcludes`), and **HTML-comment stripping**.

Deep examples and the verified source list are in the skill's `reference.md`.

### `statusline`

A two-line usage-focused statusline for Claude Code:

```
➜ my-project git:(main) S:2 M:1 U:4 | Opus 4.8 xhigh | 1h12m
 | 5h:66%[▓▓▓▓▓░░░]>23:30  7d:9%[▓░░░░░░░]>17:00 | ctx:8%[▓░░░░░░░░░]
```

Rate-limit windows (5h / 7d utilization + reset time), context-window %, git branch with
staged/modified/untracked counts, model + reasoning effort, and session duration. Bars go
green → yellow (≥50%) → red (≥80%). Cross-platform (macOS Keychain, Linux/Windows
`~/.claude/.credentials.json`).

Plugins can't register a statusline themselves, so a setup command wires it into the
user's `settings.json`:

```
/cc-tuner:statusline-setup            # install (also: update | remove | status)
```

The 5h/7d data uses Claude Code's **unofficial** OAuth usage endpoint — it degrades
silently if that ever breaks. The OAuth token is read locally and only sent to
`api.anthropic.com`.

### `task-flow`

Canonical git workflow — branch naming, Conventional Commits (incl. breaking
changes), PR verification gates, GitHub Projects board recipes (create-on-board,
field-ID caching, card lifecycle), plan lifecycle (`wiki/PLANS/` → `ARCHIVE`,
`docs/` fallback), and anti-pattern case studies with dated incidents.

The always-on core installs per repo via `/cc-tuner:task-flow-setup` (plugins
can't ship `.claude/rules/*`): a versioned template with the plans root detected
from the repo layout, repo-specific deltas in an untouched `task-flow.local.md`,
and optional cleanup of legacy hand-copied rule files.

### `smoke-verify`

A per-repo opt-in Stop-hook gate against the top regression source in agentic
coding: fix commits that pass typecheck/lint but were never actually run. In a
repo that opted in via `/cc-tuner:smoke-verify-setup`, a turn that changed
frontend files (configurable regex in `.claude/smoke-verify.cfg`) cannot end
until the change was **exercised for real** — page rendered, failing case
re-run, artifact looked at — and attested with one line of evidence:

```
bash <plugin>/scripts/smoke-verify/mark.sh verified 'opened /fit page, labels render'
```

The attestation binds to the branch + worktree-content fingerprint of the
delta, so editing again re-arms the gate (staging/committing identical content
does not). Explicit user-authorized skips are recorded (`mark.sh skip '<why>'`).
Fail-open everywhere: no config, no matched changes, malformed counter state,
or `cap` blocks (default 3) on an unchanged delta → the turn ends normally.
Scope: the gate fingerprints **uncommitted** changes — attest before
committing; a change committed mid-turn without attestation escapes it. The
hook itself is milliseconds of bash — it never runs any verification, it only
routes the agent to do it.

## /spec and /run

The task loop, split in two on purpose.

`/cc-tuner:spec <issue | description>` does all the asking. It reads the repo, the issue and the code
before it asks anything, grills the requirements via `mattpocock-skills:grill-with-docs`, and writes a
spec whose acceptance criteria each name the command or MCP step that decides them. Every `[eyes]`
criterion has to carry a machine replacement or a recorded waiver — an `[eyes]` criterion is a stop an
unattended run cannot clear, so leaving one bare just moves the failure later. The spec ends with an
explicit statement of whether it is `--auto`-ready, and why not when it isn't.

`/cc-tuner:run [--auto] <spec>` executes it and asks nothing. Without `--auto` it stops between
phases; with `--auto` it runs unattended and merges on green CI. `--auto` never waives a red gate, a
red CI, a bare `[eyes]` criterion, scope beyond the spec, or **anything outward-facing past the
merge** — a deploy or a publish still stops.

These replace `/cc-tuner:execute-task`, which tried to do both jobs in one pipeline and could do
neither well: its intake step was marked "human gate, always", so full autonomy was structurally
impossible, while the interactive work was compressed into one step of ten.

The other half of that fix is that **the run journal is now read, not just written**. It had eight
append call sites and no way to get anything back, which is why a long run lost its place: after a
compaction the playbook returns (it is re-read from the command file) but the progress does not.
`/run` opens every phase with `journal.sh resume`, and journals literal values — PR number, base SHA,
per-criterion results — because shell state does not survive between Bash calls either.

Requires the **superpowers** and **cc-codex-triage** plugins (checked at runtime via prereq-check;
cc-tuner installs and works standalone without them).

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

The `claude-md-writer` and `task-flow` skills are model-invoked: Claude loads them when the task matches their descriptions — no slash command needed for those. The installers and the lifecycle playbooks are explicit slash commands you run yourself: `/cc-tuner:statusline-setup`, `/cc-tuner:task-flow-setup` (installing the canonical rule into a repo happens ONLY via this command — installing the plugin alone does not write any `.claude/rules/` file), `/cc-tuner:smoke-verify-setup` (same opt-in story: the Stop hook loads with the plugin but stays inert until this command writes the repo's config), `/cc-tuner:spec`, and `/cc-tuner:run`.

## Scope

Claude Code only. The plugin writes Claude Code's own surfaces — memory files (CLAUDE.md, `.claude/rules/`, `CLAUDE.local.md`), user settings (statusline), and per-repo rule installs — it does not manage other agents' instruction files.

## License

MIT.
