#!/usr/bin/env bash
# cc-tuner execute-task: verify the required plugins are installed.
# One anchor file per plugin is enough — a plugin's skills/commands ship as a unit.
# Exit 0 if both present; else 1 with install hints. Override cache root via
# CLAUDE_PLUGIN_CACHE (used by tests).
set -u
CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins}"
missing=0

have() { compgen -G "$1" >/dev/null 2>&1; }  # quoted glob check — safe with spaces in the path

if ! have "$CACHE/cache/*/superpowers/*/skills/brainstorming/SKILL.md"; then
  echo "MISSING: superpowers (skills: brainstorming, writing-plans, subagent-driven-development, requesting-code-review)" >&2
  echo "  install: /plugin install superpowers@superpowers-marketplace" >&2
  missing=1
fi
if ! have "$CACHE/cache/*/cc-codex-triage/*/commands/review.md"; then
  echo "MISSING: cc-codex-triage (commands: /plan, /review)" >&2
  echo "  install: /plugin marketplace add clicktronix/cc-codex-triage && /plugin install cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
