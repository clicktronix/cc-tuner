#!/usr/bin/env bash
# cc-tuner — Stop hook: smoke-verify gate for frontend changes.
#
# FAST and fail-open. Blocks the end of a turn only when ALL of:
#   - the repo opted in (.claude/smoke-verify.cfg exists),
#   - changed files match the config's frontend patterns,
#   - no attestation (verified/skipped) exists for exactly this delta.
# The hook never verifies anything itself — it routes Claude to verify the
# change empirically (render / run the failing case / screenshot) and attest
# via scripts/smoke-verify/mark.sh. Rationale: fix commits that pass static
# checks but were never exercised are this workflow's top regression source.
#
# Runaway protection mirrors the cc-codex-triage stop hook:
#   1. blocks counter vs cap, per fingerprint — the hard terminator; any
#      malformed number fails OPEN.
#   2. Success release: an attestation whose branch AND fingerprint match the
#      current delta (mark.sh recomputes with the same shared lib).
#   3. A counter that cannot be persisted → allow (never unbounded blocking).
# stop_hook_active is deliberately not an unconditional allow — the numeric
# cap bounds cost instead (at most `cap` blocks per delta).
#
# Output contract: JSON {"decision":"block","reason":"..."} on stdout blocks
# the stop; exit 0 with no JSON allows it. Never exit non-zero.

set -u
INPUT="$(cat 2>/dev/null || true)"
: "${INPUT:-}"

allow() { exit 0; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || allow
cd "$ROOT" 2>/dev/null || allow

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)"
MARK="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/smoke-verify/mark.sh}"
MARK="${MARK:-<cc-tuner plugin>/scripts/smoke-verify/mark.sh}"
LIB="${PLUGIN_ROOT}/scripts/smoke-verify/lib.sh"
[ -f "$LIB" ] || allow
# shellcheck source=../scripts/smoke-verify/lib.sh
. "$LIB"

# Opt-in: no per-repo config, no gate.
[ -f "$SMOKE_CFG" ] || allow

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || allow
[ "$BRANCH" = "HEAD" ] && allow  # detached HEAD: nothing stable to scope to

PATTERNS="$(smoke_cfg_get patterns)"
[ -n "$PATTERNS" ] || allow  # empty/missing patterns = misconfigured → fail open

CAP="$(smoke_cfg_get cap)"
case "$CAP" in ''|*[!0-9]*|0*) CAP=3;; esac  # non-numeric/leading-zero → default

MATCHED="$(smoke_matched_paths "$PATTERNS" || true)"
[ -n "$MATCHED" ] || allow

FP="$(smoke_fingerprint "$PATTERNS")"
[ -n "$FP" ] || allow

# Release: an attestation for exactly this branch + delta.
if [ -f "$SMOKE_STATE" ]; then
  ST_BRANCH="$(smoke_state_get branch)"
  ST_FP="$(smoke_state_get fingerprint)"
  ST_STATUS="$(smoke_state_get status)"
  if [ "$ST_BRANCH" = "$BRANCH" ] && [ "$ST_FP" = "$FP" ]; then
    case "$ST_STATUS" in verified|skipped) allow;; esac
  fi
fi

# Cap bookkeeping, per fingerprint. Malformed counter → fail open.
mkdir -p "$SMOKE_STATE_DIR" 2>/dev/null || allow
N=0
if [ -f "$SMOKE_BLOCKS" ]; then
  B_FP="$(sed -n 's/^fp=//p' "$SMOKE_BLOCKS" 2>/dev/null | head -1)"
  B_N="$(sed -n 's/^n=//p' "$SMOKE_BLOCKS" 2>/dev/null | head -1)"
  if [ "$B_FP" = "$FP" ]; then
    case "$B_N" in
      0|[1-9]|[1-9][0-9]) N="$B_N";;
      *) allow;;
    esac
  fi
fi
[ "$N" -ge "$CAP" ] && allow
N=$((N + 1))
printf 'fp=%s\nn=%s\n' "$FP" "$N" > "$SMOKE_BLOCKS.tmp" 2>/dev/null \
  && mv -f "$SMOKE_BLOCKS.tmp" "$SMOKE_BLOCKS" 2>/dev/null || allow

FILES="$(printf '%s\n' "$MATCHED" | head -8 | tr '\n' ' ')"
TOTAL="$(printf '%s\n' "$MATCHED" | grep -c .)"
[ "$TOTAL" -gt 8 ] 2>/dev/null && FILES="$FILES(+$((TOTAL - 8)) more) "

REASON="smoke-verify gate (round $N/$CAP): frontend changes are UNVERIFIED: ${FILES}— Verify the change empirically before finishing: exercise the real behavior (open the affected page / run the failing case / screenshot via chrome-devtools MCP), not just typecheck or lint. Then attest with ONE line of evidence: bash '$MARK' verified '<what you exercised and saw>'. If the USER explicitly told you to skip verification this turn, attest: bash '$MARK' skip '<who said so and why>'. Editing the files again re-arms the gate (staging/committing does not). See the cc-tuner:smoke-verify skill for what counts as evidence."
REASON="$(printf '%s' "$REASON" | tr -d '"\\' | tr -s '[:cntrl:]' ' ')"
printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0
