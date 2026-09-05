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
# Runaway protection is local to this hook:
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

RULES="$(smoke_rules)"
[ -n "$RULES" ] || allow  # no rules = misconfigured → fail open

CAP="$(smoke_cfg_get cap)"
case "$CAP" in ''|*[!0-9]*|0*) CAP=3;; esac  # non-numeric/leading-zero → default

# The default evidence list, used by a rule that declares none. It is deliberately about EXERCISING
# something rather than about a browser: the gate covers whatever a repository points it at, and a
# migration, an endpoint and a screen are proved differently. A rule that knows its own kind of change
# says so in `counts.<rule>`, and that text replaces this one.
GENERIC_COUNTS="run the changed path for real and read the result — execute the exact failing case and show it passing, drive the affected flow end to end (a real request, a migration applied and rolled back, a page opened and interacted with through a browser-driving tool such as chrome-devtools MCP), or render the real artifact and look at it"

BLOCKED=""      # newline-separated per-rule sections for the block message
BLOCKED_ROUNDS=""
for rule in $RULES; do
  PATTERNS="$(smoke_rule_get patterns "$rule")"
  [ -n "$PATTERNS" ] || continue

  MATCHED="$(smoke_matched_paths "$PATTERNS" || true)"
  [ -n "$MATCHED" ] || continue

  FP="$(smoke_fingerprint "$PATTERNS")"
  [ -n "$FP" ] || continue

  STATE_FILE="$(smoke_state_file "$rule")"
  BLOCKS_FILE="$(smoke_blocks_file "$rule")"

  # Release: an attestation for exactly this branch + delta, for THIS rule. Per rule, because
  # verifying the screen says nothing about whether the migration was run.
  if [ -f "$STATE_FILE" ]; then
    ST_BRANCH="$(smoke_state_get branch "$STATE_FILE")"
    ST_FP="$(smoke_state_get fingerprint "$STATE_FILE")"
    ST_STATUS="$(smoke_state_get status "$STATE_FILE")"
    if [ "$ST_BRANCH" = "$BRANCH" ] && [ "$ST_FP" = "$FP" ]; then
      case "$ST_STATUS" in verified|skipped) continue;; esac
    fi
  fi

  # Cap bookkeeping, per rule and per fingerprint. Malformed counter → fail open for this rule only:
  # one unreadable counter must not disarm the rules that are still readable.
  mkdir -p "$SMOKE_STATE_DIR" 2>/dev/null || continue
  N=0
  if [ -f "$BLOCKS_FILE" ]; then
    B_FP="$(sed -n 's/^fp=//p' "$BLOCKS_FILE" 2>/dev/null | head -1)"
    B_N="$(sed -n 's/^n=//p' "$BLOCKS_FILE" 2>/dev/null | head -1)"
    if [ "$B_FP" = "$FP" ]; then
      case "$B_N" in
        0|[1-9]|[1-9][0-9]) N="$B_N";;
        *) continue;;
      esac
    fi
  fi
  [ "$N" -ge "$CAP" ] && continue
  N=$((N + 1))
  printf 'fp=%s\nn=%s\n' "$FP" "$N" > "$BLOCKS_FILE.tmp" 2>/dev/null \
    && mv -f "$BLOCKS_FILE.tmp" "$BLOCKS_FILE" 2>/dev/null || continue

  FILES="$(printf '%s\n' "$MATCHED" | head -8 | tr '\n' ' ')"
  TOTAL="$(printf '%s\n' "$MATCHED" | grep -c .)"
  [ "$TOTAL" -gt 8 ] 2>/dev/null && FILES="$FILES(+$((TOTAL - 8)) more) "

  COUNTS="$(smoke_rule_get counts "$rule")"
  [ -n "$COUNTS" ] || COUNTS="$GENERIC_COUNTS"
  EXCLUDES="$(smoke_rule_get excludes "$rule")"
  EXTRA=""
  [ -n "$EXCLUDES" ] && EXTRA=" Also does not count here: $EXCLUDES."

  ATTEST="bash '$MARK' verified $rule '<what you exercised and saw>'"
  [ "$rule" = default ] && ATTEST="bash '$MARK' verified '<what you exercised and saw>'"

  BLOCKED="$BLOCKED [$rule] UNVERIFIED: ${FILES}— COUNTS: ${COUNTS}.${EXTRA} Attest with: $ATTEST."
  BLOCKED_ROUNDS="${BLOCKED_ROUNDS}${BLOCKED_ROUNDS:+, }$rule $N/$CAP"
done

[ -n "$BLOCKED" ] || allow

# The block text carries the whole standard, deliberately. It used to end with 'see the
# cc-tuner:smoke-verify skill for what counts as evidence' — a pointer the agent had to choose to
# follow, at the one moment it is being told to stop. Everything load-bearing is inlined now, above
# all the DOES NOT COUNT list: the gate's entire purpose is rejecting static checks as proof, so an
# agent that never reads the list is an agent that attests on a green typecheck.
#
# What varies per rule is WHAT counts; what never varies is what does not. So the generic refusal
# below frames every section, and each rule adds its own exclusions to it.
REASON="smoke-verify gate (round $BLOCKED_ROUNDS): changes are UNVERIFIED. Exercise the real behavior before finishing, once per section below.$BLOCKED DOES NOT COUNT for any of them: typecheck, lint, a full-suite run that was already green before the change, the diff looks correct, or re-reading the code. ATTEST BEFORE COMMITTING: the gate only sees the uncommitted delta, so committing without attesting takes the change out of scope entirely. Editing a matched file again re-arms that rule (staging or committing the same content does not), so verify after the code settles. If the USER explicitly told you to skip verification this turn, attest the same way with 'skip' instead of 'verified' and say who authorized it. Never attest verified on the strength of static checks — the evidence line is the audit trail and it will say so."
REASON="$(printf '%s' "$REASON" | tr -d '"\\' | tr -s '[:cntrl:]' ' ')"
printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0
