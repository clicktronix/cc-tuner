#!/usr/bin/env bash
# cc-tuner execute-task: verify the required plugins are installed.
# One anchor file per plugin is enough — a plugin's skills/commands ship as a unit.
# Exit 0 if both present; else 1 with install hints. Override cache root via
# CLAUDE_PLUGIN_CACHE (used by tests).
set -u
CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins}"
missing=0

have() { compgen -G "$1" >/dev/null 2>&1; }  # quoted glob check — safe with spaces in the path

# mattpocock-skills: /cc-tuner:spec grills with `grilling` + `domain-modeling`, and /cc-tuner:run
# phase 4 runs `/mattpocock-skills:code-review`. This replaced the old superpowers requirement, which
# gated skills (brainstorming, writing-plans, subagent-driven-development, requesting-code-review)
# that neither command invokes any more — blocking runs that did not need it while letting the
# dependency they DO need go unchecked until phase 4 of an unattended run.
if ! have "$CACHE/cache/*/mattpocock-skills/*/skills/productivity/grilling/SKILL.md"; then
  echo "MISSING: mattpocock-skills (skills: grilling, domain-modeling, code-review)" >&2
  echo "  install: /plugin marketplace add mattpocock/mattpocock-skills && /plugin install mattpocock-skills@mattpocock-skills" >&2
  missing=1
fi
if ! have "$CACHE/cache/*/mattpocock-skills/*/skills/engineering/code-review/SKILL.md"; then
  echo "MISSING: mattpocock-skills code-review skill (run phase 4 review layer)" >&2
  echo "  install: /plugin install mattpocock-skills@mattpocock-skills (or update it — the skill moved)" >&2
  missing=1
fi
if ! have "$CACHE/cache/*/cc-codex-triage/*/commands/review.md"; then
  echo "MISSING: cc-codex-triage (commands: /plan, /review)" >&2
  echo "  install: /plugin marketplace add clicktronix/cc-codex-triage && /plugin install cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
