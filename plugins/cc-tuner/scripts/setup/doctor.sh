#!/usr/bin/env bash
# cc-tuner setup doctor: report what this machine and repo are missing before the installers run.
#
# Deterministic checks only — the command that calls this handles anything needing judgement.
# Output is one line per check: "ok", "WARN" (degraded, still usable) or "MISS" (blocks something).
# Exit 0 when nothing is MISS, 1 otherwise. bash 3.2 compatible: macOS ships 3.2.57.
#
# Test seams (all default to the real thing):
#   CC_TUNER_PLUGIN_LIST_CMD  command whose stdout is the installed-plugin JSON
#                             (default: claude plugin list --json)
#   CC_TUNER_MCP_CMD     command whose stdout is parsed for MCP servers (default: claude mcp list)
#   CC_TUNER_HOME        home dir for user-level checks (default: $HOME)
set -u

MODE="${1:-quick}"          # quick | full — full adds the MCP probe, which health-checks every
                            # configured server and can sit for 30s per unreachable one.
UHOME="${CC_TUNER_HOME:-$HOME}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
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
# `claude plugin list --json` is the platform's own answer, so nothing here parses a plugin manifest.
# What it does NOT answer is which installation applies: it returns one row per installation, and on
# 2.1.231 cc-tuner comes back twice — `scope: project` with a `projectPath` and `scope: user` without
# one, both `enabled: true`, with no `active` field. So the selection rule still has to exist, or the
# reported version is a coin flip between two installs. Same total order the delivery gate applies:
# local, then project, then user; a row scoped to a different project cannot answer for this repo.
PLUGIN_LIST="$(${CC_TUNER_PLUGIN_LIST_CMD:-claude plugin list --json} 2>/dev/null)" || PLUGIN_LIST=""

plugin_here() {  # plugin_here <id> -> "<version> (<scope>)" for the install that applies here
  printf '%s' "$PLUGIN_LIST" | jq -r --arg id "$1" --arg project "$REPO_ROOT" '
    [ .[]? | select(.id == $id and (
        .scope == "user"
        or ((.scope == "project" or .scope == "local") and .projectPath == $project)
      )) ]
    | sort_by(if .scope == "local" then 0 elif .scope == "project" then 1 else 2 end)
    | .[0] // empty | "\(.version) (\(.scope))"
  ' 2>/dev/null
}

companion() {  # companion <id> <what needs it> <install hint>
  found="$(plugin_here "$1")"
  if [ -n "$found" ]; then
    ok "$1 $found — $2"
  else
    bad "$1 not installed for this repo — $2; install: $3"
  fi
}

if [ -z "$PLUGIN_LIST" ] || ! command -v jq >/dev/null 2>&1; then
  warn "could not list installed plugins — companion plugin checks skipped"
else
  companion 'mattpocock-skills@mattpocock' \
    'grilling + domain-modeling in /cc-tuner:spec, code-review in /cc-tuner:run' \
    '/plugin marketplace add mattpocock/skills && /plugin install mattpocock-skills@mattpocock'
  companion 'cc-codex-triage@cc-codex-triage' \
    'required-review gate in /cc-tuner:run' \
    '/plugin marketplace update cc-codex-triage && /plugin update cc-codex-triage@cc-codex-triage'
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
if [ -n "$REPO_ROOT" ]; then
  [ -f "$REPO_ROOT/.claude/rules/task-flow.md" ] \
    && ok "task-flow rule installed" \
    || warn "task-flow rule not installed here — /cc-tuner:task-flow-setup"
  [ -f "$REPO_ROOT/.claude/rules/git-flow.md" ] \
    && warn "legacy git-flow.md still present — /cc-tuner:task-flow-setup migrates it (keeps your cached board field IDs)"
  [ -f "$REPO_ROOT/.claude/smoke-verify.cfg" ] \
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
