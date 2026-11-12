#!/usr/bin/env bash
# Tests for scripts/setup/companion.sh, the one owner of the companion-plugin facts: the table, the
# codex state, the Codex opt-out, the install state of a plugin and the command that fixes it.
#
# Every case drives the real program through its seams. The plugin list and the marketplace list are
# fixtures in the shape the real `claude plugin list --json` and `claude plugin marketplace list --json`
# print, and `codex` is a stub on an isolated PATH, so nothing here depends on the developer's machine.
set -u
COMPANION="$(cd "$(dirname "$0")/../../scripts/setup" && pwd)/companion.sh"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=1; }
eq() { # eq <name> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}

W="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$W"' EXIT
case "$W" in *[[:space:]]*) echo "FATAL: temp dir contains a space: $W"; exit 1 ;; esac
REPO="$W/repo"; mkdir -p "$REPO/.claude/rules"; REPO="$(cd "$REPO" && pwd -P)"
TAB="$(printf '\t')"
MATT='mattpocock-skills@mattpocock'
CT='cc-codex-triage@cc-codex-triage'

# PATH with the utilities companion.sh uses and no codex; BIN_IN / BIN_OUT put a logged-in / logged-out
# codex in front of it.
NOCODEX="$W/nocodex"; mkdir -p "$NOCODEX"
for u in bash git jq grep sed head dirname cat tr; do ln -s "$(command -v "$u")" "$NOCODEX/$u"; done
mkcodex() { mkdir -p "$W/$1"; printf '#!/bin/sh\nif [ "$1" = login ]; then\n  exit %s\nfi\nexit 0\n' "$2" > "$W/$1/codex"; chmod +x "$W/$1/codex"; }
mkcodex codex-in 0; mkcodex codex-out 1

# A fixture command: `cat <file>`. Called inside $( ), so a counter would not survive; mktemp does.
as_json() { local f; f="$(mktemp "$W/j.XXXXXX")"; printf '%s' "$1" > "$f"; printf 'cat %s' "$f"; }
MKT_NONE="$(as_json '[]')"
MKT_MATT="$(as_json '[{"installLocation":"/x/mattpocock","name":"mattpocock","repo":"mattpocock/skills","source":"github"}]')"
MKT_CT="$(as_json '[{"installLocation":"/x/ct","name":"cc-codex-triage","repo":"clicktronix/cc-codex-triage","source":"github"}]')"
MKT_MATT_FORK="$(as_json '[{"installLocation":"/x/mattpocock","name":"mattpocock","repo":"someone-else/skills","source":"github"}]')"
MKT_MATT_UPPER="$(as_json '[{"installLocation":"/x/mattpocock","name":"mattpocock","repo":"MattPocock/Skills","source":"github"}]')"
MKT_OTHER_NAME="$(as_json '[{"installLocation":"/x/o","name":"another","repo":"mattpocock/skills","source":"github"}]')"

# comp <PATH> <plugin list cmd> <marketplace list cmd> <args...>: stdout, stderr and rc land in
# $OUT, $ERR and $RC.
comp() {
  local p="$1" pl="$2" ml="$3"; shift 3
  OUT="$(CC_TUNER_PLUGIN_LIST_CMD="$pl" CC_TUNER_MARKETPLACE_LIST_CMD="$ml" PATH="$p" /bin/bash "$COMPANION" "$@" 2>"$W/err")"
  RC=$?; ERR="$(cat "$W/err")"
}
LIST_NONE="$(as_json '[]')"

# --- table: the only place these strings live ------------------------------------------------------
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" table
eq "table-rc0" 0 "$RC"
eq "table-two-rows" 2 "$(printf '%s\n' "$OUT" | grep -c .)"
case "$OUT" in *"$MATT${TAB}mattpocock${TAB}mattpocock/skills${TAB}"*) pass "table-matt-row" ;; *) fail "table-matt-row ($OUT)" ;; esac
case "$OUT" in *"$CT${TAB}cc-codex-triage${TAB}clicktronix/cc-codex-triage${TAB}"*) pass "table-triage-row" ;; *) fail "table-triage-row ($OUT)" ;; esac
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" table "$CT"
eq "table-one-id-one-row" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
case "$OUT" in "$CT${TAB}"*) pass "table-one-id-is-that-id" ;; *) fail "table-one-id-is-that-id ($OUT)" ;; esac

