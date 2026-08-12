#!/usr/bin/env bash
# cc-tuner execute-task: verify the capabilities a command actually uses are installed.
# Exit 0 when satisfied, 1 with install hints when something required is missing, 2 on usage error.
# The plugin root is the same fixed location the delivery gate resolves (lib.sh): a preflight that
# could be pointed elsewhere cannot promise the gate will find the installation it just approved.
# Tests move HOME, as the gate's tests do.
#
# Scope is the point. A single flat list made `/spec` refuse to start because a skill only Phase 6
# needs had moved upstream — an unrelated capability failing a command that never calls it.
#   --profile spec|run   what that command needs before it starts
#   --capability <name>  one capability, checked at the moment it is about to be applied
#   (no flags)           every recommended capability — doctor's view
set -u

# The single list of capabilities cc-tuner names by hand: capability|scope|kind|anchor|what needs it.
# `conditional` is a method used only when the situation calls for it, so it belongs to no profile and
# is verified immediately before use. `kind` keeps the Codex required-review contract a row rather
# than a hand-written exception: an exception is the second list this table exists to remove, and it
# would be the one place membership could silently disagree with the rest.
CAPABILITIES="
grilling|spec|skill|skills/productivity/grilling/SKILL.md|/spec grills the requirements
domain-modeling|spec|skill|skills/engineering/domain-modeling/SKILL.md|/spec pins vocabulary and writes the ADR
tdd|run|skill|skills/engineering/tdd/SKILL.md|/run picks the seam the first failing check binds to
code-review|run|skill|skills/engineering/code-review/SKILL.md|/run Phase 6 reviews the candidate
codex-required-review|run|codex-contract|-|/run verifies an exact-candidate approval before merge
diagnosing-bugs|conditional|skill|skills/engineering/diagnosing-bugs/SKILL.md|/spec reproduces a reported defect
research|conditional|skill|skills/engineering/research/SKILL.md|/spec sources an external fact
prototype|conditional|skill|skills/engineering/prototype/SKILL.md|/spec settles a contested model
"

# Profiles and capability names are read from the table, so a typo is a usage error instead of a
# silently empty check set — a command whose prerequisites quietly resolve to nothing is worse than
# one that will not start.
registry_has() {  # <field-number> <value>
  printf '%s\n' "$CAPABILITIES" \
    | awk -F'|' -v n="$1" -v v="$2" '$n == v { found = 1 } END { exit !found }'
}

PROFILE=""
CAPABILITY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile requires a value" >&2; exit 2; }
      [ "$2" != conditional ] && registry_has 2 "$2" \
        || { echo "unknown profile '$2'" >&2; exit 2; }
      PROFILE="$2"; shift ;;
    --capability)
      [ "$#" -ge 2 ] || { echo "--capability requires a value" >&2; exit 2; }
      registry_has 1 "$2" || { echo "unknown capability '$2'" >&2; exit 2; }
      CAPABILITY="$2"; shift ;;
    *) echo "usage: prereq-check.sh [--profile spec|run] [--capability <name>]" >&2; exit 2 ;;
  esac
  shift
done

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

# The selection rule itself lives in lib.sh, shared with the required-review verifier: this script
# and that gate must agree on which installation is active, and a second copy of the filter is how
# they would stop agreeing.
# shellcheck source=lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

manifest_roots() {
  [ "$MANIFEST_MODE" = "active" ] || return 1
  execute_task_manifest_roots "$MANIFEST" "$1" "$PROJECT_ROOT"
}

# Resolved once. The roots do not change between capabilities, and resolving per capability meant two
# jq processes each over the same manifest — seven capabilities paid fourteen spawns to compute one
# identical answer.
MATT_ROOTS=""
[ "$MANIFEST_MODE" = "active" ] && MATT_ROOTS="$(manifest_roots 'mattpocock-skills@mattpocock')"

have_matt_skill() {
  local relative="$1" root
  case "$MANIFEST_MODE" in
    active)
      [ -n "$MATT_ROOTS" ] || return 1
      while IFS= read -r root; do
        [ -n "$root" ] && [ -f "$root/$relative" ] && return 0
      done <<EOF
$MATT_ROOTS
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

# One pass over the registry, membership decided by the table for every row including the Codex
# contract. A skill capability is checked per anchor file rather than once per plugin because the
# plugin ships them as a unit: a single missing anchor means upstream MOVED that skill, and a phase
# that silently proceeds without its method is the failure this names.
while IFS='|' read -r cap scope kind rel need; do
  [ -n "$cap" ] || continue
  if [ -n "$CAPABILITY" ]; then
    [ "$cap" = "$CAPABILITY" ] || continue
  elif [ -n "$PROFILE" ]; then
    [ "$scope" = "$PROFILE" ] || continue
  fi
  case "$kind" in
    skill)
      have_matt_skill "$rel" && continue
      echo "MISSING: mattpocock-skills capability '$cap' — $need" >&2
      echo "  install/update: /plugin marketplace add mattpocock/skills && /plugin install mattpocock-skills@mattpocock" >&2
      ;;
    codex-contract)
      have_required_codex_review && continue
      echo "MISSING: cc-codex-triage required-review contract (--required + exact approval state) — $need" >&2
      echo "  install/update: /plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage" >&2
      ;;
    *) echo "INVALID: capability '$cap' has unknown kind '$kind'" >&2 ;;
  esac
  missing=1
done <<EOF
$CAPABILITIES
EOF

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
