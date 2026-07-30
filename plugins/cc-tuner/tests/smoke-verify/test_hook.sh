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
{ [ $rc -eq 0 ] && printf '%s' "$OUT" | grep -q '"decision":"block"' && printf '%s' "$OUT" | grep -q 'round 1/3'; } \
  && echo "PASS fe-change-blocks" || { echo "FAIL fe-change-blocks (out=$OUT)"; fails=1; }

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
{ printf '%s' "$O1" | grep -q 'round 1/2' && printf '%s' "$O2" | grep -q 'round 2/2' && [ -z "$O3" ]; } \
  && echo "PASS cap-fails-open" || { echo "FAIL cap-fails-open (o1=$O1 o2=$O2 o3=$O3)"; fails=1; }

# new delta resets the counter
echo y >> "$T/A.tsx"
OUT="$(run_hook)"
printf '%s' "$OUT" | grep -q 'round 1/2' \
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

# a path with spaces (git C-quotes it) still triggers and lists cleanly
mkrepo; cfg
echo x > "$T/My Comp.tsx"
OUT="$(run_hook)"
{ printf '%s' "$OUT" | grep -q '"decision":"block"' && printf '%s' "$OUT" | grep -q 'My Comp.tsx'; } \
  && echo "PASS quoted-path-triggers" || { echo "FAIL quoted-path-triggers (out=$OUT)"; fails=1; }
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

exit $fails
