#!/usr/bin/env bash
# statusline.sh must read 5h/7d rate-limit usage from Claude Code's own statusline
# payload (`rate_limits.five_hour` / `rate_limits.seven_day`) before ever touching OAuth
# credentials, a cache, a lock, or the network. The OAuth usage endpoint is a fallback
# for older clients that don't yet send `rate_limits` at all.
#
# Every case here runs fully offline: HOME, CLAUDE_CONFIG_DIR and TMPDIR point at a
# fresh temp dir per case, and python3/curl are shadowed on PATH by stubs that record
# being called and exit non-zero. That is what lets a test assert a negative -- that the
# credential/network path did not run -- rather than just asserting on the rendered text.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$FLOW_PLUGIN/skills/statusline/statusline.sh"
[ -f "$SCRIPT" ] || { printf 'FATAL: %s does not exist\n' "$SCRIPT"; exit 1; }

# strip_ansi -> stdin with `\033[...m` color codes removed, so assertions match on
# plain text regardless of the bar/percent colors.
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }

# stub_env -> a fresh dir with isolated HOME/config/cache and PATH-shadowing stubs for
# python3 and curl. Each stub appends its name to $STUB_MARKER and exits 1: loud enough
# that a script relying on either for real would visibly fail, not silently succeed.
stub_env() {
  local d; d="$(flow_workdir)"
  mkdir -p "$d/home/.claude" "$d/tmp" "$d/bin"
  cat > "$d/bin/python3" <<'STUB'
#!/bin/sh
echo "python3" >> "$STUB_MARKER" 2>/dev/null
echo "stub python3: no network/credentials in tests" >&2
exit 1
STUB
  cat > "$d/bin/curl" <<'STUB'
#!/bin/sh
echo "curl" >> "$STUB_MARKER" 2>/dev/null
echo "stub curl: no network in tests" >&2
exit 1
STUB
  chmod +x "$d/bin/python3" "$d/bin/curl"
  printf '%s' "$d"
}

# run_statusline <envdir> <payload-json>
# Must be called directly (never as `x=$(run_statusline ...)`) -- that would fork a
# subshell and the two globals it sets, $STATUSLINE_OUT and $STATUSLINE_RC, would die
# with it. Sets $STATUSLINE_OUT to the ANSI-stripped stdout and $STATUSLINE_RC to the
# script's exit code.
run_statusline() {
  local envdir=$1 payload=$2
  STATUSLINE_OUT=$(STUB_MARKER="$envdir/stub-called" \
        HOME="$envdir/home" \
        CLAUDE_CONFIG_DIR="$envdir/home/.claude" \
        TMPDIR="$envdir/tmp" \
        PATH="$envdir/bin:$PATH" \
        bash "$SCRIPT" <<<"$payload" 2>"$envdir/stderr")
  STATUSLINE_RC=$?
  STATUSLINE_OUT=$(printf '%s' "$STATUSLINE_OUT" | strip_ansi)
}

# --- case 1: native rate_limits present -> render from stdin, no OAuth/network at all ---
E1="$(stub_env)"
CWD1="$(flow_workdir)"
FIVE_EPOCH=$(( $(date +%s) + 3600 ))
SEVEN_EPOCH=$(( $(date +%s) + 86400 ))
PAYLOAD1=$(jq -n --arg cwd "$CWD1" --argjson five 66 --argjson five_epoch "$FIVE_EPOCH" \
  --argjson seven 9 --argjson seven_epoch "$SEVEN_EPOCH" '{
    workspace: {current_dir: $cwd},
    model: {display_name: "Test Model"},
    context_window: {used_percentage: 42},
    cost: {total_duration_ms: 0},
    rate_limits: {
      five_hour: {used_percentage: $five, resets_at: $five_epoch},
      seven_day: {used_percentage: $seven, resets_at: $seven_epoch}
    }
  }')
run_statusline "$E1" "$PAYLOAD1"; OUT1="$STATUSLINE_OUT"

check  "native-five-hour-renders"  "5h:66%" "$OUT1"
check  "native-seven-day-renders"  "7d:9%"  "$OUT1"
equals "native-path-exits-0"       "0"      "$STATUSLINE_RC"
absent "native-path-skips-python3" "python3" "$(cat "$E1/stub-called" 2>/dev/null)"
absent "native-path-skips-curl"    "curl"    "$(cat "$E1/stub-called" 2>/dev/null)"

# --- case 2: no rate_limits at all, and the OAuth fallback fails -> segment is dropped,
# exit is still 0, and the rest of the line still renders ---
E2="$(stub_env)"
CWD2="$(flow_workdir)"
PAYLOAD2=$(jq -n --arg cwd "$CWD2" '{
    workspace: {current_dir: $cwd},
    model: {display_name: "Test Model"},
    context_window: {used_percentage: 42},
    cost: {total_duration_ms: 0}
  }')
run_statusline "$E2" "$PAYLOAD2"; OUT2="$STATUSLINE_OUT"

absent "no-rate-limits-no-five-hour"  "5h:"  "$OUT2"
absent "no-rate-limits-no-seven-day"  "7d:"  "$OUT2"
equals "no-rate-limits-exits-0"       "0"    "$STATUSLINE_RC"
check  "no-rate-limits-context-still-renders" "ctx:42%" "$OUT2"

# --- case 3: only five_hour present -> seven_day is hidden, never shown as 0% ---
E3="$(stub_env)"
CWD3="$(flow_workdir)"
PAYLOAD3=$(jq -n --arg cwd "$CWD3" --argjson five 66 --argjson five_epoch "$FIVE_EPOCH" '{
    workspace: {current_dir: $cwd},
    model: {display_name: "Test Model"},
    context_window: {used_percentage: 42},
    cost: {total_duration_ms: 0},
    rate_limits: {
      five_hour: {used_percentage: $five, resets_at: $five_epoch}
    }
  }')
run_statusline "$E3" "$PAYLOAD3"; OUT3="$STATUSLINE_OUT"

check  "partial-native-five-hour-renders" "5h:66%" "$OUT3"
absent "partial-native-seven-day-absent"  "7d:"    "$OUT3"
equals "partial-native-exits-0"           "0"      "$STATUSLINE_RC"

exit $fails
