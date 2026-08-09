#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/prereq-check.sh"
fails=0
mkroot() { ROOT="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }; }  # fake plugin cache root

MP="cache/mattpocock/mattpocock-skills/1.2.0/skills"
CCT="cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"

add_grilling()    { mkdir -p "$ROOT/$MP/productivity/grilling";   touch "$ROOT/$MP/productivity/grilling/SKILL.md"; }
add_domain()      { mkdir -p "$ROOT/$MP/engineering/domain-modeling"; touch "$ROOT/$MP/engineering/domain-modeling/SKILL.md"; }
add_codereview()  { mkdir -p "$ROOT/$MP/engineering/code-review"; touch "$ROOT/$MP/engineering/code-review/SKILL.md"; }
add_codex() {
  mkdir -p "$ROOT/$CCT" "${ROOT}/${CCT%/commands}/scripts"
  printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$ROOT/$CCT/review.md"
  printf '%s\n' 'CC_CODEX_REQUIRED_REVIEW APPROVE' \
    > "${ROOT}/${CCT%/commands}/scripts/review-state.sh"
}

# all present -> exit 0
mkroot; add_grilling; add_domain; add_codereview; add_codex
CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" >/dev/null 2>&1 \
  && echo "PASS all-present" || { echo "FAIL all-present"; fails=1; }
rm -rf "$ROOT"

# A command that advertises required review cannot compensate for stale machine state.
mkroot; add_grilling; add_domain; add_codereview; add_codex
printf '%s\n' 'legacy review state' > "${ROOT}/${CCT%/commands}/scripts/review-state.sh"
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q -- '--required'; } \
  && echo "PASS cct-required-state-missing" \
  || { echo "FAIL cct-required-state-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# mattpocock-skills missing entirely -> exit exactly 1, and the message names it
mkroot; add_codex
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'mattpocock-skills'; } \
  && echo "PASS mp-missing" || { echo "FAIL mp-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# grilling present but the code-review skill absent -> still exit 1. /run phase 4 needs it, and
# discovering that mid-way through an unattended run is the failure this check exists to prevent.
mkroot; add_grilling; add_codex
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'code-review'; } \
  && echo "PASS mp-codereview-missing" || { echo "FAIL mp-codereview-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# domain-modeling is invoked during /spec and must be present before the grilling starts.
mkroot; add_grilling; add_codereview; add_codex
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'domain-modeling'; } \
  && echo "PASS mp-domain-modeling-missing" || { echo "FAIL mp-domain-modeling-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# cc-codex-triage missing -> exit exactly 1
mkroot; add_grilling; add_domain; add_codereview
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS cct-missing" || { echo "FAIL cct-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# An older installed command without the exact required-review contract fails before Phase 6.
mkroot; add_grilling; add_domain; add_codereview
mkdir -p "$ROOT/$CCT"
printf '%s\n' 'legacy review command' > "$ROOT/$CCT/review.md"
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q -- '--required'; } \
  && echo "PASS cct-required-review-missing" \
  || { echo "FAIL cct-required-review-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# Stale cache entries do not override the version selected by installed_plugins.json.
mkroot; add_grilling; add_domain; add_codereview; add_codex
ACTIVE="$ROOT/active-old"
mkdir -p "$ACTIVE/commands"
printf '%s\n' 'legacy review command' > "$ACTIVE/commands/review.md"
jq -n --arg path "$ACTIVE" \
  '{plugins:{"cc-codex-triage@cc-codex-triage":[{installPath:$path}]}}' \
  > "$ROOT/installed_plugins.json"
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q -- '--required'; } \
  && echo "PASS cct-active-version-authoritative" \
  || { echo "FAIL cct-active-version-authoritative (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# superpowers is NOT required any more: a cache with no superpowers at all must still pass.
# Requiring it blocked runs that never invoke it — the regression this guards against is someone
# re-adding the check because the plugin is still installed on their own machine.
mkroot; add_grilling; add_domain; add_codereview; add_codex
OUT="$(CLAUDE_PLUGIN_CACHE="$ROOT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'superpowers'; } \
  && echo "PASS superpowers-not-required" || { echo "FAIL superpowers-not-required (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

exit $fails
