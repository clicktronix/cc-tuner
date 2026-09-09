# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

Skills:

- **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.
- **`statusline`** — a usage-focused statusline (rate-limit 5h/7d windows, context %, git, model + effort, session duration) with a `/cc-tuner:statusline-setup` installer, since plugins can't register a statusline on their own.
- **`verify-feature`** — a stage of `/cc-tuner:run`, and usable alone. It reads the spec's acceptance criteria and the diff, finds what the repository already provides (commands, fixtures, runbooks, a browser tool, a database), picks the instrument each behaviour actually needs, runs it, and records what was observed. It replaced a Stop-hook gate that classified changes by file path: paths do not know what a change does, and a fixed proof per extension asks for the wrong evidence as often as the right one.
- **`task-flow`** — canonical branch/commit/PR/board/plan conventions: on-demand procedures in the skill, plus a `/cc-tuner:task-flow-setup` installer that writes the always-on `.claude/rules/task-flow.md` into a repo from a versioned template, since plugins can't ship rules files either.

Start with **`/cc-tuner:setup`** — it checks the environment the other commands assume (CLI tools, the `gh` token's `project` scope, companion plugins, optionally MCP servers) and reports the installer commands this repo needs. `check` reports without writes; `install` adds repository rule loading and may wire the board after the user-run installers finish.

The task loop has two commands: **`/cc-tuner:spec`** does the discovery, creates the task branch, confirms the contract and vertical slices once, then commits the spec and plan and publishes the slices as native tasks when those tools are available; **`/cc-tuner:run [--auto] <spec>`** works that plan through implementation, PR, review, CI, and merge. Without `--auto`, run stops at delivery boundaries; with it, an explicitly auto-ready spec runs unattended through a green merge, never through deploy or publish.


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
not.
The instruction remains usable without the plugin; it is guidance, not an enforcement hook.

## Install

```
/plugin marketplace add clicktronix/cc-tuner
/plugin install cc-tuner@cc-tuner
```

## Repo layout

```
.claude-plugin/marketplace.json     # marketplace manifest
plugins/
  cc-tuner/
    .claude-plugin/plugin.json      # plugin manifest
    README.md
    assets/
      task-flow/rule.template.md        # canonical .claude/rules/task-flow.md template
    skills/
      run/SKILL.md                  # /cc-tuner:run [--auto] <spec> executor
      spec/SKILL.md                 # /cc-tuner:spec writes the contract and sliced execution plan
      spec/spec-template.md         # executable spec contract filled by /cc-tuner:spec
      spec/plan-template.md         # plan grammar filled by /cc-tuner:spec
      setup/SKILL.md                # /cc-tuner:setup env check + installer orchestration
    hooks/
      hooks.json                    # SessionStart registration
      session-start.sh              # asks a fresh session to rebuild its task list from the plan
    scripts/
      merge.sh                      # checked merge: required review + public verdict + CI on the head SHA
      mutate.sh                     # one mutation, graded by the program: no-op and syntax refusals, verified restore
      plan-lint.sh                  # the plan format's validator, and the parser the hook reads it with
      plan-path.sh                  # the one branch -> plan-path resolver
      setup/doctor.sh               # environment checks behind /cc-tuner:setup
      setup/prereq-check.sh         # companion plugins installed, enabled, and carrying their contracts
      setup/plugin-here.sh          # which install of a plugin applies to this repo (one rule, two callers)
    skills/
      claude-md-writer/
        SKILL.md                    # corrected canonical skill
        reference.md                # deep examples + verified sources
      task-flow/
        SKILL.md                    # board recipes, merge strategies, plan lifecycle
        references/case-studies.md  # historical failure evidence outside the hot path
      statusline/
        SKILL.md                    # usage statusline (feature + disclaimers)
        statusline.sh               # the cross-platform statusline script
docs/superpowers/specs/             # design records
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
