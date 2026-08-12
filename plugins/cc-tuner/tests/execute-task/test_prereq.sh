#!/usr/bin/env bash
set -u
S="$(cd "$(dirname "$0")/../../scripts/execute-task" && pwd)/prereq-check.sh"
fails=0
# The gate and prereq-check both read $HOME/.claude/plugins, so a fixture installs by moving HOME
# rather than through a plugin-specific override — the whole point of the alignment.
mkroot() {
  FAKE_HOME="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  ROOT="$FAKE_HOME/.claude/plugins"
  mkdir -p "$ROOT" || { echo "FATAL: mkdir failed"; exit 1; }
}

MP="cache/mattpocock/mattpocock-skills/1.2.0/skills"
CCT="cache/cc-codex-triage/cc-codex-triage/0.6.0/commands"

# One list of the skill anchors the registry names, used by both the cache-layout and the
# active-install fixtures. Three copies of it meant adding a capability required editing all three.
MATT_SKILL_RELS="productivity/grilling
engineering/domain-modeling
engineering/code-review
engineering/tdd
engineering/diagnosing-bugs
engineering/research
engineering/prototype"

add_cap()         { mkdir -p "$ROOT/$MP/$1"; touch "$ROOT/$MP/$1/SKILL.md"; }
add_grilling()    { add_cap productivity/grilling; }
add_domain()      { add_cap engineering/domain-modeling; }
add_codereview()  { add_cap engineering/code-review; }
add_all_caps()    { for c in tdd diagnosing-bugs research prototype; do add_cap "engineering/$c"; done; }
add_codex() {
  mkdir -p "$ROOT/$CCT" "${ROOT}/${CCT%/commands}/scripts"
  printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$ROOT/$CCT/review.md"
  printf '%s\n' 'CC_CODEX_REQUIRED_REVIEW APPROVE' \
    > "${ROOT}/${CCT%/commands}/scripts/review-state.sh"
}
# A complete installation carries every capability the registry names. The manifest-resolution cases
# below assert exit 0, so an incomplete fixture would make them fail for a reason that has nothing to
# do with the resolution they exist to test.
add_active_matt() {
  root="$1"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$root/skills/$rel"; touch "$root/skills/$rel/SKILL.md"
  done <<EOF
$MATT_SKILL_RELS
EOF
}
add_active_codex() {
  root="$1"
  mkdir -p "$root/commands" "$root/scripts"
  printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$root/commands/review.md"
  printf '%s\n' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$root/scripts/review-state.sh"
}

# all present -> exit 0
mkroot; add_grilling; add_domain; add_codereview; add_all_caps; add_codex
HOME="$FAKE_HOME" bash "$S" >/dev/null 2>&1 \
  && echo "PASS all-present" || { echo "FAIL all-present"; fails=1; }
rm -rf "$ROOT"

