# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

Skills:

- **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.
- **`statusline`** — a usage-focused statusline (rate-limit 5h/7d windows, context %, git, model + effort, session duration) with a `/cc-tuner:statusline-setup` installer, since plugins can't register a statusline on their own.
- **`git-flow`** — canonical branch/commit/PR/board/plan conventions: on-demand procedures in the skill, plus a `/cc-tuner:git-flow-setup` installer that writes the always-on `.claude/rules/git-flow.md` into a repo from a versioned template, since plugins can't ship rules files either.

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
      execute-task/config.template.md   # per-project /execute-task settings
      git-flow/rule.template.md         # canonical .claude/rules/git-flow.md template
    commands/
      execute-task.md               # /cc-tuner:execute-task lifecycle playbook
      git-flow-setup.md             # /cc-tuner:git-flow-setup rule installer
      statusline-setup.md           # /cc-tuner:statusline-setup installer
    scripts/
      execute-task/                 # deterministic bash for /execute-task gates
    skills/
      claude-md-writer/
        SKILL.md                    # corrected canonical skill
        reference.md                # deep examples + verified sources
      git-flow/
        SKILL.md                    # board recipes, merge strategies, plan lifecycle
      statusline/
        SKILL.md                    # usage statusline (feature + disclaimers)
        statusline.sh               # the cross-platform statusline script
docs/superpowers/specs/             # design records
tests/scenarios/                    # eval scenarios (RED/GREEN baselines)
CHANGELOG.md
LICENSE                             # MIT
```

## License

MIT.
