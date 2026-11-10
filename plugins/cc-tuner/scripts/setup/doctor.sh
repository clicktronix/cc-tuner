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
#   CC_TUNER_MARKETPLACE_LIST_CMD  command whose stdout is the configured-marketplace JSON, read by
#                             companion.sh to choose the fix for a plugin that is not installed
#                             (default: claude plugin marketplace list --json)
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

# Instruction files a session started here loads at launch under the default "Project instructions"
# setting (claude-md-writer/reference.md), split by kind, one path per line: CLAUDE files from the
# working directory up to / (the user-global ~/.claude/CLAUDE.md does not count), AGENTS files, which
# load only when there is no CLAUDE file, and .claude/rules files without paths: frontmatter.
# @-imports are not followed: resolving them means parsing Markdown the way the loader does, so a
# pointer reached only through one is reported with that limit named instead of guessed at.
launch_files() { # launch_files claude|agents|rules
  local d="$PWD" f
  if [ "$1" = rules ]; then
    grep -rl --include='*.md' '' "$REPO_ROOT/.claude/rules" 2>/dev/null | while IFS= read -r f; do
      scoped_rule "$f" || printf '%s\n' "$f"
    done
    return
  fi
  while :; do
    if [ "$1" = claude ]; then
      for f in "$d/CLAUDE.md" "$d/.claude/CLAUDE.md" "$d/CLAUDE.local.md"; do
        if [ -f "$f" ] && [ "$f" != "$UHOME/.claude/CLAUDE.md" ]; then printf '%s\n' "$f"; fi
      done
    else
      for f in "$d/AGENTS.md" "$d/.claude/AGENTS.md"; do
        if [ -f "$f" ]; then printf '%s\n' "$f"; fi
      done
    fi
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
}
scoped_rule() { # true when the rule file $1 opens with frontmatter that has a paths: key
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [ $n -eq 1 ]; then [ "$line" = --- ] || return 1; continue; fi
    [ "$line" = --- ] && return 1
    case "$line" in paths:*) return 0 ;; esac
  done < "$1"
  return 1
}
names_pointer() { # true when any file listed on stdin mentions docs/agents
  local f
  while IFS= read -r f; do
    if [ -n "$f" ] && grep -q 'docs/agents' "$f" 2>/dev/null; then return 0; fi
  done
  return 1
}

# --- 1. command-line tools ----------------------------------------------------------------------
# Only git blocks: nothing here works without it. jq blocks two named consumers, not this tool, and
# both refuse on their own -- the statusline node checks before it patches settings.json, and
# tests/run.sh will not start. A global MISS made doctor exit non-zero, and /cc-tuner:setup stops on a
# non-zero exit, so a missing jq halted setting up claude-md-writer, which never calls jq at all.
# A blocker belongs to the capability that needs it, not to the tool that reports on all of them.
# gh and glab are not here: which one matters depends on the repository's host, and a tool nobody on
# this host uses is not a finding. Section 2 checks the one the host needs.
# Plain `if`, not `a && b || c`: that chain runs `c` whenever `b` fails, so one day a reporting
# helper returns non-zero and the script starts claiming things are missing that are not.
if command -v git     >/dev/null 2>&1; then ok "git";     else bad "git — required for every command here"; fi
if command -v jq      >/dev/null 2>&1; then ok "jq";      else warn "jq — the statusline node refuses to patch settings.json without it and the test runner will not start; both say so themselves. Install: https://jqlang.github.io/jq/download/"; fi
if command -v python3 >/dev/null 2>&1; then ok "python3"; else warn "python3 — agent-rules setup requires it; the statusline's usage segment also degrades without it"; fi

