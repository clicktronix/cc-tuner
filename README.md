# cc-tuner

A Claude Code plugin marketplace for **tuning Claude Code's own configuration** — skills that write and audit Claude Code's config files against the official docs, installed once instead of copied per project.

First skill: **`claude-md-writer`** — create, refactor, and audit `CLAUDE.md` / `.claude/rules/` memory files, every Claude Code memory fact checked against <https://code.claude.com/docs/en/memory>.

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
    skills/
      claude-md-writer/
        SKILL.md                    # corrected canonical skill
        reference.md                # deep examples + verified sources
CHANGELOG.md
LICENSE                             # MIT
```

## License

MIT.
