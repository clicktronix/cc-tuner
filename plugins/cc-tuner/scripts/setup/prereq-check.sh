#!/usr/bin/env bash
# Are the companion plugins this flow depends on installed, enabled, and carrying the contracts it
# needs? Exit 0 if so; otherwise 1, naming each miss with the command that fixes it.
#
# This is a setup-time capability check, and it lives beside doctor.sh because that is what it is. It
# spent its life under scripts/execute-task/ as part of a run-state machine that no longer exists,
# and kept that address and an `execute_task_` prefix after everything around it was deleted -- a
# directory named for a subsystem that is gone is a wrong answer to "where does this belong".
#
# Which installation applies is asked once, of scripts/setup/plugin-here.sh, which doctor.sh also
# uses. It used to be asked twice: doctor read `claude plugin list --json`, this script parsed
# `~/.claude/plugins/installed_plugins.json` by hand, and the two answers had already diverged --
# doctor skipped `enabled: false`, this did not, so a disabled plugin passed the preflight and then
# failed to load the very command the run depends on.
#
# Presence is not the whole question. `plugin-here.sh` answers "installed and enabled for this repo";
# the content checks below answer "and does that copy implement the contract", which no version
# number can. Declarative plugin dependencies in plugin.json would replace the first half once the
# upstream repositories tag releases as {plugin-name}--v{version} -- measured on 2026-08-14, neither
# cc-codex-triage (no tags at all) nor mattpocock/skills (v1.2.3) publishes them.
#
# bash 3.2 compatible: macOS ships 3.2.57.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_HERE="$HERE/plugin-here.sh"
missing=0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null \
  || (CDPATH='' cd -- "$PROJECT_ROOT" 2>/dev/null && pwd -P) || true)"

# roots <plugin-id> -> install paths, best first. rc=2 means the question could not be answered,
# which is reported as its own failure rather than as "not installed": telling someone to reinstall a
# plugin they already have, because `jq` is missing, sends them to fix the wrong thing.
roots() { bash "$PLUGIN_HERE" "$1" "$PROJECT_ROOT" 2>/dev/null; }

UNANSWERABLE=""
roots 'cc-tuner@cc-tuner' >/dev/null 2>&1
[ $? -ne 2 ] || UNANSWERABLE=1
if [ -n "$UNANSWERABLE" ]; then
  echo "MISSING: cannot list installed plugins, so the prerequisites are unknown" >&2
  echo "  needs: jq, and a 'claude' on PATH (or CC_TUNER_PLUGIN_LIST_CMD)" >&2
  exit 1
fi

# root_of <plugin-id> -- the install path that applies here, or empty.
#
# One install, never a search across several. An earlier version looped over every applicable root
# and passed if a file turned up in any of them, which reported `prereqs OK` for a `local` install
# missing the code-review skill because a `user` install two rows down still had it. Only the top
# install loads, so a check satisfied by a lower one is checking files nothing will read.
root_of() { roots "$1" | cut -f1; }

# has_file <plugin-id> <relative path> -- does the applicable install carry this file?
has_file() {
  local root; root="$(root_of "$1")"
  [ -n "$root" ] && [ -f "$root/$2" ]
}

# The required-review contract, not merely the plugin: an installed cc-codex-triage predating it
# would satisfy "is it there" and still be unable to answer for a delivery gate.
codex_contract() {
  local root review state
  root="$(root_of 'cc-codex-triage@cc-codex-triage')"
  [ -n "$root" ] || return 1
  review="$root/commands/review.md"; state="$root/scripts/review-state.sh"
  [ -f "$review" ] && [ -f "$state" ] \
    && grep -qF -- '--required' "$review" \
    && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$review" \
    && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$state"
}

# mattpocock-skills: /cc-tuner:spec grills with `grilling` + `domain-modeling`, and /cc-tuner:run
# Phase 6 runs `/mattpocock-skills:code-review`. This replaced the old superpowers requirement, which
# gated skills that neither command invokes any more — blocking runs that did not need it while
# letting the dependency they DO need go unchecked until Phase 6 of an unattended run.
MP_INSTALL='/plugin marketplace add mattpocock/skills && /plugin install mattpocock-skills@mattpocock'
if ! has_file 'mattpocock-skills@mattpocock' 'skills/productivity/grilling/SKILL.md'; then
  echo "MISSING: mattpocock-skills (skills: grilling, domain-modeling, code-review)" >&2
  echo "  install: $MP_INSTALL" >&2
  missing=1
fi
if ! has_file 'mattpocock-skills@mattpocock' 'skills/engineering/domain-modeling/SKILL.md'; then
  echo "MISSING: mattpocock-skills domain-modeling skill (/spec vocabulary pass)" >&2
  echo "  install: $MP_INSTALL (or update it — the skill moved)" >&2
  missing=1
fi
if ! has_file 'mattpocock-skills@mattpocock' 'skills/engineering/code-review/SKILL.md'; then
  echo "MISSING: mattpocock-skills code-review skill (run Phase 6 review layer)" >&2
  echo "  install: $MP_INSTALL (or update it — the skill moved)" >&2
  missing=1
fi
if ! codex_contract; then
  echo "MISSING: cc-codex-triage required-review contract (--required + exact approval state)" >&2
  echo "  install/update: /plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
