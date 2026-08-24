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

mkenv() { # builds $STUB (PATH) + $H (home) + $R (repo, physical path in $RP)
  T="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
  STUB="$T/bin"; FAKE_HOME="$T/plugin-home"; H="$T/home"; R="$T/repo"
  mkdir -p "$STUB" "$FAKE_HOME" "$H/.claude" "$R"
  for u in sed tr grep head dirname bash cat; do
    src="$(command -v "$u")" && ln -s "$src" "$STUB/$u"
  done
  ( cd "$R" && git init -q -b main 2>/dev/null ) || true
  RP="$(cd "$R" && pwd -P)"   # `git rev-parse --show-toplevel` resolves symlinks; projectPath must match
}
tool() { ln -s "$(command -v "$1")" "$STUB/$1" 2>/dev/null || true; }   # expose a real tool
ghstub() { printf '#!/bin/sh\n[ "$1" = auth ] || exit 0\ncat <<EOF\n  - Token scopes: %s\nEOF\n' "$1" > "$STUB/gh"; chmod +x "$STUB/gh"; }
# Stand in for `claude plugin list --json`; $1 is the JSON array it prints, with `__REPO__` standing
# for this fixture's repo path. Pass it as a single-quoted literal: bash 3.2 brace-expands a quoted
# command substitution used as a function argument, which shreds JSON objects into separate words.
claude_plugins() {
  { printf '#!/bin/sh\ncat <<%s\n' "'PLUGINS_EOF'"
    printf '%s\n' "$1" | sed "s|__REPO__|$RP|g"
    printf 'PLUGINS_EOF\n'
  } > "$STUB/claude"
  chmod +x "$STUB/claude"
}
plugins_ok() {   # both companions installed user-wide
  claude_plugins '[
    {"id":"mattpocock-skills@mattpocock","version":"1.0.0","scope":"user","enabled":true},
    {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
  ]'
}
run() { ( cd "${1:-$R}" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" \
          bash "$DOCTOR" "${2:-quick}" 2>&1 ); }

# --- baseline: everything present -> no blockers, exit 0 -----------------------------------------
mkenv; tool git; tool jq; tool python3; ghstub "'gist', 'project', 'repo'"; plugins_ok
OUT="$(run)"; rc=$?
check   "baseline-exit0"      "doctor: no blockers" "$OUT"
absent  "baseline-no-miss"    "MISS"                "$OUT"
check   "baseline-version"    "mattpocock-skills@mattpocock 1.0.0 (user)" "$OUT"
[ $rc -eq 0 ] || { echo "FAIL baseline-rc (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- jq missing -> WARN, and it must NOT block ---------------------------------------------------
# /cc-tuner:setup stops on a non-zero exit, so a MISS here halted setting up claude-md-writer, which
# never calls jq. The two consumers that do need it -- statusline-setup and tests/run.sh -- refuse on
# their own, at the point of use.
mkenv; tool git; tool python3; ghstub "'project'"; plugins_ok
OUT="$(run)"; rc=$?
check  "jq-missing-warned"  "WARN jq" "$OUT"
absent "jq-missing-no-miss" "MISS"    "$OUT"
[ $rc -eq 0 ] && echo "PASS jq-missing-rc0" || { echo "FAIL jq-missing-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- gh present but token has no project scope -> WARN with the refresh hint, and no block --------
# A spec may say `board: none`, and that repo never runs a board command. Step 4 of /cc-tuner:setup
# owns the refusal, because it is the step that actually needs the scope.
mkenv; tool git; tool jq; ghstub "'gist', 'repo'"; plugins_ok
OUT="$(run)"; rc=$?
check  "no-project-scope-flagged" "WARN gh token lacks the 'project' scope" "$OUT"
check  "no-project-scope-hint"    "gh auth refresh -s project"              "$OUT"
absent "no-project-scope-no-miss" "MISS"                                    "$OUT"
[ $rc -eq 0 ] && echo "PASS no-project-scope-rc0" || { echo "FAIL no-project-scope-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- `read:project` must NOT satisfy the project scope (substring trap) --------------------------
# `gh project item-edit` needs write. A substring match would report a working board and be wrong.
mkenv; tool git; tool jq; ghstub "'gist', 'read:project', 'repo'"; plugins_ok
OUT="$(run)"
check "read-project-not-accepted" "WARN gh token lacks the 'project' scope" "$OUT"
rm -rf "$T"

# --- companion plugins absent -> MISS lines carrying the install hints ---------------------------
mkenv; tool git; tool jq; ghstub "'project'"; claude_plugins '[]'
OUT="$(run)"; rc=$?
check "plugins-missing-flagged" "MISS mattpocock-skills"            "$OUT"
check "plugins-missing-hint"    "/plugin install mattpocock-skills" "$OUT"
[ $rc -eq 1 ] && echo "PASS plugins-missing-rc1" || { echo "FAIL plugins-missing-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- `claude plugin list` unavailable -> degraded, not a blocker ---------------------------------
mkenv; tool git; tool jq; ghstub "'project'"        # no claude on PATH
OUT="$(run)"; rc=$?
check  "plugin-list-unavailable-warned" "WARN could not list installed plugins" "$OUT"
absent "plugin-list-unavailable-no-miss" "MISS"                                 "$OUT"
[ $rc -eq 0 ] || { echo "FAIL plugin-list-unavailable-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- an install scoped to ANOTHER project cannot answer for this repo -----------------------------
mkenv; tool git; tool jq; ghstub "'project'"
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"9.9.9","scope":"project","enabled":true,"projectPath":"/somewhere/else"},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
]'
OUT="$(run)"
check  "foreign-project-ignored"  "MISS mattpocock-skills" "$OUT"
absent "foreign-version-not-used" "9.9.9"                  "$OUT"
rm -rf "$T"

# --- precedence: this repo's project-scoped install wins over the user-wide one -------------------
# `claude plugin list --json` returns every installation with `enabled: true` and no `active` field,
# so without this order doctor reports whichever row happens to come first — a coin flip on version.
mkenv; tool git; tool jq; ghstub "'project'"
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"1.0.0","scope":"user","enabled":true},
  {"id":"mattpocock-skills@mattpocock","version":"2.0.0","scope":"project","enabled":true,"projectPath":"__REPO__"},
  {"id":"mattpocock-skills@mattpocock","version":"9.9.9","scope":"project","enabled":true,"projectPath":"/somewhere/else"},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
]'
OUT="$(run)"
check  "project-scope-wins"    "mattpocock-skills@mattpocock 2.0.0 (project)" "$OUT"
absent "user-scope-not-chosen" "mattpocock-skills@mattpocock 1.0.0"           "$OUT"
absent "other-project-not-chosen" "9.9.9"                                     "$OUT"
rm -rf "$T"

# --- a disabled install is not an install --------------------------------------------------------
# A disabled plugin does not load its commands, so `/review --required` cannot run. Reporting it `ok`
# would be a false green in the one tool whose job is to say whether the environment works.
mkenv; tool git; tool jq; ghstub "'project'"
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"1.0.0","scope":"user","enabled":true},
  {"id":"mattpocock-skills@mattpocock","version":"2.0.0","scope":"project","enabled":false,"projectPath":"__REPO__"},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
]'
OUT="$(run)"
absent "disabled-install-not-chosen" "mattpocock-skills@mattpocock 2.0.0" "$OUT"
check  "disabled-falls-back-to-enabled" "mattpocock-skills@mattpocock 1.0.0 (user)" "$OUT"

# ...and when the only install is disabled, that is a MISS, not a silent pass.
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"2.0.0","scope":"user","enabled":false},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
]'
OUT="$(run)"
check "only-install-disabled-misses" "MISS mattpocock-skills@mattpocock" "$OUT"
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
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" full 2>&1 )"
check  "mcp-connected-ok"      "ok   MCP 'context7' connected"                 "$OUT"
check  "mcp-not-connected"     "WARN MCP 'chrome-devtools' configured but not" "$OUT"
absent "mcp-not-a-blocker"     "MISS"                                          "$OUT"

