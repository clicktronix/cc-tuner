#!/usr/bin/env bash
# prereq-check.sh and the resolver it shares with doctor.sh.
#
# The fixture is a fake `claude plugin list --json`, injected through CC_TUNER_PLUGIN_LIST_CMD, which
# is the seam the product itself reads. The previous version of this suite built a fake $HOME and
# hand-wrote installed_plugins.json, because that is what the script parsed; nothing does that any
# more, and a test that kept doing it would be exercising a route the product no longer has.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../../scripts/setup/prereq-check.sh"
RESOLVER="$HERE/../../scripts/setup/plugin-here.sh"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=1; }

W="$(mktemp -d)" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$W"' EXIT
# The fixture is delivered as `cat <file>`, and the product expands that command unquoted -- which is
# how a real `claude plugin list --json` gets its arguments. So a space in the path would split into
# two words and the suite would fail for a reason that has nothing to do with the code under test.
case "$W" in *[[:space:]]*) echo "FATAL: temp dir contains a space: $W"; exit 1 ;; esac
PROJECT="$W/project"; mkdir -p "$PROJECT"; PROJECT="$(cd "$PROJECT" && pwd -P)"

matt_root() {  # matt_root <dir> [skill to omit]
  local r="$W/$1"; shift
  local omit="${1:-}" s
  for s in productivity/grilling engineering/domain-modeling engineering/code-review; do
    [ "$s" != "$omit" ] || continue
    mkdir -p "$r/skills/$s"; touch "$r/skills/$s/SKILL.md"
  done
  printf '%s' "$r"
}

codex_root() {  # codex_root <dir> [broken: review|state]
  local r="$W/$1"; shift
  local broken="${1:-}"
  mkdir -p "$r/commands" "$r/scripts"
  if [ "$broken" = "review" ]; then printf 'legacy review command\n' > "$r/commands/review.md"
  else printf '%s\n' '--required' 'CC_CODEX_REQUIRED_REVIEW APPROVE' > "$r/commands/review.md"; fi
  if [ "$broken" = "state" ]; then printf 'legacy review state\n' > "$r/scripts/review-state.sh"
  else printf 'CC_CODEX_REQUIRED_REVIEW APPROVE\n' > "$r/scripts/review-state.sh"; fi
  printf '%s' "$r"
}

# as_list <json> -> a command string that prints it, standing in for `claude plugin list --json`
n=0
as_list() { n=$((n + 1)); printf '%s' "$1" > "$W/list.$n.json"; printf 'cat %s' "$W/list.$n.json"; }

run_with() { CC_TUNER_PLUGIN_LIST_CMD="$(as_list "$1")" \
             CLAUDE_PROJECT_DIR="$PROJECT" bash "$S" 2>&1; }

rows() {  # rows <matt-root> <codex-root> [scope] [projectPath]
  jq -nc --arg m "$1" --arg c "$2" --arg scope "${3:-user}" --arg pp "${4:-}" '
    [ {id:"mattpocock-skills@mattpocock", version:"1.0.0", scope:$scope, enabled:true, installPath:$m},
      {id:"cc-codex-triage@cc-codex-triage", version:"1.0.0", scope:$scope, enabled:true, installPath:$c} ]
    | if $pp == "" then . else map(. + {projectPath:$pp}) end'
}

M="$(matt_root matt)"; C="$(codex_root codex)"

# --- the positive path, first: a suite of refusals passes if the script refuses everything --------
OUT="$(run_with "$(rows "$M" "$C")")"
case "$OUT" in *"prereqs OK"*) pass "all-present" ;; *) fail "all-present ($OUT)" ;; esac

# --- each dependency, missing on its own ----------------------------------------------------------
OUT="$(run_with "$(rows "$W/nope" "$C")")"
case "$OUT" in *mattpocock-skills*) pass "mp-missing" ;; *) fail "mp-missing ($OUT)" ;; esac

OUT="$(run_with "$(rows "$(matt_root matt-nocr engineering/code-review)" "$C")")"
case "$OUT" in *code-review*) pass "mp-codereview-missing" ;; *) fail "mp-codereview-missing ($OUT)" ;; esac

OUT="$(run_with "$(rows "$(matt_root matt-nodm engineering/domain-modeling)" "$C")")"
case "$OUT" in *domain-modeling*) pass "mp-domain-modeling-missing" ;; *) fail "mp-domain-modeling-missing ($OUT)" ;; esac

OUT="$(run_with "$(rows "$M" "$W/nope")")"
case "$OUT" in *cc-codex-triage*) pass "cct-missing" ;; *) fail "cct-missing ($OUT)" ;; esac

