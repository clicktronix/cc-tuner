#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "$0")/../../hooks" && pwd)/smoke-verify-hook.sh"
MARK="$(cd "$(dirname "$0")/../../scripts/smoke-verify" && pwd)/mark.sh"
fails=0

mkrepo() { # fixture: git repo with a committed base file
  T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  ( cd "$T" && git init -q -b main && git config user.email a@b.c && git config user.name t \
    && echo base > app.py && git add app.py && git commit -qm init ) \
    || { echo "FATAL: fixture setup failed"; exit 1; }
}
cfg() { mkdir -p "$T/.claude"; printf 'patterns=%s\ncap=%s\n' "${1:-\\.(tsx|jsx|css)\$}" "${2:-3}" > "$T/.claude/smoke-verify.cfg"; }
run_hook() { ( cd "$T" && echo '{}' | bash "$HOOK" ); }

# no config -> allow (no output, exit 0)
mkrepo
OUT="$(run_hook)"; rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } && echo "PASS no-config-allows" || { echo "FAIL no-config-allows (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$T"

# config + only non-matching change -> allow
mkrepo; cfg
( cd "$T" && echo change >> app.py )
OUT="$(run_hook)"; rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } && echo "PASS non-fe-change-allows" || { echo "FAIL non-fe-change-allows (out=$OUT)"; fails=1; }
rm -rf "$T"

# matched untracked file -> block with round 1
mkrepo; cfg
echo '<div/>' > "$T/Comp.tsx"
OUT="$(run_hook)"; rc=$?
{ [ $rc -eq 0 ] && printf '%s' "$OUT" | grep -q '"decision":"block"' && printf '%s' "$OUT" | grep -q 'round default 1/3'; } \
  && echo "PASS fe-change-blocks" || { echo "FAIL fe-change-blocks (out=$OUT)"; fails=1; }

# the block text must carry the standard itself, not a pointer to a skill. The DOES NOT COUNT list
# is the load-bearing half: the gate exists to reject static checks as proof, so an agent that only
# reads the block message still has to be told that a green typecheck is not evidence.
{ printf '%s' "$OUT" | grep -q 'DOES NOT COUNT' \
  && printf '%s' "$OUT" | grep -q 'typecheck' \
  && printf '%s' "$OUT" | grep -q 'already green' \
  && printf '%s' "$OUT" | grep -q 'ATTEST BEFORE COMMITTING' \
  && printf '%s' "$OUT" | grep -q 'chrome-devtools'; } \
  && echo "PASS block-text-is-self-contained" || { echo "FAIL block-text-is-self-contained (out=$OUT)"; fails=1; }

# ...and must NOT punt to a skill that no longer ships
printf '%s' "$OUT" | grep -q 'smoke-verify skill' \
  && { echo "FAIL block-text-points-at-removed-skill"; fails=1; } || echo "PASS block-text-has-no-skill-pointer"

# verified attestation for the same delta -> allow
( cd "$T" && bash "$MARK" verified 'rendered Comp in browser' >/dev/null 2>&1 )
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS attested-releases" || { echo "FAIL attested-releases (out=$OUT)"; fails=1; }

# editing the matched file after attesting -> re-blocks (fingerprint moved)
echo '<span/>' >> "$T/Comp.tsx"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && echo "PASS edit-rearms" || { echo "FAIL edit-rearms (out=$OUT)"; fails=1; }

# skip attestation -> allow
( cd "$T" && bash "$MARK" skip 'user authorized skip' >/dev/null 2>&1 )
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS skip-releases" || { echo "FAIL skip-releases (out=$OUT)"; fails=1; }
rm -rf "$T"

# cap: with cap=2, third stop on the same delta fails open
mkrepo; cfg '\.(tsx)$' 2
echo x > "$T/A.tsx"
O1="$(run_hook)"; O2="$(run_hook)"; O3="$(run_hook)"
{ printf '%s' "$O1" | grep -q 'round default 1/2' && printf '%s' "$O2" | grep -q 'round default 2/2' && [ -z "$O3" ]; } \
  && echo "PASS cap-fails-open" || { echo "FAIL cap-fails-open (o1=$O1 o2=$O2 o3=$O3)"; fails=1; }

# new delta resets the counter
echo y >> "$T/A.tsx"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q 'round default 1/2' \
  && echo "PASS new-delta-resets-cap" || { echo "FAIL new-delta-resets-cap (out=$OUT)"; fails=1; }
rm -rf "$T"

# malformed blocks counter -> fail open
mkrepo; cfg
echo x > "$T/B.tsx"
run_hook >/dev/null   # seed a real counter
sed 's/^n=.*/n=banana/' "$T/.claude/smoke-verify/blocks" > "$T/.claude/smoke-verify/blocks.t" \
  && mv "$T/.claude/smoke-verify/blocks.t" "$T/.claude/smoke-verify/blocks"
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS malformed-counter-fails-open" || { echo "FAIL malformed-counter-fails-open (out=$OUT)"; fails=1; }
rm -rf "$T"