# --- 1b. the native task tools -------------------------------------------------------------------
# `/cc-tuner:spec` publishes the visible plan through TaskCreate and wires its edges with
# TaskUpdate addBlockedBy. From Claude Code 2.1.233 those tools are **off by default** on Opus 4.8,
# Sonnet 5 and later -- the reasoning being that such models track multi-step work without a written
# checklist -- and are restored by exporting CLAUDE_CODE_ENABLE_TODO_TOOLS=1 before starting Claude.
#
# Measured on 2.1.235: an Opus 5 session asked to call TaskCreate answers UNAVAILABLE without the
# variable and CREATED with it. Four eval sessions in a row published no task list because of this,
# and the cause was misread as an MCP outage each time -- which is precisely why it belongs in the
# tool whose job is to say whether the environment works.
#
# **This reads an environment variable; it does not probe for the tools, and must not be read as
# doing so.** Both errors are possible in principle: the variable set while something else excludes
# the tools, and the tools present through `--tools` or `--allowedTools` while the variable is unset.
# A doctor is a separate process from the session that would hold the tools, so it cannot ask. The
# capability answer belongs to `/cc-tuner:spec`, which is in that session and finds out by calling.
#
# A hint, not a blocker: the plan file is the durable store and a run drives from it either way.
# What is at stake is the visible task list and its edges.
case "${CLAUDE_CODE_ENABLE_TODO_TOOLS:-}" in
  1|true|TRUE|yes) ok "CLAUDE_CODE_ENABLE_TODO_TOOLS is set (variable only; the tools are not probed)" ;;
  *) warn "CLAUDE_CODE_ENABLE_TODO_TOOLS is not set — /cc-tuner:spec may publish no visible task list; set {\"env\": {\"CLAUDE_CODE_ENABLE_TODO_TOOLS\": \"1\"}} in ~/.claude/settings.json (the session's tool list shows whether TaskCreate is present)" ;;
esac

# --- 1c. nested delegation ---------------------------------------------------------------------
# /cc-tuner:run hands slices to subagents and tells each one not to delegate further; deep-review
# fans out seven read-only lenses the same way. That instruction is prose. The platform default lets a
# subagent spawn its own down to depth 3, and one run once produced dozens of unrequested agents that
# way. CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 makes the rule a limit instead of a request: the
# orchestrator still dispatches, its units cannot. A hint, not a blocker -- the prose still applies.
# 1 = only the orchestrator dispatches. 2 = a unit may still run its own Explore lookups, but
# nothing it spawns can spawn further -- the shape observed in practice, where units wanted a
# lookup and never a rig. Both hold the invariant that matters: no unrequested third layer.
case "${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-}" in
  1) ok "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1 — only the orchestrator can spawn; units and lenses cannot" ;;
  2) ok "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 — units may run their own lookups; nothing below them can spawn" ;;
  "") warn "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH is not set — subagents may nest to depth 3 by default, so a unit told not to delegate can still spawn agents; set {\"env\": {\"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH\": \"1\"}} (orchestrator only) or \"2\" (units may run lookups) in ~/.claude/settings.json" ;;
  *) warn "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH} — a third layer of agents is possible; /cc-tuner:run expects 1 or 2" ;;
esac

# --- 2. the repository's host, and the CLI that host needs ---------------------------------------
# scripts/setup/host.sh owns the answer, offline: the host comes from the origin remote's URL (or the
# host a CLI is logged in to, for an SSH alias or a self-hosted forge), never from asking the network.
# It was `gh repo view` here until 2026-11, which needed a connection and a live token to name a host,
# and /spec, /run and setup each restated the rule in prose; they disagreed. Doctor only checks that
# the CLI of the host host.sh names is installed and logged in to that host, which is the part that can
# actually fail on this machine. `local` has no remote to authenticate against, `other` has no CLI to ask
# (delivery there needs a route the user describes, section 2b checks it is written), `ambiguous` has no
# answer until the user names an origin. A tool nobody on this host uses is not a finding.
#
# A missing or logged-out CLI is a MISS on both github and gitlab: delivery goes through it and cannot
# run without it, and warning here let a run start and stop at the first merge. glab also needs
# `mr merge --sha` (merge only the reviewed commit) and `--auto-merge`, which the route's pinned merge
# uses; an older glab has neither, so that is a MISS too.
#
# `gh project *` fails with an opaque GraphQL error when the token lacks `project`. That error is the
# single most common reason an agent silently gives up on the board, so name it before it happens.
# It warns rather than blocks: a spec may say `board: none` (see skills/spec/SKILL.md), and such a
# repo never runs a board command. The refusal belongs to step 4 of /cc-tuner:setup and to the board
# recipes in the task-flow skill, which know whether a board is in play; this tool does not.
HOST=""; HOST_VIA=""; REMOTE=""; REMOTE_HOST=""
if [ -n "$REPO_ROOT" ]; then
  host_row="$(bash "$(cd "$(dirname "$0")" && pwd)/host.sh" "$REPO_ROOT" 2>/dev/null)"
  if [ -n "$host_row" ]; then
    # Parameter expansion, not `read` with a tab IFS: empty fields (no remote) would collapse.
    HOST="${host_row%%	*}";        rest="${host_row#*	}"
    HOST_VIA="${rest%%	*}";       rest="${rest#*	}"
    REMOTE="${rest%%	*}";         REMOTE_HOST="${rest#*	}"
  fi
