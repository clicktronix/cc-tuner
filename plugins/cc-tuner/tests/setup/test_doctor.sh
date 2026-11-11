#!/usr/bin/env bash
# Regression tests for scripts/setup/doctor.sh.
#
# The tool-presence checks are exercised by running doctor with a PATH containing ONLY a stub dir,
# then choosing which of git/jq/gh/python3 to place in it. Symlinking the handful of real utilities
# doctor needs keeps this deterministic on both macOS and ubuntu, where the system paths differ.
#
# The host comes from host.sh, offline, so a fixture picks its host the way a user does: through the
# `origin` remote (github by default, see mkenv) and, for a self-hosted forge, through the config files
# gh and glab keep. The gh and glab stubs log every call to $CALLS, which is how "doctor passed the
# remote's host to the CLI" and "doctor never asked the network which host this is" are asserted.
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
  MKT="$T/marketplaces.json"; printf '[]' > "$MKT"   # `claude plugin marketplace list --json`: none configured
  GH_AUTH_RC=0; GLAB_AUTH_RC=0; GLAB_HELP=both; PROFILE=""
  CALLS="$T/calls"; : > "$CALLS"
  GH_HOSTS="$T/gh-hosts.yml"; GLAB_CFG="$T/glab-config.yml"   # absent until a case writes them
  for u in sed tr grep head dirname bash cat; do
    src="$(command -v "$u")" && ln -s "$src" "$STUB/$u"
  done
  ( cd "$R" && git init -q -b main 2>/dev/null && git remote add origin git@github.com:acme/app.git ) || true
  RP="$(cd "$R" && pwd -P)"   # `git rev-parse --show-toplevel` resolves symlinks; projectPath must match
}
tool() { ln -s "$(command -v "$1")" "$STUB/$1" 2>/dev/null || true; }   # expose a real tool
# gh stub. $1 is the scopes line `gh auth status` prints; GH_AUTH_RC is its exit code. Every call is logged.
# A `repo` call is logged and fails: host detection must never ask the network, so nothing may land there.
ghstub() {
  { printf '#!/bin/sh\necho "gh $*" >> "%s"\nif [ "$1" = repo ]; then exit 1; fi\n' "$CALLS"
    printf 'if [ "$1" = auth ]; then\n  [ %s -eq 0 ] || exit 1\n  cat <<EOF\n  - Token scopes: %s\nEOF\nfi\nexit 0\n' "$GH_AUTH_RC" "$1"
  } > "$STUB/gh"
  chmod +x "$STUB/gh"
}
# glab stub: GLAB_AUTH_RC is the exit code of `glab auth status`; GLAB_HELP picks the flags `glab mr merge
# --help` lists (both | nosha | noauto), the way an older glab lacks them. Every call is logged.
glabstub() {
  { printf '#!/bin/sh\necho "glab $*" >> "%s"\nif [ "$1" = repo ]; then exit 1; fi\n' "$CALLS"
    printf 'if [ "$1" = auth ]; then exit %s; fi\n' "$GLAB_AUTH_RC"
    printf 'if [ "$1" = mr ] && [ "$2" = merge ]; then\n  echo "      --remove-source-branch   Remove source branch"\n'
    [ "$GLAB_HELP" = nosha ]  || printf '  echo "      --sha   Merge only if the HEAD matches this SHA"\n'
    [ "$GLAB_HELP" = noauto ] || printf '  echo "      --auto-merge   Set auto-merge"\n'
    printf 'fi\n'
    printf 'if [ "$1" = mr ] && [ "$2" = note ] && [ "$3" = create ]; then\n'
    [ "$GLAB_HELP" = nonote ] || printf '  echo "  -m --message  Comment or note message."\n  echo "     --resolvable  Create the note as a resolvable discussion thread."\n'
    printf '  exit 0\nfi\nexit 0\n'
  } > "$STUB/glab"
  chmod +x "$STUB/glab"
}
# Point origin at $1, and optionally list hosts the CLIs are logged in to (gh_hosts / glab_hosts).
setremote() { ( cd "$R" && git remote remove origin 2>/dev/null; git remote add origin "$1" ); }
noremote()  { ( cd "$R" && git remote remove origin ); }
gh_hosts()   { { for h in "$@"; do printf '%s:\n    user: me\n' "$h"; done; } > "$GH_HOSTS"; }
glab_hosts() { { printf 'host: gitlab.com\nhosts:\n'; for h in "$@"; do printf '    %s:\n        user:\n' "$h"; done; } > "$GLAB_CFG"; }
# codex stub: `codex login status` exits $1 (0 = logged in) and says so on stdout.
codexstub() { printf '#!/bin/sh\nif [ "$1" = login ]; then\n  [ %s -eq 0 ] && echo "Logged in using ChatGPT"\n  exit %s\nfi\nexit 0\n' "$1" "$1" > "$STUB/codex"; chmod +x "$STUB/codex"; }
# Stand in for `claude plugin marketplace list --json`: $1 is the JSON array it prints.
marketplaces() { printf '%s' "$1" > "$MKT"; }
matt_only() { claude_plugins '[{"id":"mattpocock-skills@mattpocock","version":"1.0.0","scope":"user","enabled":true}]'; }
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
run() { ( cd "${1:-$R}" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
          CC_TUNER_GH_HOSTS_FILE="$GH_HOSTS" CC_TUNER_GLAB_CONFIG_FILE="$GLAB_CFG" \
          CC_TUNER_MARKETPLACE_LIST_CMD="cat $MKT" bash "$DOCTOR" "${2:-quick}" 2>&1 ); }