# attestation from another branch does not release this one
mkrepo; cfg
echo x > "$T/C.tsx"
( cd "$T" && bash "$MARK" verified 'checked on main' >/dev/null 2>&1 )
( cd "$T" && git checkout -qb feature )
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && echo "PASS branch-scoped" || { echo "FAIL branch-scoped (out=$OUT)"; fails=1; }
rm -rf "$T"

# state dir itself never triggers the gate
mkrepo; cfg '\.(cfg|tsx)$'
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS own-state-ignored" || { echo "FAIL own-state-ignored (out=$OUT)"; fails=1; }
rm -rf "$T"

# staging identical content after attesting does NOT re-arm (worktree fingerprint)
mkrepo; cfg
echo x > "$T/D.tsx"
( cd "$T" && bash "$MARK" verified 'ran it' >/dev/null 2>&1 && git add D.tsx )
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS staging-does-not-rearm" || { echo "FAIL staging-does-not-rearm (out=$OUT)"; fails=1; }
# ...and committing it does not re-block either (delta left the gate's scope)
( cd "$T" && git commit -qm add-d )
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS committed-out-of-scope" || { echo "FAIL committed-out-of-scope (out=$OUT)"; fails=1; }
rm -rf "$T"

# ^ anchors match the PATH, not the porcelain line (top-level app/ dir)
mkrepo; cfg '(^|/)app/.*\.tsx?$'
mkdir -p "$T/app"; echo x > "$T/app/route.ts"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && echo "PASS path-anchored-patterns" || { echo "FAIL path-anchored-patterns (out=$OUT)"; fails=1; }
rm -rf "$T"

# a path with spaces still triggers and lists cleanly
mkrepo; cfg
echo x > "$T/My Comp.tsx"
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '"decision":"block"' && printf '%s' "$OUT" | grep -q 'My Comp.tsx'; } \
  && echo "PASS quoted-path-triggers" || { echo "FAIL quoted-path-triggers (out=$OUT)"; fails=1; }
rm -rf "$T"

# core.quotePath must not turn a non-ASCII path into octal text. When it did, the path still matched
# `\.tsx$` but `cat` could not open it, so editing the file left the fingerprint unchanged and a stale
# attestation released the new delta.
mkrepo; cfg
UNICODE_NAME="$(printf 'Caf\303\251.tsx')"
printf 'one\n' > "$T/$UNICODE_NAME"
( cd "$T" && bash "$MARK" verified 'opened the unicode component' >/dev/null 2>&1 )
printf 'two\n' > "$T/$UNICODE_NAME"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && echo "PASS unicode-path-edit-rearms" || { echo "FAIL unicode-path-edit-rearms (out=$OUT)"; fails=1; }
rm -rf "$T"

# CRLF-saved config still matches (CR stripped from values)
mkrepo
mkdir -p "$T/.claude"; printf 'patterns=\\.(tsx)$\r\ncap=3\r\n' > "$T/.claude/smoke-verify.cfg"
echo x > "$T/E.tsx"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && echo "PASS crlf-config" || { echo "FAIL crlf-config (out=$OUT)"; fails=1; }
rm -rf "$T"

# more than 8 matched files -> truncated list with a (+N more) marker
mkrepo; cfg
for i in 1 2 3 4 5 6 7 8 9 0; do echo x > "$T/F$i.tsx"; done
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '(+2 more)' \
  && echo "PASS file-list-truncation" || { echo "FAIL file-list-truncation (out=$OUT)"; fails=1; }
rm -rf "$T"

# detached HEAD -> fail open. The gate scopes an attestation to a branch name, and on a detached
# HEAD `rev-parse --abbrev-ref` yields the literal "HEAD", which is not a stable scope. Without this
# the gate would block a bisect or a checked-out tag with no reachable way to attest.
mkrepo; cfg
echo '<div/>' > "$T/Comp.tsx"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q '"decision":"block"' \
  || { echo "FAIL detached-head-precondition (expected a block on a branch, out=$OUT)"; fails=1; }
