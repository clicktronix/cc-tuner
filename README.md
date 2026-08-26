# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

Skills:

- **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.
- **`statusline`** — a usage-focused statusline (rate-limit 5h/7d windows, context %, git, model + effort, session duration) with a `/cc-tuner:statusline-setup` installer, since plugins can't register a statusline on their own.
- **`smoke-verify`** — not a skill: an opt-in Stop-hook gate (`/cc-tuner:smoke-verify-setup`). Frontend changes can't end a turn until they were exercised for real and attested with evidence. The whole standard lives in the block message the agent actually receives, rather than in a skill it has to choose to load.
- **`task-flow`** — canonical branch/commit/PR/board/plan conventions: on-demand procedures in the skill, plus a `/cc-tuner:task-flow-setup` installer that writes the always-on `.claude/rules/task-flow.md` into a repo from a versioned template, since plugins can't ship rules files either.

Start with **`/cc-tuner:setup`** — it checks the environment the other commands assume (CLI tools, the `gh` token's `project` scope, companion plugins, optionally MCP servers) and then runs only the installers this repo needs. `check` reports, `install` acts.

The task loop has two commands: **`/cc-tuner:spec`** does the discovery, creates the task branch, confirms the contract and vertical slices once, then commits the spec and plan and publishes the slices as native tasks when those tools are available; **`/cc-tuner:run [--auto] <spec>`** works that plan through implementation, PR, review, CI, and merge. Without `--auto`, run stops at delivery boundaries; with it, an explicitly auto-ready spec runs unattended through a green merge, never through deploy or publish.


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
      task-flow/rule.template.md        # canonical .claude/rules/task-flow.md template
      smoke-verify/config.template.cfg  # per-repo smoke-verify opt-in config
    skills/
      run/SKILL.md                  # /cc-tuner:run [--auto] <spec> executor
      spec/SKILL.md                 # /cc-tuner:spec writes the contract and sliced execution plan
      spec/spec-template.md         # executable spec contract filled by /cc-tuner:spec
      spec/plan-template.md         # plan grammar filled by /cc-tuner:spec
      setup/SKILL.md                # /cc-tuner:setup env check + installer orchestration
    hooks/
      hooks.json                    # SessionStart + Stop registrations
      session-start.sh              # asks a fresh session to rebuild its task list from the plan
      smoke-verify-hook.sh          # the smoke-verify gate (fail-open bash)
    scripts/
      merge.sh                      # the only checked merge path: verdict + required CI on the head SHA
      mutate.sh                     # one mutation, graded by the program: no-op and syntax refusals, verified restore
      plan-lint.sh                  # the plan format's validator, and the parser the hook reads it with
      plan-path.sh                  # the one branch -> plan-path resolver
      setup/doctor.sh               # environment checks behind /cc-tuner:setup
      setup/prereq-check.sh         # companion plugins installed, enabled, and carrying their contracts
      setup/plugin-here.sh          # which install of a plugin applies to this repo (one rule, two callers)
      smoke-verify/                 # fingerprint lib + attestation writer (mark.sh)
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