# --- codex: ready | nologin | absent --------------------------------------------------------------
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" codex;                          eq "codex-absent" absent "$OUT"
comp "$W/codex-in:$NOCODEX" "$LIST_NONE" "$MKT_NONE" codex;              eq "codex-ready" ready "$OUT"
comp "$W/codex-out:$NOCODEX" "$LIST_NONE" "$MKT_NONE" codex;             eq "codex-nologin" nologin "$OUT"
eq "codex-nologin-rc0" 0 "$RC"

# --- optout: recorded in task-flow.local.md ---------------------------------------------------------
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" optout "$REPO"
eq "optout-no-file-is-rc1" 1 "$RC"; eq "optout-no-file-prints-nothing" "" "$OUT"
printf '# local\nboard: none\n' > "$REPO/.claude/rules/task-flow.local.md"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" optout "$REPO"
eq "optout-no-line-is-rc1" 1 "$RC"
printf 'text cc-tuner-review: none:not-a-line-start\n' >> "$REPO/.claude/rules/task-flow.local.md"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" optout "$REPO"
eq "optout-mid-line-does-not-count" 1 "$RC"
printf 'cc-tuner-review: none:declined-in-setup\n' >> "$REPO/.claude/rules/task-flow.local.md"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" optout "$REPO"
eq "optout-present-is-rc0" 0 "$RC"; eq "optout-prints-the-reason" "declined-in-setup" "$OUT"
printf 'cc-tuner-review: none:later-reason\n' >> "$REPO/.claude/rules/task-flow.local.md"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" optout "$REPO"
eq "optout-last-line-wins" "later-reason" "$OUT"
# a repository root defaults to the working directory's repository
OUT="$(cd "$REPO" && git init -q -b main 2>/dev/null; cd "$REPO" && PATH="$NOCODEX" /bin/bash "$COMPANION" optout)"
eq "optout-defaults-to-the-current-repo" "later-reason" "$OUT"

# --- review / why: the value a spec carries --------------------------------------------------------
OTHER="$W/other"; mkdir -p "$OTHER"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" review "$OTHER"
eq "review-codex-absent" "none:codex-not-installed" "$OUT"
comp "$W/codex-out:$NOCODEX" "$LIST_NONE" "$MKT_NONE" review "$OTHER"
eq "review-codex-not-logged-in" "none:codex-not-logged-in" "$OUT"
comp "$W/codex-out:$NOCODEX" "$LIST_NONE" "$MKT_NONE" why "$OTHER"
case "$OUT" in *"codex login"*) pass "why-not-logged-in-names-login" ;; *) fail "why-not-logged-in-names-login ($OUT)" ;; esac
comp "$W/codex-in:$NOCODEX" "$LIST_NONE" "$MKT_NONE" review "$OTHER"
eq "review-codex-ready-is-rc1" 1 "$RC"; eq "review-codex-ready-prints-nothing" "" "$OUT"
comp "$W/codex-in:$NOCODEX" "$LIST_NONE" "$MKT_NONE" why "$OTHER"
eq "why-codex-ready-prints-nothing" "" "$OUT"
comp "$W/codex-in:$NOCODEX" "$LIST_NONE" "$MKT_NONE" review "$REPO"
eq "review-optout-wins-over-ready-codex" "none:later-reason" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" review "$REPO"
eq "review-optout-wins-over-absent-codex" "none:later-reason" "$OUT"
comp "$W/codex-in:$NOCODEX" "$LIST_NONE" "$MKT_NONE" why "$REPO"
case "$OUT" in *"opted out"*"later-reason"*) pass "why-optout-names-the-reason" ;; *) fail "why-optout-names-the-reason ($OUT)" ;; esac

# --- state --------------------------------------------------------------------------------------------
list() { jq -nc --arg id "$MATT" --arg pp "$REPO" "$1"; }
INST="$(as_json "$(list '[{id:$id,version:"1.0.0",scope:"user",enabled:true,installPath:"/p"}]')")"
comp "$NOCODEX" "$INST" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-installed" "installed${TAB}1.0.0${TAB}user" "$OUT"; eq "state-installed-rc0" 0 "$RC"

comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-absent" absent "$OUT"; eq "state-absent-rc1" 1 "$RC"

