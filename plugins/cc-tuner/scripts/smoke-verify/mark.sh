#!/usr/bin/env bash
# cc-tuner smoke-verify — attestation writer.
#
#   mark.sh verified '<one line: what was exercised and what it showed>'
#   mark.sh skip     '<one line: who authorized the skip and why>'
#   mark.sh status
#
# Writes .claude/smoke-verify/state binding the attestation to the current
# branch AND the fingerprint of the current frontend delta (same shared lib
# the Stop hook uses). Re-editing a matched file changes the fingerprint, so
# a stale attestation never releases the gate for new work.
#
# Exit codes: 0 ok; 2 usage; 3 not a repo / no config; 4 nothing to attest.

set -u

MODE="${1:-}"
NOTE="${2:-}"

LIB="$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$LIB"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then echo "smoke-verify: not inside a git repo" >&2; exit 3; fi
cd "$ROOT" || exit 3

if [ ! -f "$SMOKE_CFG" ]; then
  echo "smoke-verify: no $SMOKE_CFG in this repo (run /cc-tuner:smoke-verify-setup)" >&2
  exit 3
fi

PATTERNS="$(smoke_cfg_get patterns)"
if [ -z "$PATTERNS" ]; then echo "smoke-verify: config has no patterns=" >&2; exit 3; fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

if [ "$MODE" = "status" ]; then
  echo "config:   $SMOKE_CFG (patterns=$PATTERNS)"
  if [ -f "$SMOKE_STATE" ]; then cat "$SMOKE_STATE"; else echo "state:    none"; fi
  MATCHED="$(smoke_matched_lines "$PATTERNS" || true)"
  if [ -n "$MATCHED" ]; then
    FP="$(smoke_fingerprint "$PATTERNS")"
    echo "current delta fp: $FP"
    ST_FP="$(smoke_state_get fingerprint)"; ST_BR="$(smoke_state_get branch)"
    if [ "$ST_FP" = "$FP" ] && [ "$ST_BR" = "$BRANCH" ]; then
      echo "gate:     RELEASED for this delta"
    else
      echo "gate:     WOULD BLOCK (delta not attested)"
    fi
  else
    echo "gate:     idle (no matched changes)"
  fi
  exit 0
fi

case "$MODE" in verified|skipped|skip) :;; *)
  echo "usage: mark.sh verified|skip '<one-line evidence/reason>' | mark.sh status" >&2; exit 2;;
esac
[ "$MODE" = "skip" ] && MODE=skipped
if [ -z "$NOTE" ]; then
  echo "smoke-verify: an evidence/reason line is required — say WHAT was exercised (verified) or WHO authorized the skip" >&2
  exit 2
fi

MATCHED="$(smoke_matched_lines "$PATTERNS" || true)"
if [ -z "$MATCHED" ]; then
  echo "smoke-verify: no matched frontend changes — nothing to attest" >&2
  exit 4
fi
FP="$(smoke_fingerprint "$PATTERNS")"

mkdir -p "$SMOKE_STATE_DIR"
# Single-line sanitization: state is KEY=VALUE, a newline in NOTE would corrupt it.
NOTE="$(printf '%s' "$NOTE" | tr -s '[:cntrl:]' ' ' | cut -c1-500)"
{
  printf 'branch=%s\n' "$BRANCH"
  printf 'fingerprint=%s\n' "$FP"
  printf 'status=%s\n' "$MODE"
  printf 'note=%s\n' "$NOTE"
} > "$SMOKE_STATE.tmp" && mv -f "$SMOKE_STATE.tmp" "$SMOKE_STATE"
rm -f "$SMOKE_BLOCKS" 2>/dev/null
echo "smoke-verify: attested '$MODE' for branch $BRANCH (fp $(printf '%.16s' "$FP")…)"