# An existing manifest is authoritative for every dependency. Uninstalled plugins must not be
# resurrected from stale cache directories.
mkroot; add_grilling; add_domain; add_codereview; add_codex
printf '%s\n' '{"plugins":{}}' > "$ROOT/installed_plugins.json"
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'mattpocock-skills' \
  && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS active-manifest-does-not-fallback-to-stale-cache" \
  || { echo "FAIL active-manifest-does-not-fallback-to-stale-cache (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# A malformed manifest also fails closed instead of silently accepting whatever old cache remains.
mkroot; add_grilling; add_domain; add_codereview; add_codex
printf '%s\n' '{not-json' > "$ROOT/installed_plugins.json"
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'INVALID:' \
  && printf '%s' "$OUT" | grep -q 'mattpocock-skills' \
  && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS malformed-active-manifest-fails-closed" \
  || { echo "FAIL malformed-active-manifest-fails-closed (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# Active roots for both required plugins are accepted without consulting cache layout.
mkroot
ACTIVE_MATT="$ROOT/active-matt"; ACTIVE_CODEX="$ROOT/active-codex"
add_active_matt "$ACTIVE_MATT"; add_active_codex "$ACTIVE_CODEX"
jq -n --arg matt "$ACTIVE_MATT" --arg codex "$ACTIVE_CODEX" '{plugins:{
  "mattpocock-skills@mattpocock":[{scope:"user",installPath:$matt}],
  "cc-codex-triage@cc-codex-triage":[{scope:"user",installPath:$codex}]
}}' > "$ROOT/installed_plugins.json"
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'prereqs OK'; } \
  && echo "PASS active-manifest-roots-pass" \
  || { echo "FAIL active-manifest-roots-pass (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# Project/local installations are active only for their canonical project root.
mkroot
ACTIVE_MATT="$ROOT/active-matt"; ACTIVE_CODEX="$ROOT/active-codex"; PROJECT="$ROOT/project"
add_active_matt "$ACTIVE_MATT"; add_active_codex "$ACTIVE_CODEX"; mkdir -p "$PROJECT"
PROJECT="$(cd "$PROJECT" && pwd -P)"
jq -n --arg matt "$ACTIVE_MATT" --arg codex "$ACTIVE_CODEX" --arg project "$PROJECT" '{plugins:{
  "mattpocock-skills@mattpocock":[{scope:"project",projectPath:$project,installPath:$matt}],
  "cc-codex-triage@cc-codex-triage":[{scope:"local",projectPath:$project,installPath:$codex}]
}}' > "$ROOT/installed_plugins.json"
OUT="$(CLAUDE_PROJECT_DIR="$PROJECT" HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'prereqs OK'; } \
  && echo "PASS matching-project-scopes-pass" \
  || { echo "FAIL matching-project-scopes-pass (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# A valid installation scoped to another project is not active in this repository.
mkroot
ACTIVE_MATT="$ROOT/active-matt"; ACTIVE_CODEX="$ROOT/active-codex"; PROJECT="$ROOT/project"
add_active_matt "$ACTIVE_MATT"; add_active_codex "$ACTIVE_CODEX"; mkdir -p "$PROJECT"
jq -n --arg matt "$ACTIVE_MATT" --arg codex "$ACTIVE_CODEX" '{plugins:{
  "mattpocock-skills@mattpocock":[{scope:"project",projectPath:"/definitely/another/project",installPath:$matt}],
  "cc-codex-triage@cc-codex-triage":[{scope:"local",projectPath:"/definitely/another/project",installPath:$codex}]
}}' > "$ROOT/installed_plugins.json"
OUT="$(CLAUDE_PROJECT_DIR="$PROJECT" HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'mattpocock-skills' \
  && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS foreign-project-scopes-fail-closed" \
  || { echo "FAIL foreign-project-scopes-fail-closed (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# A command that advertises required review cannot compensate for stale machine state.
mkroot; add_grilling; add_domain; add_codereview; add_codex
printf '%s\n' 'legacy review state' > "${ROOT}/${CCT%/commands}/scripts/review-state.sh"
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q -- '--required'; } \
  && echo "PASS cct-required-state-missing" \
  || { echo "FAIL cct-required-state-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# mattpocock-skills missing entirely -> exit exactly 1, and the message names it
mkroot; add_codex
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'mattpocock-skills'; } \
  && echo "PASS mp-missing" || { echo "FAIL mp-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# grilling present but the code-review skill absent -> still exit 1. /run phase 4 needs it, and
# discovering that mid-way through an unattended run is the failure this check exists to prevent.
mkroot; add_grilling; add_codex
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'code-review'; } \
  && echo "PASS mp-codereview-missing" || { echo "FAIL mp-codereview-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# domain-modeling is invoked during /spec and must be present before the grilling starts.
mkroot; add_grilling; add_codereview; add_codex
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'domain-modeling'; } \
  && echo "PASS mp-domain-modeling-missing" || { echo "FAIL mp-domain-modeling-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# cc-codex-triage missing -> exit exactly 1
mkroot; add_grilling; add_domain; add_codereview
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS cct-missing" || { echo "FAIL cct-missing (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# An older installed command without the exact required-review contract fails before Phase 6.
mkroot; add_grilling; add_domain; add_codereview
mkdir -p "$ROOT/$CCT"
printf '%s\n' 'legacy review command' > "$ROOT/$CCT/review.md"
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
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
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q -- '--required'; } \
  && echo "PASS cct-active-version-authoritative" \
  || { echo "FAIL cct-active-version-authoritative (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# superpowers is NOT required any more: a cache with no superpowers at all must still pass.
# Requiring it blocked runs that never invoke it — the regression this guards against is someone
# re-adding the check because the plugin is still installed on their own machine.
mkroot; add_grilling; add_domain; add_codereview; add_all_caps; add_codex
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$OUT" | grep -qi 'superpowers'; } \
  && echo "PASS superpowers-not-required" || { echo "FAIL superpowers-not-required (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# --- capability profiles -------------------------------------------------------------------------
# A command must not refuse to start over a capability it never uses. `/spec` failing because a Phase
# 6 review skill moved sends the user to fix something unrelated to what they asked for.
mkroot; add_grilling; add_domain; add_all_caps            # no code-review, no codex
HOME="$FAKE_HOME" bash "$S" --profile spec >/dev/null 2>&1 \
  && echo "PASS profile-spec-ignores-run-capabilities" \
  || { echo "FAIL profile-spec-ignores-run-capabilities"; fails=1; }
rm -rf "$ROOT"

# but a capability the profile DOES use is named exactly
mkroot; add_domain; add_all_caps; add_codereview; add_codex   # no grilling
OUT="$(HOME="$FAKE_HOME" bash "$S" --profile spec 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'grilling'; } \
  && echo "PASS profile-spec-names-the-missing-capability" \
  || { echo "FAIL profile-spec-names-the-missing-capability (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# A conditional method is not a precondition of starting anything; it is verified at the moment it is
# applied. Both halves are one guarantee, so both are asserted on one fixture.
mkroot; add_grilling; add_domain; add_codereview; add_codex
for c in tdd diagnosing-bugs research; do add_cap "engineering/$c"; done   # prototype absent
HOME="$FAKE_HOME" bash "$S" --profile spec >/dev/null 2>&1 \
  && HOME="$FAKE_HOME" bash "$S" --profile run >/dev/null 2>&1 \
  && echo "PASS conditional-absence-does-not-break-a-profile" \
  || { echo "FAIL conditional-absence-does-not-break-a-profile"; fails=1; }
OUT="$(HOME="$FAKE_HOME" bash "$S" --capability prototype 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'prototype'; } \
  && echo "PASS capability-check-names-the-conditional" \
  || { echo "FAIL capability-check-names-the-conditional (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# The Codex required-review contract belongs to the run profile, not to every command.
mkroot; add_grilling; add_domain; add_codereview; add_all_caps   # no codex
OUT="$(HOME="$FAKE_HOME" bash "$S" --profile run 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'cc-codex-triage'; } \
  && echo "PASS profile-run-requires-the-codex-contract" \
  || { echo "FAIL profile-run-requires-the-codex-contract (rc=$rc out=$OUT)"; fails=1; }
HOME="$FAKE_HOME" bash "$S" --profile spec >/dev/null 2>&1 \
  && echo "PASS profile-spec-does-not-require-the-codex-contract" \
  || { echo "FAIL profile-spec-does-not-require-the-codex-contract"; fails=1; }
rm -rf "$ROOT"

# No flags is doctor's view: everything recommended, conditionals included.
mkroot; add_grilling; add_domain; add_codereview; add_codex
for c in tdd diagnosing-bugs prototype; do add_cap "engineering/$c"; done    # research absent
OUT="$(HOME="$FAKE_HOME" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$OUT" | grep -q 'research'; } \
  && echo "PASS default-checks-every-recommended-capability" \
  || { echo "FAIL default-checks-every-recommended-capability (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$ROOT"

# An unknown profile or capability is a usage error. Treating it as "nothing to check" would let a
# typo in a command file silently disable that command's prerequisites. No fixture: argument parsing
# rejects these before anything on disk is consulted, and installing skills here would suggest the
# outcome depended on them.
mkroot
HOME="$FAKE_HOME" bash "$S" --profile nonsense >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] \
  && echo "PASS unknown-profile-is-a-usage-error" \
  || { echo "FAIL unknown-profile-is-a-usage-error (rc=$rc)"; fails=1; }
HOME="$FAKE_HOME" bash "$S" --capability nonsense >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] \
  && echo "PASS unknown-capability-is-a-usage-error" \
  || { echo "FAIL unknown-capability-is-a-usage-error (rc=$rc)"; fails=1; }
rm -rf "$ROOT"

exit $fails
