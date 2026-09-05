#!/usr/bin/env bash
# cc-tuner smoke-verify — attestation writer.
#
#   mark.sh verified [<rule>] '<one line: what was exercised and what it showed>'
#   mark.sh skip     [<rule>] '<one line: who authorized the skip and why>'
#   mark.sh status
#
# Writes .claude/smoke-verify/state[.<rule>] binding the attestation to the
# current branch AND the fingerprint of that rule's current delta (same shared
# lib the Stop hook uses). Re-editing a matched file changes the fingerprint, so
# a stale attestation never releases the gate for new work.
#
# The rule argument is optional and resolves the way the operator means it: when
# exactly one rule matches the current delta there is nothing to disambiguate,
# and when several do, naming one is required rather than guessed. Attesting
# every matching rule from one evidence line is the thing this gate exists to
# refuse — "I ran the tests" is not proof that the migration was applied.
#
# Exit codes: 0 ok; 2 usage; 3 not a repo / no config; 4 nothing to attest;
# 5 state write failed (the gate would keep blocking — fix permissions first).

set -u

LIB="$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$LIB"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then echo "smoke-verify: not inside a git repo" >&2; exit 3; fi
cd "$ROOT" || exit 3

if [ ! -f "$SMOKE_CFG" ]; then
  echo "smoke-verify: no $SMOKE_CFG in this repo (run /cc-tuner:smoke-verify-setup)" >&2
  exit 3
fi

RULES="$(smoke_rules)"
if [ -z "$RULES" ]; then
  echo "smoke-verify: config declares no rules — expected patterns=<ere> or patterns.<rule>=<ere>" >&2
  exit 3
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

# Rules whose patterns match something in the current worktree delta.
matching_rules() {
  for rule in $RULES; do
    patterns="$(smoke_rule_get patterns "$rule")"
    [ -n "$patterns" ] || continue
    [ -n "$(smoke_matched_paths "$patterns" || true)" ] && printf '%s\n' "$rule"
  done
  return 0
}

MODE="${1:-}"

if [ "$MODE" = "status" ]; then
  echo "config:   $SMOKE_CFG"
  for rule in $RULES; do
    patterns="$(smoke_rule_get patterns "$rule")"
    state_file="$(smoke_state_file "$rule")"
    echo "--- rule $rule (patterns=$patterns)"
    matched="$(smoke_matched_paths "$patterns" || true)"
    if [ -z "$matched" ]; then
      echo "    gate:  idle (no matched changes)"
      continue
    fi
    fp="$(smoke_fingerprint "$patterns")"
    st_fp="$(smoke_state_get fingerprint "$state_file")"
    st_br="$(smoke_state_get branch "$state_file")"
    st_status="$(smoke_state_get status "$state_file")"
    st_note="$(smoke_state_get note "$state_file")"
    echo "    files: $(printf '%s\n' "$matched" | grep -c .)"
    echo "    fp:    $fp"
    if [ "$st_fp" = "$fp" ] && [ "$st_br" = "$BRANCH" ]; then
      echo "    gate:  RELEASED ($st_status: $st_note)"
    else
      echo "    gate:  WOULD BLOCK (delta not attested)"
    fi
  done
  exit 0
fi

case "$MODE" in verified|skipped|skip) :;; *)
  echo "usage: mark.sh verified|skip [<rule>] '<one-line evidence/reason>' | mark.sh status" >&2; exit 2;;
esac
[ "$MODE" = "skip" ] && MODE=skipped

# Two arguments after the mode mean <rule> <note>. One means <note>, and the rule
# then has to be unambiguous.
if [ "$#" -ge 3 ]; then
  RULE="$2"
  NOTE="$3"
  printf '%s\n' "$RULES" | grep -qx -- "$RULE" || {
    echo "smoke-verify: no rule '$RULE' in $SMOKE_CFG (rules: $(printf '%s' "$RULES" | tr '\n' ' '))" >&2
    exit 2
  }
else
  RULE=""
  NOTE="${2:-}"
fi

if [ -z "$NOTE" ]; then
  echo "smoke-verify: an evidence/reason line is required — say WHAT was exercised (verified) or WHO authorized the skip" >&2
  exit 2
fi

MATCHING="$(matching_rules)"
if [ -z "$MATCHING" ]; then
  echo "smoke-verify: no matched changes for any rule — nothing to attest" >&2
  exit 4
fi

if [ -z "$RULE" ]; then
  count="$(printf '%s\n' "$MATCHING" | grep -c .)"
  if [ "$count" -gt 1 ]; then
    echo "smoke-verify: this delta matches $count rules ($(printf '%s' "$MATCHING" | tr '\n' ' ')) — name the one you exercised: mark.sh $MODE <rule> '<evidence>'" >&2
    echo "smoke-verify: one evidence line cannot stand for two kinds of change; attest them separately." >&2
    exit 2
  fi
  RULE="$MATCHING"
fi

PATTERNS="$(smoke_rule_get patterns "$RULE")"
if [ -z "$(smoke_matched_paths "$PATTERNS" || true)" ]; then
  echo "smoke-verify: rule '$RULE' matches nothing in the current delta — nothing to attest" >&2
  exit 4
fi
FP="$(smoke_fingerprint "$PATTERNS")"
STATE_FILE="$(smoke_state_file "$RULE")"
BLOCKS_FILE="$(smoke_blocks_file "$RULE")"

# A silently failed write would leave the hook blocking until cap while this
# script reports success — so every write failure is loud (exit 5).
mkdir -p "$SMOKE_STATE_DIR" || { echo "smoke-verify: cannot create $SMOKE_STATE_DIR" >&2; exit 5; }
# Single-line sanitization: state is KEY=VALUE, a newline in NOTE would corrupt it.
NOTE="$(printf '%s' "$NOTE" | tr -s '[:cntrl:]' ' ' | cut -c1-500)"
{
  printf 'branch=%s\n' "$BRANCH"
  printf 'fingerprint=%s\n' "$FP"
  printf 'status=%s\n' "$MODE"
  printf 'note=%s\n' "$NOTE"
} > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE" \
  || { echo "smoke-verify: cannot write $STATE_FILE" >&2; exit 5; }
rm -f "$BLOCKS_FILE" 2>/dev/null

echo "smoke-verify: attested '$MODE' for rule $RULE on branch $BRANCH (fp $(printf '%.16s' "$FP")…)"
# Saying what is still open matters more than the confirmation: a multi-rule delta where one rule was
# attested looks finished from the agent's side and still blocks, and the reason has to be legible.
REMAINING="$(matching_rules | grep -vx -- "$RULE" || true)"
[ -n "$REMAINING" ] && echo "smoke-verify: still unattested for this delta: $(printf '%s' "$REMAINING" | tr '\n' ' ')"
exit 0
