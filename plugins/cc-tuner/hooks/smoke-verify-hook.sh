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

# The block text carries the whole standard, deliberately. It used to end with 'see the
# cc-tuner:smoke-verify skill for what counts as evidence' — a pointer the agent had to choose to
# follow, at the one moment it is being told to stop. Everything load-bearing is inlined now, above
# all the DOES NOT COUNT list: the gate's entire purpose is rejecting static checks as proof, so an
# agent that never reads the list is an agent that attests on a green typecheck.
REASON="smoke-verify gate (round $N/$CAP): frontend changes are UNVERIFIED: ${FILES}— Exercise the real behavior before finishing. COUNTS (any one, against the actual change): open the affected page or flow via chrome-devtools MCP (navigate, interact, screenshot) and confirm the changed behavior; run the exact failing case or affected test file and show it passing; render the real artifact (PDF, email preview, storybook story) and look at it. DOES NOT COUNT: typecheck, lint, a full-suite run that was already green before the change, the diff looks correct, or re-reading the code. Then attest with ONE line of concrete evidence — what you exercised and what it showed: bash '$MARK' verified '<what you exercised and saw>'. ATTEST BEFORE COMMITTING: the gate only sees the uncommitted delta, so committing without attesting takes the change out of scope entirely. Editing a matched file again re-arms the gate (staging or committing the same content does not), so verify after the code settles. If the USER explicitly told you to skip verification this turn, attest: bash '$MARK' skip '<who said so and why>'. Never attest verified on the strength of static checks — the evidence line is the audit trail and it will say so."
REASON="$(printf '%s' "$REASON" | tr -d '"\\' | tr -s '[:cntrl:]' ' ')"
printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0