# --- baseline: everything present -> no blockers, exit 0 -----------------------------------------
mkenv; tool git; tool jq; tool python3; ghstub "'gist', 'project', 'repo'"; plugins_ok
OUT="$(run)"; rc=$?
check   "baseline-exit0"      "doctor: no blockers" "$OUT"
absent  "baseline-no-miss"    "MISS"                "$OUT"
check   "baseline-version"    "mattpocock-skills@mattpocock 1.0.0 (user)" "$OUT"
[ $rc -eq 0 ] || { echo "FAIL baseline-rc (rc=$rc)"; fails=1; }
check   "matt-setup-missing-warned" "mattpocock-skills not configured for this repo" "$OUT"
mkdir -p "$R/docs/agents" && : > "$R/docs/agents/issue-tracker.md"
# The config files alone are not the contract: code-review 1.3 expects the tracker to "have been
# provided", i.e. named by the instructions the session loads, and asks for setup when it is not.
check   "matt-setup-unreferenced-warned" "docs/agents pointer not found" "$(run)"
POINTER='See `docs/agents/issue-tracker.md`.'
printf '## Agent skills\n\n%s\n' "$POINTER" > "$R/AGENTS.md"
OUT="$(run)"
absent  "matt-setup-present-quiet"  "mattpocock-skills not configured" "$OUT"
absent  "matt-setup-referenced-quiet" "docs/agents pointer" "$OUT"
# A CLAUDE file anywhere on the path switches AGENTS.md off, so its pointer no longer reaches the session.
printf 'Project instructions.\n' > "$R/CLAUDE.md"
OUT="$(run)"
check   "matt-setup-shadowed-agents-warned" "docs/agents pointer not loaded" "$OUT"
check   "matt-setup-shadowed-names-claude" "/repo/CLAUDE.md switches" "$OUT"
rm -f "$R/AGENTS.md"
# @-imports are not followed: a pointer reached only through one is reported, and the limit is named,
# rather than doctor claiming to know the session's context. That includes an @-path in a code span.
printf '%s\n' "$POINTER" > "$R/guide.md"
printf 'Project instructions.\n@guide.md\n' > "$R/CLAUDE.md"
check   "matt-setup-import-limit-named" "does not follow @-imports" "$(run)"
printf 'Example: `@guide.md`\n' > "$R/CLAUDE.md"
check   "matt-setup-codespan-import-warned" "docs/agents pointer not found" "$(run)"
rm -f "$R/CLAUDE.md" "$R/guide.md"
printf '%s\n' "$POINTER" > "$R/CLAUDE.local.md"
absent  "matt-setup-claude-local-quiet" "docs/agents pointer" "$(run)"
rm -f "$R/CLAUDE.local.md"
mkdir -p "$R/.claude/rules/sub"; printf '%s\n' "$POINTER" > "$R/.claude/AGENTS.md"
absent  "matt-setup-dotclaude-agents-quiet" "docs/agents pointer" "$(run)"
rm -f "$R/.claude/AGENTS.md"
# Rules without paths: load at launch; a path-scoped rule loads only when a matching file is touched.
printf -- '---\ndescription: setup\n---\n%s\n' "$POINTER" > "$R/.claude/rules/sub/setup.md"
absent  "matt-setup-unscoped-rule-quiet" "docs/agents pointer" "$(run)"
printf -- '---\npaths:\n  - "src/**"\n---\n%s\n' "$POINTER" > "$R/.claude/rules/sub/setup.md"
check   "matt-setup-scoped-rule-warned" "docs/agents pointer not found" "$(run)"
rm -rf "$R/.claude/rules/sub"
rm -rf "$R/docs/agents"
# Outside a repository there is no repo config to judge; the repo checks below are skipped too.
NOGIT="$T/plain"; mkdir -p "$NOGIT"
absent  "matt-setup-skipped-outside-git" "mattpocock-skills not configured" "$(run "$NOGIT")"
rm -rf "$T"

# --- jq missing -> WARN, and it must NOT block ---------------------------------------------------
# /cc-tuner:setup stops on a non-zero exit, so a MISS here halted setting up claude-md-writer, which
# never calls jq. The two consumers that do need it -- the statusline node and tests/run.sh -- refuse on
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
# A disabled copy needs `enable`; an install command for it is the wrong fix.
check  "only-install-disabled-says-disabled" "MISS mattpocock-skills@mattpocock is disabled" "$OUT"
check  "only-install-disabled-enable-hint"   "/plugin enable mattpocock-skills@mattpocock" "$OUT"
absent "only-install-disabled-no-install-hint" "/plugin install mattpocock-skills"        "$OUT"
# ...but only the copy that applies HERE: another project's disabled install is not this repo's to enable.
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"2.0.0","scope":"project","enabled":false,"projectPath":"/somewhere/else"},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":true}
]'
OUT="$(run)"
check  "foreign-disabled-install-gets-install-hint" "/plugin marketplace add mattpocock/skills" "$OUT"
absent "foreign-disabled-install-no-enable-hint"    "/plugin enable"                          "$OUT"
rm -rf "$T"

# --- legacy git-flow.md in the repo -> migration warning -----------------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
mkdir -p "$R/.claude/rules"; echo legacy > "$R/.claude/rules/git-flow.md"
OUT="$(run)"
check "legacy-rule-warned" "WARN legacy git-flow.md still present" "$OUT"
rm -rf "$T"