fi

case "$HOST" in
  github)
    ok "host: github (remote $REMOTE, $REMOTE_HOST)"
    if ! command -v gh >/dev/null 2>&1; then
      bad "gh — the GitHub delivery route and the board recipes in the task-flow skill need it; install: https://cli.github.com"
    elif ! gh auth status --hostname "$REMOTE_HOST" >/dev/null 2>&1; then
      bad "gh is not authenticated for $REMOTE_HOST — run: gh auth login --hostname $REMOTE_HOST"
    else
      ok "gh (authenticated for $REMOTE_HOST)"
      # Match the scope exactly rather than as a substring: `read:project` contains "project" but
      # cannot run `project item-edit`, so a substring test would report a working board and be wrong.
      if gh auth status --hostname "$REMOTE_HOST" 2>&1 | sed -n "s/.*Token scopes: //p" | tr -d "'" | tr ',' '\n' | tr -d ' ' \
         | grep -qx project; then
        ok "gh token has the 'project' scope"
      else
        refresh="gh auth refresh -s project"
        if [ "$REMOTE_HOST" != github.com ]; then refresh="gh auth refresh --hostname $REMOTE_HOST -s project"; fi
        warn "gh token lacks the 'project' scope — board commands fail with an opaque GraphQL error; harmless for a repo whose spec says board: none. fix: $refresh"
      fi
    fi
    ;;
  gitlab)
    ok "host: gitlab (remote $REMOTE, $REMOTE_HOST)"
    if ! command -v glab >/dev/null 2>&1; then
      bad "glab — the GitLab delivery route needs it; install: https://gitlab.com/gitlab-org/cli#installation"
    else
      if glab auth status --hostname "$REMOTE_HOST" >/dev/null 2>&1; then
        ok "glab (authenticated for $REMOTE_HOST)"
      else
        bad "glab is not authenticated for $REMOTE_HOST — run: glab auth login --hostname $REMOTE_HOST"
      fi
      merge_help="$(glab mr merge --help 2>&1)"
      case "$merge_help" in
        *--sha*--auto-merge*|*--auto-merge*--sha*) ;;
        *) bad "glab is too old — 'glab mr merge' lacks --sha or --auto-merge, which the GitLab route's pinned merge needs; upgrade: https://gitlab.com/gitlab-org/cli#installation" ;;
      esac
      # The route publishes every record with `glab mr note create -m … --resolvable=false`; older glab has
      # the merge flags but not this command, and would fail at the first record, after the work is done.
      note_help="$(glab mr note create --help 2>&1)"
      case "$note_help" in
        *--message*--resolvable*|*--resolvable*--message*) ;;
        *) bad "glab is too old — 'glab mr note create' lacks --message or --resolvable, which the GitLab route publishes its records with; upgrade: https://gitlab.com/gitlab-org/cli#installation" ;;
      esac
    fi
    ;;
  local) ok "host: local — no git remote, so nothing to authenticate against" ;;
  other)
    if [ -n "$REMOTE_HOST" ]; then
      warn "host: other — remote $REMOTE ($REMOTE_HOST) is not GitHub or GitLab, and neither gh nor glab is logged in to it. For GitHub Enterprise run: gh auth login --hostname $REMOTE_HOST; for a self-hosted GitLab run: glab auth login --hostname $REMOTE_HOST — either makes the host detectable. Otherwise delivery needs a route you describe; /cc-tuner:setup install delivery-route records it"
    else
      warn "host: other — remote $REMOTE has no host name to log in to (a local path or an unusable URL); delivery needs a route you describe; /cc-tuner:setup install delivery-route records it"
    fi
    ;;
  ambiguous) warn "host: ambiguous — several remotes and none is origin; name one origin, or answer the question /cc-tuner:spec asks" ;;
  *) say "     host not detected (not inside a git repository)" ;;
