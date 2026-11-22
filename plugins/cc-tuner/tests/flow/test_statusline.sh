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

# Byte-oriented locales must still emit complete UTF-8 glyphs, as on GNU tr.
LC_ALL=C run_statusline "$E1" "$PAYLOAD1"
check "byte-locale-five-hour-bar" "5h:66%[▓▓▓▓▓░░░]" "$STATUSLINE_OUT"
check "byte-locale-seven-day-bar" "7d:9%[▓░░░░░░░]" "$STATUSLINE_OUT"
check "byte-locale-context-bar" "ctx:42% [▓▓▓▓░░░░░░]" "$STATUSLINE_OUT"

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

# --- case 4: a plan with no five-hour window -> only 7d renders, behind its separator ---
E4="$(stub_env)"
CWD4="$(flow_workdir)"
PAYLOAD4=$(jq -n --arg cwd "$CWD4" --argjson seven 53 --argjson seven_epoch "$SEVEN_EPOCH" '{
    workspace: {current_dir: $cwd},
    model: {display_name: "Test Model"},
    context_window: {used_percentage: 42},
    cost: {total_duration_ms: 0},
    rate_limits: {seven_day: {used_percentage: $seven, resets_at: $seven_epoch}}
  }')
run_statusline "$E4" "$PAYLOAD4"; OUT4="$STATUSLINE_OUT"

absent "weekly-only-five-hour-absent" "5h:"        "$OUT4"
check  "weekly-only-seven-day-renders" " | 7d:53%" "$OUT4"

# --- case 5: the OAuth fallback answers five_hour null -> 7d keeps its separator too ---
E5="$(stub_env)"
CFG5=$(printf '%s' "$E5/home/.claude" | cksum | cut -d' ' -f1)
CACHE5="$E5/tmp/cc-tuner-statusline-$(id -u)-$CFG5"
mkdir -p "$CACHE5"
jq -n --argjson now "$(date +%s)" \
  '{fetched_at: $now, five_hour: null, seven_day: {utilization: 53, reset_local: "12:00"}}' > "$CACHE5/usage_cache"
run_statusline "$E5" "$PAYLOAD2"; OUT5="$STATUSLINE_OUT"

absent "oauth-weekly-only-five-hour-absent" "5h:"        "$OUT5"
check  "oauth-weekly-only-seven-day-renders" " | 7d:53%" "$OUT5"

# --- case 6: subagent models -> last on the second line, for this session only ---
E6="$(stub_env)"
AGENTS6="$E6/home/.claude/cc-tuner/subagents"
mkdir -p "$AGENTS6"
printf '2 sonnet \302\267 1 opus' > "$AGENTS6/s1"
printf '9 haiku' > "$AGENTS6/s2"
PAYLOAD6=$(printf '%s' "$PAYLOAD4" | jq '. + {session_id: "s1"}')
run_statusline "$E6" "$PAYLOAD6"; OUT6="$STATUSLINE_OUT"

check  "subagents-render-for-this-session" "subagents: 2 sonnet · 1 opus" "$OUT6"
absent "subagents-of-another-session-hidden" "9 haiku" "$OUT6"
equals "subagents-come-last" "subagents: 2 sonnet · 1 opus" \
  "$(printf '%s' "$OUT6" | tail -n 1 | sed 's/.* | //')"

# --- case 7: a file the mod stopped rewriting (a crash, a reload) shows nothing; a render never
# deletes, since the mod may have just written a fresh one ---
touch -t 200001010000 "$AGENTS6/s1"
run_statusline "$E6" "$PAYLOAD6"; OUT7="$STATUSLINE_OUT"

absent "stale-subagents-hidden" "subagents:" "$OUT7"

# --- case 8: the mod's empty file means none run -> nothing shown, file left to the sweep ---
: > "$AGENTS6/s1"
run_statusline "$E6" "$PAYLOAD6"; OUT8="$STATUSLINE_OUT"

absent "empty-subagents-hidden" "subagents:" "$OUT8"
equals "render-keeps-the-file" "yes" "$([ -e "$AGENTS6/s1" ] && echo yes || echo no)"

