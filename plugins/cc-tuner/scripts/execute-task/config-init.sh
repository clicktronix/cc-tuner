#!/usr/bin/env bash
# Ensure .claude/execute-task.md exists; scaffold from the template if missing.
# usage: config-init.sh <template-path>
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "execute-task: cannot enter repo root '$ROOT'" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "execute-task: not a git repo at '$ROOT'" >&2; exit 1; }
TEMPLATE="${1:?usage: config-init.sh <template-path>}"
CFG=".claude/execute-task.md"
if [ -f "$CFG" ]; then
  echo "config exists: $CFG"
  exit 0
fi
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
mkdir -p .claude
cp "$TEMPLATE" "$CFG"
echo "config created: $CFG — edit it for this repo, then re-run /cc-tuner:execute-task"
