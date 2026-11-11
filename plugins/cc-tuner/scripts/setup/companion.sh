#!/usr/bin/env bash
# The facts about the companion plugins cc-tuner depends on, in one place.
#
#   companion.sh table [plugin-id]
#   companion.sh codex
#   companion.sh review [repo-root]
#   companion.sh why [repo-root]
#   companion.sh optout [repo-root]
#   companion.sh state <plugin-id> [repo-root]
#   companion.sh hint  <plugin-id> [repo-root]
#
#   table   TSV, one row per companion: <id> <marketplace> <source> <needed-by>.
#   codex   ready | nologin | absent: `codex` on PATH, and `codex login status` exits 0.
#   review  `none:<reason>` (exit 0) when this repository has no Codex review bridge, else exit 1 and
#           nothing. The reason is the recorded opt-out when there is one, otherwise
#           `codex-not-installed` or `codex-not-logged-in`. This is the value a spec carries as
#           `review: none:<reason>`.
#   why     the same answer as one sentence for a person, empty when the bridge is on.
#   optout  the reason this repository recorded for declining Codex review, exit 0; exit 1 when it did
#           not. Recorded as one line, `cc-tuner-review: none:<reason>`, in
#           <repo>/.claude/rules/task-flow.local.md (the last such line wins).
#   state   installed | disabled | absent | unknown, with `<TAB><version><TAB><scope>` after the first
#           two; exit 0, 0, 1, 2. Asked of plugin-here.sh --with-disabled, so the scope and project
#           rules are the resolver's own.
#   hint    the one command that fixes the state, in `/plugin` form: `/plugin enable <id>` for a
#           disabled copy; `/plugin install <id>` when the marketplace is configured from the expected
#           repository; `/plugin marketplace add <source> && /plugin install <id>` when it is not
#           configured at all. Nothing for an installed plugin. A marketplace of that name configured
#           from a DIFFERENT repository is exit 3 with `CONFLICT: ...` on stderr and nothing on stdout.
#
# Exit 2 on a usage error or when the question cannot be answered (no `jq`, no plugin list).
#
# **One owner, and that is the whole point.** The companion table (id, marketplace, source), the codex
# test with its two reason strings, the opt-out and the install hint were restated in doctor.sh,
# prereq-check.sh and the setup node's prose, and the copies had already diverged: the node's
# marketplace test matched a marketplace by name only, so a same-named marketplace from another
# repository got a one-yes, user-scope install of whatever it carried. A marketplace counts as
# configured only when its name AND its repo match; a name match from another repo is a stop that
# names both sources, not an install.
#
# An unreadable marketplace list counts as "not configured": the add step is the safe one to repeat.
# `marketplace update` and `plugin update` presuppose both a marketplace and an install, so offering
# them to someone with neither fails naming a marketplace they never added.
#
# Seams: CC_TUNER_PLUGIN_LIST_CMD (read by plugin-here.sh) and CC_TUNER_MARKETPLACE_LIST_CMD (default
# `claude plugin marketplace list --json`) stand in for the real commands in tests.
# Only bash, git, jq, grep, sed and head: doctor runs this on a minimal PATH. bash 3.2 compatible:
# macOS ships 3.2.57.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TAB="$(printf '\t')"

table() {
  printf '%s\t%s\t%s\t%s\n' \
    'mattpocock-skills@mattpocock' 'mattpocock' 'mattpocock/skills' \
    'grilling + domain-modeling + codebase-design in /cc-tuner:spec; pr, code-review + diagnosing-bugs in /cc-tuner:run'
  printf '%s\t%s\t%s\t%s\n' \
    'cc-codex-triage@cc-codex-triage' 'cc-codex-triage' 'clicktronix/cc-codex-triage' \
    'required-review gate in /cc-tuner:run'
}

# col <plugin-id> <1-4> -> that column of the id's table row; empty when the id is not a companion.
col() {
  local row rest f i
  while IFS= read -r row; do
    [ "${row%%$TAB*}" = "$1" ] || continue
    rest="$row"; i=1
    while [ "$i" -lt "$2" ]; do rest="${rest#*$TAB}"; i=$((i + 1)); done
    f="${rest%%$TAB*}"
    printf '%s' "$f"
    return 0
  done <<EOF
$(table)
EOF
  return 1
}

usage() { printf 'companion: usage: companion.sh table|codex|review|why|optout [repo-root] | state|hint <plugin-id> [repo-root] | commands <plugin-id>\n' >&2; exit 2; }

root_of() { # root_of [repo-root]
  local r="${1:-}"
  if [ -z "$r" ]; then
    r="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$r" ] || r="$PWD"
  fi
  printf '%s' "$r"
}

codex_state() {
  command -v codex >/dev/null 2>&1 || { echo absent; return; }
  if codex login status >/dev/null 2>&1; then echo ready; else echo nologin; fi
}

optout_reason() { # optout_reason <repo-root> -> the recorded reason, rc 0; rc 1 when none
  local f="$1/.claude/rules/task-flow.local.md" line
  [ -f "$f" ] || return 1
  line="$(grep '^cc-tuner-review: none:.' "$f" 2>/dev/null | sed -n '$p' | sed 's/[[:space:]]*$//')"
  [ -n "$line" ] || return 1
  printf '%s' "${line#cc-tuner-review: none:}"
}

