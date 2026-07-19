#!/usr/bin/env bash
set -u
MARK="$(cd "$(dirname "$0")/../../scripts/smoke-verify" && pwd)/mark.sh"
fails=0

mkrepo() {
  T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  ( cd "$T" && git init -q -b main && git config user.email a@b.c && git config user.name t \
    && echo base > app.py && git add app.py && git commit -qm init ) \
    || { echo "FATAL: fixture setup failed"; exit 1; }
  mkdir -p "$T/.claude"; printf 'patterns=%s\ncap=3\n' '\.(tsx)$' > "$T/.claude/smoke-verify.cfg"
}

# no config -> exit 3
T="$(mktemp -d)"; ( cd "$T" && git init -q )
( cd "$T" && bash "$MARK" verified x >/dev/null 2>&1 ); rc=$?
[ $rc -eq 3 ] && echo "PASS no-config-rc3" || { echo "FAIL no-config-rc3 (rc=$rc)"; fails=1; }
rm -rf "$T"

# verified without an evidence line -> exit 2 (usage)
mkrepo; echo x > "$T/A.tsx"
( cd "$T" && bash "$MARK" verified >/dev/null 2>&1 ); rc=$?
[ $rc -eq 2 ] && echo "PASS evidence-required" || { echo "FAIL evidence-required (rc=$rc)"; fails=1; }

# no matched changes -> exit 4
rm "$T/A.tsx"
( cd "$T" && bash "$MARK" verified 'x' >/dev/null 2>&1 ); rc=$?
[ $rc -eq 4 ] && echo "PASS nothing-to-attest-rc4" || { echo "FAIL nothing-to-attest-rc4 (rc=$rc)"; fails=1; }

# happy path writes branch/fingerprint/status/note and clears the blocks counter
echo x > "$T/A.tsx"; mkdir -p "$T/.claude/smoke-verify"; echo stale > "$T/.claude/smoke-verify/blocks"
( cd "$T" && bash "$MARK" verified 'ran the page' >/dev/null 2>&1 ); rc=$?
ST="$T/.claude/smoke-verify/state"
{ [ $rc -eq 0 ] && grep -q '^status=verified$' "$ST" && grep -q '^branch=main$' "$ST" \
  && grep -q '^note=ran the page$' "$ST" && [ ! -f "$T/.claude/smoke-verify/blocks" ]; } \
  && echo "PASS attest-happy-path" || { echo "FAIL attest-happy-path (rc=$rc)"; fails=1; }

# a multi-line note is flattened (state stays KEY=VALUE parseable)
echo y >> "$T/A.tsx"
( cd "$T" && bash "$MARK" skip "$(printf 'line1\nline2')" >/dev/null 2>&1 )
{ grep -q '^status=skipped$' "$ST" && grep -q '^note=line1 line2$' "$ST"; } \
  && echo "PASS note-flattened" || { echo "FAIL note-flattened"; fails=1; }

# status runs and reports release state
OUT="$(cd "$T" && bash "$MARK" status 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'RELEASED' \
  && echo "PASS status-released" || { echo "FAIL status-released (out=$OUT)"; fails=1; }
rm -rf "$T"

exit $fails
