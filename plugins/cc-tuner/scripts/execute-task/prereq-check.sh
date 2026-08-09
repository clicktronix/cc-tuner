#!/usr/bin/env bash
# cc-tuner execute-task: verify the required plugins are installed.
# One anchor file per plugin is enough — a plugin's skills/commands ship as a unit.
# Exit 0 if both present; else 1 with install hints. Override cache root via
# CLAUDE_PLUGIN_CACHE (used by tests).
set -u
CACHE="${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins}"
missing=0

have() { compgen -G "$1" >/dev/null 2>&1; }  # quoted glob check — safe with spaces in the path

have_required_codex_review() {
  local review root manifest roots
  manifest="$CACHE/installed_plugins.json"
  if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
    roots="$(jq -r '.plugins["cc-codex-triage@cc-codex-triage"][]?.installPath // empty' "$manifest" 2>/dev/null)"
    if [ -n "$roots" ]; then
      while IFS= read -r root; do
        [ -n "$root" ] || continue
        review="$root/commands/review.md"
        if [ -f "$review" ] && [ -f "$root/scripts/review-state.sh" ] \
          && grep -qF -- '--required' "$review" \
          && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$review"; then
          return 0
        fi
      done <<EOF
$roots
EOF
      return 1
    fi
  fi
  for review in "$CACHE"/cache/*/cc-codex-triage/*/commands/review.md; do
    [ -f "$review" ] || continue
    root="${review%/commands/review.md}"
    if [ -f "$root/scripts/review-state.sh" ] \
      && grep -qF -- '--required' "$review" \
      && grep -qF -- 'CC_CODEX_REQUIRED_REVIEW APPROVE' "$review"; then
      return 0
    fi
  done
  return 1
}

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
if ! have "$CACHE/cache/*/mattpocock-skills/*/skills/engineering/domain-modeling/SKILL.md"; then
  echo "MISSING: mattpocock-skills domain-modeling skill (/spec vocabulary pass)" >&2
  echo "  install: /plugin install mattpocock-skills@mattpocock-skills (or update it — the skill moved)" >&2
  missing=1
fi
if ! have "$CACHE/cache/*/mattpocock-skills/*/skills/engineering/code-review/SKILL.md"; then
  echo "MISSING: mattpocock-skills code-review skill (run phase 4 review layer)" >&2
  echo "  install: /plugin install mattpocock-skills@mattpocock-skills (or update it — the skill moved)" >&2
  missing=1
fi
if ! have_required_codex_review; then
  echo "MISSING: cc-codex-triage required-review contract (--required + exact approval state)" >&2
  echo "  install/update: /plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage" >&2
  missing=1
fi

if [ "$missing" -eq 0 ]; then echo "prereqs OK"; else exit 1; fi
