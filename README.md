# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

Skills:

- **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.
- **`statusline`** — a usage-focused statusline (rate-limit 5h/7d windows, context %, git, model + effort, session duration) with a `/cc-tuner:statusline-setup` installer, since plugins can't register a statusline on their own.
- **`smoke-verify`** — not a skill: an opt-in Stop-hook gate (`/cc-tuner:smoke-verify-setup`). Frontend changes can't end a turn until they were exercised for real and attested with evidence. The whole standard lives in the block message the agent actually receives, rather than in a skill it has to choose to load.
- **`task-flow`** — canonical branch/commit/PR/board/plan conventions: on-demand procedures in the skill, plus a `/cc-tuner:task-flow-setup` installer that writes the always-on `.claude/rules/task-flow.md` into a repo from a versioned template, since plugins can't ship rules files either.

Start with **`/cc-tuner:setup`** — it checks the environment the other commands assume (CLI tools, the `gh` token's `project` scope, companion plugins, optionally MCP servers) and then runs only the installers this repo needs. `check` reports, `install` acts.

The task loop is two commands, deliberately split: **`/cc-tuner:spec`** does all the asking, creates the task branch, and commits machine-checkable acceptance criteria; **`/cc-tuner:run [--auto] <spec>`** continues that branch through implementation, PR, CI, and merge. Without `--auto` it stops at phase boundaries; with it, an explicitly auto-ready spec runs unattended through a green merge, never through deploy or publish.


## Why this exists

The same `claude-md-writer` skill had been hand-copied into ~10 project folders and silently diverged — different size numbers, a wrong import depth (5 vs the documented 4), a "user-level rules never load" claim that's backwards, `paths:` frontmatter implied on CLAUDE.md (it only works on `.claude/rules/`), and a botched find-replace port. Centralizing it as a plugin kills the drift: one source of truth, doc-verified, updated in one place.

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
      tiering/tiering.md                # effort tiers + THE sensitive-surface list (/run phases 1 and 4)
      execute-task/config.template.md   # per-project run settings (superseded by a spec's Run config)
      task-flow/rule.template.md        # canonical .claude/rules/task-flow.md template
      smoke-verify/config.template.cfg  # per-repo smoke-verify opt-in config
    commands/
      run.md                        # /cc-tuner:run [--auto] <spec> executor
      setup.md                      # /cc-tuner:setup env check + installer orchestration
      spec.md                       # /cc-tuner:spec interactive spec writer
      task-flow-setup.md            # /cc-tuner:task-flow-setup rule installer
      smoke-verify-setup.md         # /cc-tuner:smoke-verify-setup gate opt-in
      statusline-setup.md           # /cc-tuner:statusline-setup installer
    hooks/
      hooks.json                    # Stop hook registration
      smoke-verify-hook.sh          # the smoke-verify gate (fail-open bash)
    scripts/
      execute-task/                 # deterministic bash for /run gates (dir name predates the split)
      setup/doctor.sh               # environment checks behind /cc-tuner:setup
      smoke-verify/                 # fingerprint lib + attestation writer (mark.sh)
    skills/
      claude-md-writer/
        SKILL.md                    # corrected canonical skill
        reference.md                # deep examples + verified sources
      task-flow/
        SKILL.md                    # board recipes, merge strategies, plan lifecycle
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
