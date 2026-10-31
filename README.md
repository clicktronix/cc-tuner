# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

Skills:

- **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.
- **`statusline`** — a usage-focused statusline (rate-limit 5h/7d windows, context %, git, model + effort, session duration), installed by the statusline node of `/cc-tuner:setup`, since plugins can't register a statusline on their own.
- **`verify-feature`** — a stage of `/cc-tuner:run`, and usable alone. It reads the spec's acceptance criteria and the diff, finds what the repository already provides (commands, fixtures, runbooks, a browser tool, a database), picks the instrument each behaviour actually needs, runs it, and records what was observed.
- **`task-flow`** — canonical branch/commit/PR/board/plan conventions: on-demand procedures in the skill, plus the task-flow node of `/cc-tuner:setup` that writes the always-on `.claude/rules/task-flow.md` into a repo from a versioned template, since plugins can't ship rules files either.

Start with **`/cc-tuner:setup`** — one command, run as independent nodes that each detect, propose, apply and verify: environment, instruction cleanup, rule loading, the task-flow rule, task tools, an optional statusline, an optional board, and an optional one-call Codex audit. `check` writes nothing; `install` applies the additive changes and asks only where a change is not additive. The task loop has two commands: **`/cc-tuner:spec`** turns a task into a committed spec and sliced plan (with `--groom`, it only records the decisions in the issue), and **`/cc-tuner:run [--auto] <spec>`** works that plan through implementation, PR, review, CI, and merge, moving the board card as it goes; details in the [plugin README](plugins/cc-tuner/README.md).


## Why this exists

The same `claude-md-writer` skill had been hand-copied into ~10 project folders and silently diverged — different size numbers, a wrong import depth (5 vs the documented 4), a "user-level rules never load" claim that's backwards, `paths:` frontmatter implied on CLAUDE.md (it only works on `.claude/rules/`), and a botched find-replace port. Centralizing it as a plugin kills the drift: one source of truth, doc-verified, updated in one place.

## Repository rules

[Research and design](docs/2026-09-09-agent-rules-research.md).

`agent-rules` loads the target repository's applicable instructions, modular rules, and linked
contracts before a review or change, including when a task crosses into another repository.
The plugin supplies one generic skill; project rules stay in their existing canonical files.

Run `/cc-tuner:setup install agent-rules` to add a short loading instruction to the repository's root
`AGENTS.md` (or the effective `AGENTS.override.md`). Use `check` instead of `install` for a
read-only status and diff, which distinguishes a missing block from one installed too low in the
file. Repeated installation is a no-op. Conflicting managed blocks and symlinks require inspection
and are not overwritten. No rule index or per-repo skill is copied. The block goes at the very top,
ahead of the file's own heading, because Codex stops adding project instructions once the chain
reaches `project_doc_max_bytes` (32 KiB by default) — prose is preserved byte for byte, its order is
not. Empty overrides stay empty so `AGENTS.md` remains active.
The instruction remains usable without the plugin; it is guidance, not an enforcement hook.

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

## Repo layout

```
.claude-plugin/marketplace.json     # marketplace manifest
plugins/cc-tuner/                   # the plugin: manifest, README, agents/, assets/, hooks/, output-styles/,
                                    # scripts/ (merge, heavy-check, plan and review helpers, setup/), skills/, tests/
docs/                               # design records, ADRs and plans
tests/run.sh                        # repo validation (also the CI entry point)
tests/scenarios/                    # eval scenarios (RED/GREEN baselines)
release-please-config.json          # what a release bumps
CHANGELOG.md                        # generated from commits since 0.9.0
LICENSE                             # MIT
```

## Releasing

Versions are bumped by [release-please](https://github.com/googleapis/release-please), not by hand.
Push Conventional Commits to `main` and it maintains one open release PR that bumps the version and
writes the `CHANGELOG.md` entry; merging that PR tags the release. **Do not hand-edit the version** —
it lives in three places (`marketplace.json` twice, `plugin.json` once) and 0.6.0 shipped with two of
them disagreeing, which is why this is automated and why `tests/run.sh` asserts that every field
release-please is configured to touch actually resolves.

One thing stays manual: the `v0.x.y` marker at the top of `assets/task-flow/rule.template.md`. It
means "the plugin version when this template last changed", so bumping it every release would make
every installed copy report itself outdated and invite a pointless rewrite. Bump it only when the
template's content changes.

Entries up to 0.8.0 were written by hand and are left as they are.

## License

MIT.