# quick mode must NOT probe -- the probe health-checks every server and can hang for 30s each
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" quick 2>&1 )"
absent "quick-skips-mcp" "MCP 'context7'" "$OUT"
rm -rf "$T"

# --- the native task tools are opt-in on current models -------------------------------------------
# /cc-tuner:plan publishes the visible plan through TaskCreate. From Claude Code 2.1.233 those tools
# are off by default on Opus 4.8 / Sonnet 5 and later. Four eval sessions published no task list
# because of it and the cause was misread as an MCP outage each time, which is why doctor now says it.
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" bash "$DOCTOR" quick 2>&1 )"
check "todo-tools-unset-warns" "CLAUDE_CODE_ENABLE_TODO_TOOLS is not set" "$OUT"
absent "todo-tools-unset-not-a-blocker" "MISS CLAUDE_CODE_ENABLE_TODO_TOOLS" "$OUT"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" \
        CLAUDE_CODE_ENABLE_TODO_TOOLS=1 bash "$DOCTOR" quick 2>&1 )"
check "todo-tools-set-ok" "ok   CLAUDE_CODE_ENABLE_TODO_TOOLS is set" "$OUT"
rm -rf "$T"

# --- "cannot tell" is not "not installed" --------------------------------------------------------
# The resolver reports three outcomes: found, absent, and unable to answer. doctor used to end the
# call with `|| return 0`, flattening the last two, so a plugin list it could not parse produced two
# confident MISS lines naming install commands for plugins nobody had looked for. A blocker the user
# cannot act on correctly is worse than a warning that says what is actually wrong.
mkenv; tool git; tool jq; ghstub "'project'"
printf '#!/bin/sh\nprintf "{not-json"\n' > "$STUB/claude"; chmod +x "$STUB/claude"
OUT="$(run)"; rc=$?
check  "unparsable-list-warns"          "WARN mattpocock-skills@mattpocock — could not determine" "$OUT"
absent "unparsable-list-does-not-miss"  "MISS mattpocock-skills"                                  "$OUT"
absent "unparsable-list-no-install-hint" "plugin marketplace add mattpocock"                      "$OUT"
[ $rc -eq 0 ] && echo "PASS unparsable-list-is-not-a-blocker" \
              || { echo "FAIL unparsable-list-is-not-a-blocker (rc=$rc)"; fails=1; }
rm -rf "$T"

# ...and a plugin that really is absent must still be a blocker, or the branch above would pass by
# never reporting anything.
mkenv; tool git; tool jq; ghstub "'project'"
claude_plugins '[{"id":"cc-codex-triage@cc-codex-triage","version":"1","scope":"user","enabled":true,"installPath":"/x"}]'
OUT="$(run)"
check "genuinely-absent-still-misses" "MISS mattpocock-skills@mattpocock not installed" "$OUT"
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