cmd_review() { # review <repo-root>; $2 = reason | sentence
  local reason
  if reason="$(optout_reason "$1")"; then
    if [ "$2" = reason ]; then printf 'none:%s\n' "$reason"; else printf 'this repository opted out of Codex review (%s)\n' "$reason"; fi
    return 0
  fi
  case "$(codex_state)" in
    absent)  if [ "$2" = reason ]; then echo 'none:codex-not-installed'; else echo 'codex is not on PATH'; fi ;;
    nologin) if [ "$2" = reason ]; then echo 'none:codex-not-logged-in'; else echo 'codex is not logged in (run: codex login)'; fi ;;
    *) return 1 ;;
  esac
}

cmd_state() { # state <id> <repo-root>
  local row rc rest
  [ -n "$(col "$1" 2)" ] || { printf 'companion: %s is not a companion plugin\n' "$1" >&2; exit 2; }
  row="$(bash "$HERE/plugin-here.sh" --with-disabled "$1" "$2" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) ;;
    1) echo absent; return 1 ;;
    *) echo unknown; return 2 ;;
  esac
  # path <TAB> version <TAB> scope <TAB> enabled|disabled. Parameter expansion, not `read` with a tab
  # IFS, which collapses an empty installPath and shifts every column left.
  rest="${row#*$TAB}"
  local ver="${rest%%$TAB*}"; rest="${rest#*$TAB}"
  local scope="${rest%%$TAB*}" en="${rest#*$TAB}"
  if [ "$en" = disabled ]; then
    printf 'disabled\t%s\t%s\n' "$ver" "$scope"
  else
    printf 'installed\t%s\t%s\n' "$ver" "$scope"
  fi
  return 0
}

cmd_hint() { # hint <id> <repo-root>
  local id="$1" mkt src st repo mkts
  mkt="$(col "$id" 2)"; src="$(col "$id" 3)"
  [ -n "$mkt" ] || { printf 'companion: %s is not a companion plugin\n' "$id" >&2; exit 2; }
  st="$(cmd_state "$id" "$2")"
  case "${st%%$TAB*}" in
    installed) return 0 ;;
    disabled) printf '/plugin enable %s\n' "$id"; return 0 ;;
    unknown) exit 2 ;;
  esac
  mkts="$(${CC_TUNER_MARKETPLACE_LIST_CMD:-claude plugin marketplace list --json} 2>/dev/null)" || mkts=""
  # A marketplace added by URL is stored with `url`, not `repo`: a GitHub URL of the expected repository
  # (https, ssh:// or scp-like, with or without .git) is the same source; any other host or path is not.
  if printf '%s' "$mkts" | jq -e --arg n "$mkt" --arg s "$src" '
       def slug: if (.repo // "") != "" then .repo
         else [ (.url // "") | capture("^(?:(?:https?|ssh|git)://(?:[^@/]+@)?github\\.com(?::[0-9]+)?/|(?:[^@/:]+@)?github\\.com:)(?<s>[^/]+/[^/]+?)(?:\\.git)?/?$").s ][0] // "" end;
       any(.[]?; .name == $n and (slug | ascii_downcase) == ($s | ascii_downcase))' >/dev/null 2>&1; then
    printf '/plugin install %s\n' "$id"
  elif printf '%s' "$mkts" | jq -e --arg n "$mkt" 'any(.[]?; .name == $n)' >/dev/null 2>&1; then
    repo="$(printf '%s' "$mkts" | jq -r --arg n "$mkt" \
      '[ .[]? | select(.name == $n) ][0] | (.repo // .url // .path // "an unknown source")' 2>/dev/null)"
    printf 'CONFLICT: marketplace %s is configured from %s, expected %s — remove it or install by hand\n' \
      "$mkt" "$repo" "$src" >&2
    exit 3
  else
    printf '/plugin marketplace add %s && /plugin install %s\n' "$src" "$id"
  fi
}

SUB="${1:-}"
[ -n "$SUB" ] || usage
shift

case "$SUB" in
  table)
    if [ -n "${1:-}" ]; then
      table | grep -F -- "$1$TAB" | head -n 1
    else
      table
    fi ;;
  codex)  codex_state ;;
  commands) # commands <id>: the slash commands from the table alone, for a session with no `claude` CLI to ask
    [ -n "${1:-}" ] || usage
    mkt="$(col "$1" 2)"; src="$(col "$1" 3)"
    [ -n "$mkt" ] || { printf 'companion: %s is not a companion plugin\n' "$1" >&2; exit 2; }
    printf '/plugin marketplace add %s\n/plugin install %s\n' "$src" "$1" ;;
  review) cmd_review "$(root_of "${1:-}")" reason ;;
  why)    cmd_review "$(root_of "${1:-}")" sentence; exit 0 ;;
  optout) r="$(optout_reason "$(root_of "${1:-}")")" || exit 1; printf '%s\n' "$r" ;;
  state)
    [ -n "${1:-}" ] || usage
    command -v jq >/dev/null 2>&1 || { printf 'companion: jq is required\n' >&2; echo unknown; exit 2; }
    cmd_state "$1" "$(root_of "${2:-}")"; exit $? ;;
  hint)
    [ -n "${1:-}" ] || usage
    command -v jq >/dev/null 2>&1 || { printf 'companion: jq is required\n' >&2; exit 2; }
    cmd_hint "$1" "$(root_of "${2:-}")" ;;
  *) usage ;;
esac
