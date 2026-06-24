#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/prereq-check.sh"
fails=0
mkroot() { ROOT="$(mktemp -d)"; }  # fake plugin cache root

# both present -> exit 0
mkroot
mkdir -p "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming"
touch    "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming/SKILL.md"
mkdir -p "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"
touch    "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands/review.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1 \
  && echo "PASS both-present" || { echo "FAIL both-present"; fails=1; }
rm -rf "$ROOT"

# superpowers missing -> exit exactly 1
mkroot
mkdir -p "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"
touch    "$ROOT/cache/cc-codex-triage/cc-codex-triage/0.6.0/commands/review.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS sp-missing" || { echo "FAIL sp-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$ROOT"

# cc-codex-triage missing -> exit exactly 1
mkroot
mkdir -p "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming"
touch    "$ROOT/cache/superpowers-marketplace/superpowers/5.1.0/skills/brainstorming/SKILL.md"
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && echo "PASS cct-missing" || { echo "FAIL cct-missing (rc=$rc, want 1)"; fails=1; }
rm -rf "$ROOT"

exit $fails
