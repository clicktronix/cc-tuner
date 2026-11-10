#!/usr/bin/env bash
# The command that installs a plugin which is not installed.
#
#   install-hint.sh <marketplace> <marketplace-source> <plugin-id>
#
# Prints `/plugin install <id>` when the marketplace is already configured, otherwise
# `/plugin marketplace add <source> && /plugin install <id>`. `marketplace update` and `plugin update`
# presuppose both, so offering them to someone with neither fails naming a marketplace they never
# added. An unreadable marketplace list counts as "not configured": the add step is the safe one to
# repeat.
#
# One program with two callers, doctor.sh and prereq-check.sh, for the reason plugin-here.sh is one:
# two copies of the same answer have already drifted apart once.
#
# CC_TUNER_MARKETPLACE_LIST_CMD overrides the source command, which is how the tests install a fixture.
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

[ "$#" -eq 3 ] || { printf 'install-hint: usage: install-hint.sh <marketplace> <source> <plugin-id>\n' >&2; exit 2; }

MKTS="$(${CC_TUNER_MARKETPLACE_LIST_CMD:-claude plugin marketplace list --json} 2>/dev/null)" || MKTS=""
if printf '%s' "$MKTS" | jq -e --arg n "$1" 'any(.[]?; .name == $n)' >/dev/null 2>&1; then
  printf '/plugin install %s\n' "$3"
else
  printf '/plugin marketplace add %s && /plugin install %s\n' "$2" "$3"
fi