esac

# --- 2b. the delivery route key block for that host -----------------------------------------------------
# Outside GitHub no script refuses a bad merge, so the route is the gate. Its text is a plugin reference
# that /cc-tuner:run reads at Delivery; the repository holds a short key block in task-flow.local.md,
# written and checked by scripts/setup/route.sh. This section only maps route.sh's one-line answer to a
# finding, so the checker that writes the block and the checker that reports on it are the same program
# (doctor used to carry its own sed extraction, and advised an install that setup refused for a malformed
# block). `none-needed` (github with no block) says nothing: merge.sh is the route.
ROUTE_CMD="/cc-tuner:setup install delivery-route"
case "$HOST" in
  github|gitlab|local|other)
    ROUTE_OUT="$(bash "$(cd "$(dirname "$0")" && pwd)/route.sh" check "$HOST" "$REPO_ROOT" 2>&1)"
    R_WORD="${ROUTE_OUT%% *}"; R_REST=""; R_A=""; R_B=""
    case "$ROUTE_OUT" in *" "*) R_REST="${ROUTE_OUT#* }"; R_A="${R_REST%% *}"; R_B="${R_REST#* }" ;; esac
    case "$R_WORD" in
      current)       ok "delivery route ($HOST) current" ;;
      present-other) ok "delivery route (other) present (user-described, not compared)" ;;
      none-needed)   ;;
      missing)       warn "delivery route not written — $ROUTE_CMD" ;;
      mismatch)      warn "delivery route block is for host ${R_A:-unknown}, but this repository's host is $HOST — $ROUTE_CMD" ;;
      drift)         warn "delivery route ($HOST) differs from the plugin's key block — $ROUTE_CMD rewrites it" ;;
      malformed)     warn "malformed delivery-route block (${R_A:-?} opening, ${R_B:-?} closing markers) — fix .claude/rules/task-flow.local.md by hand" ;;
      stale-on-github) warn "stale delivery-route block (${R_A:-unknown}) in .claude/rules/task-flow.local.md on a github repository, where merge.sh is the route — setup cannot remove it; delete the lines from its <!-- cc-tuner:delivery-route ... --> marker through <!-- /cc-tuner:delivery-route --> by hand" ;;
      *)             warn "delivery route could not be checked: ${ROUTE_OUT:-route.sh printed nothing}" ;;
    esac
    ;;
esac

# --- 3. companion plugins ------------------------------------------------------------------------
# Every fact about the companions -- which plugin comes from which marketplace, whether codex is usable,
# whether the repository opted out of Codex review, whether a plugin is installed, disabled or absent
# here, and the command that fixes it -- is asked of scripts/setup/companion.sh, which prereq-check.sh
# and the setup node also use. Those facts were restated here, in prereq-check and in the node's prose,
# and the copies diverged: on `enabled: false` (one filtered it, one did not), and on a marketplace
# matched by name alone. Which installation applies is companion.sh's question to plugin-here.sh.
COMPANION="$(cd "$(dirname "$0")" && pwd)/companion.sh"
TAB="$(printf '\t')"

# state_of <id>: sets ST (installed | disabled | absent | unknown) and FOUND ("<version> (<scope>)").
# The resolver's three outcomes stay distinct: an earlier version flattened "cannot tell" into "nothing
# found", so a malformed plugin list produced confident MISS lines telling the user to reinstall plugins
# that were never looked for. Split in bash, not awk or cut: this tool reports on environments missing
# things, so every external it adds is one more way for it to fail where it is needed most.
state_of() {
  local out rest ver
  out="$(bash "$COMPANION" state "$1" "$REPO_ROOT" 2>/dev/null)"
  ST="${out%%$TAB*}"; FOUND=""
  case "$ST" in
    installed|disabled) rest="${out#*$TAB}"; ver="${rest%%$TAB*}"; FOUND="$ver (${rest#*$TAB})" ;;
    absent) ;;
    *) ST=unknown ;;
  esac
}