# --- case 9: the file of a session that ended without a render is swept, a live one stays ---
touch -t 200001010000 "$AGENTS6/ended"
run_statusline "$E6" "$PAYLOAD6"

equals "ended-session-file-swept" "no" "$([ -e "$AGENTS6/ended" ] && echo yes || echo no)"
equals "other-live-session-file-kept" "yes" "$([ -e "$AGENTS6/s2" ] && echo yes || echo no)"

# --- case 10: change counts are reused for a while, the branch name never is ---
E10="$(stub_env)"
REPO10="$(flow_workdir)"
git -C "$REPO10" init -q -b main
git -C "$REPO10" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
PAYLOAD10=$(jq -n --arg cwd "$REPO10" '{workspace: {current_dir: $cwd}, cost: {total_duration_ms: 0}}')
run_statusline "$E10" "$PAYLOAD10"
touch "$REPO10/new-file"
run_statusline "$E10" "$PAYLOAD10"; OUT10="$STATUSLINE_OUT"
absent "git-counts-reused-within-ttl" "U:1" "$OUT10"

find "$E10/tmp" -name 'git-*' -exec touch -t 200001010000 {} +
run_statusline "$E10" "$PAYLOAD10"; OUT11="$STATUSLINE_OUT"
check  "git-counts-recounted-after-ttl" "U:1" "$OUT11"

git -C "$REPO10" switch -q -c other
touch "$REPO10/another-file"
run_statusline "$E10" "$PAYLOAD10"; OUT12="$STATUSLINE_OUT"
check  "git-branch-is-never-stale" "git:(other)" "$OUT12"
check  "git-counts-belong-to-the-branch" "U:2" "$OUT12"

# --- case 11: temp files a cancelled render left behind are swept ---
CACHE11="$E10/tmp/cc-tuner-statusline-$(id -u)-$(printf '%s' "$E10/home/.claude" | cksum | cut -d' ' -f1)"
touch -t 200001010000 "$CACHE11/usage_cache.tmp.123" "$CACHE11/git-old"
run_statusline "$E10" "$PAYLOAD10"
equals "cancelled-render-temp-swept" "no" "$([ -e "$CACHE11/usage_cache.tmp.123" ] && echo yes || echo no)"
equals "old-git-counts-swept" "no" "$([ -e "$CACHE11/git-old" ] && echo yes || echo no)"

# --- case 12: the OAuth fallback reads credentials of the active profile only ---
# macOS keeps the default profile's token in the Keychain entry `Claude Code-credentials`. A session on
# another CLAUDE_CONFIG_DIR must not read it: that would show the default account's usage. Real python3
# runs here; `security` is a stub that records the call and returns no token, so nothing reaches the
# network in either case.
keychain_env() { # keychain_env -> envdir with real python3 and a recording `security`
  local d; d="$(stub_env)"
  ln -sf "$(command -v python3)" "$d/bin/python3"
  printf '#!/bin/sh\necho security >> "$STUB_MARKER"\nexit 44\n' > "$d/bin/security"; chmod +x "$d/bin/security"
  printf '%s' "$d"
}
run_profile() { # run_profile <envdir> <config-dir> <payload>
  STUB_MARKER="$1/stub-called" HOME="$1/home" CLAUDE_CONFIG_DIR="$2" TMPDIR="$1/tmp" \
    PATH="$1/bin:/usr/bin:/bin" bash "$SCRIPT" <<<"$3" >/dev/null 2>&1
}
E12="$(keychain_env)"; mkdir -p "$E12/profile b"
run_profile "$E12" "$E12/profile b" "$PAYLOAD2"
if grep -qx security "$E12/stub-called" 2>/dev/null; then
  echo "FAIL custom-profile-skips-default-keychain"; fails=$((fails+1))
else
  echo "PASS custom-profile-skips-default-keychain"
fi
E13="$(keychain_env)"
run_profile "$E13" "$E13/home/.claude" "$PAYLOAD2"
if grep -qx security "$E13/stub-called" 2>/dev/null; then
  echo "PASS default-profile-reads-keychain"
else
  echo "FAIL default-profile-reads-keychain"; fails=$((fails+1))
fi

exit $fails