# --- installed task-flow rule compared with the plugin's template ---------------------------------
# Presence alone reported "ok" for rules three releases old; the header carries the template version.
TEMPLATE="$(cd "$(dirname "$0")/../../assets/task-flow" && pwd)/rule.template.md"
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
mkdir -p "$R/.claude/rules"; cat "$TEMPLATE" > "$R/.claude/rules/task-flow.md"
OUT="$(run)"
check  "task-flow-current-ok"  "ok   task-flow rule installed and current" "$OUT"
printf '<!-- cc-tuner:task-flow v0.10.0 — installed by an older setup. -->\nold\n' > "$R/.claude/rules/task-flow.md"
OUT="$(run)"
check  "task-flow-stale-warned" "WARN task-flow rule v0.10.0 differs from the plugin's v" "$OUT"
check  "task-flow-stale-hint"   "/cc-tuner:setup install task-flow" "$OUT"
absent "task-flow-stale-no-miss" "MISS" "$OUT"
rm -rf "$T"

# --- MCP probe: only runs in full mode, and reads connection state not mere presence -------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
printf '#!/bin/sh\ncat <<EOF\ncontext7: https://mcp.context7.com/mcp (HTTP) - OK Connected\nchrome-devtools: npx chrome-devtools-mcp - X Failed to connect\nEOF\n' > "$STUB/mcpfix"
chmod +x "$STUB/mcpfix"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" full 2>&1 )"
check  "mcp-connected-ok"      "ok   MCP 'context7' connected"                 "$OUT"
check  "mcp-not-connected"     "WARN MCP 'chrome-devtools' configured but not" "$OUT"
absent "mcp-not-a-blocker"     "MISS"                                          "$OUT"

# quick mode must NOT probe -- the probe health-checks every server and can hang for 30s each
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
        CC_TUNER_MCP_CMD="mcpfix" bash "$DOCTOR" quick 2>&1 )"
absent "quick-skips-mcp" "MCP 'context7'" "$OUT"
rm -rf "$T"

# --- the native task tools are opt-in on current models -------------------------------------------
# /cc-tuner:spec publishes the visible plan through TaskCreate. From Claude Code 2.1.233 those tools
# are off by default on Opus 4.8 / Sonnet 5 and later. Four eval sessions published no task list
# because of it and the cause was misread as an MCP outage each time, which is why doctor now says it.
# `env -u`: the variable leaks in from the developer's own session when settings.json exports it,
# and the "unset" arm then tests the developer's machine instead of the doctor.
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
OUT="$( cd "$R" && env -u CLAUDE_CODE_ENABLE_TODO_TOOLS -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH \
        PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" bash "$DOCTOR" quick 2>&1 )"
check "todo-tools-unset-warns" "CLAUDE_CODE_ENABLE_TODO_TOOLS is not set" "$OUT"
check "spawn-depth-unset-warns" "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH is not set" "$OUT"
absent "spawn-depth-unset-not-a-blocker" "MISS CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH" "$OUT"
absent "todo-tools-unset-not-a-blocker" "MISS CLAUDE_CODE_ENABLE_TODO_TOOLS" "$OUT"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
        CLAUDE_CODE_ENABLE_TODO_TOOLS=1 CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 bash "$DOCTOR" quick 2>&1 )"
check "todo-tools-set-ok" "ok   CLAUDE_CODE_ENABLE_TODO_TOOLS is set" "$OUT"
check "spawn-depth-set-ok" "ok   CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1" "$OUT"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
        CLAUDE_CODE_ENABLE_TODO_TOOLS=1 CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 bash "$DOCTOR" quick 2>&1 )"
check "spawn-depth-2-ok" "ok   CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2" "$OUT"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CLAUDE_CONFIG_DIR="$PROFILE" \
        CLAUDE_CODE_ENABLE_TODO_TOOLS=1 CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=3 bash "$DOCTOR" quick 2>&1 )"
check "spawn-depth-3-warns" "WARN CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=3" "$OUT"
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
PROFILE="$T/custom profile"; mkdir -p "$PROFILE"
OUT="$(run)"
check "custom-profile-does-not-use-default-script" "statusline not installed" "$OUT"
check "custom-profile-env-hint" "$PROFILE/settings.json" "$OUT"
touch "$PROFILE/cc-tuner-statusline.sh"
OUT="$(run)"
check "custom-profile-script-present" "ok   statusline script installed" "$OUT"

rm -rf "$T"