# fix_of <id>: sets FIX to the command that fixes the state, or the CONFLICT text when a same-named
# marketplace comes from another repository (FIXRC 3).
fix_of() { FIX="$(bash "$COMPANION" hint "$1" "$REPO_ROOT" 2>&1)"; FIXRC=$?; }

# needed_by <id>: what the plugin is for, from the companion table.
needed_by() { local row; row="$(bash "$COMPANION" table "$1")"; printf '%s' "${row##*$TAB}"; }

# codex is what makes cc-codex-triage necessary: the plugin only drives codex, so without a usable one
# the review bridge cannot run, specs say `review: none:<reason>`, and a missing plugin is no blocker.
case "$(bash "$COMPANION" codex)" in
  ready)  ok "codex (logged in)" ;;
  absent) say "     codex not on PATH (optional) — the review bridge is off" ;;
  *)      warn "codex is installed but not logged in — run: codex login" ;;
esac

# Still asked once, only to tell "no plugins listed" from "that plugin is not installed": the first
# is an environment this tool cannot see into, the second is a finding about the environment.
PLUGIN_LIST="$(${CC_TUNER_PLUGIN_LIST_CMD:-claude plugin list --json} 2>/dev/null)" || PLUGIN_LIST=""

companion() {  # companion <id>
  local id="$1" what; what="$(needed_by "$1")"
  state_of "$id"
  case "$ST" in
    installed) ok "$id $FOUND — $what" ;;
    # Disabled is its own finding with its own command: `install` fails on a plugin that is there.
    disabled)  fix_of "$id"; bad "$id is disabled for this repo — $what; enable: $FIX" ;;
    # Not installed is a finding about the environment; unable to tell is a limit of this tool, and
    # naming an install command for a plugin nobody looked for sends the user to fix the wrong thing.
    absent)    fix_of "$id"
               if [ "$FIXRC" -eq 3 ]; then bad "$id not installed for this repo — $what; $FIX"
               else bad "$id not installed for this repo — $what; install: $FIX"; fi ;;
    *)         warn "$id — could not determine which installation applies; $what" ;;
  esac
}

# cc-codex-triage has a third state the other companion lacks: it can be fine to be absent. When the
# review bridge is off -- no usable codex, or the repository declined Codex review -- the plugin is
# optional and a missing one is a plain line. Installed with the bridge off is a plugin that cannot do
# its job, which is worth a WARN unless the repository chose that.
triage_check() {
  local id='cc-codex-triage@cc-codex-triage' what review why opted=0 label
  what="$(needed_by "$id")"
  review="$(bash "$COMPANION" review "$REPO_ROOT")"; why="$(bash "$COMPANION" why "$REPO_ROOT")"
  bash "$COMPANION" optout "$REPO_ROOT" >/dev/null 2>&1 && opted=1
  state_of "$id"
  case "$ST" in
    installed)
      if [ -z "$review" ]; then ok "$id $FOUND — $what"
      elif [ "$opted" -eq 1 ]; then say "     $id $FOUND — installed, $why; specs use review: $review"
      else warn "$id $FOUND — installed, but $why: the review bridge cannot run (specs use review: $review)"
      fi ;;
    disabled|absent)
      if [ -n "$review" ]; then
        label="not installed"; [ "$ST" = disabled ] && label="disabled"
        say "     $id $label — optional, $why (specs use review: $review)"
      else
        companion "$id"
      fi ;;
    *) warn "$id — could not determine which installation applies; $what" ;;
  esac
}

if ! command -v jq >/dev/null 2>&1; then
  # Named as the reason because the list may be perfectly readable: reporting "could not list" here
  # sent people to debug `claude plugin list` when the only thing missing was jq.
  warn "companion plugin checks skipped — jq is not installed, so this cannot read the plugin list (install: https://jqlang.github.io/jq/download/); the SessionStart plan restore is off without it too"
elif [ -z "$PLUGIN_LIST" ]; then
  warn "could not list installed plugins — companion plugin checks skipped"