DIS="$(as_json "$(list '[{id:$id,version:"2.0.0",scope:"user",enabled:false,installPath:"/p"}]')")"
comp "$NOCODEX" "$DIS" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-disabled" "disabled${TAB}2.0.0${TAB}user" "$OUT"; eq "state-disabled-rc0" 0 "$RC"

# A disabled project install belonging to ANOTHER project is not this repository's to enable.
FOREIGN="$(as_json "$(list '[{id:$id,version:"2.0.0",scope:"project",enabled:false,installPath:"/p",projectPath:"/somewhere/else"}]')")"
comp "$NOCODEX" "$FOREIGN" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-foreign-disabled-is-absent" absent "$OUT"
comp "$NOCODEX" "$FOREIGN" "$MKT_NONE" hint "$MATT" "$REPO"
case "$OUT" in *"/plugin enable"*) fail "hint-foreign-disabled-no-enable ($OUT)" ;; *) pass "hint-foreign-disabled-no-enable" ;; esac

# A disabled install scoped to THIS project counts.
HERE_DIS="$(as_json "$(list '[{id:$id,version:"2.0.0",scope:"project",enabled:false,installPath:"/p",projectPath:$pp}]')")"
comp "$NOCODEX" "$HERE_DIS" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-disabled-here-scope" "disabled${TAB}2.0.0${TAB}project" "$OUT"

# An applicable enabled install answers as installed even beside a disabled one: the mode never
# disagrees with plugin-here.sh without the flag about whether the plugin is installed.
BOTH="$(as_json "$(list '[{id:$id,version:"2.0.0",scope:"project",enabled:false,installPath:"/p",projectPath:$pp},{id:$id,version:"1.0.0",scope:"user",enabled:true,installPath:"/q"}]')")"
comp "$NOCODEX" "$BOTH" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-enabled-install-beats-disabled" "installed${TAB}1.0.0${TAB}user" "$OUT"

comp "$NOCODEX" "false" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-unlistable-is-unknown" unknown "$OUT"; eq "state-unlistable-rc2" 2 "$RC"
BADJSON="$(as_json '{not-json')"
comp "$NOCODEX" "$BADJSON" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-unparsable-is-unknown" unknown "$OUT"; eq "state-unparsable-rc2" 2 "$RC"
NOJQ="$W/nojq"; mkdir -p "$NOJQ"; for u in bash git grep sed head dirname cat tr; do ln -s "$(command -v "$u")" "$NOJQ/$u"; done
comp "$NOJQ" "$INST" "$MKT_NONE" state "$MATT" "$REPO"
eq "state-no-jq-is-unknown" unknown "$OUT"; eq "state-no-jq-rc2" 2 "$RC"
comp "$NOCODEX" "$INST" "$MKT_NONE" state "not-a-companion@x" "$REPO"
eq "state-unknown-id-rc2" 2 "$RC"

# --- hint -----------------------------------------------------------------------------------------------
comp "$NOCODEX" "$INST" "$MKT_NONE" hint "$MATT" "$REPO"
eq "hint-installed-is-silent" "" "$OUT"; eq "hint-installed-rc0" 0 "$RC"
comp "$NOCODEX" "$DIS" "$MKT_NONE" hint "$MATT" "$REPO"
eq "hint-disabled-enables" "/plugin enable $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" hint "$MATT" "$REPO"
eq "hint-no-marketplace-adds" "/plugin marketplace add mattpocock/skills && /plugin install $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" hint "$CT" "$REPO"
eq "hint-triage-no-marketplace-adds" "/plugin marketplace add clicktronix/cc-codex-triage && /plugin install $CT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_MATT" hint "$MATT" "$REPO"
eq "hint-configured-installs" "/plugin install $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_CT" hint "$CT" "$REPO"
eq "hint-triage-configured-installs" "/plugin install $CT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_MATT_UPPER" hint "$MATT" "$REPO"
eq "hint-repo-match-ignores-case" "/plugin install $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$MKT_OTHER_NAME" hint "$MATT" "$REPO"
eq "hint-other-marketplace-name-still-adds" "/plugin marketplace add mattpocock/skills && /plugin install $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "false" hint "$MATT" "$REPO"
eq "hint-unreadable-marketplace-list-adds" "/plugin marketplace add mattpocock/skills && /plugin install $MATT" "$OUT"
comp "$NOCODEX" "$LIST_NONE" "$(as_json '{not-json')" hint "$MATT" "$REPO"
eq "hint-unparsable-marketplace-list-adds" "/plugin marketplace add mattpocock/skills && /plugin install $MATT" "$OUT"