( cd "$T" && git checkout -q --detach HEAD )
OUT="$(run_hook)"; rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } \
  && echo "PASS detached-head-allows" || { echo "FAIL detached-head-allows (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$T"

# --- named rules: the gate is not about frontends ------------------------------------------------
# One `patterns=` with one hard-coded evidence list could only ever describe one kind of change, and
# the kind it described was a screen. These cases pin the replacement: a repository declares its own
# classes of change, each with what proves THAT class, and each is released on its own.
rules_cfg() {
  mkdir -p "$T/.claude"
  cat > "$T/.claude/smoke-verify.cfg" <<'CFG'
cap=3
patterns.ui=\.(tsx|jsx)$
counts.ui=open the affected screen through chrome-devtools MCP and interact with it
excludes.ui=a storybook snapshot that was already green
patterns.migration=(^|/)migrations/.*\.(sql|py)$
counts.migration=apply the migration and roll it back on a scratch database, and show the schema diff
patterns.api=(^|/)api/.*\.py$
counts.api=send a real request to the running service and show the status and body
CFG
}

# a backend-only change triggers its own rule, with its own evidence text and no browser talk
mkrepo; rules_cfg
mkdir -p "$T/migrations"; echo 'ALTER TABLE t ADD COLUMN c int;' > "$T/migrations/001_add_c.sql"
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '\[migration\]' \
  && printf '%s' "$OUT" | grep -q 'roll it back on a scratch database' \
  && printf '%s' "$OUT" | grep -q 'round migration 1/3'; } \
  && echo "PASS non-frontend-rule-blocks" || { echo "FAIL non-frontend-rule-blocks (out=$OUT)"; fails=1; }
absent_ui=$(printf '%s' "$OUT" | grep -c '\[ui\]')
[ "$absent_ui" -eq 0 ] && echo "PASS unmatched-rule-silent" || { echo "FAIL unmatched-rule-silent (out=$OUT)"; fails=1; }
rm -rf "$T"

# two classes changed in one turn -> both named, and the per-rule exclusion rides along
mkrepo; rules_cfg
mkdir -p "$T/migrations" "$T/api"
echo 'ALTER TABLE t ADD COLUMN d int;' > "$T/migrations/002_add_d.sql"
echo '<div/>' > "$T/Panel.tsx"
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '\[migration\]' && printf '%s' "$OUT" | grep -q '\[ui\]' \
  && printf '%s' "$OUT" | grep -q 'storybook snapshot that was already green'; } \
  && echo "PASS two-rules-both-named" || { echo "FAIL two-rules-both-named (out=$OUT)"; fails=1; }

# an ambiguous attestation is refused rather than applied to both: one evidence line cannot stand
# for two kinds of change, which is the whole reason the rules are separate.
OUT="$( cd "$T" && bash "$MARK" verified 'ran the app' 2>&1 )"; rc=$?
{ [ $rc -eq 2 ] && printf '%s' "$OUT" | grep -q 'name the one you exercised'; } \
  && echo "PASS ambiguous-attestation-refused" || { echo "FAIL ambiguous-attestation-refused (rc=$rc out=$OUT)"; fails=1; }

# attesting one rule releases only that rule, and says what is still open
OUT="$( cd "$T" && bash "$MARK" verified migration 'applied 002 up and down on scratch, schema diff shown' 2>&1 )"
printf '%s' "$OUT" | grep -q 'still unattested for this delta: ui' \
  && echo "PASS partial-attestation-reports-remainder" || { echo "FAIL partial-attestation-reports-remainder (out=$OUT)"; fails=1; }
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '\[ui\]'; } && printf '%s' "$OUT" | grep -qv '\[migration\] UNVERIFIED' \
  && echo "PASS attested-rule-drops-out" || { echo "FAIL attested-rule-drops-out (out=$OUT)"; fails=1; }
printf '%s' "$OUT" | grep -q '\[migration\]' \
  && { echo "FAIL attested-rule-still-listed (out=$OUT)"; fails=1; } || echo "PASS attested-rule-not-listed"

# the last one released ends the block entirely
( cd "$T" && bash "$MARK" verified ui 'opened /panel in chrome-devtools, the panel renders' >/dev/null 2>&1 )
OUT="$(run_hook)"
[ -z "$OUT" ] && echo "PASS all-rules-attested-allows" || { echo "FAIL all-rules-attested-allows (out=$OUT)"; fails=1; }

# editing one rule's file re-arms only that rule
echo '<span/>' >> "$T/Panel.tsx"
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '\[ui\]'; } && ! printf '%s' "$OUT" | grep -q '\[migration\]' \
  && echo "PASS edit-rearms-one-rule" || { echo "FAIL edit-rearms-one-rule (out=$OUT)"; fails=1; }
rm -rf "$T"

# an unknown rule name is refused, not silently treated as the evidence line
mkrepo; rules_cfg
echo '<div/>' > "$T/Only.tsx"
OUT="$( cd "$T" && bash "$MARK" verified typo 'whatever' 2>&1 )"; rc=$?
{ [ $rc -eq 2 ] && printf '%s' "$OUT" | grep -q "no rule 'typo'"; } \
  && echo "PASS unknown-rule-refused" || { echo "FAIL unknown-rule-refused (rc=$rc out=$OUT)"; fails=1; }
rm -rf "$T"

exit $fails