# --- codex is what makes cc-codex-triage necessary ------------------------------------------------
# Without a usable codex the review bridge cannot run, so reporting its plugin as a blocker sends the
# user to install something that would sit idle. Specs then say `review: none:<reason>`.
mkenv; tool git; tool jq; ghstub "'project'"; matt_only          # no codex on PATH, triage not installed
OUT="$(run)"; rc=$?
absent "codex-absent-triage-not-miss"   "MISS cc-codex-triage"             "$OUT"
check  "codex-absent-triage-optional"   "cc-codex-triage.*optional"        "$OUT"
check  "codex-absent-names-review-none" "review: none:"                    "$OUT"
absent "codex-absent-no-install-hint"   "plugin install cc-codex-triage"   "$OUT"
[ $rc -eq 0 ] && echo "PASS codex-absent-rc0" || { echo "FAIL codex-absent-rc0 (rc=$rc)"; fails=1; }
codexstub 1                                                        # codex present, login status fails
OUT="$(run)"; rc=$?
absent "codex-not-logged-in-not-miss"   "MISS"                             "$OUT"
check  "codex-not-logged-in-hint"       "codex login"                      "$OUT"
check  "codex-not-logged-in-review-none" "review: none:"                   "$OUT"
[ $rc -eq 0 ] && echo "PASS codex-not-logged-in-rc0" || { echo "FAIL codex-not-logged-in-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- logged-in codex, cc-codex-triage not installed: the install command depends on the marketplace --
mkenv; tool git; tool jq; ghstub "'project'"; matt_only; codexstub 0
OUT="$(run)"; rc=$?
check  "triage-no-marketplace-miss"     "MISS cc-codex-triage@cc-codex-triage not installed" "$OUT"
check  "triage-no-marketplace-add"      "/plugin marketplace add clicktronix/cc-codex-triage" "$OUT"
check  "triage-no-marketplace-install"  "/plugin install cc-codex-triage@cc-codex-triage"     "$OUT"
absent "triage-no-marketplace-no-update" "marketplace update"              "$OUT"
[ $rc -eq 1 ] && echo "PASS triage-logged-in-rc1" || { echo "FAIL triage-logged-in-rc1 (rc=$rc)"; fails=1; }
marketplaces '[{"name":"cc-codex-triage","source":"github","repo":"clicktronix/cc-codex-triage"}]'
OUT="$(run)"
check  "triage-marketplace-configured-installs" "/plugin install cc-codex-triage@cc-codex-triage" "$OUT"
absent "triage-marketplace-configured-no-add"   "marketplace add clicktronix"                     "$OUT"
absent "triage-marketplace-configured-no-update" "marketplace update"                             "$OUT"
printf '#!/bin/sh\nexit 1\n' > "$STUB/mktfail"; chmod +x "$STUB/mktfail"
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CC_TUNER_MARKETPLACE_LIST_CMD="mktfail" bash "$DOCTOR" quick 2>&1 )"
check  "marketplace-list-failed-still-adds"     "/plugin marketplace add clicktronix/cc-codex-triage" "$OUT"
rm -rf "$T"

# --- mattpocock-skills gets the same marketplace-aware hint ---------------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; claude_plugins '[]'
OUT="$(run)"
check  "matt-no-marketplace-add"        "/plugin marketplace add mattpocock/skills"  "$OUT"
check  "matt-no-marketplace-install"    "/plugin install mattpocock-skills@mattpocock" "$OUT"
marketplaces '[{"name":"mattpocock","source":"github","repo":"mattpocock/skills"}]'
OUT="$(run)"
check  "matt-marketplace-configured-installs" "/plugin install mattpocock-skills@mattpocock" "$OUT"
absent "matt-marketplace-configured-no-add"   "marketplace add mattpocock"                   "$OUT"
rm -rf "$T"

# --- triage installed but codex unusable: the bridge cannot run ----------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
OUT="$(run)"; rc=$?
check  "triage-installed-codex-absent-warns"   "WARN cc-codex-triage@cc-codex-triage .*cannot run" "$OUT"
absent "triage-installed-codex-absent-no-miss" "MISS"                                              "$OUT"
[ $rc -eq 0 ] && echo "PASS triage-installed-codex-absent-rc0" || { echo "FAIL triage-installed-codex-absent-rc0 (rc=$rc)"; fails=1; }
codexstub 1
check  "triage-installed-not-logged-in-warns"  "WARN cc-codex-triage@cc-codex-triage .*codex login" "$(run)"
codexstub 0
OUT="$(run)"
check  "triage-installed-codex-ready-ok"        "ok   cc-codex-triage@cc-codex-triage 0.10.0 (user)" "$OUT"
absent "triage-installed-codex-ready-quiet"     "cannot run"                                        "$OUT"
rm -rf "$T"

