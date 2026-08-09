#!/usr/bin/env bash
# Regression tests for scripts/setup/doctor.sh.
#
# The tool-presence checks are exercised by running doctor with a PATH containing ONLY a stub dir,
# then choosing which of git/jq/gh/python3 to place in it. Symlinking the handful of real utilities
# doctor needs keeps this deterministic on both macOS and ubuntu, where the system paths differ.
set -u
DOCTOR="$(cd "$(dirname "$0")/../../scripts/setup" && pwd)/doctor.sh"
fails=0

check() { # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -q "$2"; then echo "PASS $1"; else echo "FAIL $1 (want /$2/ in: $3)"; fails=1; fi
}
absent() {
  if printf '%s' "$3" | grep -q "$2"; then echo "FAIL $1 (unwanted /$2/ present)"; fails=1; else echo "PASS $1"; fi
}

mkenv() { # builds $STUB (PATH) + $CACHE (plugins) + $H (home) + $R (repo)
  T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  STUB="$T/bin"; CACHE="$T/plugins"; H="$T/home"; R="$T/repo"
  mkdir -p "$STUB" "$CACHE" "$H/.claude" "$R"
  for u in sed tr grep head dirname bash cat; do
    src="$(command -v "$u")" && ln -s "$src" "$STUB/$u"
  done
  ( cd "$R" && git init -q -b main 2>/dev/null ) || true
}
tool() { ln -s "$(command -v "$1")" "$STUB/$1" 2>/dev/null || true; }   # expose a real tool
ghstub() { printf '#!/bin/sh\n[ "$1" = auth ] || exit 0\ncat <<EOF\n  - Token scopes: %s\nEOF\n' "$1" > "$STUB/gh"; chmod +x "$STUB/gh"; }
plugins_ok() {   # anchors prereq-check.sh looks for: mattpocock-skills (grilling + code-review) + cc-codex-triage
  mkdir -p "$CACHE/cache/m/mattpocock-skills/1/skills/productivity/grilling" \
           "$CACHE/cache/m/mattpocock-skills/1/skills/engineering/domain-modeling" \
           "$CACHE/cache/m/mattpocock-skills/1/skills/engineering/code-review" \
           "$CACHE/cache/m/cc-codex-triage/1/commands" \
           "$CACHE/cache/m/cc-codex-triage/1/scripts"
  touch "$CACHE/cache/m/mattpocock-skills/1/skills/productivity/grilling/SKILL.md" \
        "$CACHE/cache/m/mattpocock-skills/1/skills/engineering/domain-modeling/SKILL.md" \
        "$CACHE/cache/m/mattpocock-skills/1/skills/engineering/code-review/SKILL.md"
  printf '%s\n' 'CC_CODEX_REQUIRED_REVIEW APPROVE' \
    > "$CACHE/cache/m/cc-codex-triage/1/scripts/review-state.sh"
  printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' \
    > "$CACHE/cache/m/cc-codex-triage/1/commands/review.md"
}
run() { ( cd "${1:-$R}" && PATH="$STUB" CLAUDE_PLUGIN_CACHE="$CACHE" CC_TUNER_HOME="$H" \
          bash "$DOCTOR" "${2:-quick}" 2>&1 ); }

# --- baseline: everything present -> no blockers, exit 0 -----------------------------------------
mkenv; tool git; tool jq; tool python3; ghstub "'gist', 'project', 'repo'"; plugins_ok
OUT="$(run)"; rc=$?
check   "baseline-exit0"      "doctor: no blockers" "$OUT"
absent  "baseline-no-miss"    "MISS"                "$OUT"
[ $rc -eq 0 ] || { echo "FAIL baseline-rc (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- jq missing -> MISS and exit 1 ---------------------------------------------------------------
mkenv; tool git; tool python3; ghstub "'project'"; plugins_ok
OUT="$(run)"; rc=$?
check "jq-missing-flagged" "MISS jq" "$OUT"
[ $rc -eq 1 ] && echo "PASS jq-missing-rc1" || { echo "FAIL jq-missing-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- gh present but token has no project scope -> MISS with the refresh hint ---------------------
mkenv; tool git; tool jq; ghstub "'gist', 'repo'"; plugins_ok
OUT="$(run)"
check "no-project-scope-flagged" "MISS gh token lacks the 'project' scope" "$OUT"
check "no-project-scope-hint"    "gh auth refresh -s project"              "$OUT"
rm -rf "$T"

# --- `read:project` must NOT satisfy the project scope (substring trap) --------------------------
# `gh project item-edit` needs write. A substring match would report a working board and be wrong.
mkenv; tool git; tool jq; ghstub "'gist', 'read:project', 'repo'"; plugins_ok
OUT="$(run)"
check "read-project-not-accepted" "MISS gh token lacks the 'project' scope" "$OUT"
rm -rf "$T"

# --- companion plugins absent -> MISS lines carrying the install hints ---------------------------
mkenv; tool git; tool jq; ghstub "'project'"        # no plugins_ok
OUT="$(run)"; rc=$?
check "plugins-missing-flagged" "MISS mattpocock-skills"            "$OUT"
check "plugins-missing-hint"    "/plugin install mattpocock-skills" "$OUT"
[ $rc -eq 1 ] && echo "PASS plugins-missing-rc1" || { echo "FAIL plugins-missing-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- legacy git-flow.md in the repo -> migration warning -----------------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
mkdir -p "$R/.claude/rules"; echo legacy > "$R/.claude/rules/git-flow.md"
OUT="$(run)"
check "legacy-rule-warned" "WARN legacy git-flow.md still present" "$OUT"
rm -rf "$T"

# --- MCP probe: only runs in full mode, and reads connection state not mere presence -------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
printf '#!/bin/sh\ncat <<EOF\ncontext7: https://mcp.context7.com/mcp (HTTP) - OK Connected\nchrome-devtools: npx chrome-devtools-mcp - X Failed to connect\nEOF\n' > "$STUB/mcpfix"
chmod +x "$STUB/mcpfix"
OUT="$( cd "$R" && PATH="$STUB" CLAUDE_PLUGIN_CACHE="$CACHE" CC_TUNER_HOME="$H" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" full 2>&1 )"
check  "mcp-connected-ok"      "ok   MCP 'context7' connected"                 "$OUT"
check  "mcp-not-connected"     "WARN MCP 'chrome-devtools' configured but not" "$OUT"
absent "mcp-not-a-blocker"     "MISS"                                          "$OUT"

# quick mode must NOT probe -- the probe health-checks every server and can hang for 30s each
OUT="$( cd "$R" && PATH="$STUB" CLAUDE_PLUGIN_CACHE="$CACHE" CC_TUNER_HOME="$H" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" quick 2>&1 )"
absent "quick-skips-mcp" "MCP 'context7'" "$OUT"
rm -rf "$T"

# --- statusline detection is home-scoped ---------------------------------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
OUT="$(run)"
check "statusline-absent" "statusline not installed" "$OUT"
touch "$H/.claude/cc-tuner-statusline.sh"
OUT="$(run)"
check "statusline-present" "ok   statusline script installed" "$OUT"
rm -rf "$T"

exit $fails
