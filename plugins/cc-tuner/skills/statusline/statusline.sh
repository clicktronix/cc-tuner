#!/usr/bin/env bash
#
# cc-tuner usage statusline for Claude Code.
#
# Renders two lines:
#   line 1: ➜ <dir> git:(<branch>) S:.. M:.. U:..  | <model> | <session duration>
#   line 2: 5h:NN%[bar]>HH:MM  7d:NN%[bar]>HH:MM | ctx:NN%[bar]
#
# The 5h / 7d figures come from Claude Code's OAuth usage endpoint, cached for
# 5 minutes. This is an UNOFFICIAL/internal endpoint (api/oauth/usage,
# anthropic-beta: oauth-2025-04-20) — it may change or stop working without
# notice. Everything degrades gracefully: if the token or endpoint is
# unavailable, the rate-limit segment is simply omitted.
#
# Cross-platform: macOS (Keychain), Linux & Windows (~/.claude/.credentials.json,
# honoring $CLAUDE_CONFIG_DIR). Requires: bash, jq, python3, git.

# --- ANSI colors ($'...' emits real ESC bytes) ---
GREEN=$'\033[1;32m'
CYAN=$'\033[0;36m'
BLUE=$'\033[1;34m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
MAGENTA=$'\033[0;35m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Portable file mtime (epoch seconds): BSD/macOS `stat -f`, GNU/Linux `stat -c`.
_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# JSON from stdin (the statusline payload Claude Code pipes in)
input=$(cat)

# --- Directory ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
dir_name=$(basename "$cwd")

