#!/usr/bin/env bash
# cc-tuner setup doctor: report what this machine and repo are missing before the installers run.
#
# Deterministic checks only — the command that calls this handles anything needing judgement.
# Output is one line per check: "ok", "WARN" (degraded, still usable) or "MISS" (blocks something).
# Exit 0 when nothing is MISS, 1 otherwise. bash 3.2 compatible: macOS ships 3.2.57.
#
# Test seams (all default to the real thing):
#   CLAUDE_PLUGIN_CACHE  plugin cache root, honoured by prereq-check.sh too
#   CC_TUNER_MCP_CMD     command whose stdout is parsed for MCP servers (default: claude mcp list)
#   CC_TUNER_HOME        home dir for user-level checks (default: $HOME)
set -u

MODE="${1:-quick}"          # quick | full — full adds the MCP probe, which health-checks every
                            # configured server and can sit for 30s per unreachable one.
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/../.." && pwd)"
UHOME="${CC_TUNER_HOME:-$HOME}"
miss=0

say()  { printf '%s\n' "$1"; }
ok()   { say "ok   $1"; }
warn() { say "WARN $1"; }
bad()  { say "MISS $1"; miss=1; }

# --- 1. command-line tools ----------------------------------------------------------------------
# jq is hard-required: statusline-setup refuses to patch settings.json without it, and tests/run.sh
# will not start. The rest degrade rather than block.
# Plain `if`, not `a && b || c`: that chain runs `c` whenever `b` fails, so one day a reporting
# helper returns non-zero and the script starts claiming things are missing that are not.
if command -v git     >/dev/null 2>&1; then ok "git";     else bad "git — required for every command here"; fi
if command -v jq      >/dev/null 2>&1; then ok "jq";      else bad "jq — statusline-setup and the test runner both refuse to run without it; brew install jq"; fi
if command -v gh      >/dev/null 2>&1; then ok "gh";      else warn "gh — board and PR recipes in the task-flow skill need it; brew install gh"; fi
if command -v python3 >/dev/null 2>&1; then ok "python3"; else warn "python3 — the statusline's usage segment degrades without it"; fi

# --- 2. gh auth and the project scope ------------------------------------------------------------
# `gh project *` fails with an opaque GraphQL error when the token lacks `project`. That error is the
# single most common reason an agent silently gives up on the board, so name it before it happens.
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    # Match the scope exactly rather than as a substring: `read:project` contains "project" but
    # cannot run `project item-edit`, so a substring test would report a working board and be wrong.
    if gh auth status 2>&1 | sed -n "s/.*Token scopes: //p" | tr -d "'" | tr ',' '\n' | tr -d ' ' \
       | grep -qx project; then
      ok "gh token has the 'project' scope"
    else
      bad "gh token lacks the 'project' scope — board commands fail with an opaque GraphQL error; fix: gh auth refresh -s project"
    fi
  else
    bad "gh is not authenticated — run: gh auth login"
  fi
fi

# --- 3. companion plugins ------------------------------------------------------------------------
# Delegated to the existing checker rather than duplicated: it already knows the anchor paths.
PREREQ="$PLUGIN_ROOT/scripts/execute-task/prereq-check.sh"
if [ -f "$PREREQ" ]; then
  if out="$(bash "$PREREQ" 2>&1)"; then
    ok "companion plugins (superpowers, cc-codex-triage)"
  else
    printf '%s\n' "$out" | while IFS= read -r line; do
      case "$line" in
        MISSING:*) say "MISS ${line#MISSING: }" ;;
        *)         say "     $line" ;;
      esac
    done
    miss=1
  fi
else
  warn "prereq-check.sh not found at $PREREQ — cannot verify companion plugins"
fi

# --- 4. MCP servers (full mode only) -------------------------------------------------------------
if [ "$MODE" = "full" ]; then
  mcp_out="$(${CC_TUNER_MCP_CMD:-claude mcp list} 2>/dev/null)" || mcp_out=""
  if [ -z "$mcp_out" ]; then
    warn "could not list MCP servers — skipping context7 / chrome-devtools checks"
  else
    for srv in context7 chrome-devtools; do
      line="$(printf '%s\n' "$mcp_out" | grep "^$srv:" | head -1)"
      if [ -z "$line" ]; then
        warn "MCP '$srv' not configured — task-flow research steps fall back to WebFetch"
      elif printf '%s' "$line" | grep -q 'Connected'; then
        ok "MCP '$srv' connected"
      else
        warn "MCP '$srv' configured but not connected: $line"
      fi
    done
  fi
else
  say "     (MCP probe skipped — run 'full' to include it; it health-checks every server)"
fi

# --- 5. what is installed in THIS repo -----------------------------------------------------------
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  [ -f "$ROOT/.claude/rules/task-flow.md" ] \
    && ok "task-flow rule installed" \
    || warn "task-flow rule not installed here — /cc-tuner:task-flow-setup"
  [ -f "$ROOT/.claude/rules/git-flow.md" ] \
    && warn "legacy git-flow.md still present — /cc-tuner:task-flow-setup migrates it (keeps your cached board field IDs)"
  [ -f "$ROOT/.claude/smoke-verify.cfg" ] \
    && ok "smoke-verify gate opted in" \
    || say "     smoke-verify not opted in here (frontend repos only — /cc-tuner:smoke-verify-setup)"
else
  warn "not inside a git repository — repo-level checks skipped"
fi

# --- 6. user-level statusline --------------------------------------------------------------------
if [ -f "$UHOME/.claude/cc-tuner-statusline.sh" ]; then
  ok "statusline script installed"
else
  say "     statusline not installed (optional — /cc-tuner:statusline-setup)"
fi

say ""
if [ "$miss" -eq 0 ]; then
  say "doctor: no blockers"
else
  say "doctor: blockers found (see MISS lines)"
fi
exit "$miss"