# --- presence is not the contract -----------------------------------------------------------------
OUT="$(run_with "$(rows "$M" "$(codex_root codex-oldcmd review)")")"
case "$OUT" in *--required*) pass "cct-required-review-missing" ;; *) fail "cct-required-review-missing ($OUT)" ;; esac

OUT="$(run_with "$(rows "$M" "$(codex_root codex-oldstate state)")")"
case "$OUT" in *--required*) pass "cct-required-state-missing" ;; *) fail "cct-required-state-missing ($OUT)" ;; esac

# --- enabled: false. The divergence this migration closed -----------------------------------------
# doctor.sh skipped disabled installs; the hand-rolled manifest walk this script used did not. A
# disabled plugin does not load its commands, so the preflight passed and then the run reached a gate
# that could never fire.
DISABLED="$(jq -nc --arg m "$M" --arg c "$C" '
  [ {id:"mattpocock-skills@mattpocock", version:"1.0.0", scope:"user", enabled:false, installPath:$m},
    {id:"cc-codex-triage@cc-codex-triage", version:"1.0.0", scope:"user", enabled:true, installPath:$c} ]')"
OUT="$(run_with "$DISABLED")"
case "$OUT" in *mattpocock-skills*) pass "disabled-plugin-is-not-installed" ;;
               *) fail "disabled-plugin-is-not-installed ($OUT)" ;; esac

# --- scope ----------------------------------------------------------------------------------------
OUT="$(run_with "$(rows "$M" "$C" project "$PROJECT")")"
case "$OUT" in *"prereqs OK"*) pass "matching-project-scope-passes" ;; *) fail "matching-project-scope-passes ($OUT)" ;; esac

OUT="$(run_with "$(rows "$M" "$C" project /definitely/another/project)")"
case "$OUT" in *mattpocock-skills*) pass "foreign-project-scope-fails-closed" ;;
               *) fail "foreign-project-scope-fails-closed ($OUT)" ;; esac

# --- unanswerable is its own answer ---------------------------------------------------------------
# Reporting "not installed" when the real problem is a missing jq sends someone to reinstall a plugin
# they already have.
OUT="$(CC_TUNER_PLUGIN_LIST_CMD=false CLAUDE_PROJECT_DIR="$PROJECT" bash "$S" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && case "$OUT" in *"prerequisites are unknown"*) true ;; *) false ;; esac; } \
  && pass "unlistable-is-reported-as-unknown" || fail "unlistable-is-reported-as-unknown (rc=$rc $OUT)"

# superpowers is NOT required: a list with none of it must still pass. The regression guarded against
# is someone re-adding the check because the plugin is installed on their own machine.
OUT="$(run_with "$(rows "$M" "$C")")"
case "$OUT" in *[Ss]uperpowers*) fail "superpowers-not-required ($OUT)" ;; *) pass "superpowers-not-required" ;; esac

# --- the resolver itself --------------------------------------------------------------------------
# Its three outcomes must stay distinguishable: rows, none, and cannot-answer. Collapsing the last
# two is what makes a broken environment look like an uninstalled plugin.
r() { CC_TUNER_PLUGIN_LIST_CMD="$(as_list "$1")" bash "$RESOLVER" "$2" "$PROJECT" 2>/dev/null; }
OUT="$(r "$(rows "$M" "$C")" 'mattpocock-skills@mattpocock')"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$OUT" = "$(printf '%s\t1.0.0\tuser' "$M")" ]; } \
  && pass "resolver-emits-path-version-scope" || fail "resolver-emits-path-version-scope (rc=$rc '$OUT')"

r "$(rows "$M" "$C")" 'nothing@nowhere' >/dev/null 2>&1
[ $? -eq 1 ] && pass "resolver-absent-is-rc1" || fail "resolver-absent-is-rc1"

CC_TUNER_PLUGIN_LIST_CMD=false bash "$RESOLVER" 'x@y' "$PROJECT" >/dev/null 2>&1
[ $? -eq 2 ] && pass "resolver-unanswerable-is-rc2" || fail "resolver-unanswerable-is-rc2"

# Precedence: local beats project beats user, and list order must not decide it. Emitted worst-first
# here on purpose -- a resolver that returned the list as given would pass every other case.
ORDERED="$(jq -nc --arg pp "$PROJECT" '
  [ {id:"p@p", version:"3", scope:"user",    enabled:true, installPath:"/u"},
    {id:"p@p", version:"2", scope:"project", enabled:true, installPath:"/p", projectPath:$pp},
    {id:"p@p", version:"1", scope:"local",   enabled:true, installPath:"/l", projectPath:$pp} ]')"
OUT="$(r "$ORDERED" 'p@p' | cut -f3 | tr '\n' ',')"
[ "$OUT" = "local,project,user," ] \
  && pass "resolver-total-order" || fail "resolver-total-order (got '$OUT')"

exit $fails