# Same marketplace name, another repository: a stop that names both sources, and nothing on stdout.
comp "$NOCODEX" "$LIST_NONE" "$MKT_MATT_FORK" hint "$MATT" "$REPO"
eq "hint-conflict-rc3" 3 "$RC"
eq "hint-conflict-stdout-empty" "" "$OUT"
case "$ERR" in "CONFLICT: marketplace mattpocock is configured from someone-else/skills, expected mattpocock/skills"*) pass "hint-conflict-names-both-sources" ;;
               *) fail "hint-conflict-names-both-sources ($ERR)" ;; esac
case "$ERR" in *"remove it or install by hand"*) pass "hint-conflict-says-what-to-do" ;; *) fail "hint-conflict-says-what-to-do ($ERR)" ;; esac
# A marketplace row with no repo cannot be shown to match either.
comp "$NOCODEX" "$LIST_NONE" "$(as_json '[{"name":"mattpocock","source":"git","url":"https://example.com/skills.git"}]')" hint "$MATT" "$REPO"
eq "hint-conflict-without-repo-rc3" 3 "$RC"
case "$ERR" in *"https://example.com/skills.git"*) pass "hint-conflict-shows-url-source" ;; *) fail "hint-conflict-shows-url-source ($ERR)" ;; esac
# The expected GitHub repository added by URL is the same source, in any form the CLI stores.
for u in https://github.com/mattpocock/skills.git https://github.com/MattPocock/skills git@github.com:mattpocock/skills.git ssh://git@github.com/mattpocock/skills.git; do
  comp "$NOCODEX" "$LIST_NONE" "$(as_json '[{"name":"mattpocock","source":"git","url":"'"$u"'"}]')" hint "$MATT" "$REPO"
  eq "hint-github-url-is-the-expected-source ($u)" "/plugin install $MATT" "$OUT"
done
# Another repository, or the expected path on another host, stays a conflict.
for u in https://github.com/someone-else/skills.git https://evil.example/github.com/mattpocock/skills.git git@github.com.evil.example:mattpocock/skills.git 'https://evil.example?@github.com/mattpocock/skills.git' 'https://evil.example#@github.com/mattpocock/skills.git' 'https://github.com/mattpocock/skills.git?x=1'; do
  comp "$NOCODEX" "$LIST_NONE" "$(as_json '[{"name":"mattpocock","source":"git","url":"'"$u"'"}]')" hint "$MATT" "$REPO"
  eq "hint-foreign-url-conflicts ($u)" 3 "$RC"
done
# An installed or disabled plugin never reaches the marketplace question.
comp "$NOCODEX" "$INST" "$MKT_MATT_FORK" hint "$MATT" "$REPO"
eq "hint-installed-ignores-conflict" 0 "$RC"
comp "$NOCODEX" "$DIS" "$MKT_MATT_FORK" hint "$MATT" "$REPO"
eq "hint-disabled-ignores-conflict" "/plugin enable $MATT" "$OUT"

comp "$NOCODEX" "false" "$MKT_NONE" hint "$MATT" "$REPO"
eq "hint-unlistable-rc2" 2 "$RC"; eq "hint-unlistable-prints-nothing" "" "$OUT"

# --- usage ----------------------------------------------------------------------------------------------
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE"
eq "no-subcommand-rc2" 2 "$RC"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" frobnicate
eq "unknown-subcommand-rc2" 2 "$RC"
comp "$NOCODEX" "$LIST_NONE" "$MKT_NONE" state
eq "state-needs-an-id" 2 "$RC"

# No `claude` on PATH: the fixed commands come from the table alone, whatever is installed.
OUT="$(PATH=/usr/bin:/bin bash "$COMPANION" commands mattpocock-skills@mattpocock 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && echo "PASS commands-rc0" || { echo "FAIL commands-rc0 (rc=$rc $OUT)"; fails=1; }
[ "$OUT" = "/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock" ] && echo "PASS commands-from-the-table" || { echo "FAIL commands-from-the-table ($OUT)"; fails=1; }

exit $fails