else
  companion 'mattpocock-skills@mattpocock'
  # The engineering skills expect the issue tracker to "have been provided": docs/agents/ holds the
  # config, and the instructions the session loads have to name it. Files nobody points at leave
  # code-review asking for /setup-matt-pocock-skills on every run. Repo config needs a repo.
  if [ -n "$REPO_ROOT" ] && { state_of 'mattpocock-skills@mattpocock'; [ "$ST" = installed ]; }; then
    if [ ! -f "$REPO_ROOT/docs/agents/issue-tracker.md" ]; then
      warn "mattpocock-skills not configured for this repo (no docs/agents/issue-tracker.md) — run /setup-matt-pocock-skills once"
    else
      CLAUDE_FILES="$(launch_files claude)" AGENTS_FILES="$(launch_files agents)"
      if [ -n "$CLAUDE_FILES" ]; then FIRST="${CLAUDE_FILES%%$'\n'*}"; else FIRST="$REPO_ROOT/AGENTS.md"; fi
      if printf '%s\n' "${CLAUDE_FILES:-$AGENTS_FILES}" | names_pointer || launch_files rules | names_pointer; then
        :
      elif [ -n "$CLAUDE_FILES" ] && printf '%s\n' "$AGENTS_FILES" | names_pointer; then
        warn "docs/agents pointer not loaded: AGENTS.md names it, but $FIRST switches native AGENTS.md loading off — unless that file @-imports AGENTS.md, move the '## Agent skills' block into it"
      else
        warn "docs/agents pointer not found: no CLAUDE/AGENTS file on this path and no .claude/rules file without paths: names docs/agents (doctor does not follow @-imports; ignore this if an imported file carries it) — add the '## Agent skills' block /setup-matt-pocock-skills writes to $FIRST"
      fi
    fi
  fi
  triage_check
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
  # Presence alone reported "ok" for rules three releases old. The first line carries the version of
  # the template the rule was installed from, so compare the whole file and name both versions.
  TF_RULE="$REPO_ROOT/.claude/rules/task-flow.md"
  TF_TEMPLATE="$(cd "$(dirname "$0")/../../assets/task-flow" && pwd)/rule.template.md"
  tf_version() { head -n 1 "$1" 2>/dev/null | sed -n 's/.*cc-tuner:task-flow \(v[0-9][0-9.]*\).*/\1/p'; }
  if [ ! -f "$TF_RULE" ]; then
    warn "task-flow rule not installed here — /cc-tuner:setup install task-flow"
  elif [ ! -f "$TF_TEMPLATE" ]; then
    ok "task-flow rule installed (plugin template not found, version not compared)"
  elif [ "$(cat "$TF_RULE")" = "$(cat "$TF_TEMPLATE")" ]; then
    ok "task-flow rule installed and current"
  else
    warn "task-flow rule $(tf_version "$TF_RULE") differs from the plugin's $(tf_version "$TF_TEMPLATE") — /cc-tuner:setup install task-flow (task-flow.local.md is kept)"
  fi
  [ -f "$REPO_ROOT/.claude/rules/git-flow.md" ] \
    && warn "legacy git-flow.md still present — /cc-tuner:setup install task-flow migrates it (keeps your cached board field IDs)"
  # Verification is a stage of /run (cc-tuner:verify-feature), not a per-repo opt-in any more, so
  # there is nothing to report here. What still helps is knowing whether anything can drive a browser,
  # because that is the instrument a UI criterion needs and its absence changes what a run can prove.
  [ -f "$REPO_ROOT/.claude/smoke-verify.cfg" ] \
    && warn "leftover .claude/smoke-verify.cfg — the Stop-hook gate it opted into was removed; verification is now a stage of /run (cc-tuner:verify-feature). Delete the file and .claude/smoke-verify/"
else
  warn "not inside a git repository — repo-level checks skipped"
fi

# --- 6. user-level statusline --------------------------------------------------------------------
if [ -f "$UHOME/.claude/cc-tuner-statusline.sh" ]; then
  ok "statusline script installed"
else
  say "     statusline not installed (optional — /cc-tuner:setup install statusline)"
fi

say ""
if [ "$miss" -eq 0 ]; then
  say "doctor: no blockers"
else
  say "doctor: blockers found (see MISS lines)"
fi
exit "$miss"