# --- a same-named marketplace from another repository is a stop, not an install ---------------------
# `marketplace list` rows carry `repo`. Matching by name alone sent a one-yes, user-scope install to
# whatever repository owned the name; the hint now names both sources and offers no install.
mkenv; tool git; tool jq; ghstub "'project'"; claude_plugins '[]'
marketplaces '[{"installLocation":"/x/m","name":"mattpocock","repo":"someone-else/skills","source":"github"}]'
OUT="$(run)"; rc=$?
check  "conflict-misses-matt"        "MISS mattpocock-skills@mattpocock" "$OUT"
check  "conflict-names-found-source" "configured from someone-else/skills" "$OUT"
check  "conflict-names-expected-source" "expected mattpocock/skills"      "$OUT"
absent "conflict-offers-no-install"  "/plugin install mattpocock-skills"  "$OUT"
absent "conflict-offers-no-add"      "marketplace add mattpocock"         "$OUT"
[ $rc -eq 1 ] && echo "PASS conflict-rc1" || { echo "FAIL conflict-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"
mkenv; tool git; tool jq; ghstub "'project'"; matt_only; codexstub 0
marketplaces '[{"installLocation":"/x/m","name":"cc-codex-triage","repo":"someone-else/triage","source":"github"}]'
OUT="$(run)"
check  "triage-conflict-misses"      "MISS cc-codex-triage@cc-codex-triage" "$OUT"
check  "triage-conflict-names-both"  "someone-else/triage.*expected clicktronix/cc-codex-triage" "$OUT"
absent "triage-conflict-no-install"  "/plugin install cc-codex-triage"     "$OUT"
rm -rf "$T"

# --- a disabled cc-codex-triage with a usable codex needs `enable` -------------------------------------
mkenv; tool git; tool jq; ghstub "'project'"; codexstub 0
claude_plugins '[
  {"id":"mattpocock-skills@mattpocock","version":"1.0.0","scope":"user","enabled":true},
  {"id":"cc-codex-triage@cc-codex-triage","version":"0.10.0","scope":"user","enabled":false}
]'
OUT="$(run)"; rc=$?
check  "triage-disabled-misses"       "MISS cc-codex-triage@cc-codex-triage is disabled" "$OUT"
check  "triage-disabled-enable-hint"  "/plugin enable cc-codex-triage@cc-codex-triage"   "$OUT"
absent "triage-disabled-no-install"   "/plugin install cc-codex-triage"                  "$OUT"
[ $rc -eq 1 ] && echo "PASS triage-disabled-rc1" || { echo "FAIL triage-disabled-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- a repository that declined Codex review ----------------------------------------------------------
# companion.sh owns the record: `cc-tuner-review: none:<reason>` in task-flow.local.md. With it, the
# missing bridge is a plain line carrying the recorded reason, never a blocker, even with codex ready.
mkenv; tool git; tool jq; ghstub "'project'"; matt_only; codexstub 0
mkdir -p "$R/.claude/rules"; printf 'cc-tuner-review: none:declined-in-setup\n' > "$R/.claude/rules/task-flow.local.md"
OUT="$(run)"; rc=$?
absent "optout-triage-not-miss"        "MISS"                                   "$OUT"
check  "optout-names-recorded-reason"  "review: none:declined-in-setup"         "$OUT"
check  "optout-says-opted-out"         "cc-codex-triage.*opted out"             "$OUT"
absent "optout-no-install-hint"        "plugin install cc-codex-triage"         "$OUT"
[ $rc -eq 0 ] && echo "PASS optout-rc0" || { echo "FAIL optout-rc0 (rc=$rc)"; fails=1; }
plugins_ok
OUT="$(run)"
absent "optout-installed-triage-no-warn" "WARN cc-codex-triage"                 "$OUT"
check  "optout-installed-triage-names-reason" "cc-codex-triage@cc-codex-triage 0.10.0 .*review: none:declined-in-setup" "$OUT"
rm -rf "$T"

# --- without jq the list is not read at all, and the reason is jq, not the list -------------------
mkenv; tool git; tool python3; ghstub "'project'"; plugins_ok
OUT="$(run)"
check  "no-jq-names-jq-as-reason"        "companion plugin checks skipped.*jq" "$OUT"
check  "no-jq-names-plan-restore-off"    "SessionStart plan restore"           "$OUT"
absent "no-jq-not-a-list-failure"        "could not list installed plugins"    "$OUT"
rm -rf "$T"
mkenv; tool git; tool jq; ghstub "'project'"       # jq present, claude absent: the list command failed
OUT="$(run)"
check  "list-failure-says-list-failed"   "could not list installed plugins" "$OUT"
absent "list-failure-does-not-blame-jq"  "SessionStart plan restore"        "$OUT"
rm -rf "$T"

# --- the host decides which CLI is checked ---------------------------------------------------------
# The host is host.sh's answer, so it is driven through origin and the CLIs' config files. Only the CLI of
# the detected host is checked, against the remote's host, and a missing or logged-out one blocks.
# github: gh is checked, glab is not mentioned.
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
OUT="$(run)"
check  "host-github-detected"      "ok   host: github (remote origin, github.com)" "$OUT"
check  "host-github-checks-gh"     "ok   gh"      "$OUT"
absent "host-github-no-glab"       "glab"         "$OUT"
check  "host-github-gh-gets-remote-host" "gh auth status --hostname github.com" "$(cat "$CALLS")"
absent "host-never-asks-the-network" "repo" "$(cat "$CALLS")"
GH_AUTH_RC=1; ghstub "'project'"
OUT="$(run)"; rc=$?
check  "gh-unauthenticated-misses" "MISS gh is not authenticated" "$OUT"
check  "gh-unauthenticated-hint"   "gh auth login --hostname github.com" "$OUT"
[ $rc -eq 1 ] && echo "PASS gh-unauthenticated-rc1" || { echo "FAIL gh-unauthenticated-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# github with gh not installed: delivery goes through gh, so it blocks (it was a WARN before host.sh, review H6)
mkenv; tool git; tool jq; plugins_ok
OUT="$(run)"; rc=$?
check  "gh-missing-misses"         "MISS gh — " "$OUT"
check  "gh-missing-names-install-page" "install: https://cli.github.com" "$OUT"
absent "gh-missing-no-brew"        "brew" "$OUT"
[ $rc -eq 1 ] && echo "PASS gh-missing-rc1" || { echo "FAIL gh-missing-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# github Enterprise: a host gh is logged in to, with gh checked against THAT host
mkenv; tool git; tool jq; ghstub "'repo'"; plugins_ok
setremote https://ghe.corp.example/acme/app.git; gh_hosts github.com ghe.corp.example
OUT="$(run)"
check  "host-ghe-detected"         "ok   host: github (remote origin, ghe.corp.example)" "$OUT"
check  "host-ghe-gh-gets-its-host" "gh auth status --hostname ghe.corp.example" "$(cat "$CALLS")"
check  "host-ghe-refresh-hint-names-host" "gh auth refresh --hostname ghe.corp.example -s project" "$OUT"
rm -rf "$T"

# github by its URL, gh logged out: the host needs no CLI to be known, and the finding is the login
mkenv; tool git; tool jq; GH_AUTH_RC=1; ghstub "'project'"; plugins_ok
OUT="$(run)"
check  "host-github-by-url"             "host: github"                  "$OUT"
check  "host-github-by-url-unauth-miss" "MISS gh is not authenticated"  "$OUT"
rm -rf "$T"

# an SSH alias for github.com: the host is the alias target, gh is asked about that
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
SSHSTUB="$T/ssh"; printf '#!/bin/sh\necho "hostname github.com"\n' > "$SSHSTUB"; chmod +x "$SSHSTUB"
setremote git@github-work:acme/app.git
OUT="$( cd "$R" && PATH="$STUB" HOME="$FAKE_HOME" CC_TUNER_HOME="$H" CC_TUNER_SSH_CMD="$SSHSTUB" \
        CC_TUNER_GH_HOSTS_FILE="$GH_HOSTS" CC_TUNER_GLAB_CONFIG_FILE="$GLAB_CFG" \
        CC_TUNER_MARKETPLACE_LIST_CMD="cat $MKT" bash "$DOCTOR" 2>&1 )"
check  "host-alias-resolves-to-github" "ok   host: github (remote origin, github.com)" "$OUT"
rm -rf "$T"

# a lookalike is not github: the old substring match said github for this URL
mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
setremote git@gitlab.com:acme/github.com-mirror.git
OUT="$(run)"
check  "host-substring-trap-is-gitlab" "ok   host: gitlab (remote origin, gitlab.com)" "$OUT"
absent "host-substring-trap-no-gh"     "ok   gh"                                     "$OUT"
rm -rf "$T"

# the origin remote decides, not the first one
mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
( cd "$R" && git remote add aaa-mirror https://github.com/acme/app.git )
setremote https://gitlab.com/acme/app.git
OUT="$(run)"
check  "host-origin-not-first-remote" "ok   host: gitlab (remote origin, gitlab.com)" "$OUT"
rm -rf "$T"

# only remote, not named origin
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
noremote; ( cd "$R" && git remote add upstream https://github.com/acme/app.git )
check  "host-only-remote-used"     "ok   host: github (remote upstream, github.com)" "$(run)"
rm -rf "$T"

# several remotes and no origin: a question, not a guess
mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
noremote; ( cd "$R" && git remote add a https://github.com/acme/app.git && git remote add b https://gitlab.com/acme/app.git )
OUT="$(run)"; rc=$?
check  "host-ambiguous-warns"      "WARN host: ambiguous — several remotes and none is origin" "$OUT"
check  "host-ambiguous-asks"       "name one origin, or answer the question /cc-tuner:spec asks" "$OUT"
absent "host-ambiguous-no-miss"    "MISS"                                                       "$OUT"
[ $rc -eq 0 ] && echo "PASS host-ambiguous-rc0" || { echo "FAIL host-ambiguous-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# gitlab: glab is checked against the remote's host, gh is not asked about at all.
mkenv; tool git; tool jq; GH_AUTH_RC=1; ghstub "'project'"; glabstub; plugins_ok
setremote https://gitlab.com/acme/app.git
OUT="$(run)"; rc=$?
check  "host-gitlab-detected"     "ok   host: gitlab (remote origin, gitlab.com)" "$OUT"
check  "host-gitlab-checks-glab"  "ok   glab"                "$OUT"
absent "host-gitlab-no-gh-miss"   "MISS"                     "$OUT"
absent "host-gitlab-no-gh-line"   "gh is not authenticated"  "$OUT"
check  "host-gitlab-glab-gets-remote-host" "glab auth status --hostname gitlab.com" "$(cat "$CALLS")"
absent "host-gitlab-gh-never-run"  "^gh "                    "$(cat "$CALLS")"
absent "host-never-asks-the-network-glab" "repo" "$(cat "$CALLS")"
[ $rc -eq 0 ] && echo "PASS host-gitlab-rc0" || { echo "FAIL host-gitlab-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# self-hosted GitLab: a host glab is logged in to
mkenv; tool git; tool jq; glabstub; plugins_ok
setremote git@git.corp.example:acme/app.git; glab_hosts gitlab.com git.corp.example
OUT="$(run)"
check  "host-gitlab-self-hosted"   "ok   host: gitlab (remote origin, git.corp.example)" "$OUT"
check  "host-gitlab-self-hosted-glab-gets-its-host" "glab auth status --hostname git.corp.example" "$(cat "$CALLS")"
rm -rf "$T"

# gitlab, glab logged out -> a blocker (it was a WARN before host.sh, review H6)
mkenv; tool git; tool jq; GLAB_AUTH_RC=1; ghstub "'project'"; glabstub; plugins_ok
setremote https://gitlab.com/acme/app.git
OUT="$(run)"; rc=$?
check  "host-gitlab-unauth-misses" "MISS glab is not authenticated"  "$OUT"
check  "host-gitlab-unauth-hint"   "glab auth login --hostname gitlab.com" "$OUT"
[ $rc -eq 1 ] && echo "PASS host-gitlab-unauth-rc1" || { echo "FAIL host-gitlab-unauth-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# gitlab, glab not installed
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
setremote https://gitlab.com/acme/app.git
OUT="$(run)"; rc=$?
check  "glab-missing-misses"       "MISS glab — "                                    "$OUT"
check  "glab-missing-names-install-page" "install: https://gitlab.com/gitlab-org/cli" "$OUT"
absent "glab-missing-no-brew"      "brew"                                            "$OUT"
[ $rc -eq 1 ] && echo "PASS glab-missing-rc1" || { echo "FAIL glab-missing-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

# gitlab, glab too old for the route's pinned merge: --sha and --auto-merge are each required
for missing in nosha noauto; do
  mkenv; tool git; tool jq; GLAB_HELP=$missing; glabstub; plugins_ok
  setremote https://gitlab.com/acme/app.git
  OUT="$(run)"; rc=$?
  check  "glab-too-old-$missing-misses" "MISS glab is too old — 'glab mr merge' lacks --sha or --auto-merge" "$OUT"
  check  "glab-too-old-$missing-authenticated-still-ok" "ok   glab (authenticated" "$OUT"
  [ $rc -eq 1 ] && echo "PASS glab-too-old-$missing-rc1" || { echo "FAIL glab-too-old-$missing-rc1 (rc=$rc)"; fails=1; }
  rm -rf "$T"
done

# local: no remote; neither CLI is mentioned, nothing blocks
mkenv; tool git; tool jq; plugins_ok; noremote
OUT="$(run)"; rc=$?
check  "host-local-detected"  "host: local"  "$OUT"
absent "host-local-no-gh"     "gh"           "$OUT"
absent "host-local-no-glab"   "glab"         "$OUT"
absent "host-local-no-miss"   "MISS"         "$OUT"
[ $rc -eq 0 ] && echo "PASS host-local-rc0" || { echo "FAIL host-local-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# other: a remote neither CLI is logged in to. Not a blocker; the WARN names the host and both logins
mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
setremote git@git.example.org:acme/app.git
OUT="$(run)"; rc=$?
check  "host-other-detected"       "host: other"            "$OUT"
check  "host-other-needs-a-route"  "route you describe"     "$OUT"
check  "host-other-names-setup"    "host: other.*install delivery-route" "$OUT"
check  "host-other-names-host"     "remote origin (git.example.org)" "$OUT"
check  "host-other-hints-gh-login"   "gh auth login --hostname git.example.org"   "$OUT"
check  "host-other-hints-glab-login" "glab auth login --hostname git.example.org" "$OUT"
absent "host-other-no-miss"        "MISS"                   "$OUT"
absent "host-other-never-runs-a-cli" "auth"                 "$(cat "$CALLS")"
[ $rc -eq 0 ] && echo "PASS host-other-rc0" || { echo "FAIL host-other-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# other, remote is a filesystem path: no host to log in to, and no login is suggested
mkenv; tool git; tool jq; plugins_ok
setremote /srv/git/app.git
OUT="$(run)"
check  "host-other-path-says-no-host" "has no host name to log in to" "$OUT"
absent "host-other-path-no-login-hint" "auth login"                    "$OUT"
rm -rf "$T"

# not a git repository: no host, and the host section says so rather than guessing
mkenv; tool git; tool jq; ghstub "'project'"; plugins_ok
mkdir -p "$T/plain"
OUT="$(run "$T/plain")"; rc=$?
check  "host-not-a-repo"           "host not detected (not inside a git repository)" "$OUT"
absent "host-not-a-repo-no-gh"     "gh "                                              "$OUT"
[ $rc -eq 0 ] && echo "PASS host-not-a-repo-rc0" || { echo "FAIL host-not-a-repo-rc0 (rc=$rc)"; fails=1; }
rm -rf "$T"

# --- the delivery route key block in task-flow.local.md ------------------------------------------------
# The block is produced by scripts/setup/route.sh write and read back by route.sh check, which doctor
# calls, so every fixture here is written by the real producer. The file is first built the way setup
# builds it (a header and a delta) and the writer appends or replaces the block; hand-made blocks appear
# only for states the producer refuses to make (malformed, CRLF).
ROUTE_SH="$(cd "$(dirname "$DOCTOR")" && pwd)/route.sh"
ROUTE_CMD="/cc-tuner:setup install delivery-route"
route_file() { mkdir -p "$R/.claude/rules"; printf '%s' "$R/.claude/rules/task-flow.local.md"; }
# Write the route for host $1 (and body file $2 for other) into a task-flow.local.md that has prose
# before and after, with the real producer. The producer needs mktemp, cp and mv, which doctor's stubbed
# PATH does not have, so it runs on the caller's PATH.
write_route() {
  f="$(route_file)"
  printf '# task-flow — repo-specific deltas\n\nboard: 3\n' > "$f"
  PATH="$ORIG_PATH" bash "$ROUTE_SH" write "$1" "$f" ${2:+"$2"} >/dev/null || { echo "FAIL write_route $1"; fails=1; }
  printf '\nmore deltas\n' >> "$f"
}
ORIG_PATH="$PATH"
OTHER_BODY_FILE="$(mktemp)"; printf 'Open a review on our forge, wait for two approvals, merge from the UI.\n' > "$OTHER_BODY_FILE"
gitlab_env() {
  mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
  setremote https://gitlab.com/acme/app.git
}

# local: missing, current, drifted, malformed, mismatched
mkenv; tool git; tool jq; plugins_ok; noremote
OUT="$(run)"; rc=$?
check  "route-local-missing-warns"   "WARN delivery route not written — $ROUTE_CMD" "$OUT"
absent "route-local-missing-no-miss" "MISS"                                          "$OUT"
[ $rc -eq 0 ] && echo "PASS route-local-missing-rc0" || { echo "FAIL route-local-missing-rc0 (rc=$rc)"; fails=1; }
# a task-flow.local.md that exists without a block is the same finding
printf '# task-flow — repo-specific deltas\n' > "$(route_file)"
check  "route-local-file-without-block-warns" "delivery route not written" "$(run)"
# local, current: written by the producer, read by the checker doctor calls
write_route local
OUT="$(run)"
check  "route-local-current-ok"      "ok   delivery route (local) current" "$OUT"
absent "route-local-current-quiet"   "delivery route not written"           "$OUT"
absent "route-local-current-no-warn" "differs"                              "$OUT"
# a checkout with CRLF line endings is still current
sed 's/$/\r/' "$(route_file)" > "$T/crlf" && cp "$T/crlf" "$(route_file)"
check  "route-local-crlf-current-ok" "ok   delivery route (local) current" "$(run)"
# local, drifted: the key block's sentence edited by hand
write_route local
sed 's/never by a web merge/by any merge/' "$(route_file)" > "$T/drift" && cp "$T/drift" "$(route_file)"
OUT="$(run)"
check  "route-local-drift-warns"     "WARN delivery route (local) differs from the plugin's key block — $ROUTE_CMD" "$OUT"
absent "route-local-drift-not-ok"    "ok   delivery route"                                                        "$OUT"
# a legacy block (the old copied route text with a versioned marker) is drift too
printf '# deltas\n\n<!-- cc-tuner:delivery-route local v0.23.0 -->\nold route\n<!-- /cc-tuner:delivery-route -->\n' > "$(route_file)"
check  "route-local-legacy-block-drifts" "delivery route (local) differs" "$(run)"
# malformed: counted, and the advice is a hand fix, not an install that setup would refuse
write_route local
sed '/^<!-- \/cc-tuner:delivery-route -->$/d' "$(route_file)" > "$T/open" && cp "$T/open" "$(route_file)"
OUT="$(run)"
check  "route-local-unclosed-is-malformed" "WARN malformed delivery-route block (1 opening, 0 closing markers) — fix .claude/rules/task-flow.local.md by hand" "$OUT"
absent "route-local-malformed-no-install-advice" "install delivery-route" "$OUT"
write_route local; cat "$(route_file)" > "$T/twice"; sed -n '/^<!-- cc-tuner:delivery-route /,/^<!-- \/cc-tuner:delivery-route -->$/p' "$T/twice" >> "$(route_file)"
check  "route-local-two-blocks-malformed" "malformed delivery-route block (2 opening, 2 closing markers)" "$(run)"
# a block written for another host
write_route gitlab
OUT="$(run)"
check  "route-host-mismatch-warns"   "WARN delivery route block is for host gitlab, but this repository's host is local — $ROUTE_CMD" "$OUT"
absent "route-host-mismatch-not-ok"  "ok   delivery route"                                                                           "$OUT"
rm -rf "$T"

# gitlab: missing, current, drifted, mismatched
gitlab_env
OUT="$(run)"; rc=$?
check  "route-gitlab-missing-warns"  "WARN delivery route not written — $ROUTE_CMD" "$OUT"
[ $rc -eq 0 ] && echo "PASS route-gitlab-missing-rc0" || { echo "FAIL route-gitlab-missing-rc0 (rc=$rc)"; fails=1; }
write_route gitlab
check  "route-gitlab-current-ok"     "ok   delivery route (gitlab) current" "$(run)"
write_route gitlab
sed 's/gitlab route/any route/' "$(route_file)" > "$T/drift" && cp "$T/drift" "$(route_file)"
check  "route-gitlab-drift-warns"    "WARN delivery route (gitlab) differs from the plugin's key block — $ROUTE_CMD" "$(run)"
write_route local
check  "route-gitlab-mismatch-warns" "delivery route block is for host local, but this repository's host is gitlab" "$(run)"
rm -rf "$T"

# other: the user's own description is reported, never compared
mkenv; tool git; tool jq; ghstub "'project'"; glabstub; plugins_ok
setremote git@git.example.org:acme/app.git
OUT="$(run)"
check  "route-other-missing-warns"   "WARN delivery route not written — $ROUTE_CMD" "$OUT"
write_route other "$OTHER_BODY_FILE"
OUT="$(run)"; rc=$?
check  "route-other-present-ok"      "ok   delivery route (other) present (user-described, not compared)" "$OUT"
absent "route-other-present-no-warn" "delivery route not written"                                           "$OUT"
[ $rc -eq 0 ] && echo "PASS route-other-present-rc0" || { echo "FAIL route-other-present-rc0 (rc=$rc)"; fails=1; }
write_route local
check  "route-other-mismatch-warns"  "delivery route block is for host local, but this repository's host is other" "$(run)"
rm -rf "$T"

# github: merge.sh is the route, so doctor says nothing unless a block is left over from another host
mkenv; tool git; tool jq; ghstub "'gist', 'project', 'repo'"; plugins_ok
absent "route-github-says-nothing"   "delivery route" "$(run)"
write_route gitlab
OUT="$(run)"; rc=$?
check  "route-github-stale-block-warns" "WARN stale delivery-route block (gitlab) in .claude/rules/task-flow.local.md on a github repository" "$OUT"
check  "route-github-stale-says-remove-by-hand" "delete the lines from its <!-- cc-tuner:delivery-route ... --> marker through <!-- /cc-tuner:delivery-route --> by hand" "$OUT"
absent "route-github-stale-no-install-advice" "install delivery-route" "$OUT"
[ $rc -eq 0 ] && echo "PASS route-github-stale-block-rc0" || { echo "FAIL route-github-stale-block-rc0 (rc=$rc)"; fails=1; }
write_route other "$OTHER_BODY_FILE"
check  "route-github-stale-other-block-warns" "WARN stale delivery-route block (other)" "$(run)"
# a malformed block is reported as malformed on github too
printf '# deltas\n\n<!-- cc-tuner:delivery-route gitlab -->\n' > "$(route_file)"
check  "route-github-malformed-warns" "malformed delivery-route block (1 opening, 0 closing markers)" "$(run)"
rm -rf "$T" "$OTHER_BODY_FILE"

# glab 1.85 has the merge flags but no `mr note create --resolvable`, so the route could not publish a record.
mkenv; tool git; tool jq; tool python3; setremote git@gitlab.com:acme/app.git; GLAB_AUTH_RC=0 GLAB_HELP=nonote glabstub; plugins_ok
OUT="$(run)"; rc=$?
check "glab-without-note-create-misses" "MISS glab is too old — 'glab mr note create' lacks --message or --resolvable" "$OUT"
[ $rc -eq 1 ] && echo "PASS glab-without-note-create-rc1" || { echo "FAIL glab-without-note-create-rc1 (rc=$rc)"; fails=1; }
rm -rf "$T"

exit $fails