# --- Git info with staged/modified/untracked counts ---
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    staged=$(git -C "$cwd" diff --cached --numstat --no-optional-locks 2>/dev/null | wc -l | tr -d ' ')
    modified=$(git -C "$cwd" diff --numstat --no-optional-locks 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

    counts=""
    [ "$staged" -gt 0 ] 2>/dev/null && counts="${counts} ${GREEN}S:${staged}${RESET}"
    [ "$modified" -gt 0 ] 2>/dev/null && counts="${counts} ${YELLOW}M:${modified}${RESET}"
    [ "$untracked" -gt 0 ] 2>/dev/null && counts="${counts} ${RED}U:${untracked}${RESET}"

    if [ -n "$counts" ]; then
      git_info=" ${BLUE}git:(${RED}${branch}${BLUE})${RESET}${counts}"
    else
      git_info=" ${BLUE}git:(${RED}${branch}${BLUE})${RESET} ${GREEN}✓${RESET}"
    fi
  fi
fi

# --- Model + reasoning effort ---
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
model_info=""
if [ -n "$model" ]; then
  model_info=" ${DIM}|${RESET} ${MAGENTA}${model}${RESET}"
  # .effort.level is present only when the model supports it (low/medium/high/xhigh)
  [ -n "$effort" ] && model_info="${model_info} ${DIM}${effort}${RESET}"
fi

# --- Session duration (with hours rollover) ---
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
duration_info=""
if [ -n "$duration_ms" ] && [ "$duration_ms" != "0" ]; then
  duration_sec=$((duration_ms / 1000))
  mins=$((duration_sec / 60))
  secs=$((duration_sec % 60))
  hours=$((mins / 60))
  mins=$((mins % 60))
  if [ "$hours" -gt 0 ]; then
    dur="${hours}h${mins}m"
  elif [ "$mins" -gt 0 ]; then
    dur="${mins}m${secs}s"
  else
    dur="${secs}s"
  fi
  duration_info=" ${DIM}|${RESET} ${DIM}${dur}${RESET}"
fi

# --- Rate-limit usage (5 min cache, mkdir lock so only one process refreshes) ---
usage_info=""
USAGE_CACHE="${TMPDIR:-/tmp}/claude_usage_cache"
USAGE_CACHE_LOCK="${TMPDIR:-/tmp}/claude_usage_cache.lock"
USAGE_CACHE_TTL=300

refresh_usage() {
  # mkdir is atomic — only one process wins the lock and refreshes.
  if ! mkdir "$USAGE_CACHE_LOCK" 2>/dev/null; then
    # Drop a stale lock (a crashed process would leave it forever).
    local lock_age=$(( $(date +%s) - $(_mtime "$USAGE_CACHE_LOCK") ))
    [ "$lock_age" -gt 30 ] && rm -rf "$USAGE_CACHE_LOCK" || return 0
    mkdir "$USAGE_CACHE_LOCK" 2>/dev/null || return 0
  fi
  trap 'rm -rf "$USAGE_CACHE_LOCK"' RETURN

  local tmp="${USAGE_CACHE}.tmp.$$"
  # Python does three things: find the OAuth token cross-platform, call the
  # usage endpoint, and pre-compute local reset times (HH:MM) into the cached
  # JSON so the per-render path needs no python at all.
  python3 -c "
import json, urllib.request, sys, subprocess, re, codecs, os, shutil
from datetime import datetime

def get_token():
    # macOS: Keychain
    if shutil.which('security'):
        try:
            r = subprocess.run(
                ['security', 'find-generic-password', '-s', 'Claude Code-credentials', '-w'],
                capture_output=True, text=True, timeout=5)
            raw = r.stdout.strip()
            if raw:
                try:
                    return json.loads(raw)['claudeAiOauth']['accessToken']
                except (json.JSONDecodeError, ValueError, KeyError):
                    try:
                        decoded = codecs.decode(raw, 'hex').decode('utf-8')
                        m = re.search(r'\"accessToken\":\"([^\"]+)\"', decoded)
                        if m:
                            return m.group(1)
                    except Exception:
                        pass
        except Exception:
            pass
    # Linux / Windows: credentials file (honors CLAUDE_CONFIG_DIR)
    cfg = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.join(os.path.expanduser('~'), '.claude')
    try:
        with open(os.path.join(cfg, '.credentials.json')) as f:
            return json.load(f)['claudeAiOauth']['accessToken']
    except Exception:
        return None

token = get_token()
if not token:
    sys.exit(1)
req = urllib.request.Request(
    'https://api.anthropic.com/api/oauth/usage',
    headers={'Authorization': f'Bearer {token}', 'anthropic-beta': 'oauth-2025-04-20'})
data = json.loads(urllib.request.urlopen(req, timeout=5).read())

for key in ('five_hour', 'seven_day'):
    node = data.get(key)
    if isinstance(node, dict) and node.get('resets_at'):
        try:
            node['reset_local'] = datetime.fromisoformat(node['resets_at']).astimezone().strftime('%H:%M')
        except Exception:
            pass
json.dump(data, sys.stdout)
" > "$tmp" 2>/dev/null
  if [ $? -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$USAGE_CACHE"
  else
    rm -f "$tmp"
    # On failure, touch the old cache so we keep showing it and retry after TTL.
    [ -f "$USAGE_CACHE" ] && touch "$USAGE_CACHE"
  fi
}

# Refresh when the cache is missing or older than the TTL.
if [ ! -f "$USAGE_CACHE" ]; then
  refresh_usage
else
  cache_age=$(( $(date +%s) - $(_mtime "$USAGE_CACHE") ))
  [ "$cache_age" -gt "$USAGE_CACHE_TTL" ] && refresh_usage
fi

# Progress bar helper. usage: make_bar <percent> <length> -> bar_result, bar_color
make_bar() {
  local pct=$1
  local len=$2

  if [ "$pct" -ge 80 ]; then
    bar_color="${RED}"
  elif [ "$pct" -ge 50 ]; then
    bar_color="${YELLOW}"
  else
    bar_color="${GREEN}"
  fi

  local filled=$(( pct * len / 100 ))
  [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  [ "$filled" -gt "$len" ] && filled=$len
  local empty_count=$(( len - filled ))

  bar_result=""
  [ "$filled" -gt 0 ] && bar_result=$(printf "%${filled}s" | tr ' ' '▓')
  [ "$empty_count" -gt 0 ] && bar_result="${bar_result}$(printf "%${empty_count}s" | tr ' ' '░')"
}

# Coerce a "66.6"-style utilization into a safe integer percent.
to_int_pct() {
  local v=${1%.*}
  case "$v" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

# Render one rate-limit window. usage: window_segment <label> <pct> <reset_local>
window_segment() {
  local label=$1 pct reset
  pct=$(to_int_pct "$2")
  reset=$3
  make_bar "$pct" 8
  local reset_str=""
  [ -n "$reset" ] && reset_str="${DIM}>${reset}${RESET}"
  # Format is '%s' — the literal % belongs in the data argument as a single %.
  printf '%s' " ${bar_color}${label}:${pct}%${RESET}${DIM}[${RESET}${bar_color}${bar_result}${RESET}${DIM}]${RESET}${reset_str}"
}

# Parse cache → 5h / 7d segments
if [ -f "$USAGE_CACHE" ] && [ -s "$USAGE_CACHE" ]; then
  five_h=$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  five_reset=$(jq -r '.five_hour.reset_local // empty' "$USAGE_CACHE" 2>/dev/null)
  seven_d=$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null)
  seven_reset=$(jq -r '.seven_day.reset_local // empty' "$USAGE_CACHE" 2>/dev/null)

  [ -n "$five_h" ] && usage_info="${usage_info} ${DIM}|${RESET}$(window_segment 5h "$five_h" "$five_reset")"
  [ -n "$seven_d" ] && usage_info="${usage_info}$(window_segment 7d "$seven_d" "$seven_reset")"
fi

# --- Context window with progress bar ---
context_info=""
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used_pct" ]; then
  used_int=$(to_int_pct "$used_pct")
  make_bar "$used_int" 10
  context_info=" ${DIM}|${RESET} ${bar_color}ctx:${used_int}%${RESET} ${DIM}[${RESET}${bar_color}${bar_result}${RESET}${DIM}]${RESET}"
fi

# --- Second line: the bars ---
bars_line="${usage_info}${context_info}"

# Output: line 1 = dir/git/model/duration, line 2 = bars
printf "%s  %s%s%s%s\n%s" \
  "${GREEN}➜${RESET}" \
  "${CYAN}${dir_name}${RESET}" \
  "$git_info" \
  "$model_info" \
  "$duration_info" \
  "$bars_line"
