#!/usr/bin/env bash
# cc-tuner execute-task: verify the required plugins are installed.
# One anchor file per plugin is enough — a plugin's skills/commands ship as a unit.
# Exit 0 if both present; else 1 with install hints. The plugin root is the same fixed location the
# delivery gate resolves (lib.sh): a preflight that could be pointed elsewhere cannot promise the
# gate will find the installation it just approved. Tests move HOME, as the gate's tests do.
set -u
CACHE="$HOME/.claude/plugins"
missing=0
MANIFEST="$CACHE/installed_plugins.json"
MANIFEST_MODE="cache"
PROJECT_START="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT_ROOT="$(git -C "$PROJECT_START" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(cd "$PROJECT_START" 2>/dev/null && pwd -P || true)"
elif ! PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)"; then
  PROJECT_ROOT=""
fi

have() { compgen -G "$1" >/dev/null 2>&1; }  # quoted glob check — safe with spaces in the path

# Once Claude Code publishes an installed-plugin manifest it is the authority for the active
# version. Falling back to old cache directories when an active key is missing makes an uninstalled
# plugin look available. Cache discovery remains only for older installations without a manifest.
if [ -e "$MANIFEST" ]; then
  if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1 \
    && jq -e '.plugins | type == "object"' "$MANIFEST" >/dev/null 2>&1; then
    MANIFEST_MODE="active"
  else
    MANIFEST_MODE="invalid"
    echo "INVALID: $MANIFEST is present but is not a readable installed-plugin manifest" >&2
  fi
fi

# The selection rule lives in lib.sh, shared with the required-review verifier: this script and that
# gate must agree on which installation is active, and a second copy of the filter is how they would
# stop agreeing.
#
# An earlier revision inlined it here, reasoning that lib.sh is deleted in Task 9. That was premature:
# lib.sh still ships and is still sourced by five other files, so the inline created a live second
# copy of one rule -- the thing this repository forbids -- to avoid work that has not happened yet.
# Migration before deletion licenses postponing the delete, not duplicating the rule.
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

manifest_roots() {
  local manifest="$1" key="$2" project="$3"
  [ -f "$manifest" ] && [ -n "$project" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.plugins | type == "object"' "$manifest" >/dev/null 2>&1 || return 1
  jq -r --arg key "$key" --arg project "$project" '
    .plugins[$key] // [] |
    if type == "array" then
      [ .[]? | select(
          .scope == "user" or
          ((.scope == "project" or .scope == "local") and .projectPath == $project)
        ) ]
      | sort_by(if .scope == "local" then 0 elif .scope == "project" then 1 else 2 end)
      | .[] | .installPath // empty
    else empty end
  ' "$manifest" 2>/dev/null
}

execute_task_codex_root_qualifies() {
  local root="$1" review="$1/commands/review.md" state="$1/scripts/review-state.sh"
  [ -f "$review" ] && [ -f "$state" ] \
    && grep -qF -- '--required' "$review" \
    && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$review" \
    && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$state"
}

manifest_roots() {
  [ "$MANIFEST_MODE" = "active" ] || return 1
  execute_task_manifest_roots "$MANIFEST" "$1" "$PROJECT_ROOT"
}

have_matt_skill() {
  local relative="$1" root roots
  case "$MANIFEST_MODE" in
    active)
      roots="$(manifest_roots 'mattpocock-skills@mattpocock')"
      [ -n "$roots" ] || return 1
      while IFS= read -r root; do
        [ -n "$root" ] && [ -f "$root/$relative" ] && return 0
      done <<EOF
$roots
EOF
      return 1
      ;;
    invalid) return 1 ;;
    cache) have "$CACHE/cache/*/mattpocock-skills/*/$relative" ;;
  esac
}

have_required_codex_review() {
  local root roots
  # Same predicate the delivery gate applies (lib.sh): preflight passing on an installation the gate
  # then refuses — or approving from one preflight never saw — is the divergence this check exists
  # to prevent.
  if [ "$MANIFEST_MODE" = "active" ]; then
    roots="$(manifest_roots 'cc-codex-triage@cc-codex-triage')"
    [ -n "$roots" ] || return 1
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      execute_task_codex_root_qualifies "$root" && return 0
    done <<EOF
$roots
EOF
    return 1
  fi
  [ "$MANIFEST_MODE" = "cache" ] || return 1
  for root in "$CACHE"/cache/*/cc-codex-triage/*; do
    execute_task_codex_root_qualifies "$root" && return 0
  done
  return 1
}

# mattpocock-skills: /cc-tuner:spec grills with `grilling` + `domain-modeling`, and /cc-tuner:run
# Phase 6 runs `/mattpocock-skills:code-review`. This replaced the old superpowers requirement, which
# gated skills (brainstorming, writing-plans, subagent-driven-development, requesting-code-review)
# that neither command invokes any more — blocking runs that did not need it while letting the
# dependency they DO need go unchecked until Phase 6 of an unattended run.
if ! have_matt_skill "skills/productivity/grilling/SKILL.md"; then
  echo "MISSING: mattpocock-skills (skills: grilling, domain-modeling, code-review)" >&2
  echo "  install: /plugin marketplace add mattpocock/skills && /plugin install mattpocock-skills@mattpocock" >&2
  missing=1
fi
if ! have_matt_skill "skills/engineering/domain-modeling/SKILL.md"; then
  echo "MISSING: mattpocock-skills domain-modeling skill (/spec vocabulary pass)" >&2
  echo "  install: /plugin install mattpocock-skills@mattpocock (or update it — the skill moved)" >&2
  missing=1
fi
if ! have_matt_skill "skills/engineering/code-review/SKILL.md"; then
  echo "MISSING: mattpocock-skills code-review skill (run Phase 6 review layer)" >&2
  echo "  install: /plugin install mattpocock-skills@mattpocock (or update it — the skill moved)" >&2
  missing=1
fi
if ! have_required_codex_review; then
  echo "MISSING: cc-codex-triage required-review contract (--required + exact approval state)" >&2
  echo "  install/update: /plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
